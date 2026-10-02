//! **LINK-Q2's measurement seam, turned around at LINK-Q3** — dev flags,
//! default OFF, logs only.
//!
//! LINK-Q2 priced two ratified locks — P1 §0.8's one shared socket and D-062's
//! full-block stream — on the founder's own network before anything moved them:
//! the app changed ONE thing at a time on its live socket and said what it saw
//! (`ping` probed beside `get_server_info`, Nagle put back on, the kernel's own
//! round trip read beside every probe, D-338). The founder then approved
//! stream-less on one socket (D-340), and LINK-Q3 built it (D-344): messages
//! now come from accepted transactions (`walk.rs`) and `BlockAdded` is not
//! subscribed in production. **So the stream arm inverted:** `ba=1` puts the
//! full-block stream BACK on the dev install's socket, scanned for the parity
//! log only (`devab: msg path=ba`), beside the walk's own first sightings
//! (`path=v2`); the V2 poller arm is retired, because production now is that
//! path.
//!
//! **The fence.** Everything here keys on one file, [`FLAGS_FILE`], beside the
//! endpoint health ledger in the app's private files dir, and is read only when
//! that dir belongs to the side-by-side dev install ([`DEV_PACKAGE`], built with
//! `KV_DEV_INSTALL=1`): the wallet itself — debug, profile or release — never
//! runs an arm, whoever writes the file (`consensus-auditor`, LINK-Q2: a forgotten
//! `ba=0` on the real wallet would silence its messages across reinstalls). Only
//! `run-as` on a debuggable build can write there, the app never does, the
//! manifest refuses backups, and a file older than [`FLAGS_MAX_AGE`] reads as off.
//! No file, an unreadable or stale one, or anything but `on=1` is "all off" —
//! today's app: every hook below is one relaxed load that returns.
//!
//! **What an arm costs the dev install, named.** A `ba=1` arm adds the stream's
//! ~455 MB an hour back to the dev install's download, and nothing else: the
//! stream is scanned for the log and never folded, so the message intake, its
//! cursor and the witness are the walk's whatever the arm says.
//!
//! **Never user-visible, never a verdict.** Nothing here feeds the glass, a
//! strike, the watchdog or the wallet lane. Every line starts `devab: ` at Info
//! (the liblog lane, L53) and carries public chain data only — txids, sizes,
//! round trips — and the arm's `cell=` label, so a capture partitions by arm.

use std::collections::{HashSet, VecDeque};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, OnceLock, PoisonError};
use std::time::{Duration, Instant};

use async_trait::async_trait;
use kaspa_consensus_core::header::CompressedParents;
use kaspa_rpc_core::api::rpc::RpcApi;
use kaspa_rpc_core::{RpcBlock, RpcHash};

use crate::link;
use crate::transport::TransportEvent;

/// The flags file's name, in the same directory as `endpoint.health`.
pub const FLAGS_FILE: &str = "devab.flags";
/// The only install whose files dir may arm the seam: the side-by-side dev
/// package (`KV_DEV_INSTALL=1`), never the wallet itself.
pub const DEV_PACKAGE: &str = "org.kaspaverse.app.dev";
/// A flags file not rewritten for this long reads as off — a forgotten arm
/// expires on its own. The A/B driver rewrites it every cell.
pub const FLAGS_MAX_AGE: Duration = Duration::from_secs(12 * 3600);

/// How often the flags file is read.
const POLL: Duration = Duration::from_secs(2);
/// How often the tick and frame accumulators are written out.
const FLUSH_EVERY: Duration = Duration::from_secs(10);
/// The prober's cadence — the Network screen's own (D-332). Open loop: every
/// probe is sent on schedule whatever the ones before it are doing, so a stall
/// is sampled once per 500 ms it lasts (the wrk2 method) and never under-counted.
const PROBE_EVERY: Duration = Duration::from_millis(500);
/// A probe still unanswered after this is logged as `timeout`. Long on purpose:
/// this measures stalls, so it must not truncate them at the screen's 5 s cap.
const PROBE_TIMEOUT: Duration = Duration::from_secs(30);
/// Our own bound on the dev loop's subscribe/unsubscribe call — the pin's is
/// the wRPC sweep's 60 s (`wallet-security-auditor`, LINK-Q2 note 3).
const SET_TIMEOUT: Duration = Duration::from_secs(10);
/// Bounds on what accumulates between flushes (a 10 s window at 10 BPS holds
/// ~100 ticks) and on the first-sighting memory per path.
const MAX_GAPS: usize = 4096;
const SEEN_TXIDS: usize = 8192;
/// How many blocks after `frames` turns on get a per-block sample line.
const FRAME_SAMPLES: u32 = 5;

// ── Flags ───────────────────────────────────────────────────────────────────

/// The parsed flags file. `Default` is today's app: everything off.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct DevFlags {
    /// The master switch (`on=1`). Off ⇒ every other field is its default.
    pub on: bool,
    /// The arm's label, echoed on every line (`[A-Za-z0-9._-]`, ≤ 32).
    pub cell: String,
    /// `probe=1`: the open-loop prober, alternating `ping` and `get_server_info`.
    pub probe: bool,
    /// `ba=1`: `BlockAdded` subscribed on the bound socket (and on the next),
    /// for the parity window's `path=ba` sightings. Absent or `ba=0` is
    /// production since LINK-Q3: no stream.
    pub block_added_on: bool,
    /// `nagle=1`: Nagle put back ON for the bound socket — the A/B's old arm.
    /// Absent is the dialer's production setting (off, `TCP_NODELAY`).
    pub nagle_on: bool,
    /// `frames=1`: per-block parents statistics (under `ba=1`), every 10 s.
    pub frames: bool,
    /// `lanefault=1` (PRE3-LANE): at the wallet lane's next close, replay the
    /// ordering before PRE3-LANE — the close straight through, no sever, no
    /// drain, one `UtxosChanged` after it — so the pinned processor dies at its
    /// own line and the supervisor must rebuild the lane on glass. Once per
    /// process, read when the wallet engine starts.
    pub lane_fault: bool,
}

