#!/usr/bin/env python3
"""Per-sitting metrics from Claude Code session transcripts.

Usage:
  tools/session_metrics.py                 # the most recent sitting in this project
  tools/session_metrics.py 0e751e19 65e8   # sittings by session-id prefix
  tools/session_metrics.py --all           # every retained sitting with 20+ main calls
  tools/session_metrics.py --since 2026-10-16T19:00 --until 2026-10-16T23:00 <id>
                                           # only records inside a window (UTC)

Per sitting it prints active time, model and effort per agent, output and thinking,
the main thread's average context and its context at the first code edit, the
nested-copy share, and token weight.

Definitions (the session workflow assessment's, D-363):
  active      wall clock minus every gap of 10 minutes or more between records
  context     input + cache read + cache write tokens of one model call
  weight      API-equivalent tokens: input 1x, cache read 0.1x, cache write 1.25x (5 min)
              or 2x (1 h), output 5x. A relative weight, not a bill
  nested copy a subagent spawned by another subagent (e.g. an auditor skill forked
              from inside a general agent, L304); its share is of the whole weight
  first code edit  the first main-thread call that writes a code file (Edit/Write, or
              a Bash write: a heredoc that writes, sed -i, a redirect, tee)
"""
import argparse
import collections
import datetime as dt
import glob
import json
import os
import re
import sys

ROOT = os.path.expanduser('~/.claude/projects/-home-user-kaspa-verse')
IDLE_GAP = 600
CODE_EXT = r'\.(rs|dart|kt|kts|java|swift|py|sh|ag|sil|c|h|gradle|toml)\b'
P = r'[\w./~-]*' + CODE_EXT
BASH_TARGETS = [re.compile(r'>>?\s*(' + P + ')'),                    # a redirect into a code file
                re.compile(r'\btee\s+(?:-a\s+)?(' + P + ')'),
                re.compile(r'\b(?:sed|perl)\s+-i\S*\s+.*?(' + P + ')'),
                re.compile(r'\.write(?:_text)?\(')]                       # a heredoc that writes
QUOTED_CODE = re.compile(r"['\"](" + P + r")['\"]")
EDIT_TOOLS = ('Edit', 'Write', 'MultiEdit', 'NotebookEdit')


def ts(s):
    return dt.datetime.fromisoformat(s.replace('Z', '+00:00'))


def load(path, since=None, until=None):
    out = []
    with open(path) as f:
        for line in f:
            try:
                d = json.loads(line)
            except ValueError:
                continue
            t = d.get('timestamp')
            if t and ((since and ts(t) < since) or (until and ts(t) > until)):
                continue
            out.append(d)
    return out


def ctx_of(u):
    return (u.get('input_tokens') or 0) + (u.get('cache_read_input_tokens') or 0) + \
        (u.get('cache_creation_input_tokens') or 0)


def weight_of(u):
    cc = u.get('cache_creation') or {}
    w1h = cc.get('ephemeral_1h_input_tokens')
    w5m = cc.get('ephemeral_5m_input_tokens')
    if w1h is None and w5m is None:  # older records carry only the total
        w5m = u.get('cache_creation_input_tokens') or 0
    return ((u.get('input_tokens') or 0) + 0.1 * (u.get('cache_read_input_tokens') or 0) +
            2.0 * (w1h or 0) + 1.25 * (w5m or 0) + 5 * (u.get('output_tokens') or 0))


def is_code_write(name, inp):
    if name in EDIT_TOOLS:
        p = inp.get('file_path') or inp.get('notebook_path') or ''
        return bool(re.search(CODE_EXT + '$', p)) and '/docs/' not in p and '/scratchpad/' not in p
    if name == 'Bash':
        c = inp.get('command') or ''
        hits = []
        for rx in BASH_TARGETS[:3]:
            hits += [m.group(1) for m in rx.finditer(c)]
        if BASH_TARGETS[3].search(c):
            hits += [m.group(1) for m in QUOTED_CODE.finditer(c)]
        if re.search(r'\bgit apply\b|\bpatch\s+-p', c):
            hits.append('patch')
        return any('/scratchpad/' not in h and not h.startswith('docs/') for h in hits)
    return False


def analyze(recs):
    """One transcript: calls deduplicated by message id (the last record wins)."""
    msgs = {}
    times = []
    compacts = 0
    first_edit_ctx = None
    tool_start = {}
    fg_wait = collections.Counter()
    for d in recs:
        t = d.get('timestamp')
        if t:
            times.append(ts(t))
        if d.get('type') == 'system' and d.get('subtype') == 'compact_boundary':
            compacts += 1
        m = d.get('message') or {}
        if d.get('type') == 'assistant' and m.get('id'):
            msgs[m['id']] = (m.get('model'), m.get('usage') or {}, d.get('effort'))
            for c in m.get('content') or []:
                if isinstance(c, dict) and c.get('type') == 'tool_use':
                    inp = c.get('input') or {}
                    if t:
                        tool_start[c['id']] = (ts(t), c.get('name'), inp)
                    if first_edit_ctx is None and is_code_write(c.get('name'), inp):
                        first_edit_ctx = ctx_of(m.get('usage') or {})
        if d.get('type') == 'user' and isinstance(m.get('content'), list) and t:
            for x in m['content']:
                if isinstance(x, dict) and x.get('type') == 'tool_result' and x.get('tool_use_id') in tool_start:
                    t0, name, inp = tool_start[x['tool_use_id']]
                    if name in ('Agent', 'Skill', 'Task'):
                        fg_wait[name] += (ts(t) - t0).total_seconds()
    times.sort()
    active = sum(g for g in ((b - a).total_seconds() for a, b in zip(times, times[1:])) if 0 < g < IDLE_GAP)
    use = collections.Counter()
    models, efforts = collections.Counter(), collections.Counter()
    peak = 0
    for model, u, e in msgs.values():
        c = ctx_of(u)
        peak = max(peak, c)
        use['ctx'] += c
        use['out'] += u.get('output_tokens') or 0
        use['think'] += (u.get('output_tokens_details') or {}).get('thinking_tokens') or 0
        use['weight'] += weight_of(u)
        if model != '<synthetic>':
            models[model] += 1
            efforts[e] += 1
    return dict(start=times[0] if times else None, end=times[-1] if times else None, active=active,
                calls=len(msgs), use=use, models=models, efforts=efforts, peak=peak,
                avg_ctx=use['ctx'] / len(msgs) if msgs else 0, first_edit_ctx=first_edit_ctx,
                compacts=compacts, fg_wait=fg_wait)


