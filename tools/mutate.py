#!/usr/bin/env python3
"""Apply a list of hand-written mutants, run each one's test, and report what survived.

Usage:
  tools/mutate.py MUTANTS.json [--in-diff REV] [--timeout S] [--memory-max 6G] [--log-dir DIR]

MUTANTS.json is a list of objects:
  {"id": "S1",                       optional, defaults to the list position
   "file": "rust/chain/src/send.rs", relative to the repo root
   "old": "exact text, once in the file",
   "new": "the mutated text",
   "test": "cargo test ...",         or a top-level default: {"test": ..., "build": ..., "mutants": [...]}
   "build": "cargo test --no-run ..."  optional: run first; a failure is an unviable mutant
   "note": "what the mutant breaks"}

Outcomes:
  killed     the test failed (or hit the timeout) with the mutant in place
  survived   the test passed with the mutant in place: a gap, or an equivalent mutant
  bad-patch  the old text is missing or not unique, or the build failed (unviable)

`--in-diff REV` keeps only mutants whose old text overlaps lines changed since REV
(`git diff -U0 REV`): the diff-scoped mutation of Google's practice (arXiv 2102.11378)
and cargo-mutants' --in-diff. The full sweep stays a phase-close job.

Safety (L238, L269, L272, L287, L302):
  - paths are resolved to absolute before anything runs;
  - a file is restored by rewriting its original bytes, never by moving a backup, and
    its mtime is set to now, so cargo never reuses the mutant's build;
  - SIGINT, SIGTERM and SIGHUP restore before exiting; a journal lets the next run
    restore anything a hard kill left live;
  - the build and the test each run in their own process group, killed as a group at the
    timeout, optionally inside a systemd memory scope;
  - the unmutated test must pass before any mutant runs;
  - the run ends with a sha256 check of every file it touched.
Exit status: 0 when every viable mutant was killed, 1 when any survived, 2 on a harness error.
"""
import argparse
import hashlib
import json
import os
import re
import signal
import subprocess
import sys
import tempfile
import time

ROOT = os.path.realpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
JOURNAL = os.path.join(os.environ.get('TMPDIR') or tempfile.gettempdir(),
                       'kv-mutate-' + hashlib.sha256(ROOT.encode()).hexdigest()[:12] + '.json')

originals = {}  # absolute path -> original bytes, for every file this run has touched


def sha(b):
    return hashlib.sha256(b).hexdigest()


def write_bytes(path, data):
    with open(path, 'wb') as f:
        f.write(data)
    os.utime(path, None)  # L302: a restored file is newer than any build of the mutant


def save_journal():
    tmp = JOURNAL + '.tmp'
    with open(tmp, 'w') as f:
        json.dump({p: b.decode('latin-1') for p, b in originals.items()}, f)
    os.replace(tmp, JOURNAL)


def restore_all():
    for path, data in originals.items():
        with open(path, 'rb') as f:
            if f.read() == data:
                os.utime(path, None)
                continue
        write_bytes(path, data)


def recover_journal():
    if not os.path.exists(JOURNAL):
        return
    with open(JOURNAL) as f:
        left = {p: s.encode('latin-1') for p, s in json.load(f).items()}
    for path, data in left.items():
        with open(path, 'rb') as f:
            if f.read() != data:
                write_bytes(path, data)
                print(f'mutate: restored {os.path.relpath(path, ROOT)} from a previous run that did not finish')
    os.remove(JOURNAL)


def on_signal(signum, _frame):
    restore_all()
    if os.path.exists(JOURNAL):
        os.remove(JOURNAL)
    print(f'\nmutate: signal {signum}; every file restored', file=sys.stderr)
    sys.exit(2)


def run(cmd, timeout, memory_max, log):
    """Run a shell command in its own process group; (status, seconds). status None = timeout."""
    if memory_max:
        cmd = (f'systemd-run --user --scope --quiet -p MemoryMax={memory_max} -p MemorySwapMax=0 '
               f'bash -c {json.dumps(cmd)}')
    t0 = time.monotonic()
    with open(log, 'ab') as out:
        p = subprocess.Popen(cmd, shell=True, cwd=ROOT, stdout=out, stderr=subprocess.STDOUT,
                             start_new_session=True, executable='/bin/bash')
        try:
            rc = p.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            os.killpg(p.pid, signal.SIGKILL)  # L269: the whole group, never a name match
            p.wait()
            rc = None
    return rc, time.monotonic() - t0


def changed_lines(rev, rel):
    out = subprocess.run(['git', 'diff', '-U0', rev, '--', rel], cwd=ROOT,
                         capture_output=True, text=True, check=True).stdout
    lines = set()
    for m in re.finditer(r'^@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@', out, re.M):
        start, n = int(m.group(1)), int(m.group(2) or 1)
        lines.update(range(start, start + max(n, 1)))
    if not out and subprocess.run(['git', 'ls-files', '--error-unmatch', rel], cwd=ROOT,
                                  capture_output=True).returncode != 0:
        return None  # untracked: every line is new
    return lines


def first_failure(log):
    try:
        text = open(log, errors='replace').read()
    except OSError:
        return ''
    m = re.search(r'^test (\S+) \.\.\. FAILED|^---- (\S+) stdout ----|panicked at ([^\n]+)', text, re.M)
    return next((g for g in m.groups() if g), '')[:90] if m else ''