impl DevFlags {
    /// Parse `key=value` lines. Fails closed: only the exact values below move
    /// a flag, unknown keys are ignored, and without `on=1` the result is
    /// [`DevFlags::default`] whatever else the file says.
    pub fn parse(text: &str) -> Self {
        let mut f = DevFlags::default();
        for line in text.lines() {
            let Some((key, value)) = line.split_once('=') else {
                continue;
            };
            match (key.trim(), value.trim()) {
                ("on", "1") => f.on = true,
                ("probe", "1") => f.probe = true,
                ("ba", "1") => f.block_added_on = true,
                ("nagle", "1") => f.nagle_on = true,
                ("frames", "1") => f.frames = true,
                ("lanefault", "1") => f.lane_fault = true,
                ("cell", cell) => f.cell = sanitize_cell(cell),
                _ => {}
            }
        }
        if f.on {
            f
        } else {
            DevFlags::default()
        }
    }

    /// Read the flags file at `path`; a missing, unreadable or stale file (last
    /// written more than [`FLAGS_MAX_AGE`] ago) is "all off".
    pub fn read(path: &Path) -> Self {
        let fresh = std::fs::metadata(path)
            .and_then(|m| m.modified())
            .ok()
            .and_then(|at| at.elapsed().ok())
            .is_some_and(|age| age <= FLAGS_MAX_AGE);
        if !fresh {
            return DevFlags::default();
        }
        std::fs::read_to_string(path)
            .map(|text| Self::parse(&text))
            .unwrap_or_default()
    }

    /// The log form — every key, so a capture line states the whole arm.
    pub fn line(&self) -> String {
        format!(
            "on={} probe={} ba={} nagle={} frames={} lanefault={} cell={}",
            u8::from(self.on),
            u8::from(self.probe),
            u8::from(self.block_added_on),
            u8::from(self.nagle_on),
            u8::from(self.frames),
            u8::from(self.lane_fault),
            self.cell_or_dash(),
        )
    }

    fn cell_or_dash(&self) -> &str {
        if self.cell.is_empty() {
            "-"
        } else {
            &self.cell
        }
    }
}

/// Keep a label loggable: ASCII word characters, dot and dash, at most 32.
fn sanitize_cell(raw: &str) -> String {
    raw.chars()
        .filter(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '-'))
        .take(32)
        .collect()
}

// ── The kernel's view of a socket (D-338) ────────────────────────────────────

/// What `TCP_INFO` says about one socket. Round trips in microseconds, as the
/// kernel keeps them. Fields a kernel is too old to fill are `None`.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct TcpSample {
    /// Congestion-avoidance state (0 open … 4 loss).
    pub ca_state: u8,
    /// Smoothed round trip (`tcpi_rtt`) and its mean deviation (`tcpi_rttvar`).
    pub rtt_us: u32,
    pub rttvar_us: u32,
    /// The kernel's windowed minimum (`tcpi_min_rtt`, Linux 4.6+).
    pub min_rtt_us: Option<u32>,
    /// The receiver-side estimate (`tcpi_rcv_rtt`) — ours is the receiving end.
    pub rcv_rtt_us: u32,
    pub snd_cwnd: u32,
    pub unacked: u32,
    pub lost: u32,
    pub total_retrans: u32,
    /// Bytes this socket has received (`tcpi_bytes_received`, Linux 4.1+).
    pub bytes_received: Option<u64>,
    /// Which dialed socket answered (the dialer registry's sequence), so a
    /// capture shows when the witness moved to another socket.
    pub sock_seq: u64,
}

/// The platform half of the witness, installed once by the bridge: finding the
/// wRPC socket's descriptor needs the dialer's registry, and reading a
/// descriptor this crate does not own needs `unsafe`, which this crate forbids.
/// Every call is keyed by the host the socket was dialed to (its newest socket),
/// and must verify the descriptor still names that socket before and after
/// using it — answering `None` when it does not, since a descriptor from the
/// registry may be closed or reused by the time it is read.
#[derive(Clone, Copy)]
pub struct SocketOps {
    /// Start or stop the dialer's socket registry (off by default).
    pub remember: fn(on: bool),
    /// Read `TCP_INFO` and the current `TCP_NODELAY` for `host`'s newest socket.
    pub read: fn(host: &str) -> Option<(TcpSample, bool)>,
    /// Set `TCP_NODELAY` to `nodelay` on `host`'s socket; the value read back
    /// and which dialed socket it was (the registry's sequence).
    pub set_nodelay: fn(host: &str, nodelay: bool) -> Option<(bool, u64)>,
}

static SOCKET_OPS: OnceLock<SocketOps> = OnceLock::new();

/// Install the platform half (once; later calls are ignored).
pub fn install_socket_ops(ops: SocketOps) {
    let _ = SOCKET_OPS.set(ops);
}

fn tcp_sample(host: &str) -> Option<(TcpSample, bool)> {
    (SOCKET_OPS.get()?.read)(host)
}

fn set_nodelay(host: &str, nodelay: bool) -> Option<(bool, u64)> {
    (SOCKET_OPS.get()?.set_nodelay)(host, nodelay)
}

fn remember_sockets(on: bool) {
    if let Some(ops) = SOCKET_OPS.get() {
        (ops.remember)(on);
    }
}

fn sample_fields(sample: Option<(TcpSample, bool)>) -> String {
    match sample {
        Some((t, nodelay)) => format!(
            "tcp={}/{}/{}/{} cwnd={} unacked={} lost={} retr={} rx={} ca={} nd={} sock={}",
            t.rtt_us,
            t.rttvar_us,
            t.min_rtt_us.map_or("-".to_string(), |v| v.to_string()),
            t.rcv_rtt_us,
            t.snd_cwnd,
            t.unacked,
            t.lost,
            t.total_retrans,
            t.bytes_received.map_or("-".to_string(), |v| v.to_string()),
            t.ca_state,
            u8::from(nodelay),
            t.sock_seq,
        ),
        None => "tcp=-".to_string(),
    }
}

// ── Frames: how much of a header's parent list repeats (deliverable 7) ─────

/// One block's parents, measured against the node's own compressed form.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct ParentsStats {
    /// Levels in `parents_by_level`.
    pub levels: usize,
    /// Runs the pinned `CompressedParents` folds them into.
    pub runs: usize,
    /// Parent hashes as sent (every level spelled out) and as the node's
    /// `CompressedParents` holds them (counts only — on disk the node writes
    /// bincode, `database/src/access.rs`, which frames them differently).
    pub expanded: usize,
    pub compressed: usize,
    /// Their borsh bytes each way — the wire codec (`store!` is borsh): what
    /// `BlockAdded` sends today, and what the compressed form would cost sent
    /// the same way (as VSPC v2 already sends it, rusty-kaspa #786).
    pub expanded_bytes: usize,
    pub compressed_bytes: usize,
}