def title_of(recs):
    for d in reversed(recs):
        if d.get('type') == 'ai-title':
            return d.get('aiTitle', '')
    return ''


def sitting(main_path, since=None, until=None):
    recs = load(main_path, since, until)
    a = analyze(recs)
    sid = os.path.basename(main_path)[:-6]
    agents = []
    for p in sorted(glob.glob(f'{ROOT}/{sid}/subagents/*.jsonl')):
        r = load(p, since, until)
        if not r:
            continue
        b = analyze(r)
        if not b['calls']:
            continue
        meta = {}
        mp = p[:-6] + '.meta.json'
        if os.path.exists(mp):
            try:
                meta = json.load(open(mp))
            except ValueError:
                pass
        b['id'] = os.path.basename(p)[6:-6]
        b['meta'] = meta
        agents.append(b)
    ids = {g['id'] for g in agents}
    for g in agents:
        parent = g['meta'].get('parentAgentId')
        g['nested'] = bool(parent) and (parent in ids or g['meta'].get('spawnDepth', 1) > 1)
    return sid, title_of(recs), a, agents


def fmt_k(n):
    return f'{n / 1e3:,.0f}k'


def fmt_mix(counter):
    return ', '.join(f'{k}×{v}' if len(counter) > 1 else f'{k}' for k, v in counter.most_common())


def report(sid, title, a, agents):
    total = a['use']['weight'] + sum(g['use']['weight'] for g in agents)
    nested = sum(g['use']['weight'] for g in agents if g['nested'])
    sub_w = sum(g['use']['weight'] for g in agents)
    span = (a['end'] - a['start']).total_seconds() / 3600 if a['start'] else 0
    print(f"\n### {sid[:8]}  {a['start']:%Y-%m-%d %H:%M}  {title[:70]!r}")
    print(f"  active {a['active'] / 3600:.1f} h (span {span:.1f} h) · compactions {a['compacts']}")
    print(f"  main: {a['calls']} calls · {fmt_mix(a['models'])} · effort {fmt_mix(a['efforts'])}")
    print(f"  main output {fmt_k(a['use']['out'])} (thinking {fmt_k(a['use']['think'])}) · context peak "
          f"{fmt_k(a['peak'])} / average {fmt_k(a['avg_ctx'])} · at first code edit "
          f"{fmt_k(a['first_edit_ctx']) if a['first_edit_ctx'] is not None else '—'}")
    waits = ', '.join(f'{k} {v / 60:.0f} min' for k, v in a['fg_wait'].items()) or 'none'
    print(f"  main thread blocked on agents/skills: {waits}")
    print(f"  token weight {total / 1e6:.1f}M · main {100 * a['use']['weight'] / max(total, 1):.0f}% · "
          f"subagents {100 * sub_w / max(total, 1):.0f}% · nested copies {100 * nested / max(total, 1):.0f}%")
    print(f"  subagents: {len(agents)} ({sum(g['nested'] for g in agents)} nested)")
    for g in agents:
        m = g['meta']
        label = m.get('description') or (f"nested in {m.get('parentAgentId', '')[:10]}" if g['nested'] else '')
        span_m = (g['end'] - g['start']).total_seconds() / 60 if g['start'] else 0
        print(f"    {g['id'][:10]} {m.get('agentType', '?'):17s} d{m.get('spawnDepth', '?')} "
              f"{m.get('requestShape', '?'):10s} {fmt_mix(g['models']):22s} effort {fmt_mix(g['efforts']):8s} "
              f"{span_m:5.0f} min · out {fmt_k(g['use']['out'])} · weight {g['use']['weight'] / 1e6:.1f}M · {label[:44]}")


def parse_time(s):
    if not s:
        return None
    t = dt.datetime.fromisoformat(s.replace('Z', '+00:00'))
    return t if t.tzinfo else t.replace(tzinfo=dt.timezone.utc)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    ap.add_argument('ids', nargs='*', help='session-id prefixes')
    ap.add_argument('--all', action='store_true')
    ap.add_argument('--since', help='ISO time (UTC); ignore records before it')
    ap.add_argument('--until', help='ISO time (UTC); ignore records after it')
    args = ap.parse_args()
    since = parse_time(args.since)
    until = parse_time(args.until)
    paths = sorted(glob.glob(f'{ROOT}/*.jsonl'), key=os.path.getmtime)
    if args.ids:
        paths = [p for p in paths if any(os.path.basename(p).startswith(i) for i in args.ids)]
    elif not args.all:
        paths = paths[-1:]
    if not paths:
        print('session_metrics: no transcript matched', file=sys.stderr)
        return 1
    for p in paths:
        sid, title, a, agents = sitting(p, since, until)
        if not a['start'] or (args.all and a['calls'] < 20):
            continue
        report(sid, title, a, agents)
    return 0


if __name__ == '__main__':
    sys.exit(main())