def main():
    ap = argparse.ArgumentParser(description='Apply mutants one at a time and report killed, survived, bad-patch.')
    ap.add_argument('mutants')
    ap.add_argument('--in-diff', metavar='REV')
    ap.add_argument('--timeout', type=float, default=1800)
    ap.add_argument('--memory-max', metavar='SIZE')
    ap.add_argument('--log-dir', default=os.path.join(os.environ.get('TMPDIR') or tempfile.gettempdir(), 'kv-mutate-logs'))
    args = ap.parse_args()

    for s in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        signal.signal(s, on_signal)
    recover_journal()

    spec = json.load(open(args.mutants))
    defaults = spec if isinstance(spec, dict) else {}
    mutants = spec['mutants'] if isinstance(spec, dict) else spec
    os.makedirs(args.log_dir, exist_ok=True)

    plan = []
    for i, m in enumerate(mutants, 1):
        mid = str(m.get('id', i))
        path = os.path.realpath(os.path.join(ROOT, m['file']))
        if not path.startswith(ROOT + os.sep) or not os.path.isfile(path):
            plan.append((mid, m, path, f'no such file {m["file"]}'))
            continue
        test = m.get('test') or defaults.get('test')
        if not test:
            plan.append((mid, m, path, 'no test command'))
            continue
        text = open(path, encoding='utf-8').read()
        n = text.count(m['old'])
        if n != 1:
            plan.append((mid, m, path, 'old text not found' if n == 0 else f'old text found {n} times'))
            continue
        if args.in_diff:
            lines = changed_lines(args.in_diff, os.path.relpath(path, ROOT))
            first = text[:text.index(m['old'])].count('\n') + 1
            span = set(range(first, first + m['old'].count('\n') + 1))
            if lines is not None and not span & lines:
                plan.append((mid, m, path, 'skip: outside the diff'))
                continue
        plan.append((mid, m, path, None))

    runnable = [p for p in plan if p[3] is None]
    skipped = [p for p in plan if p[3] and p[3].startswith('skip')]
    print(f'mutate: {len(mutants)} mutants · {len(runnable)} to run · {len(skipped)} outside the diff')

    baselines = {}
    for mid, m, path, _ in runnable:
        key = (m.get('build') or defaults.get('build'), m.get('test') or defaults.get('test'))
        if key in baselines:
            continue
        log = os.path.join(args.log_dir, 'baseline.log')
        open(log, 'w').close()
        if key[0]:
            rc, _ = run(key[0], args.timeout, args.memory_max, log)
            if rc != 0:
                print(f'mutate: the unmutated build fails ({key[0]}); log {log}', file=sys.stderr)
                return 2
        rc, secs = run(key[1], args.timeout, args.memory_max, log)
        if rc != 0:
            print(f'mutate: the unmutated test does not pass ({key[1]}); log {log}', file=sys.stderr)
            return 2
        baselines[key] = secs
        print(f'mutate: baseline green in {secs:.0f} s: {key[1]}')

    results = []
    for mid, m, path, problem in plan:
        if problem and problem.startswith('skip'):
            continue
        if problem:
            results.append((mid, 'bad-patch', problem, m))
            continue
        original = open(path, 'rb').read()
        originals.setdefault(path, original)
        save_journal()
        log = os.path.join(args.log_dir, f'mutant-{re.sub(r"[^A-Za-z0-9_.-]", "_", mid)}.log')
        open(log, 'w').close()
        try:
            write_bytes(path, original.decode('utf-8').replace(m['old'], m['new'], 1).encode('utf-8'))
            build = m.get('build') or defaults.get('build')
            if build:
                rc, _ = run(build, args.timeout, args.memory_max, log)
                if rc != 0:
                    results.append((mid, 'bad-patch', 'build failed (unviable)', m))
                    continue
            rc, secs = run(m.get('test') or defaults.get('test'), args.timeout, args.memory_max, log)
        finally:
            write_bytes(path, original)
        if rc is None:
            results.append((mid, 'killed', f'timeout after {secs:.0f} s', m))
        elif rc != 0:
            results.append((mid, 'killed', first_failure(log) or f'exit {rc}', m))
        else:
            results.append((mid, 'survived', f'log {log}', m))
        print(f'  {mid:8s} {results[-1][1]:9s} {results[-1][2]}', flush=True)

    restore_all()
    bad = [os.path.relpath(p, ROOT) for p, b in originals.items() if sha(open(p, 'rb').read()) != sha(b)]
    if os.path.exists(JOURNAL):
        os.remove(JOURNAL)
    if bad:
        print(f'mutate: RESTORE FAILED for {", ".join(bad)}', file=sys.stderr)
        return 2

    print('\nid       outcome    file:line                                   detail')
    for mid, outcome, detail, m in results:
        path = os.path.realpath(os.path.join(ROOT, m['file']))
        line = '?'
        if os.path.isfile(path):
            text = open(path, encoding='utf-8').read()
            if m['old'] in text:
                line = text[:text.index(m['old'])].count('\n') + 1
        where = f'{m["file"]}:{line}'
        print(f'{mid:8s} {outcome:10s} {where:43s} {detail}' + (f'  ({m["note"]})' if m.get('note') else ''))
    count = {k: sum(1 for r in results if r[1] == k) for k in ('killed', 'survived', 'bad-patch')}
    print(f'\nmutate: {len(results)} run · {count["killed"]} killed · {count["survived"]} survived · '
          f'{count["bad-patch"]} bad-patch · every touched file restored (sha256 checked)')
    return 1 if count['survived'] else 0


if __name__ == '__main__':
    sys.exit(main())