/// Measure `parents_by_level` exactly as the pin would compress it (INV-9: the
/// pinned `CompressedParents`, never a re-implementation). `None` if the pin
/// refuses the list (more than 255 levels, or oversized).
pub fn parents_stats(parents_by_level: &[Vec<RpcHash>]) -> Option<ParentsStats> {
    let expanded_bytes = borsh::to_vec(&parents_by_level.to_vec()).ok()?.len();
    let compressed = CompressedParents::try_from(parents_by_level.to_vec()).ok()?;
    let compressed_bytes = borsh::to_vec(&compressed).ok()?.len();
    Some(ParentsStats {
        levels: parents_by_level.len(),
        runs: compressed.raw().len(),
        expanded: parents_by_level.iter().map(Vec::len).sum(),
        compressed: compressed.raw().iter().map(|(_, level)| level.len()).sum(),
        expanded_bytes,
        compressed_bytes,
    })
}

#[derive(Default)]
struct FrameTotals {
    blocks: u64,
    txs: u64,
    levels: u64,
    expanded: u64,
    compressed: u64,
    expanded_bytes: u64,
    compressed_bytes: u64,
    refused: u64,
}

/// A bounded first-sighting set: oldest txids fall out first.
#[derive(Default)]
struct Seen {
    set: HashSet<String>,
    order: VecDeque<String>,
}

impl Seen {
    fn first(&mut self, txid: &str) -> bool {
        if self.set.contains(txid) {
            return false;
        }
        self.set.insert(txid.to_string());
        self.order.push_back(txid.to_string());
        while self.order.len() > SEEN_TXIDS {
            if let Some(old) = self.order.pop_front() {
                self.set.remove(&old);
            }
        }
        true
    }
}

// ── State and hooks ──────────────────────────────────────────────────────────

/// One monitor's measurement state. The hot-path hooks read one atomic each and
/// return at once while the flags are off.
#[derive(Default)]
pub(crate) struct DevAb {
    flags: Mutex<DevFlags>,
    on: AtomicBool,
    block_added_on: AtomicBool,
    frames: AtomicBool,
    last_tick_mono_ms: AtomicU64,
    gaps: Mutex<Vec<u32>>,
    frames_acc: Mutex<FrameTotals>,
    frame_samples_left: AtomicU64,
    seen_ba: Mutex<Seen>,
    seen_v2: Mutex<Seen>,
    probe_seq: AtomicU64,
    probe_running: AtomicBool,
    /// The bound socket generation the per-socket settings were last applied
    /// to (0 = none yet, or an arm changed since).
    applied_gen: AtomicU64,
    /// What the socket `gen` was last told about `BlockAdded`: `(gen, false)`
    /// once its connect left it off (production since LINK-Q3), `(gen, true)`
    /// once an arm subscribed it. Only a socket an arm changed is ever touched
    /// with the flags off.
    ba_known: Mutex<(u64, bool)>,
    /// The socket an arm put Nagle back on (0 = none), restored when the flags
    /// switch off.
    nagle_on_gen: AtomicU64,
}

impl DevAb {
    pub(crate) fn flags(&self) -> DevFlags {
        self.flags
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .clone()
    }

    fn cell(&self) -> String {
        self.flags().cell_or_dash().to_string()
    }

    /// Is `BlockAdded` to be subscribed on a new socket? Read by the bind's
    /// subscribe step and the block arm; `false` unless the flags say `on=1`
    /// and `ba=1` (LINK-Q3: production has no stream).
    pub(crate) fn block_added_on(&self) -> bool {
        self.block_added_on.load(Ordering::Relaxed)
    }

    /// The bind's subscribe step reports what it did for socket `gen`. A report
    /// about an older socket than the one recorded is dropped — it cannot
    /// overwrite a newer socket's state.
    pub(crate) fn subscribed(&self, gen: u64, block_added: bool) {
        let mut known = self.ba_known.lock().unwrap_or_else(PoisonError::into_inner);
        if gen >= known.0 {
            *known = (gen, block_added);
        }
    }

    pub(crate) fn ba_known(&self, gen: u64) -> Option<bool> {
        let (known_gen, on) = *self.ba_known.lock().unwrap_or_else(PoisonError::into_inner);
        (known_gen == gen).then_some(on)
    }

    /// A DAA tick arrived on the bound socket.
    pub(crate) fn on_tick(&self, mono_ms: u64) {
        if !self.on.load(Ordering::Relaxed) {
            return;
        }
        let last = self.last_tick_mono_ms.swap(mono_ms, Ordering::Relaxed);
        if last != 0 && mono_ms >= last {
            let mut gaps = self.gaps.lock().unwrap_or_else(PoisonError::into_inner);
            if gaps.len() < MAX_GAPS {
                gaps.push(u32::try_from(mono_ms - last).unwrap_or(u32::MAX));
            }
        }
    }

    /// A `BlockAdded` arrived: its parents, when `frames=1`.
    pub(crate) fn on_block(&self, block: &RpcBlock) {
        if !self.frames.load(Ordering::Relaxed) {
            return;
        }
        let stats = parents_stats(&block.header.parents_by_level);
        let mut acc = self
            .frames_acc
            .lock()
            .unwrap_or_else(PoisonError::into_inner);
        acc.blocks += 1;
        acc.txs += block.transactions.len() as u64;
        match stats {
            Some(s) => {
                acc.levels += s.levels as u64;
                acc.expanded += s.expanded as u64;
                acc.compressed += s.compressed as u64;
                acc.expanded_bytes += s.expanded_bytes as u64;
                acc.compressed_bytes += s.compressed_bytes as u64;
                if self
                    .frame_samples_left
                    .fetch_update(Ordering::Relaxed, Ordering::Relaxed, |n| n.checked_sub(1))
                    .is_ok()
                {
                    let runs: Vec<String> =
                        CompressedParents::try_from(block.header.parents_by_level.to_vec())
                            .map(|c| {
                                c.raw()
                                    .iter()
                                    .map(|(cum, level)| format!("{cum}:{}", level.len()))
                                    .collect()
                            })
                            .unwrap_or_default();
                    log::info!(
                        "devab: frame-sample hash={} daa={} txs={} levels={} runs=[{}] \
                         parents={}/{} pbytes={}/{} cell={}",
                        block.header.hash,
                        block.header.daa_score,
                        block.transactions.len(),
                        s.levels,
                        runs.join(","),
                        s.expanded,
                        s.compressed,
                        s.expanded_bytes,
                        s.compressed_bytes,
                        self.cell()
                    );
                }
            }
            None => acc.refused += 1,
        }
    }

    /// The transport scan's matches on a `BlockAdded`: the first time each
    /// txid is seen on this path. Txids only — never a payload (§4).
    pub(crate) fn on_ba_matches(&self, matches: &[TransportEvent]) {
        if !self.on.load(Ordering::Relaxed) || matches.is_empty() {
            return;
        }
        let t = unix_ms();
        let cell = self.cell();
        let mut seen = self.seen_ba.lock().unwrap_or_else(PoisonError::into_inner);
        for event in matches {
            if let Some(txid) = &event.txid {
                if seen.first(txid) {
                    log::info!("devab: msg path=ba txid={txid} t={t} cell={cell}");
                }
            }
        }
    }

    /// The message walk's matches (production's path since LINK-Q3): the first
    /// time each txid is seen on it, logged as `path=v2` beside the stream's
    /// `path=ba`, so the judge pairs the two per message as E2 did, inverted.
    /// Txids only — never a payload (§4).
    pub(crate) fn on_walk_matches(&self, matches: &[TransportEvent]) {
        if !self.on.load(Ordering::Relaxed) || matches.is_empty() {
            return;
        }
        let t = unix_ms();
        let cell = self.cell();
        let mut seen = self.seen_v2.lock().unwrap_or_else(PoisonError::into_inner);
        for event in matches {
            if let Some(txid) = &event.txid {
                if seen.first(txid) {
                    log::info!("devab: msg path=v2 txid={txid} t={t} cell={cell}");
                }
            }
        }
    }

    /// Write out the tick gaps and frame totals gathered since the last flush.
    fn flush(&self) {
        let cell = self.cell();
        let gaps = std::mem::take(&mut *self.gaps.lock().unwrap_or_else(PoisonError::into_inner));
        let list: Vec<String> = gaps.iter().map(u32::to_string).collect();
        log::info!(
            "devab: ticks n={} gaps={} cell={cell}",
            gaps.len(),
            if list.is_empty() {
                "-".to_string()
            } else {
                list.join(",")
            }
        );
        if self.frames.load(Ordering::Relaxed) {
            let acc = std::mem::take(
                &mut *self
                    .frames_acc
                    .lock()
                    .unwrap_or_else(PoisonError::into_inner),
            );
            log::info!(
                "devab: frames n={} txs={} levels={} parents={}/{} pbytes={}/{} refused={} cell={cell}",
                acc.blocks,
                acc.txs,
                acc.levels,
                acc.expanded,
                acc.compressed,
                acc.expanded_bytes,
                acc.compressed_bytes,
                acc.refused
            );
        }
    }
}

// ── The loops, against the monitor's side of the seam ────────────────────────

/// What the loops need from the monitor, and nothing more.
#[async_trait]
pub(crate) trait DevHost: Clone + Send + Sync + 'static {
    /// False once the monitor is gone; the loops then exit.
    fn alive(&self) -> bool;
    /// The flags file, once the monitor knows its files dir.
    fn flags_path(&self) -> Option<PathBuf>;
    /// The bound socket's generation and URL, if a socket is bound.
    fn bound(&self) -> Option<(u64, String)>;
    /// The stable handle: each call lands on the socket bound at call time.
    fn rpc(&self) -> Arc<dyn RpcApi>;
    /// The measurement state this monitor's hooks write to.
    fn devab(&self) -> Arc<DevAb>;
    /// Subscribe (`true`) or unsubscribe `BlockAdded` on socket `gen`'s own
    /// listener. Refused when `gen` is not the bound socket.
    async fn set_block_added(&self, gen: u64, subscribe: bool) -> Result<(), String>;
}

/// Read the flags once, synchronously — at the moment the monitor learns its
/// files dir, so the dialer's registry is on before the first dial. Answers
/// whether the file armed the seam; only then does the monitor run [`run`].
pub(crate) fn prime(state: &DevAb, path: &Path) -> bool {
    let flags = read_armed(path);
    if !flags.on {
        return false;
    }
    remember_sockets(true);
    store_switches(state, &flags);
    log::info!("devab: flags {} (at start)", flags.line());
    *state.flags.lock().unwrap_or_else(PoisonError::into_inner) = flags;
    true
}

/// The ONE way the seam reads its flags — at start and in the loop alike — so
/// the fence holds at the function that applies the file, not one layer above
/// it (`consensus-auditor` delta, LINK-Q2): outside the dev install every read
/// is "all off", whoever writes the file and whoever spawns the loop.
pub(crate) fn read_armed(path: &Path) -> DevFlags {
    if is_dev_install(path) {
        DevFlags::read(path)
    } else {
        DevFlags::default()
    }
}

/// **Is the wallet lane's fault arm set?** (`lanefault=1`, PRE3-LANE.) The
/// flags file beside the wallet's activity log — the same file, in the same
/// `wallet/` dir, the monitor reads beside `endpoint.cache` — read through
/// [`read_armed`], so outside the dev install the answer is always no. True at
/// most once per process: the arm stages one death, and the lane the
/// supervisor rebuilds must not inherit it.
pub(crate) fn lane_fault_armed(store_path: &Path) -> bool {
    static SPENT: AtomicBool = AtomicBool::new(false);
    let flags = read_armed(&store_path.with_file_name(FLAGS_FILE));
    if !(flags.on && flags.lane_fault) || SPENT.swap(true, Ordering::SeqCst) {
        return false;
    }
    log::warn!(
        "devab: flags {} — the wallet lane's fault arm is set",
        flags.line()
    );
    true
}

/// Is `path` inside the dev install's own data dir? A path component, never a
/// substring, so no other package's name can pass for it.
pub(crate) fn is_dev_install(path: &Path) -> bool {
    path.components()
        .any(|c| c.as_os_str() == std::ffi::OsStr::new(DEV_PACKAGE))
}

pub(crate) fn store_switches(state: &DevAb, flags: &DevFlags) {
    state.on.store(flags.on, Ordering::Relaxed);
    state
        .block_added_on
        .store(flags.on && flags.block_added_on, Ordering::Relaxed);
    let frames_was = state
        .frames
        .swap(flags.on && flags.frames, Ordering::Relaxed);
    if flags.on && flags.frames && !frames_was {
        state
            .frame_samples_left
            .store(u64::from(FRAME_SAMPLES), Ordering::Relaxed);
    }
    if !flags.on {
        state.last_tick_mono_ms.store(0, Ordering::Relaxed);
    }
}

/// The main loop: read the flags every [`POLL`], apply a change, keep the
/// bound socket in the arm's shape, flush every [`FLUSH_EVERY`].
pub(crate) async fn run<H: DevHost>(host: H) {
    let state = host.devab();
    let mut last_flush = Instant::now();
    loop {
        tokio::time::sleep(POLL).await;
        if !host.alive() {
            return;
        }
        step(&host, &state).await;
        if state.on.load(Ordering::Relaxed) && last_flush.elapsed() >= FLUSH_EVERY {
            state.flush();
            last_flush = Instant::now();
        }
    }
}

/// One pass of the loop: read the flags through the fence, apply a change, keep
/// the bound socket in the arm's shape.
pub(crate) async fn step<H: DevHost>(host: &H, state: &Arc<DevAb>) {
    let flags = host
        .flags_path()
        .map(|p| read_armed(&p))
        .unwrap_or_default();
    apply(host, state, flags).await;
    follow_socket(host, state).await;
}

/// Take a new set of flags: log it, flip the hot-path switches, start or stop
/// the probe and poll loops. Idempotent for an unchanged file.
pub(crate) async fn apply<H: DevHost>(host: &H, state: &Arc<DevAb>, flags: DevFlags) {
    let before = state.flags();
    if flags != before {
        if flags.on && !before.on {
            remember_sockets(true);
        }
        if !flags.on && before.on {
            // Put back what an arm changed on the live socket while the
            // registry can still find it, then forget the registry.
            restore_nagle(host, state);
            remember_sockets(false);
        }
        store_switches(state, &flags);
        log::info!("devab: flags {}", flags.line());
        *state.flags.lock().unwrap_or_else(PoisonError::into_inner) = flags;
        // A changed arm re-applies the per-socket settings on the next follow.
        state.applied_gen.store(0, Ordering::Relaxed);
    }
    let now = state.flags();
    if now.on && now.probe && !state.probe_running.swap(true, Ordering::SeqCst) {
        tokio::spawn(prober(host.clone()));
    }
}

/// Nagle back off (the dialer's production setting) on the socket an arm
/// turned it on for, if that socket is still the bound one.
fn restore_nagle<H: DevHost>(host: &H, state: &DevAb) {
    let gen = state.nagle_on_gen.swap(0, Ordering::Relaxed);
    if gen == 0 {
        return;
    }
    if let Some((bound, url)) = host.bound() {
        if bound == gen {
            let hostname = link::endpoint_host(&url);
            let read_back = set_nodelay(hostname, true);
            log::info!(
                "devab: nagle nd=1 on {} gen={gen} → {} (flags off)",
                link::sanitize_node_text(hostname),
                match read_back {
                    Some((true, seq)) => format!("ok sock={seq}"),
                    Some((false, seq)) => format!("read back nd=0 sock={seq}"),
                    None => "unreadable".to_string(),
                }
            );
        }
    }
}

/// Keep the bound socket in the arm's shape: `BlockAdded` subscribed or not,
/// and — only while the flags are on — Nagle as the arm says. Re-applied once
/// per socket and once per arm change. With the flags off this touches nothing
/// but a subscription an arm had added, which it removes.
pub(crate) async fn follow_socket<H: DevHost>(host: &H, state: &Arc<DevAb>) {
    let Some((gen, url)) = host.bound() else {
        return;
    };
    if state.applied_gen.load(Ordering::Relaxed) == gen {
        return;
    }
    // Not before the socket's own connect step has subscribed it and said so:
    // a bind is visible here a moment before its listener exists, and a call
    // then would fail and be marked done (seen on glass, 2026-09-28: `no
    // listener on the bound socket`). The next poll finds it reported.
    let Some(known) = state.ba_known(gen) else {
        return;
    };
    let known = Some(known);
    let flags = state.flags();
    let hostname = link::endpoint_host(&url).to_string();
    // The raw host keys the registry; the logged form is sanitized (the rule
    // `endpoint_host`'s doc sets for every caller that logs it).
    let shown = link::sanitize_node_text(&hostname);
    let want_ba = flags.on && flags.block_added_on;
    // A socket's connect subscribed it per the switch and said so; only an arm
    // change on a live socket needs a call. With the flags off, the one socket
    // ever touched is one an arm left subscribed — back to production here.
    let mut in_shape = true;
    if known != Some(want_ba) && (flags.on || known == Some(true)) {
        let outcome = tokio::time::timeout(SET_TIMEOUT, host.set_block_added(gen, want_ba))
            .await
            .unwrap_or_else(|_| Err(format!("no answer in {}s", SET_TIMEOUT.as_secs())));
        if outcome.is_ok() {
            state.subscribed(gen, want_ba);
        } else {
            // Retried on the next poll rather than marked done; a socket that
            // cannot take the call is torn down and replaced soon anyway.
            in_shape = false;
        }
        log::info!(
            "devab: ba {} on {shown} gen={gen} → {} cell={}",
            if want_ba { "subscribe" } else { "unsubscribe" },
            outcome.map_or_else(|e| link::sanitize_node_text(&e), |()| "ok".to_string()),
            flags.cell_or_dash()
        );
    }
    if flags.on {
        let nodelay = !flags.nagle_on;
        let read_back = set_nodelay(&hostname, nodelay);
        state
            .nagle_on_gen
            .store(if flags.nagle_on { gen } else { 0 }, Ordering::Relaxed);
        log::info!(
            "devab: nagle nd={} on {shown} gen={gen} → {} cell={}",
            u8::from(nodelay),
            match read_back {
                Some((v, seq)) if v == nodelay => format!("ok sock={seq}"),
                Some((v, seq)) => format!("read back nd={} sock={seq}", u8::from(v)),
                None => "unreadable".to_string(),
            },
            flags.cell_or_dash()
        );
    }
    if in_shape {
        state.applied_gen.store(gen, Ordering::Relaxed);
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum ProbeCall {
    Ping,
    Info,
}

/// Even sequence numbers ping, odd ones ask `get_server_info`: the two methods
/// alternate on one 500 ms cadence, a pair half a second apart, so they see the
/// same air (deliverable 2).
fn probe_call(seq: u64) -> ProbeCall {
    if seq.is_multiple_of(2) {
        ProbeCall::Ping
    } else {
        ProbeCall::Info
    }
}

/// The open-loop prober: one probe every [`PROBE_EVERY`], each on its own task,
/// with the kernel's view of the bound socket read at the moment it is sent.
async fn prober<H: DevHost>(host: H) {
    let state = host.devab();
    let mut every = tokio::time::interval(PROBE_EVERY);
    every.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
    loop {
        every.tick().await;
        let flags = state.flags();
        if !host.alive() || !flags.on || !flags.probe {
            state.probe_running.store(false, Ordering::SeqCst);
            return;
        }
        let seq = state.probe_seq.fetch_add(1, Ordering::Relaxed);
        let call = probe_call(seq);
        let hostname = host
            .bound()
            .map(|(_, url)| link::endpoint_host(&url).to_string())
            .unwrap_or_else(|| "-".to_string());
        let kernel = sample_fields(tcp_sample(&hostname));
        let hostname = link::sanitize_node_text(&hostname);
        let rpc = host.rpc();
        let cell = flags.cell_or_dash().to_string();
        let t0 = unix_ms();
        let started = Instant::now();
        tokio::spawn(async move {
            let answered = match call {
                ProbeCall::Ping => tokio::time::timeout(PROBE_TIMEOUT, rpc.ping())
                    .await
                    .map(|r| r.is_ok()),
                ProbeCall::Info => tokio::time::timeout(PROBE_TIMEOUT, rpc.get_server_info())
                    .await
                    .map(|r| r.is_ok()),
            };
            let ms = started.elapsed().as_millis();
            let rtt = match answered {
                Ok(true) => ms.to_string(),
                Ok(false) => format!("refused@{ms}"),
                Err(_) => "timeout".to_string(),
            };
            log::info!(
                "devab: probe seq={seq} m={} t0={t0} rtt={rtt} host={hostname} {kernel} cell={cell}",
                match call {
                    ProbeCall::Ping => "ping",
                    ProbeCall::Info => "info",
                }
            );
        });
    }
}

fn unix_ms() -> u128 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis())
        .unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn no_file_or_no_master_switch_is_all_off() {
        assert_eq!(DevFlags::parse(""), DevFlags::default());
        assert_eq!(
            DevFlags::parse("probe=1\nba=1\nnagle=1\nframes=1\ncell=x"),
            DevFlags::default(),
            "without on=1 nothing may move"
        );
        assert_eq!(DevFlags::parse("on=true\nprobe=1"), DevFlags::default());
        assert_eq!(
            DevFlags::read(Path::new("/nonexistent/devab.flags")),
            DevFlags::default()
        );
    }

    #[test]
    fn only_exact_values_move_a_flag() {
        // `v2=1` is the retired poller's key (LINK-Q3): now unknown, ignored.
        let f = DevFlags::parse("on=1\nprobe=yes\nba=0\nnagle=0\nframes=2\nv2=1\nbogus=1");
        assert!(f.on);
        assert!(!f.probe && !f.block_added_on && !f.nagle_on && !f.frames);
        let g = DevFlags::parse(" on = 1 \n ba = 1 \n nagle=1\nprobe=1\nframes=1");
        assert!(g.on && g.block_added_on && g.nagle_on && g.probe && g.frames);
    }

    #[test]
    fn the_cell_label_is_kept_loggable() {
        let f = DevFlags::parse("on=1\ncell=A1 ba0;rm -rf\u{7}/x_y.z-9");
        assert_eq!(f.cell, "A1ba0rm-rfx_y.z-9");
        let long = DevFlags::parse(&format!("on=1\ncell={}", "c".repeat(80)));
        assert_eq!(long.cell.len(), 32);
        assert_eq!(
            DevFlags::default().line(),
            "on=0 probe=0 ba=0 nagle=0 frames=0 lanefault=0 cell=-"
        );
    }

    /// **The wallet lane's fault arm is fenced like every other** (PRE3-LANE,
    /// D-340): only `lanefault=1` under `on=1`, only in the dev install's
    /// `wallet/` dir, and at most once per process.
    #[test]
    fn the_lane_fault_arm_is_fenced_and_fires_once() {
        assert!(
            DevFlags::parse(
                "on=1
lanefault=1"
            )
            .lane_fault
        );
        assert!(
            !DevFlags::parse("lanefault=1").lane_fault,
            "on=1 is the master switch"
        );
        assert!(
            !DevFlags::parse(
                "on=1
lanefault=yes"
            )
            .lane_fault
        );

        let base = std::env::temp_dir().join(format!("kv-lanefault-{}", std::process::id()));
        // The real wallet's dir: the file says arm, the fence says no.
        let wallet = base.join("org.kaspaverse.app").join("files").join("wallet");
        std::fs::create_dir_all(&wallet).unwrap();
        std::fs::write(
            wallet.join(FLAGS_FILE),
            "on=1
lanefault=1
",
        )
        .unwrap();
        assert!(!lane_fault_armed(&wallet.join("activity.kvlog")));
        // The dev install's dir: armed, once.
        let dev = base.join(DEV_PACKAGE).join("files").join("wallet");
        std::fs::create_dir_all(&dev).unwrap();
        std::fs::write(
            dev.join(FLAGS_FILE),
            "on=1
lanefault=1
",
        )
        .unwrap();
        assert!(lane_fault_armed(&dev.join("activity.kvlog")));
        assert!(
            !lane_fault_armed(&dev.join("activity.kvlog")),
            "a rebuilt lane must not inherit the arm"
        );
        let _ = std::fs::remove_dir_all(&base);
    }

    fn h(n: u8) -> RpcHash {
        RpcHash::from_bytes([n; 32])
    }

    /// The node's compression folds identical consecutive levels; the wire
    /// spells every level out. Counted by the pinned type, bytes by borsh.
    #[test]
    fn parents_stats_measure_the_pinned_compression() {
        let levels = vec![
            vec![h(1), h(2)],
            vec![h(1), h(2)],
            vec![h(3)],
            vec![h(3)],
            vec![h(3)],
        ];
        let s = parents_stats(&levels).expect("a valid list");
        assert_eq!(s.levels, 5);
        assert_eq!(s.runs, 2);
        assert_eq!(s.expanded, 7);
        assert_eq!(s.compressed, 3);
        // Vec<Vec<Hash>>: u32 count + per level (u32 count + 32·n).
        assert_eq!(s.expanded_bytes, 4 + 2 * (4 + 64) + 3 * (4 + 32));
        // Vec<(u8, Vec<Hash>)>: u32 count + per run (u8 + u32 count + 32·n).
        assert_eq!(s.compressed_bytes, 4 + (1 + 4 + 64) + (1 + 4 + 32));
        let flat = parents_stats(&[vec![h(9)]]).unwrap();
        assert_eq!((flat.runs, flat.expanded, flat.compressed), (1, 1, 1));
        let refused: Vec<Vec<RpcHash>> = vec![vec![h(1)]; 256];
        assert!(
            parents_stats(&refused).is_none(),
            "the pin refuses > 255 levels"
        );
    }

    /// No file (production): the seam is not armed, the registry is never
    /// asked for, and a connect leaves the stream off (LINK-Q3).
    #[test]
    fn priming_without_a_file_arms_nothing() {
        let state = DevAb::default();
        assert!(!prime(&state, Path::new("/nonexistent/devab.flags")));
        assert!(!state.block_added_on() && !state.on.load(Ordering::Relaxed));
        assert_eq!(state.flags(), DevFlags::default());
    }

    #[test]
    fn probes_alternate_ping_and_info() {
        let calls: Vec<ProbeCall> = (0..4).map(probe_call).collect();
        assert_eq!(
            calls,
            vec![
                ProbeCall::Ping,
                ProbeCall::Info,
                ProbeCall::Ping,
                ProbeCall::Info
            ]
        );
    }

    #[test]
    fn hooks_do_nothing_while_off() {
        let state = DevAb::default();
        state.on_tick(1_000);
        state.on_tick(1_100);
        assert!(state.gaps.lock().unwrap().is_empty());
        assert!(!state.block_added_on());
        let walked = TransportEvent {
            txid: Some("aa".repeat(32)),
            kind: "comm".to_string(),
            namespace: crate::transport::WireNamespace::CiphMsg,
            body: Vec::new(),
            addresses: Vec::new(),
            block_time_ms: None,
            block_hash: None,
        };
        state.on_walk_matches(std::slice::from_ref(&walked));
        assert!(
            state.seen_v2.lock().unwrap().set.is_empty(),
            "off: the walk's sightings are not recorded"
        );
        store_switches(&state, &DevFlags::parse("on=1\nba=1"));
        assert!(state.block_added_on());
        state.on_walk_matches(std::slice::from_ref(&walked));
        assert_eq!(state.seen_v2.lock().unwrap().set.len(), 1);
        state.on_tick(2_000);
        state.on_tick(2_150);
        assert_eq!(*state.gaps.lock().unwrap(), vec![150]);
        store_switches(&state, &DevFlags::default());
        assert!(
            !state.block_added_on(),
            "off must return to production: no stream"
        );
        state.on_tick(3_000);
        assert_eq!(state.gaps.lock().unwrap().len(), 1);
    }

    #[test]
    fn a_txid_is_first_seen_once_and_the_memory_is_bounded() {
        let mut seen = Seen::default();
        assert!(seen.first("a"));
        assert!(!seen.first("a"));
        for i in 0..(SEEN_TXIDS + 10) {
            seen.first(&i.to_string());
        }
        assert!(seen.order.len() <= SEEN_TXIDS && seen.set.len() <= SEEN_TXIDS);
        assert!(seen.first("a"), "the oldest fall out");
    }

    /// A stand-in monitor: one bound socket, a record of every subscription
    /// call the seam makes, and no network (its rpc answers "no socket").
    #[derive(Clone)]
    struct FakeHost {
        state: Arc<DevAb>,
        bound: Arc<Mutex<Option<(u64, String)>>>,
        calls: Arc<Mutex<Vec<(u64, bool)>>>,
        fail: Arc<AtomicBool>,
        flags: Option<PathBuf>,
    }

    impl FakeHost {
        fn new(gen: u64) -> Self {
            Self {
                state: Arc::new(DevAb::default()),
                bound: Arc::new(Mutex::new(Some((gen, "wss://node.example/wrpc".into())))),
                calls: Arc::new(Mutex::new(Vec::new())),
                fail: Arc::new(AtomicBool::new(false)),
                flags: None,
            }
        }
        fn calls(&self) -> Vec<(u64, bool)> {
            self.calls.lock().unwrap().clone()
        }
    }

    #[async_trait]
    impl DevHost for FakeHost {
        fn alive(&self) -> bool {
            true
        }
        fn flags_path(&self) -> Option<PathBuf> {
            self.flags.clone()
        }
        fn bound(&self) -> Option<(u64, String)> {
            self.bound.lock().unwrap().clone()
        }
        fn rpc(&self) -> Arc<dyn RpcApi> {
            crate::link_rpc::LinkRpc::new()
        }
        fn devab(&self) -> Arc<DevAb> {
            self.state.clone()
        }
        async fn set_block_added(&self, gen: u64, subscribe: bool) -> Result<(), String> {
            self.calls.lock().unwrap().push((gen, subscribe));
            if self.fail.load(Ordering::SeqCst) {
                return Err("refused".to_string());
            }
            Ok(())
        }
    }

    /// **Production is untouched.** With no flags file, a socket whose connect
    /// left `BlockAdded` off (LINK-Q3) is followed without a single call — on
    /// the first socket, on the next, and on a repeat pass.
    #[tokio::test]
    async fn with_the_flags_off_the_seam_makes_no_call_on_any_socket() {
        let host = FakeHost::new(1);
        let state = host.devab();
        state.subscribed(1, state.block_added_on());
        apply(&host, &state, DevFlags::default()).await;
        follow_socket(&host, &state).await;
        follow_socket(&host, &state).await;
        *host.bound.lock().unwrap() = Some((2, "wss://other.example/wrpc".into()));
        state.subscribed(2, state.block_added_on());
        follow_socket(&host, &state).await;
        assert!(
            host.calls().is_empty(),
            "flags off, yet the seam called: {:?}",
            host.calls()
        );
        assert!(!state.probe_running.load(Ordering::SeqCst));
    }

    /// A bind is visible a moment before its connect step has subscribed it:
    /// the seam waits for that report rather than calling into a socket with no
    /// listener yet, and does not mark the socket done while it waits.
    #[tokio::test]
    async fn the_seam_waits_for_the_connect_step_before_touching_a_socket() {
        let host = FakeHost::new(3);
        let state = host.devab();
        apply(&host, &state, DevFlags::parse("on=1\nba=1")).await;
        follow_socket(&host, &state).await;
        assert!(
            host.calls().is_empty(),
            "called before the connect step reported"
        );
        assert_eq!(
            state.applied_gen.load(Ordering::Relaxed),
            0,
            "marked done while waiting"
        );
        state.subscribed(3, false);
        follow_socket(&host, &state).await;
        assert_eq!(host.calls(), vec![(3, true)]);
    }

    /// An arm that adds `BlockAdded` does it once on the live socket, a new
    /// socket connects with it (the bind asks the switch), and switching the
    /// flags off takes it off exactly the socket the arm left with it.
    #[tokio::test]
    async fn an_arm_adds_the_stream_once_and_switching_off_removes_it() {
        let host = FakeHost::new(7);
        let state = host.devab();
        state.subscribed(7, false);
        apply(&host, &state, DevFlags::parse("on=1\nba=1\ncell=b1")).await;
        follow_socket(&host, &state).await;
        follow_socket(&host, &state).await;
        assert_eq!(host.calls(), vec![(7, true)]);
        // A swap: the new socket's connect read the switch and subscribed it.
        *host.bound.lock().unwrap() = Some((8, "wss://other.example/wrpc".into()));
        assert!(state.block_added_on());
        state.subscribed(8, state.block_added_on());
        follow_socket(&host, &state).await;
        assert_eq!(
            host.calls(),
            vec![(7, true)],
            "the new socket needed no call"
        );
        // Off: only the socket an arm left with the stream goes back.
        apply(&host, &state, DevFlags::default()).await;
        follow_socket(&host, &state).await;
        assert_eq!(host.calls(), vec![(7, true), (8, false)]);
        assert!(!state.block_added_on());
    }

    /// **The fence** (`consensus-auditor`, LINK-Q2): only the dev install's
    /// own data dir can arm the seam — matched as a path component, so the
    /// wallet's dir, a longer package name and a substring all fail.
    #[test]
    fn only_the_dev_install_can_arm_the_seam() {
        let dev = Path::new("/data/user/0/org.kaspaverse.app.dev/files/wallet/devab.flags");
        assert!(is_dev_install(dev));
        for not_dev in [
            "/data/user/0/org.kaspaverse.app/files/wallet/devab.flags",
            "/data/user/0/org.kaspaverse.app.devious/files/wallet/devab.flags",
            "/data/user/0/xorg.kaspaverse.app.dev/files/wallet/devab.flags",
            "/data/data/org.kaspaverse.app/files/org.kaspaverse.app.devab.flags",
        ] {
            assert!(
                !is_dev_install(Path::new(not_dev)),
                "{not_dev} armed the seam"
            );
        }
        // End to end through `prime`, with a real armed file in each place.
        let root = std::env::temp_dir().join(format!("kv-devab-fence-{}", std::process::id()));
        for (pkg, armed) in [
            ("org.kaspaverse.app.dev", true),
            ("org.kaspaverse.app", false),
        ] {
            let dir = root.join(pkg).join("files").join("wallet");
            std::fs::create_dir_all(&dir).unwrap();
            let file = dir.join(FLAGS_FILE);
            std::fs::write(&file, "on=1\nba=1\n").unwrap();
            let state = DevAb::default();
            assert_eq!(prime(&state, &file), armed, "{pkg}");
            assert_eq!(state.block_added_on(), armed, "{pkg}");
        }
        let _ = std::fs::remove_dir_all(&root);
    }

    /// A forgotten arm expires: a file not rewritten for longer than
    /// [`FLAGS_MAX_AGE`] reads as off, whatever it says.
    #[test]
    fn a_stale_flags_file_reads_as_off() {
        let dir = std::env::temp_dir().join(format!("kv-devab-stale-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let file = dir.join(FLAGS_FILE);
        std::fs::write(&file, "on=1\nba=1\n").unwrap();
        assert!(DevFlags::read(&file).on, "a fresh file is read");
        let old = std::time::SystemTime::now() - FLAGS_MAX_AGE - Duration::from_secs(60);
        std::fs::File::options()
            .write(true)
            .open(&file)
            .unwrap()
            .set_modified(old)
            .unwrap();
        assert_eq!(
            DevFlags::read(&file),
            DevFlags::default(),
            "a stale file armed the seam"
        );
        let ahead = std::time::SystemTime::now() + Duration::from_secs(3600);
        std::fs::File::options()
            .write(true)
            .open(&file)
            .unwrap()
            .set_modified(ahead)
            .unwrap();
        assert_eq!(
            DevFlags::read(&file),
            DevFlags::default(),
            "a future-dated file armed the seam"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// A report about an older socket cannot overwrite a newer one's.
    #[test]
    fn a_stale_connect_report_is_dropped() {
        let state = DevAb::default();
        state.subscribed(5, true);
        state.subscribed(4, false);
        assert_eq!(state.ba_known(5), Some(true));
        assert_eq!(state.ba_known(4), None);
    }

    /// A restore the node refused is not marked done: the next poll retries it.
    #[tokio::test]
    async fn a_refused_call_is_retried_on_the_next_poll() {
        let host = FakeHost::new(9);
        let state = host.devab();
        state.subscribed(9, false);
        host.fail.store(true, Ordering::SeqCst);
        apply(&host, &state, DevFlags::parse("on=1\nba=1")).await;
        follow_socket(&host, &state).await;
        assert_eq!(
            state.applied_gen.load(Ordering::Relaxed),
            0,
            "a refused call marked the socket done"
        );
        host.fail.store(false, Ordering::SeqCst);
        follow_socket(&host, &state).await;
        assert_eq!(host.calls(), vec![(9, true), (9, true)]);
        assert_eq!(state.applied_gen.load(Ordering::Relaxed), 9);
    }

    /// **The fence holds in the loop too** (`consensus-auditor` delta): a loop
    /// step whose flags path is the WALLET's reads an armed file as all off and
    /// touches nothing — so spawning the loop unconditionally could never arm
    /// the wallet. The same step under the dev install's dir does arm.
    #[tokio::test]
    async fn a_loop_step_outside_the_dev_install_applies_nothing() {
        let root = std::env::temp_dir().join(format!("kv-devab-loop-{}", std::process::id()));
        for (pkg, armed) in [
            ("org.kaspaverse.app", false),
            ("org.kaspaverse.app.dev", true),
        ] {
            let dir = root.join(pkg).join("files").join("wallet");
            std::fs::create_dir_all(&dir).unwrap();
            let file = dir.join(FLAGS_FILE);
            std::fs::write(&file, "on=1\nba=1\n").unwrap();
            let mut host = FakeHost::new(4);
            host.flags = Some(file);
            let state = host.devab();
            state.subscribed(4, false);
            step(&host, &state).await;
            assert_eq!(state.flags().on, armed, "{pkg}");
            assert_eq!(state.block_added_on(), armed, "{pkg}");
            let want: Vec<(u64, bool)> = if armed { vec![(4, true)] } else { vec![] };
            assert_eq!(host.calls(), want, "{pkg}");
        }
        let _ = std::fs::remove_dir_all(&root);
    }
}
