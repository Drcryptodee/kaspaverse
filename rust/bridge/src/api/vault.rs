//! The platform vault session (P1.2) — the one process-wide handle to the
//! unlocked custody engine, reachable by BOTH constitutional lanes:
//!
//! - **Path B** (passphrase) over FRB: `Uint8List` in, Argon2id → XChaCha20
//!   unseal, here. The passphrase is zeroized the moment this code is done.
//! - **Path A** (biometric) over JNI (`jni_seed`, Android-only): the Keystore
//!   Cipher's plaintext seed crosses Kotlin → Rust and loads the same vault.
//!
//! A process-wide singleton is deliberate, not the L6 anti-pattern: two
//! independent lanes (FRB and JNI) must observe ONE vault, so a shared handle
//! is required, not merely convenient. The lock is poison-recovering (L7) — its
//! contents are an all-or-nothing `Option`, safe to recover after a panic.
//!
//! Nothing secret-shaped crosses to Dart: every public fn returns `()`, `bool`,
//! `VaultStatus` (bools + non-secret counters), or `Result<_, AppError>`.

use std::fs;
use std::io::{self, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Mutex, OnceLock, PoisonError};
use std::time::{SystemTime, UNIX_EPOCH};

use kaspaverse_chain::Address;
use kaspaverse_core::{
    read_facts, seal_seed, unseal_seed, Branch, CoreError, InputKind, KeyChain, MnemonicCeremony,
    Prefix, SealParams, SecretSeed, UnlockedVault, VaultSigner, PEPPER_LEN,
};
use tokio::sync::broadcast::{self, error::RecvError};
use zeroize::Zeroizing;

use crate::api::error::AppError;
use crate::frb_generated::StreamSink;

// ── Process-wide state ────────────────────────────────────────────────────

/// The sole strong owner of the unlocked vault (None = locked).
static VAULT: Mutex<Option<UnlockedVault>> = Mutex::new(None);

/// Monotonic lock generation — the §0.11 lifecycle lock's memory (F3).
///
/// Every install of an unlocked vault sits at the far end of slow work: an
/// Argon2id KDF of about a second on the passphrase lanes, an unbounded
/// BiometricPrompt + Keystore round-trip on the JNI one. `lock_vault` used to
/// clear `VAULT` and return, recording nothing a later install could observe,
/// so a lock landing inside that window was **silently overwritten**: the
/// wallet came back unlocked in the background with its auto-lock timer already
/// cancelled Dart-side. `lockVault` and `unlockWithPassphrase` are both
/// `executeNormal` on FRB's worker pool, so this is a genuine race on real
/// threads — and with the default grace of 0 seconds its trigger is pressing
/// Home, taking a call, or a full-screen notification.
///
/// The rule is L73's: a check and the state it protects must be ONE critical
/// section. So this counter is read and written **only while holding the
/// `VAULT` guard** — that mutex, not the atomic's own ordering, is what makes
/// lock-vs-install a decision with exactly two outcomes, both correct.
static LOCK_EPOCH: AtomicU64 = AtomicU64::new(0);
/// App-private directory the platform hands us at init; the sealed blob and the
/// lockout counter live here (INV-3 — never SharedPreferences).
static VAULT_DIR: Mutex<Option<PathBuf>> = Mutex::new(None);
/// **The device pepper (D-312), held only for the operation that needs it.**
///
/// 32 bytes an `AndroidKeyStore` HMAC key produced for this app on this phone.
/// It is the hardware factor that makes a 6-digit PIN offerable: without it the
/// sealed file is 10^6 candidates at ~679 ms each for anyone who lifts it, and
/// `vault.lockout` cannot help because those guesses never transit the app.
///
/// **Kotlin pushes it in over JNI** ([`install_pepper`], from
/// `VaultBridge.nativeInstallVaultPepper`) — never Dart, so the hardware factor
/// has no more presence in the Dart heap than the seed does (INV-1/3). Every
/// consumer [`take_pepper`]s it, so it is resident for the length of one seal or
/// one unlock rather than for the life of the process: a memory scrape of a
/// LOCKED app must not hand over the one thing that makes the PIN offline-
/// guessable. `lock_vault` drops it too, for the case where a ceremony is
/// abandoned between the install and the call it was installed for.
static PEPPER: Mutex<Option<Zeroizing<Vec<u8>>>> = Mutex::new(None);

/// Install the device pepper for the next vault operation. Called from the JNI
/// lane; wrong-length input is refused here rather than in the KDF.
///
/// Android-only in practice — the lane that feeds it is `jni_seed`, which is
/// compiled for Android alone, so every other target sees an unused fn. Same
/// attribute the other three JNI-facing entries carry.
#[cfg_attr(not(target_os = "android"), allow(dead_code))]
pub(crate) fn install_pepper(pepper: Zeroizing<Vec<u8>>) -> Result<(), AppError> {
    if pepper.len() != PEPPER_LEN {
        return Err(AppError::msg("device pepper must be exactly 32 bytes"));
    }
    *PEPPER.lock().unwrap_or_else(PoisonError::into_inner) = Some(pepper);
    Ok(())
}

/// Consume the installed pepper, if any. Taking rather than borrowing is what
/// bounds its residency to one operation.
fn take_pepper() -> Option<Zeroizing<Vec<u8>>> {
    PEPPER.lock().unwrap_or_else(PoisonError::into_inner).take()
}

/// Status fan-out; lazily created so `send` works without a runtime.
static STATUS_TX: OnceLock<broadcast::Sender<VaultStatus>> = OnceLock::new();

/// The live mnemonic during a P1.4 create ceremony (D-038): generated by
/// [`begin_create`], displayed by the native FLAG_SECURE reveal/verify surface
/// over the JNI lane (D-037 — words never cross FRB), consumed by
/// [`seal_and_persist`]. Held only for the ceremony and dropped — zeroizing the
/// phrase via the inner `Mnemonic`'s `Drop` — on seal, on [`abandon_create`], or
/// on the §0.11 lifecycle signal (via [`lock_vault`]). `None` = no create in
/// progress. A second strong owner beside `VAULT`: deliberate, not the L6
/// singleton anti-pattern — the native lane and FRB must observe one ceremony.
static CREATE_CEREMONY: Mutex<Option<MnemonicCeremony>> = Mutex::new(None);

const BLOB_FILE: &str = "vault.kvsb";
const LOCKOUT_FILE: &str = "vault.lockout";

// ── DTOs (FRB-facing: plain structs, no secret-shaped fields) ─────────────

/// What Dart may observe about the vault — bools and non-secret counters only.
#[derive(Clone, Debug, Default)]
pub struct VaultStatus {
    /// A sealed blob exists at rest (a wallet has been created).
    pub exists: bool,
    /// The vault is currently unlocked in memory.
    pub unlocked: bool,
    /// If rate-limited, the unix time (s) until which unlock is refused.
    pub locked_out_until_unix: Option<u64>,
    /// Consecutive failed unlock attempts (resets to 0 on any success).
    pub failed_attempts: u32,
}

/// **What the user types to open this vault** — the founder's D-312 choice,
/// crossing to Dart so the unlock screen can draw the right pad first.
///
/// Not a secret and not secret-shaped: it is a plaintext byte in the blob
/// header, which is why it may cross at all. Mapped onto the core `InputKind`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum VaultInputKind {
    /// Any-length printable secret on the alphanumeric pad.
    Passphrase,
    /// Six digits on the number pad — offerable only with a device binding.
    Digits,
}

impl From<VaultInputKind> for InputKind {
    fn from(k: VaultInputKind) -> Self {
        match k {
            VaultInputKind::Passphrase => InputKind::Passphrase,
            VaultInputKind::Digits => InputKind::Digits,
        }
    }
}

impl From<InputKind> for VaultInputKind {
    fn from(k: InputKind) -> Self {
        match k {
            InputKind::Passphrase => VaultInputKind::Passphrase,
            InputKind::Digits => VaultInputKind::Digits,
        }
    }
}

/// Which pad this vault's unlock screen should offer FIRST.
///
/// **Advisory, never a gate.** The screen that reads this must always offer the
/// other pad: the byte is unauthenticated at the moment it is read (reading it
/// needs no secret), and a number pad drawn at somebody whose secret contains
/// letters would lock them out of their own wallet while they were holding the
/// correct passphrase. Dart falls back to `Passphrase` on any error for the same
/// reason — the alphanumeric pad can enter a PIN, the number pad cannot enter a
/// passphrase, so the fallback is the one that can type either secret.
pub fn vault_input_kind() -> Result<VaultInputKind, AppError> {
    let blob = read_blob()?;
    let facts = read_facts(&blob).map_err(AppError::core)?;
    Ok(facts.input_kind.into())
}

/// Argon2id cost parameters chosen by on-device tuning (P1.2 §0.3). Mapped onto
/// the core `SealParams`, which bounds-checks them (8 MiB..=256 MiB, D-031.2).
#[derive(Clone, Copy, Debug)]
pub struct VaultKdfParams {
    pub m_cost_kib: u32,
    pub t_cost: u32,
    pub p_cost: u32,
}

impl VaultKdfParams {
    /// The v1 starting grid (P1 §0.3): m = 64 MiB, t = 3, p = 1. Kept for
    /// reference/benching; new vaults use [`VaultKdfParams::tuned`].
    pub fn starting_grid() -> Self {
        let d = SealParams::default();
        Self {
            m_cost_kib: d.m_cost_kib,
            t_cost: d.t_cost,
            p_cost: d.p_cost,
        }
    }

    /// The P1.2 on-device tuned point (LG V60, release build, 2026-06-13):
    /// m = 192 MiB → 679 ms measured, ~32% headroom under the ≤1.0 s unlock
    /// budget — 256 MiB measured 910 ms, too close to the edge for field
    /// thermal/load variance (D-026: a budget miss is a finding). Full grid
    /// in PERFORMANCE_BUDGET.md. Default for new vaults; the blob header
    /// carries whatever a vault was actually sealed with.
    pub fn tuned() -> Self {
        Self {
            m_cost_kib: 192 * 1024,
            t_cost: 3,
            p_cost: 1,
        }
    }
}

impl From<VaultKdfParams> for SealParams {
    fn from(p: VaultKdfParams) -> Self {
        SealParams {
            m_cost_kib: p.m_cost_kib,
            t_cost: p.t_cost,
            p_cost: p.p_cost,
        }
    }
}

// ── Lockout (persisted; survives process restart — wallet-security item 11) ─

/// After this many consecutive failures, backoff begins.
const LOCKOUT_FREE_ATTEMPTS: u32 = 5;

// Internal persistence type — NOT an FRB DTO. `frb(ignore)` keeps codegen from
// trying to marshal it to Dart (it would touch these private fields).
#[flutter_rust_bridge::frb(ignore)]
#[derive(Clone, Copy, Default, PartialEq, Eq, Debug)]
struct Lockout {
    failed_attempts: u32,
    locked_until_unix: u64,
}

impl Lockout {
    fn active_until(&self, now: u64) -> Option<u64> {
        (self.locked_until_unix > now).then_some(self.locked_until_unix)
    }

    fn to_bytes(self) -> [u8; 12] {
        let mut b = [0u8; 12];
        b[0..4].copy_from_slice(&self.failed_attempts.to_le_bytes());
        b[4..12].copy_from_slice(&self.locked_until_unix.to_le_bytes());
        b
    }

    fn from_bytes(b: &[u8]) -> Option<Self> {
        if b.len() != 12 {
            return None;
        }
        Some(Self {
            failed_attempts: u32::from_le_bytes([b[0], b[1], b[2], b[3]]),
            locked_until_unix: u64::from_le_bytes([
                b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11],
            ]),
        })
    }
}

/// Backoff after `failed` consecutive failures: 0 while under the free budget,
/// then 30 s doubling per extra failure, capped at one hour. Pure — unit-tested.
fn lockout_delay_secs(failed: u32) -> u64 {
    if failed <= LOCKOUT_FREE_ATTEMPTS {
        return 0;
    }
    let over = (failed - LOCKOUT_FREE_ATTEMPTS - 1).min(7);
    (30u64.saturating_mul(1u64 << over)).min(3600)
}

// ── Paths & time ──────────────────────────────────────────────────────────

fn vault_dir() -> Result<PathBuf, AppError> {
    VAULT_DIR
        .lock()
        .unwrap_or_else(PoisonError::into_inner)
        .clone()
        .ok_or_else(|| AppError::msg("vault not initialised — call init_vault first"))
}

fn blob_path() -> Result<PathBuf, AppError> {
    Ok(vault_dir()?.join(BLOB_FILE))
}

fn lockout_path() -> Result<PathBuf, AppError> {
    Ok(vault_dir()?.join(LOCKOUT_FILE))
}

/// App-private path for the wallet activity log (§0.10): the vault's dir, in a
/// `wallet/` subdir. Public chain data only (INV-3) — distinct from the sealed
/// blob, no encryption layer.
pub(crate) fn wallet_store_path() -> Result<PathBuf, AppError> {
    Ok(vault_dir()?.join("wallet").join("activity.kvlog"))
}

/// App-private path for the change-address cursor (P1.6, D-041): the next-unused
/// change index, persisted so fresh-per-send change survives a restart. Public
/// data (an index), in the same `wallet/` subdir — no encryption (INV-3).
pub(crate) fn change_cursor_path() -> Result<PathBuf, AppError> {
    Ok(vault_dir()?.join("wallet").join("change.cursor"))
}

/// App-private path for the auto-lock grace period (D-133): how long the vault
/// may survive the app going to the background. Public data (a duration in
/// seconds), same `wallet/` subdir, no encryption (INV-3).
pub(crate) fn lock_grace_path() -> Result<PathBuf, AppError> {
    Ok(vault_dir()?.join("wallet").join("lock.grace"))
}

/// The longest auto-lock grace this app will honour, and therefore the longest it
/// will ever WRITE.
///
/// A ceiling is what keeps this a *grace period* rather than an off switch. P1
/// §0.11 makes backgrounding drop the vault; D-133 softens that to a user-chosen
/// delay because re-entering a passphrase after every glance at another app is
/// friction with no custody gain on a phone whose own lock screen is the real
/// perimeter. "Never" is not on the menu at any layer: not in the picker, and not
/// in a file an attacker with a debugger could write.
pub(crate) const MAX_LOCK_GRACE_SECS: u32 = 900;

/// Read the auto-lock grace in seconds. Missing, malformed or out-of-range reads
/// as **0 — lock immediately**, which is the pre-D-133 behaviour.
///
/// The direction of that fallback is the whole point: every other persisted count
/// in this module falls back to the value that costs the user a re-probe, but
/// this one falls back to the value that costs an attacker everything. A file
/// this app could not have written must never be able to BUY unlock time.
pub(crate) fn lock_grace_secs() -> u32 {
    let raw = lock_grace_path()
        .ok()
        .and_then(|p| fs::read(p).ok())
        .filter(|b| b.len() == 4)
        .map(|b| u32::from_le_bytes([b[0], b[1], b[2], b[3]]))
        .unwrap_or(0);
    persisted_count(raw, MAX_LOCK_GRACE_SECS)
}

/// Persist the auto-lock grace, clamped to [`MAX_LOCK_GRACE_SECS`].
///
/// Clamped, not refused — unlike [`set_change_cursor`], because the two failures
/// are opposites. A cursor past its ceiling must not advance (advancing would
/// reuse a spent index); a grace past its ceiling is a request for *less*
/// security than the app allows, and the safe answer is to grant the most it
/// will, not to leave whatever was there before.
pub(crate) fn set_lock_grace_secs(secs: u32) -> Result<(), AppError> {
    let secs = secs.min(MAX_LOCK_GRACE_SECS);
    atomic_write(&lock_grace_path()?, &secs.to_le_bytes())
        .map_err(|e| AppError::io("write lock grace", e))
}

/// App-private path remembering the last-good wRPC endpoint (P1.5 re-audit —
/// the connect fast path). Public data (a wss URL the PNN resolver handed us),
/// in the same `wallet/` subdir — no encryption (INV-3), no new trust (INV-8:
/// the resolver is already an untrusted accelerator; remembering its last
/// answer adds nothing).
pub(crate) fn endpoint_cache_path() -> Result<PathBuf, AppError> {
    Ok(node_config_dir()?.join("endpoint.cache"))
}

/// Where the link's view of "which node" is persisted: the resolver's
/// last-good memory (`endpoint.cache` + `endpoint.health`) and, since D-187,
/// the user's own pin (`node.config`). Deliberately ONE directory — the two
/// are adjacent in meaning and easy to confuse, and keeping them side by side
/// makes the distinction visible (see `chain::node_config` module docs) rather
/// than hiding it across trees. Public data either way: a `wss://` URL
/// (INV-3), never key material.
pub(crate) fn node_config_dir() -> Result<PathBuf, AppError> {
    Ok(vault_dir()?.join("wallet"))
}

/// App-private dir for the P2.3 transport stores (conversations + messages).
/// Message bodies in there are ciphertext-at-rest (§0.4); conversation
/// metadata is public-wire-class data (see `transport_store.rs` module docs)
/// — sibling of the P1.5 `wallet/` subdir.
pub(crate) fn transport_store_dir() -> Result<PathBuf, AppError> {
    Ok(vault_dir()?.join("transport"))
}

/// App-private dir for the user's own preferences that reach the network —
/// the explorer templates and the price source (`explorer.config`,
/// `rate.config`). Its own directory rather than a corner of `wallet/`,
/// because these are neither custody state nor chain state: nothing in here
/// affects a balance, a signature or a dial, and a reader looking for what
/// this app can be pointed at should find both files in one place (the INV-8
/// census, D-207 clause a). Public strings only — a URL template and an
/// `https://` endpoint (INV-3).
pub(crate) fn prefs_dir() -> Result<PathBuf, AppError> {
    Ok(vault_dir()?.join("prefs"))
}

/// App-private dir for the V1 acceptance tracker (`acceptance.kvlog` +
/// `vcc.cursor`). Public chain data only — txids, block hashes, timestamps
/// (INV-3); node-only reads (INV-8). Sibling of `wallet/` and `transport/`;
/// serves BOTH (sends and conversation txids), hence its own home.
pub(crate) fn chain_store_dir() -> Result<PathBuf, AppError> {
    Ok(vault_dir()?.join("chain"))
}

/// A vault-scoped transport decryptor (core's weak-handle seam, P2.3): every
/// decrypt starts with a `Weak::upgrade` that fails once the vault locks —
/// key bytes exist only inside core, never here (INV-1). Errors if locked.
pub(crate) fn transport_decryptor() -> Result<kaspaverse_core::TransportDecryptor, AppError> {
    let guard = VAULT.lock().unwrap_or_else(PoisonError::into_inner);
    let vault = guard
        .as_ref()
        .ok_or_else(|| AppError::msg("wallet is locked"))?;
    Ok(vault.transport_decryptor())
}

/// The largest discovery mark this app can ever have written. A mark is
/// `highest_funded_index + 1`, and the deepest pass probes
/// `wallet::MANUAL_DISCOVERY_DEPTH` indices, so a larger value on disk is not a
/// window we produced — it is corruption. (`wallet.rs` asserts that relationship
/// at compile time.)
///
/// It tracks the **manual** scan's depth, not the automatic one. This constant
/// was 512 — equal to the automatic cap — and the manual "scan for more
/// addresses" control raised the deepest producible mark to 2048. Left at 512, a
/// manual scan that found funds at change index 1500 would have written mark 1501
/// and read it back as UNSET on the very next call: the scan reports success, the
/// marks silently vanish, and the wallet opens on the gap limit. The scan would
/// have been Track 1's original defect wearing a fresh button.
pub(crate) const MAX_SCAN_MARK: u32 = 2048;

/// The largest change cursor this app will believe — and therefore the largest
/// it will ever WRITE. Not a policy limit: the cursor advances by exactly one
/// per fully-broadcast send (D-041), so reaching it takes 100 000 sends from
/// this device.
///
/// The two must be the same number. A writer that can produce a value its own
/// reader rejects turns the 100 000th send into a cursor that reads back as
/// unset — silently dropping to the discovery mark and reusing change indices
/// the wallet already spent from. [`set_change_cursor`] refuses to pass it
/// instead, which repeats one index but says so.
pub(crate) const MAX_CHANGE_CURSOR: u32 = 100_000;

/// Validate a persisted count: **out of range reads as UNSET, never clamped.**
///
/// Both files are a handful of unauthenticated bytes on disk, and every consumer
/// scales linearly in their value — a window feeds `derive_wallet_addresses(n,
/// n)`, which is `Vec::with_capacity(n)` plus `n` BIP32 derivations under the
/// `VAULT` mutex. Unvalidated, `u32::MAX` is a ~137 GB allocation →
/// `handle_alloc_error` → **SIGABRT**, worse than the caught panic INV-2
/// forbids and self-reinforcing, since the same bytes are re-read every launch.
///
/// Clamping to the ceiling stops the abort and replaces it with something almost
/// as bad: the widest legal window forever, on every unlock and every send,
/// never rewritten — the marks only persist when they *change*, so the corrupt
/// bytes survive, and the only user escape (clear app data) destroys
/// `vault.kvsb`. Zero is the honest reading of a value this app could not have
/// written, and it heals: discovery re-probes and writes a sane mark, the next
/// send writes a sane cursor. Neither loses funds — the window is rebuilt from
/// the chain, and `wallet::next_change_index` floors the cursor at the
/// discovered mark, so a cursor read as 0 still lands past the funded history.
fn persisted_count(raw: u32, ceiling: u32) -> u32 {
    if raw > ceiling {
        log::warn!("vault: persisted count {raw} is past its {ceiling} ceiling — reading as unset");
        return 0;
    }
    raw
}

/// Read the persisted change cursor (the next-unused change index). A missing,
/// malformed or out-of-range file reads as 0 — a fresh wallet has used no change
/// addresses, and an impossible one is not evidence (see [`persisted_count`]).
pub(crate) fn change_cursor() -> u32 {
    let raw = change_cursor_path()
        .ok()
        .and_then(|p| fs::read(p).ok())
        .filter(|b| b.len() == 4)
        .map(|b| u32::from_le_bytes([b[0], b[1], b[2], b[3]]))
        .unwrap_or(0);
    persisted_count(raw, MAX_CHANGE_CURSOR)
}

/// Persist the change cursor atomically — advanced only after a fully-broadcast
/// send (D-041), so an abandoned/failed send never burns an index.
///
/// Refuses to write past [`MAX_CHANGE_CURSOR`], so the file can never hold a
/// value [`change_cursor`] reads as unset. Reaching that is 100 000 sends from
/// one device; past it, change addresses repeat from the last index, which is a
/// linkability regression stated in the log rather than a silent fall back to
/// indices the wallet's own history already spent from.
pub(crate) fn set_change_cursor(next: u32) -> Result<(), AppError> {
    if next > MAX_CHANGE_CURSOR {
        log::warn!(
            "vault: change cursor is at its {MAX_CHANGE_CURSOR} ceiling — not advancing; \
             change addresses repeat from here (D-041 fresh-per-send no longer holds)"
        );
        return Ok(());
    }
    atomic_write(&change_cursor_path()?, &next.to_le_bytes())
        .map_err(|e| AppError::io("write change cursor", e))
}

/// App-private path for the discovery high-water marks: the highest FUNDED
/// receive and change index observed on chain. Public data (two indices), same
/// `wallet/` subdir, no encryption (INV-3).
pub(crate) fn scan_window_path() -> Result<PathBuf, AppError> {
    Ok(vault_dir()?.join("wallet").join("scan.window"))
}

/// Read the persisted `(receive_seen, change_seen)` discovery marks — COUNTS of
/// indices needing coverage (`highest_funded + 1`), never bare indices, so that 0
/// means "nothing found" and cannot be confused with "index 0 is funded".
/// Missing or
/// malformed reads as `(0, 0)` — nothing discovered yet, so the caller falls
/// back to the fixed gap limit.
///
/// **Deliberately not `change.cursor`.** That file counts change indices *this
/// app* burned on its own sends (D-041); it is written only after a successful
/// broadcast and knows nothing about a wallet used elsewhere. Conflating the two
/// is precisely what let a restored wallet watch 30 addresses while its funds
/// sat at change index 77 — a local send-counter was standing in for a fact
/// about the chain. Two files, two meanings, neither pretending to be the other.
///
/// Each mark is validated by [`persisted_count`] against [`MAX_SCAN_MARK`] and
/// OR-ed with what this process has already learned (see
/// [`set_scan_high_water`]), so the window never depends on a disk write having
/// succeeded.
pub(crate) fn scan_high_water() -> (u32, u32) {
    let (disk_receive, disk_change) = scan_window_path()
        .ok()
        .and_then(|p| fs::read(p).ok())
        .filter(|b| b.len() == 8)
        .map(|b| {
            (
                persisted_count(u32::from_le_bytes([b[0], b[1], b[2], b[3]]), MAX_SCAN_MARK),
                persisted_count(u32::from_le_bytes([b[4], b[5], b[6], b[7]]), MAX_SCAN_MARK),
            )
        })
        .unwrap_or((0, 0));
    // The memo goes through the same validation as the disk half — one
    // validation point that covers only one of two inputs is not one.
    let (memo_receive, memo_change) = SCAN_MARKS
        .lock()
        .unwrap_or_else(PoisonError::into_inner)
        .map(|(r, c)| {
            (
                persisted_count(r, MAX_SCAN_MARK),
                persisted_count(c, MAX_SCAN_MARK),
            )
        })
        .unwrap_or((0, 0));
    (disk_receive.max(memo_receive), disk_change.max(memo_change))
}

/// What a discovery pass has learned **this process**, whether or not the write
/// to disk stuck. Held because the failure is otherwise silent and expensive: a
/// successful probe followed by a failed persist used to leave the caller
/// re-reading the OLD marks off disk and opening on the narrow window — the
/// exact stranding this whole mechanism exists to prevent — for a wallet that
/// had just proved where its funds were. A failed write now costs the NEXT
/// launch one re-probe and costs this session nothing.
///
/// Monotonic and process-lifetime — it survives a vault lock on purpose (see
/// [`lock_vault`]); only the test harness resets it, because tests fabricate
/// several fresh vault dirs inside one process.
static SCAN_MARKS: Mutex<Option<(u32, u32)>> = Mutex::new(None);

/// Record the discovery marks — in memory first, then to disk.
///
/// Monotonic in BOTH stores, structurally: the max is taken once and the same
/// values go to memory and to disk. Persisting the caller's raw arguments while
/// max-ing only the memo would leave on-disk monotonicity resting on the one
/// call site that happens to compute it correctly — and a future second caller
/// narrowing the marks means the next launch opens on the narrow window, which
/// is the original defect. A scan that finds nothing must never shrink a window
/// that previously found something, or a transient RPC failure would strand
/// funds we had already learned to watch.
pub(crate) fn set_scan_high_water(receive_hi: u32, change_hi: u32) -> Result<(), AppError> {
    let (receive_hi, change_hi) = {
        let mut memo = SCAN_MARKS.lock().unwrap_or_else(PoisonError::into_inner);
        let (prev_receive, prev_change) = memo.unwrap_or((0, 0));
        let grown = (prev_receive.max(receive_hi), prev_change.max(change_hi));
        *memo = Some(grown);
        grown
    };
    let mut bytes = [0u8; 8];
    bytes[..4].copy_from_slice(&receive_hi.to_le_bytes());
    bytes[4..].copy_from_slice(&change_hi.to_le_bytes());
    atomic_write(&scan_window_path()?, &bytes).map_err(|e| AppError::io("write scan window", e))
}

/// Derive the public receive + change address window from the unlocked vault,
/// for the wallet-sync engine. INV-1: the seed and the `KeyChain` NEVER leave
/// this module — the keychain reference is held only under the `VAULT` lock and
/// only public [`Address`] values are returned. The single derivation site (the
/// two-consumer seam, now wired): the SAME window is watched by the `UtxoContext`
/// (via the engine) and registered with the `VaultSigner` ([`build_wallet_signer`]).
/// `change_count` widens with the change cursor (D-041) so used change addresses
/// are re-watched after a restart. Errors if locked.
/// Returns `(all_watched, change_only)`: the full receive+change window to watch,
/// and — separately — the change addresses, so the sync engine can tell our own
/// returning change from a real deposit (a UTXO at a change address is never a
/// deposit; D — device find 2026-06-15).
pub(crate) fn derive_wallet_addresses(
    receive_count: u32,
    change_count: u32,
) -> Result<(Vec<Address>, Vec<Address>), AppError> {
    let (receive, change) = derive_wallet_branches(receive_count, change_count)?;
    let all = receive.into_iter().chain(change.iter().cloned()).collect();
    Ok((all, change))
}

/// The same single derivation site, returning the branches **separately** as
/// `(receive, change)`.
///
/// Exists because address discovery needs the receive branch on its own, and
/// taking it as `&all[..receive_count]` made a cross-module layout contract —
/// "the concatenation is receive-then-change" — load-bearing with nothing but a
/// comment holding it. Correct today and unable to panic, but if that order ever
/// flipped, discovery would read change balances as receive indices and the
/// window would widen on the wrong branch. A tuple cannot be misread.
pub(crate) fn derive_wallet_branches(
    receive_count: u32,
    change_count: u32,
) -> Result<(Vec<Address>, Vec<Address>), AppError> {
    let guard = VAULT.lock().unwrap_or_else(PoisonError::into_inner);
    let vault = guard
        .as_ref()
        .ok_or_else(|| AppError::msg("wallet is locked — cannot derive addresses"))?;
    let keychain = vault.keychain();
    let mut receive = Vec::with_capacity(receive_count as usize);
    for index in 0..receive_count {
        receive.push(keychain.receive_address(index).map_err(AppError::core)?);
    }
    let mut change = Vec::with_capacity(change_count as usize);
    for index in 0..change_count {
        change.push(keychain.change_address(index).map_err(AppError::core)?);
    }
    Ok((receive, change))
}

// `change_address_at(index)` lived here until Wave B. Its last caller was the
// storage-mass hint in `send.rs`, which had no business deriving a fresh
// `change/N` at all — payment change returns to `receive/0`
// (`payment_change_address`), and pricing the hint against a different coin
// shape than the send uses made it wrong as well as inconsistent. Nothing is
// lost by its removal: it was exactly `wallet_address_at(Branch::Change, index)`
// below, which any future caller with a real reason can use. Deleting it makes
// the rule structural instead of a comment someone has to notice.

/// The watched-window address at an arbitrary `(branch, index)` slot — the
/// P2.3 re-seal-to-self target (a conversation's §0.7 bound slot). Public
/// data, same single derivation site. Errors if locked.
pub(crate) fn wallet_address_at(branch: Branch, index: u32) -> Result<Address, AppError> {
    let guard = VAULT.lock().unwrap_or_else(PoisonError::into_inner);
    let vault = guard
        .as_ref()
        .ok_or_else(|| AppError::msg("wallet is locked"))?;
    vault
        .keychain()
        .address(branch, index)
        .map_err(AppError::core)
}

/// Build a [`VaultSigner`] for a send, registering the SAME watched window
/// (receive `0..receive_count` + change `0..change_count`) so `try_sign` resolves
/// any input the Generator selects, plus the fresh change. The signer holds a
/// Weak ref to the keychain (the lock kill switch); keys are derived transiently
/// per signature and zeroized (signer.rs). INV-1: the keychain stays inside this
/// module — only the opaque signer (no key table in memory) leaves. Errors if locked.
pub(crate) fn build_wallet_signer(
    receive_count: u32,
    change_count: u32,
) -> Result<VaultSigner, AppError> {
    let guard = VAULT.lock().unwrap_or_else(PoisonError::into_inner);
    let vault = guard
        .as_ref()
        .ok_or_else(|| AppError::msg("wallet is locked — cannot sign"))?;
    let signer = vault.signer();
    for index in 0..receive_count {
        signer
            .register(Branch::Receive, index)
            .map_err(AppError::core)?;
    }
    for index in 0..change_count {
        signer
            .register(Branch::Change, index)
            .map_err(AppError::core)?;
    }
    Ok(signer)
}

/// The wallet's primary receive address (receive index 0), for the Receive
/// sheet. An address is PUBLIC (derived from the account xpub) — INV-1 governs
/// secrets, not addresses — so it may cross the FFI. Errors if the vault is
/// locked. (Next-unused-address rotation is deferred; P1.5 shows index 0.)
pub fn vault_receive_address() -> Result<String, AppError> {
    let guard = VAULT.lock().unwrap_or_else(PoisonError::into_inner);
    let vault = guard
        .as_ref()
        .ok_or_else(|| AppError::msg("wallet is locked"))?;
    let address: String = vault
        .keychain()
        .receive_address(0)
        .map_err(AppError::core)?
        .into();
    Ok(address)
}

fn now_unix() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

// ── Atomic storage (temp + fsync + rename; power-cut-safe) ────────────────

/// Write `bytes` to `path` atomically: a power cut mid-write leaves the old
/// file intact, never a half-written one (P1.1-audit corruption vector). Temp
/// file in the SAME directory → fsync data → rename (atomic on POSIX) → fsync
/// the directory so the rename itself is durable. std-only (no new dep).
/// `pub(crate)` so the wallet/send lanes reuse it (the change cursor, P1.6).
pub(crate) fn atomic_write(path: &Path, bytes: &[u8]) -> io::Result<()> {
    let dir = path
        .parent()
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "path has no parent dir"))?;
    let name = path
        .file_name()
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "path has no file name"))?;
    // Create the parent on the way in. `scan.window` is the first writer into
    // `wallet/` on a fresh install, and the failure it used to produce was
    // silent in the worst possible way: the write errors, the caller reads it as
    // "discovery failed", and the wallet opens on the 30-wide window — on
    // exactly the restored wallet the mark exists for.
    fs::create_dir_all(dir)?;
    let tmp = dir.join(format!(".{}.tmp", name.to_string_lossy()));
    {
        let mut f = fs::File::create(&tmp)?;
        f.write_all(bytes)?;
        f.sync_all()?; // data on disk before the rename
    }
    fs::rename(&tmp, path)?; // atomic replace within the directory
                             // Best-effort directory fsync: makes the rename survive a power cut.
                             // The rename's atomicity does not depend on it (it can't tear).
    if let Ok(dirf) = fs::File::open(dir) {
        let _ = dirf.sync_all();
    }
    Ok(())
}

fn read_lockout() -> Lockout {
    lockout_path()
        .ok()
        .and_then(|p| fs::read(p).ok())
        .and_then(|b| Lockout::from_bytes(&b))
        .unwrap_or_default()
}

fn write_lockout(l: Lockout) -> Result<(), AppError> {
    atomic_write(&lockout_path()?, &l.to_bytes()).map_err(|e| AppError::io("write lockout", e))
}

// ── Status ────────────────────────────────────────────────────────────────

fn is_unlocked() -> bool {
    VAULT
        .lock()
        .unwrap_or_else(PoisonError::into_inner)
        .is_some()
}

fn current_status() -> VaultStatus {
    let lockout = read_lockout();
    VaultStatus {
        exists: blob_path().map(|p| p.exists()).unwrap_or(false),
        unlocked: is_unlocked(),
        locked_out_until_unix: lockout.active_until(now_unix()),
        failed_attempts: lockout.failed_attempts,
    }
}

fn status_tx() -> &'static broadcast::Sender<VaultStatus> {
    STATUS_TX.get_or_init(|| broadcast::channel(16).0)
}

fn broadcast_status() {
    let _ = status_tx().send(current_status()); // fails only with no subscribers
}

/// Sample the lock generation. Every unlock lane calls this **before** its slow
/// work starts, and presents the value back to [`set_vault_if_current`].
fn lock_epoch() -> u64 {
    let _guard = VAULT.lock().unwrap_or_else(PoisonError::into_inner);
    LOCK_EPOCH.load(Ordering::SeqCst)
}

/// Install a freshly unlocked vault — unless a lock landed since `epoch`.
///
/// Returns `false` when the install was refused, in which case `v` drops here
/// and its keychain Arc with it. The caller must NOT report an unlocked vault
/// on a `false`; the truth goes out over [`broadcast_status`], which is what
/// the Dart shell actually gates on (it never shows home optimistically).
#[must_use]
fn set_vault_if_current(v: UnlockedVault, epoch: u64) -> bool {
    let mut guard = VAULT.lock().unwrap_or_else(PoisonError::into_inner);
    if LOCK_EPOCH.load(Ordering::SeqCst) != epoch {
        log::info!("vault install refused — a lock landed while it was being unlocked");
        return false;
    }
    *guard = Some(v);
    true
}

// ── FRB surface ───────────────────────────────────────────────────────────

/// Hand the bridge the platform's app-private directory (INV-3). Idempotent
/// for the same path (hot restart re-calls it); a later call with a DIFFERENT
/// path is refused — silently re-homing the vault would strand the blob and
/// the lockout state where no caller looks (custody, not configuration).
pub fn init_vault(app_private_dir: String) -> Result<(), AppError> {
    let new = PathBuf::from(app_private_dir);
    let mut dir = VAULT_DIR.lock().unwrap_or_else(PoisonError::into_inner);
    match dir.as_ref() {
        Some(current) if *current != new => {
            return Err(AppError::msg(
                "vault dir already initialised to a different path; refusing to re-home",
            ));
        }
        _ => *dir = Some(new),
    }
    drop(dir);
    broadcast_status();
    Ok(())
}

/// Subscribe to vault status. Paints the current state immediately, then on
/// every change. One stream per process; survives Dart hot restart (re-attach).
pub async fn vault_status_stream(sink: StreamSink<VaultStatus>) -> Result<(), AppError> {
    let mut rx = status_tx().subscribe();
    let _ = sink.add(current_status());
    tokio::spawn(async move {
        loop {
            match rx.recv().await {
                Ok(s) => {
                    if sink.add(s).is_err() {
                        break;
                    }
                }
                Err(RecvError::Lagged(_)) => continue,
                Err(RecvError::Closed) => break,
            }
        }
    });
    Ok(())
}

/// Whether a sealed blob exists at rest.
pub fn vault_exists() -> bool {
    blob_path().map(|p| p.exists()).unwrap_or(false)
}

// ── P1.4 create ceremony (two-step: generate → hold → reveal → seal) ────────
// D-038, debt repaid at the P1.4 device pass. The retired `create_vault` (a
// one-shot generate+seal that never surfaced the phrase, so it could not back a
// real backup) is GONE — these two-step fns ARE the onboarding surface. The live
// phrase is held in `CREATE_CEREMONY` and shown only by the native reveal/verify
// surface over the JNI lane (D-037) — never FRB.

/// Begin a create ceremony: generate a fresh 12-word mnemonic and hold it for
/// the native reveal/verify surface. Refuses if a vault already exists (one
/// wallet per install) or a ceremony is already in progress (seal or abandon the
/// prior one first). The phrase never crosses FRB.
pub fn begin_create() -> Result<(), AppError> {
    if blob_path()?.exists() {
        return Err(AppError::msg(
            "a vault already exists; refusing to overwrite",
        ));
    }
    let mut slot = CREATE_CEREMONY
        .lock()
        .unwrap_or_else(PoisonError::into_inner);
    if slot.is_some() {
        return Err(AppError::msg("a create ceremony is already in progress"));
    }
    *slot = Some(MnemonicCeremony::generate(DEFAULT_WORD_COUNT).map_err(AppError::core)?);
    log::info!("create ceremony begun (12 words held; no secret values)");
    Ok(())
}

/// **How many words a create ceremony draws unless the user says otherwise.**
///
/// Twelve, and D-312 did not change that — it changed only whether 24 is
/// reachable. 12 words is 128 bits, which already saturates secp256k1's
/// ~128-bit effective security; 24 is offered for parity with the wallets users
/// arrive from, and **no copy anywhere may say or imply it is more secure**.
pub const DEFAULT_WORD_COUNT: usize = 12;

/// How many words the held ceremony has. A count, not a secret — the create
/// screen needs it to name the extra word by its ordinal (a *13th* for twelve,
/// a *25th* for twenty-four), and getting that wrong puts a wrong label on the
/// one piece of paper that restores the wallet.
pub fn ceremony_word_count() -> Result<u32, AppError> {
    CREATE_CEREMONY
        .lock()
        .unwrap_or_else(PoisonError::into_inner)
        .as_ref()
        .map(|c| c.word_count() as u32)
        .ok_or_else(|| AppError::msg("no create ceremony in progress"))
}

/// **Redraw the held ceremony at a different word count** — the `12 | 24`
/// control on `O3`, which lives on the native reveal surface (D-312).
///
/// Called over the JNI lane, not FRB, because the control is a native view and
/// the words it is about to redraw never cross to Dart. The old mnemonic is
/// dropped — zeroizing its phrase — before the new one exists, so the two are
/// never both resident.
///
/// Refuses if a vault already exists or no ceremony is in progress, so this can
/// never become a second door into creating one.
///
/// **Build, then swap** — and the order is the whole safety property. Dropping
/// the old phrase first would mean an `OsRng` failure or a bad count leaves NO
/// ceremony, while the screen that called this still shows a grid and still
/// believes the words on it are live: the user would walk the quiz on a phrase
/// Rust no longer holds and discover it at the seal. Building first costs one
/// moment with two zeroize-on-drop mnemonics resident, and buys a failure that
/// changes nothing at all (`ffi-leak-auditor`, D-312).
#[cfg_attr(not(target_os = "android"), allow(dead_code))]
pub(crate) fn regenerate_ceremony(word_count: usize) -> Result<(), AppError> {
    if blob_path()?.exists() {
        return Err(AppError::msg(
            "a vault already exists; refusing to overwrite",
        ));
    }
    let mut slot = CREATE_CEREMONY
        .lock()
        .unwrap_or_else(PoisonError::into_inner);
    if slot.is_none() {
        return Err(AppError::msg("no create ceremony in progress"));
    }
    let fresh = MnemonicCeremony::generate(word_count).map_err(AppError::core)?;
    // The assignment drops the old mnemonic, zeroizing its phrase (D-038).
    *slot = Some(fresh);
    log::info!("create ceremony redrawn ({word_count} words held; no secret values)");
    Ok(())
}

/// Abandon an in-progress create ceremony (back-gesture / cancel): drops the
/// held mnemonic, zeroizing the phrase. Idempotent (a no-op if none is held).
pub fn abandon_create() {
    if CREATE_CEREMONY
        .lock()
        .unwrap_or_else(PoisonError::into_inner)
        .take()
        .is_some()
    {
        log::info!("create ceremony abandoned");
    }
    // A pepper installed for a seal that will now never run must not outlive
    // it, exactly as in `lock_vault` (D-312). Abandon is the OTHER way a
    // ceremony ends, and it was the one this was missing (`ffi-leak-auditor`).
    if take_pepper().is_some() {
        log::info!("device pepper dropped (ceremony abandoned)");
    }
}

/// Complete a create ceremony: seal the held mnemonic's seed under `passphrase`,
/// persist the blob atomically, and leave the vault unlocked. The optional
/// `extra_word` (13th word / BIP39 passphrase) is restricted to **ASCII** on the
/// create path (D-031.5; `mnemonic.rs::into_seed`): the pinned `to_seed` does no
/// NFKD, so a non-ASCII extra word would silently derive a different wallet on a
/// normalizing implementation — refused here so a NEW backup stays portable. The
/// cheap checks (ASCII, vault-absent, ceremony-present) run BEFORE the ceremony
/// is consumed, so a rejected attempt leaves it held for a retry.
pub fn seal_and_persist(
    passphrase: Vec<u8>,
    extra_word: Vec<u8>,
    params: VaultKdfParams,
    input_kind: VaultInputKind,
) -> Result<(), AppError> {
    let passphrase = Zeroizing::new(passphrase);
    let extra_word = Zeroizing::new(extra_word);
    if !extra_word.is_ascii() {
        return Err(AppError::msg(
            "extra word must be ASCII — a non-ASCII word can derive a different wallet elsewhere",
        ));
    }
    if blob_path()?.exists() {
        return Err(AppError::msg(
            "a vault already exists; refusing to overwrite",
        ));
    }
    // **Is there a ceremony at all** — asked before the binding, and without
    // consuming it. A lifecycle lock landing mid-ceremony drops both the phrase
    // AND the installed pepper, so `binding_for` running first would answer
    // *this phone cannot hardware-bind the vault* on a phone that can: the
    // wrong cause, on the exact failure the honest error was written for
    // (`consensus-auditor`, D-312).
    if CREATE_CEREMONY
        .lock()
        .unwrap_or_else(PoisonError::into_inner)
        .is_none()
    {
        return Err(AppError::msg("no create ceremony in progress"));
    }
    // **Before the ceremony is consumed**, with the other cheap checks — this
    // function's contract is that a rejected attempt leaves the phrase HELD for
    // a retry. Below the `take()` it was not: a PIN chosen on a phone whose
    // Keystore hiccupped at exactly this moment would have destroyed a phrase
    // the user had already revealed, written on paper and passed a quiz on, and
    // handed them a different one to write down again (`ffi-leak-auditor`,
    // D-312).
    let pepper = binding_for(input_kind, &passphrase)?;
    // Sampled before the KDF: a lifecycle lock landing any time after this
    // point must win over the install below (F3).
    let epoch = lock_epoch();
    let ceremony = CREATE_CEREMONY
        .lock()
        .unwrap_or_else(PoisonError::into_inner)
        .take()
        .ok_or_else(|| AppError::msg("no create ceremony in progress"))?;
    let seed = ceremony.into_seed(&extra_word).map_err(AppError::core)?;
    let blob = seal_seed(
        &seed,
        &passphrase,
        params.into(),
        input_kind.into(),
        pepper.as_ref().map(|p| p.as_slice()),
    )
    .map_err(AppError::core)?;
    atomic_write(&blob_path()?, &blob).map_err(|e| AppError::io("write blob", e))?;
    let installed = set_vault_if_current(
        UnlockedVault::new(KeyChain::from_seed(seed, Prefix::Mainnet).map_err(AppError::core)?),
        epoch,
    );
    // Still `Ok`: the wallet WAS created and the blob is on disk, so an error
    // here would tell the user their wallet does not exist while it does — and
    // send them into a retry that `refusing to overwrite` will reject. The
    // creation succeeded; it is simply locked, which is what backgrounding
    // during it means. `broadcast_status` carries that.
    if installed {
        log::info!("vault created (path=passphrase scheme=argon2id, ceremony-backed)");
    } else {
        log::info!("vault created (path=passphrase scheme=argon2id) — locked on arrival");
    }
    broadcast_status();
    Ok(())
}

/// **A PIN so guessable that the lockout is the only thing standing behind it.**
///
/// The device binding kills the OFFLINE attack completely — without the phone
/// there is no lane at all. What it cannot touch is a thief holding the phone,
/// who gets `LOCKOUT_FREE_ATTEMPTS` and then roughly a guess an hour forever.
/// Against a uniform 10^6 that is nothing; against the real distribution of
/// human-chosen 6-digit codes it is not, because the top of that distribution is
/// dominated by repeats and runs (`wallet-security-auditor`, D-312).
///
/// So the two shapes that dominate it are refused at the seal: **every digit the
/// same** (`000000`, `111111`, …) and **a run of consecutive digits** in either
/// direction (`123456`, `654321`, …). Ten plus two is a small blocklist, and it
/// is deliberately small — a long list of "weak" codes teaches users to pick the
/// eleventh-most-obvious one, and the honest defence is the lockout plus the
/// binding, not a dictionary.
///
/// Refused at the SEAL rather than in a screen: the bytes are here, this is
/// where the rule cannot be forgotten by the next caller, and a passphrase is
/// never subject to it (any-length ASCII has no such shape).
fn is_trivially_guessable_pin(pin: &[u8]) -> bool {
    if pin.len() < 2 || !pin.iter().all(|b| b.is_ascii_digit()) {
        return false;
    }
    let all_same = pin.windows(2).all(|w| w[0] == w[1]);
    let up = pin.windows(2).all(|w| w[1] == w[0] + 1);
    let down = pin.windows(2).all(|w| w[0] == w[1] + 1);
    all_same || up || down
}

/// **The pepper this seal will use, and the rule that makes the PIN safe.**
///
/// A 6-digit PIN and the hardware binding **ship together or not at all**
/// (D-312, the founder's own condition when he took the option). So a `Digits`
/// vault whose phone cannot produce a pepper is refused here rather than sealed
/// weaker than what it replaces — six digits with no hardware factor would be a
/// real downgrade from the any-length passphrase it is offered instead of, and
/// the one place that can enforce it is the seal.
///
/// A `Passphrase` vault takes the binding when it is available and seals without
/// it when it is not: the binding only ever makes the file harder to attack off
/// the phone, and refusing to create a wallet because a Keystore call failed
/// would be a worse answer than creating the one we ship today.
fn binding_for(
    input_kind: VaultInputKind,
    passphrase: &[u8],
) -> Result<Option<Zeroizing<Vec<u8>>>, AppError> {
    if input_kind == VaultInputKind::Digits && is_trivially_guessable_pin(passphrase) {
        return Err(AppError::msg(
            "that PIN is one of the first anyone would try — pick digits that are not all the \
             same and not in a row",
        ));
    }
    let pepper = take_pepper();
    if pepper.is_none() && input_kind == VaultInputKind::Digits {
        return Err(AppError::msg(
            "this phone cannot hardware-bind the vault, so a 6-digit PIN cannot be used here — \
             choose a passphrase instead",
        ));
    }
    Ok(pepper)
}

/// **Re-wrap a pre-D-312 vault, once, on the unlock that proved the secret.**
///
/// Called with the seed the unseal just produced and the passphrase that opened
/// it, so nothing is guessed and nothing is asked of the user. Three properties
/// make this safe to run against the vault on somebody's only phone:
///
/// 1. **It never runs eagerly.** Not on install, not on launch — only after a
///    correct secret has already unsealed the old blob, so a failure here can
///    never be the thing that stops a user opening their wallet.
/// 2. **The new blob is unsealed again BEFORE the old one is replaced.** A seal
///    that cannot be re-opened is discarded with the original untouched. It
///    costs one extra KDF on one unlock in the app's lifetime, which is the
///    cheapest insurance available against a bug in the derivation path this
///    very commit introduces.
/// 3. **Every failure is non-fatal.** The unlock already succeeded; a migration
///    that cannot complete logs and leaves v1 on disk, and the next unlock tries
///    again. The user is never blocked and never told anything went wrong,
///    because from where they are standing nothing did.
///
/// It is deliberately NOT a `Result` — no caller may make the unlock depend on
/// it.
fn migrate_blob(seed: &SecretSeed, passphrase: &[u8], pepper: Option<&[u8]>) {
    let path = match blob_path() {
        Ok(p) => p,
        Err(_) => return,
    };
    let params: SealParams = VaultKdfParams::tuned().into();
    let fresh = match seal_seed(seed, passphrase, params, InputKind::Passphrase, pepper) {
        Ok(blob) => blob,
        Err(e) => {
            log::warn!("vault migration: re-seal failed ({e}); v1 blob left in place");
            return;
        }
    };
    // Property 2. A re-seal that does not re-open is not written.
    if let Err(e) = unseal_seed(&fresh, passphrase, pepper) {
        log::warn!("vault migration: verify failed ({e}); v1 blob left in place");
        return;
    }
    match atomic_write(&path, &fresh) {
        Ok(()) => log::info!(
            "vault migrated v1 -> v2 (device_bound={})",
            pepper.is_some()
        ),
        Err(e) => log::warn!("vault migration: write failed ({e}); v1 blob left in place"),
    }
}

/// Restore preview (deliverable 2 — the decoy/typo trap): derive the FIRST
/// receive address from a candidate phrase WITHOUT persisting or unlocking. A
/// single wrong word opens a visibly DIFFERENT wallet, so surfacing the derived
/// address lets the user catch a typo before committing instead of landing in a
/// silent empty wallet. The address is public (INV-2 permits it to cross);
/// `phrase`/`extra_word` are the user's `Uint8List`, wiped Dart-side after the
/// call (INV-1 sentence two). Restore accepts any UTF-8 extra word (max
/// compatibility — unlike the ASCII-only create path).
pub fn restore_preview(phrase: Vec<u8>, extra_word: Vec<u8>) -> Result<String, AppError> {
    let phrase = Zeroizing::new(phrase);
    let extra_word = Zeroizing::new(extra_word);
    let seed = MnemonicCeremony::restore(&phrase)
        .map_err(AppError::core)?
        .into_seed(&extra_word)
        .map_err(AppError::core)?;
    let keychain = KeyChain::from_seed(seed, Prefix::Mainnet).map_err(AppError::core)?;
    let address: String = keychain.receive_address(0).map_err(AppError::core)?.into();
    Ok(address)
}

/// Restore-commit (deliverable 2): restore from `phrase` (+ optional
/// `extra_word`), seal the derived seed under `passphrase`, persist, unlock.
/// Refuses if a vault already exists. Any-UTF-8 extra word (restore is the
/// compatibility path; the ASCII restriction is create-only).
pub fn restore_and_persist(
    phrase: Vec<u8>,
    extra_word: Vec<u8>,
    passphrase: Vec<u8>,
    params: VaultKdfParams,
    input_kind: VaultInputKind,
) -> Result<(), AppError> {
    let phrase = Zeroizing::new(phrase);
    let extra_word = Zeroizing::new(extra_word);
    let passphrase = Zeroizing::new(passphrase);
    if blob_path()?.exists() {
        return Err(AppError::msg(
            "a vault already exists; refusing to overwrite",
        ));
    }
    // Sampled before the KDF — see `seal_and_persist` (F3).
    let epoch = lock_epoch();
    let seed = MnemonicCeremony::restore(&phrase)
        .map_err(AppError::core)?
        .into_seed(&extra_word)
        .map_err(AppError::core)?;
    let pepper = binding_for(input_kind, &passphrase)?;
    let blob = seal_seed(
        &seed,
        &passphrase,
        params.into(),
        input_kind.into(),
        pepper.as_ref().map(|p| p.as_slice()),
    )
    .map_err(AppError::core)?;
    atomic_write(&blob_path()?, &blob).map_err(|e| AppError::io("write blob", e))?;
    let installed = set_vault_if_current(
        UnlockedVault::new(KeyChain::from_seed(seed, Prefix::Mainnet).map_err(AppError::core)?),
        epoch,
    );
    if installed {
        log::info!("vault restored (path=passphrase scheme=argon2id)");
    } else {
        log::info!("vault restored (path=passphrase scheme=argon2id) — locked on arrival");
    }
    broadcast_status();
    Ok(())
}

/// Serializes passphrase-unlock attempts end-to-end. The lockout counter is a
/// read-modify-write spanning a seconds-long KDF — unserialized, concurrent
/// failures lose updates (caught LIVE on-device 2026-06-13: two overlapping
/// wrong attempts both recorded `attempt=1`, so a burst of N parallel guesses
/// would count as one — wallet-security item 11). Concurrent attempts have no
/// legitimate use; they wait their turn.
static UNLOCK_GATE: Mutex<()> = Mutex::new(());

/// Unlock via passphrase (Path B). Rate-limit is checked BEFORE the KDF runs
/// (wallet-security 11), so a locked-out attempt costs nothing. On failure the
/// attempt counter advances and persists; on success it resets. Attempts are
/// serialized by [`UNLOCK_GATE`] so every failure is counted.
pub fn unlock_with_passphrase(passphrase: Vec<u8>) -> Result<(), AppError> {
    let _gate = UNLOCK_GATE.lock().unwrap_or_else(PoisonError::into_inner);
    let passphrase = Zeroizing::new(passphrase);
    let now = now_unix();
    let mut lockout = read_lockout();
    if let Some(until) = lockout.active_until(now) {
        let remaining = until.saturating_sub(now);
        log::warn!("vault unlock refused: locked out {remaining}s");
        return Err(AppError::msg(format!(
            "too many attempts — locked out for {remaining} more seconds"
        )));
    }
    log::info!("vault unlock attempt (path=passphrase)");
    // Sampled before the KDF. THIS is the reported repro: press Home inside the
    // ~1 s Argon2id window and the lock used to be overwritten by the unlock it
    // was racing (F3).
    let epoch = lock_epoch();
    let blob = read_blob()?;
    // Taken, not borrowed: the hardware factor is resident for this call and no
    // longer (see [`PEPPER`]). A blob that is not device-bound ignores it — the
    // core refuses to mix a pepper into a vault sealed without one, which is
    // what lets every pre-D-312 vault keep opening on the update that adds it.
    let pepper = take_pepper();
    let pepper = pepper.as_ref().map(|p| p.as_slice());
    // **A vault that is not device-bound is still owed one**, however it got
    // that way — a v1 blob, or a v2 one migrated on an unlock where the
    // Keystore happened to be unavailable. Keying this on the VERSION alone
    // made the binding a one-shot coin flip: a transient failure at the single
    // migrating unlock left the vault permanently unbound, with no later
    // attempt and nothing on the glass, quietly dropping the founder's
    // condition for that user (`consensus-auditor`, D-312).
    let needs_migration = read_facts(&blob)
        .map(|f| f.version < 2 || (!f.device_bound && pepper.is_some()))
        .unwrap_or(false);
    match unseal_seed(&blob, &passphrase, pepper) {
        Ok(seed) => {
            // Before the seed is consumed by the keychain, and only ever after
            // the secret has been proven correct.
            if needs_migration {
                migrate_blob(&seed, &passphrase, pepper);
            }
            let keychain = KeyChain::from_seed(seed, Prefix::Mainnet).map_err(AppError::core)?;
            let installed = set_vault_if_current(UnlockedVault::new(keychain), epoch);
            // The passphrase was right, so the lockout resets either way —
            // refusing the install is a lifecycle decision, never a failed
            // attempt, and counting it as one would let backgrounding the app
            // during an unlock walk the user into a lockout.
            let _ = write_lockout(Lockout::default());
            if installed {
                log::info!("vault unlock ok (path=passphrase)");
            } else {
                log::info!("vault unlock superseded by a lock (path=passphrase)");
            }
            broadcast_status();
            Ok(())
        }
        // **A device-binding refusal is not a failed attempt** (D-312), and
        // counting it as one would be a real defect rather than a strict
        // reading. The secret may be perfectly correct: what failed is that
        // this phone could not produce the pepper — a Keystore that was
        // transiently unavailable, or a file that came from another device. The
        // user cannot fix it by typing anything, so every retry would burn an
        // attempt and walk them into an hour-long lockout for a condition no
        // amount of correct typing resolves. The lockout exists to price
        // GUESSES; this is not one.
        Err(e @ CoreError::DeviceBinding(_)) => {
            log::warn!("vault unlock refused: device binding unavailable");
            broadcast_status();
            Err(AppError::core(e))
        }
        Err(e) => {
            lockout.failed_attempts = lockout.failed_attempts.saturating_add(1);
            let delay = lockout_delay_secs(lockout.failed_attempts);
            if delay > 0 {
                lockout.locked_until_unix = now.saturating_add(delay);
            }
            let _ = write_lockout(lockout);
            log::warn!(
                "vault unlock failed (path=passphrase, attempt={})",
                lockout.failed_attempts
            );
            broadcast_status();
            Err(AppError::core(e))
        }
    }
}

/// Lock the vault. **Contract (D-031.4): "no new operation can start", not
/// "instant erasure".** A sign already in flight holds an upgraded strong ref
/// (from the core Arc/Weak design) and completes; the seed zeroizes when that
/// last ref drops. This fn intentionally exposes no "erased" flag — `VaultStatus`
/// reports `unlocked=false` only — so the bridge can never assert erasure while
/// a sign is concurrently finishing. Also the Flutter lifecycle hook: Dart calls
/// this on background/detach.
pub fn lock_vault() {
    {
        let mut guard = VAULT.lock().unwrap_or_else(PoisonError::into_inner);
        // Bump FIRST, and **unconditionally** — not only when a vault was
        // actually taken. The reported repro is an unlock: the vault is
        // already `None` when Home is pressed, so a bump conditional on
        // `take()` finding something would leave that exact case unguarded and
        // the fix would prove nothing. What is being recorded is the user's
        // intent — "locked as of now" — which is a fact about the lifecycle,
        // not about what happened to be resident.
        //
        // Inside the guard, so this and every `set_vault_if_current` are
        // serialized by one mutex (L73). Only two interleavings exist and both
        // end locked: bump-then-install refuses the install; install-then-bump
        // takes the vault it just installed.
        LOCK_EPOCH.fetch_add(1, Ordering::SeqCst);
        if let Some(vault) = guard.take() {
            vault.lock(); // consumes; drops the bridge's strong Arc
            log::info!("vault locked");
        }
    }
    // A pepper installed for a ceremony that never ran must not outlive it
    // (D-312): the whole point of taking rather than borrowing is that the
    // hardware factor is not resident while the app sits locked.
    if take_pepper().is_some() {
        log::info!("device pepper dropped (lifecycle)");
    }
    // §0.11: a background/detach mid-create must not leave the phrase resident.
    // Dropping the held ceremony zeroizes it (D-038); abandon is idempotent.
    if CREATE_CEREMONY
        .lock()
        .unwrap_or_else(PoisonError::into_inner)
        .take()
        .is_some()
    {
        log::info!("create ceremony dropped (lifecycle)");
    }
    // NOTE: `SCAN_MARKS` deliberately survives a lock. It is tempting to clear
    // it as "vault state", and that would be a real bug: if the persist to disk
    // had failed, clearing the memo makes the re-unlock read `(0, 0)` and
    // rebuild the SIGNER on a 30-wide window — while the sync engine, which is
    // process-lifetime and untouched by a lock, keeps watching the wide one.
    // Visible and unspendable, which is the exact state this whole mechanism
    // exists to prevent. The memo only ever grows, and there is one wallet per
    // install, so keeping it can only widen.
    broadcast_status();
}

/// The user's auto-lock grace in seconds (D-133). `0` = lock the instant the app
/// leaves the foreground, which is both the default and the value any unreadable
/// or impossible file falls back to.
///
/// Enforcement lives Dart-side, in the lifecycle observer that already owns the
/// §0.11 kill switch; this is only where the choice is kept. That split is worth
/// stating because it bounds the guarantee: a grace period is a promise about
/// *this* process's own lifecycle handling, never a claim that a killed process
/// or a debugger honours it.
pub fn vault_lock_grace_secs() -> u32 {
    lock_grace_secs()
}

/// Set the auto-lock grace, clamped to [`MAX_LOCK_GRACE_SECS`] (15 minutes).
pub fn set_vault_lock_grace_secs(secs: u32) -> Result<(), AppError> {
    set_lock_grace_secs(secs)?;
    log::info!("vault: auto-lock grace set to {} s", lock_grace_secs());
    Ok(())
}

fn read_blob() -> Result<Vec<u8>, AppError> {
    fs::read(blob_path()?).map_err(|e| AppError::io("read blob", e))
}

/// Time one Argon2id run at `params` on THIS device (P1.2 §0.3 tuning):
/// seals a throwaway seed under a dummy passphrase and returns elapsed
/// milliseconds. No secrets involved; bounds-checked by the core
/// (8 MiB..=256 MiB, D-031.2). Runs on FRB's worker pool like the real KDF.
pub fn kdf_bench_ms(params: VaultKdfParams) -> Result<u64, AppError> {
    let seed = SecretSeed::from_seed_bytes(Box::new([0u8; 64]));
    let started = std::time::Instant::now();
    seal_seed(
        &seed,
        b"kdf-bench-dummy",
        params.into(),
        InputKind::Passphrase,
        None,
    )
    .map_err(AppError::core)?;
    Ok(started.elapsed().as_millis() as u64)
}

// ── JNI lane entry points (called by `jni_seed`, Android-only) ────────────
// Not `pub`, so FRB never exposes them to Dart — they are the Kotlin↔Rust
// seed lane only.

/// Path-A unlock: load the vault from the raw seed bytes the Keystore Cipher
/// decrypted (delivered over JNI). A biometric unlock is a success like a
/// passphrase one, so it resets the lockout.
#[cfg_attr(not(target_os = "android"), allow(dead_code))]
pub(crate) fn load_vault_from_seed_bytes(seed: Box<[u8; 64]>) -> Result<(), AppError> {
    // Sampled at the JNI hand-off — and note precisely what that does and does
    // NOT cover (F3). The unbounded part of this lane is the BiometricPrompt +
    // Keystore round-trip, and that happens entirely BEFORE Rust is called, so
    // this sample cannot see it. What covers that window is Dart's ceremony
    // deferral: `unlockBiometric` routes through `VaultService.runCeremony`,
    // which holds a §0.11 lock rather than firing it and settles it in its
    // `finally` — which is exactly why the passphrase lanes, which do NOT route
    // through it, were the ones that raced.
    //
    // So this is defence in depth over the sliver from the seed's arrival to
    // the install, and a guard that stays correct if that deferral is ever
    // narrowed. It is not the biometric lane's primary protection, and must
    // not be cited as one.
    let epoch = lock_epoch();
    let keychain = KeyChain::from_seed(SecretSeed::from_seed_bytes(seed), Prefix::Mainnet)
        .map_err(AppError::core)?;
    let installed = set_vault_if_current(UnlockedVault::new(keychain), epoch);
    let _ = write_lockout(Lockout::default());
    if installed {
        log::info!("vault unlock ok (path=biometric)");
    } else {
        log::info!("vault unlock superseded by a lock (path=biometric)");
    }
    broadcast_status();
    Ok(())
}

/// Path-A enroll: hand the live seed to the JNI export so the Keystore Cipher
/// can wrap it under a hardware key. Errors if locked. The returned buffer
/// zeroizes on drop — the JNI side copies it into a Java `byte[]` and drops it.
#[cfg_attr(not(target_os = "android"), allow(dead_code))]
pub(crate) fn export_seed_for_keystore() -> Result<Zeroizing<[u8; 64]>, AppError> {
    let guard = VAULT.lock().unwrap_or_else(PoisonError::into_inner);
    let vault = guard
        .as_ref()
        .ok_or_else(|| AppError::msg("vault is locked; cannot export seed for sealing"))?;
    Ok(vault.with_seed_bytes(|b| Zeroizing::new(*b)))
}

/// Reveal lane (P1.4, D-037): the space-joined words of the in-progress create
/// ceremony, for the native FLAG_SECURE reveal/verify surface to render. The
/// returned buffer zeroizes on drop; the JNI side copies it into a Java `byte[]`,
/// renders, and wipes it (the same JVM residual class as Path-A enroll, D-033).
/// Pre-sized so the join never reallocates (no stray heap fragments). Errors if
/// no ceremony is in progress. Words NEVER cross FRB (INV-1) — only this
/// crate-internal JNI path reads them.
#[cfg_attr(not(target_os = "android"), allow(dead_code))]
pub(crate) fn reveal_ceremony_words() -> Result<Zeroizing<Vec<u8>>, AppError> {
    let guard = CREATE_CEREMONY
        .lock()
        .unwrap_or_else(PoisonError::into_inner);
    let ceremony = guard
        .as_ref()
        .ok_or_else(|| AppError::msg("no create ceremony in progress"))?;
    // 24 words × ~8 bytes + separators sits well under 256; no reallocation.
    let mut buf: Zeroizing<Vec<u8>> = Zeroizing::new(Vec::with_capacity(256));
    for (i, word) in ceremony.words().enumerate() {
        if i > 0 {
            buf.push(b' ');
        }
        buf.extend_from_slice(word.as_bytes());
    }
    Ok(buf)
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use std::sync::atomic::{AtomicU64, Ordering};

    // Serializes every test that touches the process-wide VAULT/VAULT_DIR so
    // cargo's default parallel runner can't let them clobber each other (L7).
    static TEST_LOCK: Mutex<()> = Mutex::new(());
    static COUNTER: AtomicU64 = AtomicU64::new(0);

    // Fast, in-bounds KDF so the suite stays quick (mirrors core's TEST_PARAMS).
    pub(crate) fn cheap_params() -> VaultKdfParams {
        VaultKdfParams {
            m_cost_kib: 8 * 1024,
            t_cost: 1,
            p_cost: 1,
        }
    }

    fn fresh_dir() -> PathBuf {
        let mut p = std::env::temp_dir();
        p.push(format!(
            "kv-vault-test-{}-{}",
            std::process::id(),
            COUNTER.fetch_add(1, Ordering::Relaxed)
        ));
        fs::create_dir_all(&p).unwrap();
        p
    }

    /// Enter a clean global-vault world: lock the serializer, point VAULT_DIR
    /// at a fresh temp dir, clear any leftover unlocked vault. Returns the guard
    /// (held for the test's lifetime) and the dir.
    pub(crate) fn enter() -> (std::sync::MutexGuard<'static, ()>, PathBuf) {
        let guard = TEST_LOCK.lock().unwrap_or_else(PoisonError::into_inner);
        let dir = fresh_dir();
        *VAULT_DIR.lock().unwrap_or_else(PoisonError::into_inner) = Some(dir.clone());
        *VAULT.lock().unwrap_or_else(PoisonError::into_inner) = None;
        *CREATE_CEREMONY
            .lock()
            .unwrap_or_else(PoisonError::into_inner) = None;
        // The discovery memo outlives a temp dir (it is process state, not
        // vault state), so a test that widened the window would otherwise hand
        // the next test a wallet that had already found funds.
        *SCAN_MARKS.lock().unwrap_or_else(PoisonError::into_inner) = None;
        // Same reasoning for the D-312 pepper: it is process state, so a test
        // that installed one and did not spend it would hand the next test a
        // device binding it never asked for.
        *PEPPER.lock().unwrap_or_else(PoisonError::into_inner) = None;
        (guard, dir)
    }

    // ── F3: a lock landing during a slow KDF is not overwritten ───────────

    fn a_vault() -> UnlockedVault {
        UnlockedVault::new(
            KeyChain::from_seed(
                SecretSeed::from_seed_bytes(Box::new([7u8; 64])),
                Prefix::Mainnet,
            )
            .unwrap(),
        )
    }

    /// **The race, as reported.** `set_vault` was unconditional, so a §0.11
    /// lifecycle lock that landed while Argon2id was running got clobbered by
    /// the unlock it was racing — leaving the wallet unlocked in the background
    /// with its auto-lock timer already cancelled Dart-side.
    #[test]
    fn a_lock_during_the_kdf_wins_over_the_install_it_raced() {
        let (_g, _dir) = enter();
        // The unlock lane samples the epoch, then spends a second in the KDF…
        let epoch = lock_epoch();
        // …and the user presses Home inside that window.
        lock_vault();
        // The install must now be refused, not applied.
        assert!(
            !set_vault_if_current(a_vault(), epoch),
            "an install from before the lock must be refused"
        );
        assert!(!is_unlocked(), "the wallet must still be locked");
    }

    /// The bump is UNCONDITIONAL, and this is the test that says why. The
    /// reported repro is an unlock, so `VAULT` is already `None` when Home is
    /// pressed — a generation bumped only when `take()` found something would
    /// leave exactly that case unguarded, and the fix would prove nothing.
    #[test]
    fn locking_an_already_locked_vault_still_supersedes_an_unlock_in_flight() {
        let (_g, _dir) = enter();
        assert!(!is_unlocked(), "precondition: locked, as at an unlock");
        let epoch = lock_epoch();
        lock_vault(); // takes nothing — and must still count
        assert!(!set_vault_if_current(a_vault(), epoch));
        assert!(!is_unlocked());
    }

    /// The other interleaving, which must still succeed: no lock landed, so the
    /// unlock installs. A guard that refused here would simply break unlocking.
    #[test]
    fn an_uncontested_unlock_still_installs() {
        let (_g, _dir) = enter();
        let epoch = lock_epoch();
        assert!(set_vault_if_current(a_vault(), epoch));
        assert!(is_unlocked());
        lock_vault();
        assert!(!is_unlocked());
    }

    /// Install-then-lock — the opposite order — must also end locked. Both
    /// interleavings are correct; that is the point of putting the generation
    /// under the same mutex as the state it guards (L73).
    #[test]
    fn a_lock_after_the_install_takes_the_vault_it_found() {
        let (_g, _dir) = enter();
        let epoch = lock_epoch();
        assert!(set_vault_if_current(a_vault(), epoch));
        lock_vault();
        assert!(!is_unlocked());
        // And the stale epoch cannot be replayed to resurrect it.
        assert!(!set_vault_if_current(a_vault(), epoch));
        assert!(!is_unlocked());
    }

    /// Driven on real threads rather than by simulating the interleaving, so
    /// the claim is about the lock discipline and not about the order these
    /// statements happen to be written in. Whichever side wins, the wallet ends
    /// locked — never unlocked-after-a-lock.
    #[test]
    fn the_race_ends_locked_whichever_side_wins() {
        let (_g, _dir) = enter();
        for _ in 0..200 {
            *VAULT.lock().unwrap_or_else(PoisonError::into_inner) = None;
            let epoch = lock_epoch();
            let installer = std::thread::spawn(move || set_vault_if_current(a_vault(), epoch));
            let locker = std::thread::spawn(lock_vault);
            let installed = installer.join().unwrap();
            locker.join().unwrap();
            assert!(
                !is_unlocked(),
                "a lock and an install raced and left the vault UNLOCKED (installed={installed})"
            );
        }
    }

    // ── Pure-logic tests (no global state) ────────────────────────────────

    #[test]
    fn lockout_backoff_is_zero_under_budget_then_grows_and_caps() {
        for n in 0..=LOCKOUT_FREE_ATTEMPTS {
            assert_eq!(lockout_delay_secs(n), 0, "no lockout at {n} failures");
        }
        assert_eq!(lockout_delay_secs(LOCKOUT_FREE_ATTEMPTS + 1), 30);
        assert_eq!(lockout_delay_secs(LOCKOUT_FREE_ATTEMPTS + 2), 60);
        assert_eq!(lockout_delay_secs(LOCKOUT_FREE_ATTEMPTS + 3), 120);
        // Caps at one hour, never overflows however many failures.
        assert_eq!(lockout_delay_secs(100), 3600);
        assert_eq!(lockout_delay_secs(u32::MAX), 3600);
    }

    #[test]
    fn lockout_serialises_round_trip_and_rejects_wrong_length() {
        let l = Lockout {
            failed_attempts: 7,
            locked_until_unix: 1_700_000_123,
        };
        assert_eq!(Lockout::from_bytes(&l.to_bytes()), Some(l));
        assert_eq!(Lockout::from_bytes(&[0u8; 11]), None);
        assert_eq!(Lockout::from_bytes(&[]), None);
    }

    #[test]
    fn the_cursor_never_writes_a_value_its_own_reader_would_reject() {
        let (_g, _dir) = enter();
        // The writer's whole range round-trips.
        for value in [0u32, 1, 77, MAX_CHANGE_CURSOR - 1, MAX_CHANGE_CURSOR] {
            set_change_cursor(value).unwrap();
            assert_eq!(change_cursor(), value);
        }
        // And past the ceiling it holds rather than writing something that
        // reads back as unset — which would drop the next send to the discovery
        // mark and reuse indices the wallet already spent from.
        set_change_cursor(MAX_CHANGE_CURSOR + 1).unwrap();
        assert_eq!(change_cursor(), MAX_CHANGE_CURSOR);
        set_change_cursor(u32::MAX).unwrap();
        assert_eq!(change_cursor(), MAX_CHANGE_CURSOR);
    }

    #[test]
    fn an_unreadable_lock_grace_buys_an_attacker_nothing() {
        let (_g, _dir) = enter();
        // Unset is the strictest setting, not the loosest — a fresh install locks
        // the instant it leaves the foreground, exactly as it did before D-133.
        assert_eq!(lock_grace_secs(), 0);

        for value in [0u32, 30, 60, 300, MAX_LOCK_GRACE_SECS] {
            set_lock_grace_secs(value).unwrap();
            assert_eq!(lock_grace_secs(), value);
        }

        // Past the ceiling the WRITER clamps, so the file can never hold a value
        // the reader would reject.
        set_lock_grace_secs(u32::MAX).unwrap();
        assert_eq!(lock_grace_secs(), MAX_LOCK_GRACE_SECS);

        // And a file this app could not have written reads as 0. This is the
        // direction that matters: every other persisted count in this module
        // falls back to the value that costs the user a re-probe, but an
        // out-of-range grace must never be able to BUY unlock time — the failure
        // mode is someone else holding the phone.
        atomic_write(&lock_grace_path().unwrap(), &u32::MAX.to_le_bytes()).unwrap();
        assert_eq!(lock_grace_secs(), 0, "corruption must lock, never linger");
        // Truncated / absent are the same answer.
        atomic_write(&lock_grace_path().unwrap(), &[0u8; 2]).unwrap();
        assert_eq!(lock_grace_secs(), 0);
    }

    #[test]
    fn an_impossible_persisted_count_reads_as_unset_never_as_the_ceiling() {
        // In range, including the boundary, passes through untouched.
        assert_eq!(persisted_count(0, MAX_SCAN_MARK), 0);
        assert_eq!(persisted_count(78, MAX_SCAN_MARK), 78);
        assert_eq!(persisted_count(MAX_SCAN_MARK, MAX_SCAN_MARK), MAX_SCAN_MARK);

        // Out of range is UNSET, not clamped — the distinction the second
        // wallet-security audit turned on. Clamping stops the SIGABRT and
        // replaces it with a permanent brick: the widest legal window on every
        // unlock and every send, and the bad bytes are never rewritten, because
        // the marks only persist when they change. Zero re-probes and heals.
        assert_eq!(persisted_count(MAX_SCAN_MARK + 1, MAX_SCAN_MARK), 0);
        assert_eq!(persisted_count(u32::MAX, MAX_SCAN_MARK), 0);
        assert_eq!(persisted_count(u32::MAX, MAX_CHANGE_CURSOR), 0);
    }

    #[test]
    fn a_mark_the_deepest_scan_can_produce_survives_the_write_and_read_back() {
        // The landmine the manual "scan for more addresses" control walks onto,
        // and the one thing the compile assert in `wallet.rs` cannot express.
        //
        // That assert pins `MAX_SCAN_MARK` to `MANUAL_DISCOVERY_DEPTH`, so the
        // two constants can never drift. What it cannot check is the CONSEQUENCE
        // — that a mark a real pass produces makes it through `atomic_write`,
        // back off disk, and through `persisted_count` still meaning what it
        // meant. Left at the old 512 ceiling, a manual scan finding funds at
        // change index 1500 wrote mark 1501 and read it back as 0: the scan
        // reports success, the marks silently vanish, and the wallet reopens on
        // a 30-wide window. The user taps "scan deeper", is told it worked, and
        // the funds stay invisible.
        let (_g, _dir) = enter();
        let deepest = MAX_SCAN_MARK; // = highest_funded_index + 1 at full depth
        set_scan_high_water(deepest, deepest).unwrap();
        assert_eq!(
            scan_high_water(),
            (deepest, deepest),
            "the deepest producible mark read back as something else — \
             a scan that reports success and loses what it found"
        );

        // Straight off disk too, with the process memo taken out of the picture:
        // `scan_high_water` ORs the two, so a memo that happens to hold the right
        // value would mask a file that does not — and the next launch reads only
        // the file.
        let bytes = fs::read(scan_window_path().unwrap()).unwrap();
        assert_eq!(
            (
                persisted_count(
                    u32::from_le_bytes([bytes[0], bytes[1], bytes[2], bytes[3]]),
                    MAX_SCAN_MARK
                ),
                persisted_count(
                    u32::from_le_bytes([bytes[4], bytes[5], bytes[6], bytes[7]]),
                    MAX_SCAN_MARK
                ),
            ),
            (deepest, deepest),
            "the next launch would read these as UNSET and open on the gap limit"
        );
    }

    #[test]
    fn the_scan_marks_are_monotonic_on_disk_and_not_only_in_memory() {
        let (_g, _dir) = enter();
        set_scan_high_water(41, 78).unwrap();
        assert_eq!(scan_high_water(), (41, 78));

        // A caller passing something smaller must not narrow either store. The
        // memo would have absorbed it either way; this asserts the FILE did too,
        // because a next launch reads the file and nothing else.
        set_scan_high_water(0, 12).unwrap();
        let bytes = fs::read(scan_window_path().unwrap()).unwrap();
        assert_eq!(
            (
                u32::from_le_bytes([bytes[0], bytes[1], bytes[2], bytes[3]]),
                u32::from_le_bytes([bytes[4], bytes[5], bytes[6], bytes[7]]),
            ),
            (41, 78),
            "the persisted marks narrowed — the next launch would open short"
        );
        assert_eq!(scan_high_water(), (41, 78));
    }

    #[test]
    fn a_corrupt_scan_window_file_reads_as_unset_and_the_next_pass_heals_it() {
        let (_g, _dir) = enter();
        let path = scan_window_path().unwrap();
        atomic_write(&path, &[0xffu8; 8]).unwrap();
        assert_eq!(
            scan_high_water(),
            (0, 0),
            "an impossible mark is not evidence"
        );
        // …and the wallet is not stuck there: a real pass writes over it.
        set_scan_high_water(3, 78).unwrap();
        assert_eq!(scan_high_water(), (3, 78));
    }

    #[test]
    fn atomic_write_replaces_without_tearing_and_makes_dirs_durable() {
        let dir = fresh_dir();
        let path = dir.join("blob.bin");
        atomic_write(&path, b"first-version").unwrap();
        assert_eq!(fs::read(&path).unwrap(), b"first-version");
        // Overwrite with a different length — old content fully replaced, and
        // no stray temp file left behind.
        atomic_write(&path, b"second").unwrap();
        assert_eq!(fs::read(&path).unwrap(), b"second");
        let leftovers: Vec<_> = fs::read_dir(&dir)
            .unwrap()
            .filter_map(|e| e.ok())
            .filter(|e| e.file_name().to_string_lossy().contains(".tmp"))
            .collect();
        assert!(leftovers.is_empty(), "temp file not cleaned up by rename");
    }

    // ── Global-vault flow tests (serialized via TEST_LOCK) ────────────────

    /// Stand up a sealed + unlocked vault the way the ceremony does, minus the
    /// device-only reveal/verify (begin → seal). The headless stand-in for the
    /// retired `create_vault` (D-038).
    pub(crate) fn seal_test_vault(passphrase: Vec<u8>, params: VaultKdfParams) {
        begin_create().unwrap();
        seal_and_persist(passphrase, Vec::new(), params, VaultInputKind::Passphrase).unwrap();
    }

    #[test]
    fn create_lock_unlock_round_trip() {
        let (_g, _dir) = enter();
        let pw = b"correct horse battery".to_vec();

        assert!(!vault_exists());
        seal_test_vault(pw.clone(), cheap_params());
        assert!(vault_exists());
        assert!(current_status().unlocked);

        lock_vault();
        assert!(!current_status().unlocked);
        assert!(current_status().exists); // blob persists across lock

        unlock_with_passphrase(pw).unwrap();
        assert!(current_status().unlocked);
        lock_vault();
    }

    // ── D-312: the pad choice, the device binding, and the migration ──────

    const TEST_PEPPER: [u8; 32] = [0x5Au8; 32];

    fn install_test_pepper() {
        install_pepper(Zeroizing::new(TEST_PEPPER.to_vec())).unwrap();
    }

    #[test]
    fn a_refused_seal_leaves_the_phrase_held_for_a_retry() {
        let (_g, _dir) = enter();
        begin_create().unwrap();
        // A PIN on a phone that cannot bind: the seal is refused. **The phrase
        // must still be there.** The user has already revealed it, written it
        // on paper and passed a quiz on it; destroying it here and handing them
        // a different one to write down is the worst thing this function could
        // do, and it is what the check running below the `take()` did
        // (`ffi-leak-auditor`, D-312).
        assert!(take_pepper().is_none());
        assert!(seal_and_persist(
            b"481902".to_vec(),
            Vec::new(),
            cheap_params(),
            VaultInputKind::Digits,
        )
        .is_err());
        assert_eq!(
            ceremony_word_count().unwrap(),
            12,
            "a refused seal destroyed the held phrase"
        );

        // …and the retry, with the binding available, seals the SAME ceremony.
        install_test_pepper();
        seal_and_persist(
            b"481902".to_vec(),
            Vec::new(),
            cheap_params(),
            VaultInputKind::Digits,
        )
        .unwrap();
        lock_vault();
    }

    #[test]
    fn an_unbound_v2_vault_is_still_offered_its_binding_on_a_later_unlock() {
        let (_g, dir) = enter();
        // A phone whose Keystore was unavailable at the migrating unlock: the
        // vault lands on v2 UNBOUND. Keying the migration on the version alone
        // made that permanent — one coin flip, no retry, nothing on the glass
        // (`consensus-auditor`, D-312).
        seal_test_vault(b"pw".to_vec(), cheap_params());
        let path = dir.join("vault.kvsb");
        assert!(!read_facts(&fs::read(&path).unwrap()).unwrap().device_bound);
        lock_vault();

        // The next unlock with a working Keystore takes the offer.
        install_test_pepper();
        unlock_with_passphrase(b"pw".to_vec()).unwrap();
        let facts = read_facts(&fs::read(&path).unwrap()).unwrap();
        assert!(facts.device_bound, "the binding was never retried");
        assert_eq!(facts.version, 2);
        lock_vault();

        // …and it opens with the pepper and refuses without it, so the retry
        // produced a real binding rather than a flag.
        install_test_pepper();
        unlock_with_passphrase(b"pw".to_vec()).unwrap();
        lock_vault();
        assert!(unlock_with_passphrase(b"pw".to_vec()).is_err());
    }

    #[test]
    fn a_dropped_ceremony_says_so_rather_than_blaming_the_keystore() {
        let (_g, _dir) = enter();
        // The lifecycle case: a lock lands between the pepper install and the
        // seal, taking BOTH. The user must be told their setup session ended,
        // not that their phone cannot bind — which is the wrong cause, on the
        // exact failure the honest error exists for (`consensus-auditor`).
        install_test_pepper();
        lock_vault();
        let e = seal_and_persist(
            b"481902".to_vec(),
            Vec::new(),
            cheap_params(),
            VaultInputKind::Digits,
        )
        .unwrap_err();
        assert!(
            e.message.contains("no create ceremony"),
            "wrong cause reported: {}",
            e.message
        );
    }

    #[test]
    fn a_pin_needs_the_binding_and_a_passphrase_does_not() {
        let (_g, _dir) = enter();
        // **The founder's own condition, enforced where every caller meets it.**
        // Six digits with no hardware factor is 10^6 candidates at ~679 ms each
        // for anyone who lifts the file — a downgrade from the passphrase it is
        // offered instead of. So the PIN and the binding ship together or the
        // PIN does not ship.
        assert!(take_pepper().is_none(), "no pepper installed");
        assert!(
            binding_for(VaultInputKind::Digits, b"481902").is_err(),
            "a PIN must not seal without the device binding"
        );
        // A passphrase vault seals either way: the binding only ever makes the
        // file harder to attack off the phone, and refusing to create a wallet
        // because a Keystore call failed would be the worse answer.
        assert!(binding_for(VaultInputKind::Passphrase, b"pw")
            .unwrap()
            .is_none());
        install_test_pepper();
        assert!(binding_for(VaultInputKind::Passphrase, b"pw")
            .unwrap()
            .is_some());
    }

    #[test]
    fn the_pin_shapes_a_thief_would_try_first_are_refused() {
        let (_g, _dir) = enter();
        install_test_pepper();
        // Repeats and runs, in both directions — the top of the real
        // distribution of human-chosen codes, and the only guesses a thief
        // holding the phone has time to make against the lockout.
        for weak in [
            b"000000".as_slice(),
            b"111111",
            b"999999",
            b"123456",
            b"654321",
            b"456789",
        ] {
            assert!(
                is_trivially_guessable_pin(weak),
                "{} was not refused",
                String::from_utf8_lossy(weak)
            );
        }
        // …and nothing else is, because a long blocklist only teaches people to
        // pick the eleventh-most-obvious code.
        for ok in [
            b"481902".as_slice(),
            b"135790",
            b"112233",
            b"246813",
            b"100000",
        ] {
            assert!(
                !is_trivially_guessable_pin(ok),
                "{} was refused and should not be",
                String::from_utf8_lossy(ok)
            );
        }
        // A passphrase is never subject to the rule, whatever it looks like.
        assert!(
            binding_for(VaultInputKind::Passphrase, b"123456").is_ok(),
            "the shape rule is the PIN's, not every secret's"
        );
        // And it is enforced at the seal, where it cannot be forgotten.
        begin_create().unwrap();
        install_test_pepper();
        assert!(seal_and_persist(
            b"123456".to_vec(),
            Vec::new(),
            cheap_params(),
            VaultInputKind::Digits,
        )
        .is_err());
        // …and the refusal left the written-down phrase alive, as every other
        // refusal on this path does.
        assert_eq!(ceremony_word_count().unwrap(), 12);
        abandon_create();
    }

    #[test]
    fn the_pepper_is_taken_not_borrowed() {
        let (_g, _dir) = enter();
        install_test_pepper();
        assert!(take_pepper().is_some());
        // Both ways a ceremony can end drop it — a pepper installed for a seal
        // that will never run must not outlive it.
        install_test_pepper();
        abandon_create();
        assert!(take_pepper().is_none(), "abandon did not drop the pepper");
        // **Resident for one operation, not for the life of the process.** A
        // memory scrape of a LOCKED app must not hand over the one thing that
        // makes a 6-digit PIN offline-guessable.
        assert!(take_pepper().is_none(), "the pepper outlived its operation");

        // …and a ceremony abandoned between the install and the call it was
        // installed for does not leave it resident either.
        install_test_pepper();
        lock_vault();
        assert!(take_pepper().is_none(), "lock did not drop the pepper");
    }

    #[test]
    fn a_wrong_length_pepper_is_refused_at_the_door() {
        let (_g, _dir) = enter();
        assert!(install_pepper(Zeroizing::new(vec![0u8; 16])).is_err());
        assert!(take_pepper().is_none());
    }

    #[test]
    fn a_bound_vault_needs_its_pepper_at_every_unlock() {
        let (_g, _dir) = enter();
        install_test_pepper();
        begin_create().unwrap();
        seal_and_persist(
            b"481902".to_vec(),
            Vec::new(),
            cheap_params(),
            VaultInputKind::Digits,
        )
        .unwrap();
        // The pad choice is in the blob, readable with no secret — this is what
        // the unlock screen draws its keypad from.
        assert_eq!(vault_input_kind().unwrap(), VaultInputKind::Digits);
        lock_vault();

        // **The file alone is not enough.** Without the pepper the right PIN
        // does not open it, and the error is NOT "wrong passphrase": the secret
        // was correct and this phone simply cannot produce the other half.
        let refused = unlock_with_passphrase(b"481902".to_vec()).unwrap_err();
        assert!(
            refused.message.contains("bound to its phone"),
            "expected a device-binding refusal, got: {}",
            refused.message
        );
        // **…and it is not counted as a failed attempt, because it was not
        // one.** The lockout prices GUESSES; this is a phone that could not
        // produce its own key, which no amount of correct typing resolves.
        // Counting it would walk a user into an hour-long lockout for a
        // condition they cannot fix.
        assert_eq!(current_status().failed_attempts, 0);

        // The exemption is NOT a hole: a genuinely wrong secret, with the
        // binding present, still counts. Without this line the fix above could
        // be widened into "unseal failures do not count" and nothing would say.
        install_test_pepper();
        assert!(unlock_with_passphrase(b"000000".to_vec()).is_err());
        assert_eq!(current_status().failed_attempts, 1);

        install_test_pepper();
        unlock_with_passphrase(b"481902".to_vec()).unwrap();
        lock_vault();
    }

    #[test]
    fn a_passphrase_vault_still_opens_with_a_pepper_in_the_room() {
        let (_g, _dir) = enter();
        // **The migration's subtler half.** The update that introduces the
        // pepper has it in hand at every unlock. If it were mixed in
        // unconditionally, every vault sealed before D-312 would stop opening
        // on the update that shipped it — a silent, total lockout,
        // indistinguishable from a wrong passphrase.
        seal_test_vault(b"just-a-passphrase".to_vec(), cheap_params());
        lock_vault();
        install_test_pepper();
        unlock_with_passphrase(b"just-a-passphrase".to_vec()).unwrap();
        lock_vault();
    }

    #[test]
    fn a_migration_writes_only_a_blob_it_has_already_re_opened() {
        let (_g, dir) = enter();
        seal_test_vault(b"pw".to_vec(), cheap_params());
        let path = dir.join("vault.kvsb");
        let before = fs::read(&path).unwrap();

        let seed = SecretSeed::from_seed_bytes(Box::new([9u8; 64]));
        // A wrong-length pepper makes the re-seal fail. The old blob must be
        // exactly where it was: a migration that cannot complete is a no-op,
        // never a half-written vault, because the unlock it rides on has
        // already succeeded and the user is not waiting on it.
        migrate_blob(&seed, b"pw", Some(&[0u8; 7]));
        assert_eq!(fs::read(&path).unwrap(), before, "a failed migration wrote");

        // The good path replaces the file with one that has ALREADY been
        // unsealed once, in memory, before the write.
        migrate_blob(&seed, b"pw", Some(&TEST_PEPPER));
        let after = fs::read(&path).unwrap();
        assert_ne!(after, before);
        let facts = read_facts(&after).unwrap();
        assert_eq!(facts.version, 2);
        assert!(facts.device_bound);
        assert_eq!(facts.input_kind, InputKind::Passphrase);
        // It opens, which is the property — the seed's bytes are the core's
        // to compare, and it does (`a_v1_blob_still_opens_with_its_own
        // _passphrase`).
        assert!(unseal_seed(&after, b"pw", Some(&TEST_PEPPER)).is_ok());
        assert!(
            unseal_seed(&after, b"pw", None).is_err(),
            "the migrated blob must be bound to this phone"
        );
        lock_vault();
    }

    #[test]
    fn the_word_count_can_be_redrawn_but_never_over_a_vault() {
        let (_g, _dir) = enter();
        begin_create().unwrap();
        assert_eq!(ceremony_word_count().unwrap(), 12);

        regenerate_ceremony(24).unwrap();
        assert_eq!(ceremony_word_count().unwrap(), 24);
        regenerate_ceremony(12).unwrap();
        assert_eq!(ceremony_word_count().unwrap(), 12);

        // **Anything but 12 or 24 is refused, and the LIVE phrase survives it.**
        // Build-then-swap: a failed redraw changes nothing, so the grid the
        // screen is still showing is still the phrase Rust holds. The other
        // order would have left the user walking a quiz on words that no longer
        // existed (`ffi-leak-auditor`, D-312).
        assert!(regenerate_ceremony(18).is_err());
        assert_eq!(ceremony_word_count().unwrap(), 12);

        // And it is never a second door into creating a wallet.
        abandon_create();
        seal_test_vault(b"pw".to_vec(), cheap_params());
        begin_create().unwrap_err();
        assert!(regenerate_ceremony(24).is_err());
        lock_vault();
    }

    #[test]
    fn seal_refuses_to_overwrite_existing_vault() {
        let (_g, _dir) = enter();
        seal_test_vault(b"pw-one".to_vec(), cheap_params());
        // Seal's own guard (defense-in-depth beside begin_create's): handed a
        // ceremony past begin's gate, it must STILL refuse over an existing vault.
        *CREATE_CEREMONY
            .lock()
            .unwrap_or_else(PoisonError::into_inner) =
            Some(MnemonicCeremony::generate(12).unwrap());
        let again = seal_and_persist(
            b"pw-two".to_vec(),
            Vec::new(),
            cheap_params(),
            VaultInputKind::Passphrase,
        );
        assert!(again.is_err(), "seal must refuse over an existing vault");
        abandon_create();
        lock_vault();
    }

    #[test]
    fn wrong_passphrase_advances_lockout_and_survives_restart() {
        let (_g, dir) = enter();
        seal_test_vault(b"the-real-one".to_vec(), cheap_params());
        lock_vault();

        // Three wrong attempts.
        for expected in 1..=3u32 {
            assert!(unlock_with_passphrase(b"wrong".to_vec()).is_err());
            assert_eq!(current_status().failed_attempts, expected);
        }

        // Simulate a process restart: drop the in-memory state, re-init from the
        // same on-disk directory. The counter must NOT reset (wallet-security 11).
        *VAULT.lock().unwrap_or_else(PoisonError::into_inner) = None;
        *VAULT_DIR.lock().unwrap_or_else(PoisonError::into_inner) = None;
        init_vault(dir.to_string_lossy().to_string()).unwrap();
        assert_eq!(
            current_status().failed_attempts,
            3,
            "lockout counter did not survive restart"
        );

        // The correct passphrase still works and clears the counter.
        unlock_with_passphrase(b"the-real-one".to_vec()).unwrap();
        assert_eq!(current_status().failed_attempts, 0);
        lock_vault();
    }

    #[test]
    fn locked_out_unlock_is_refused_before_the_kdf() {
        let (_g, _dir) = enter();
        seal_test_vault(b"pw".to_vec(), cheap_params());
        lock_vault();

        // Force an active lockout window directly, then time the refusal: it
        // must return without paying the KDF (the whole point of pre-checking).
        write_lockout(Lockout {
            failed_attempts: 9,
            locked_until_unix: now_unix() + 600,
        })
        .unwrap();
        let started = std::time::Instant::now();
        let res = unlock_with_passphrase(b"pw".to_vec());
        assert!(res.is_err());
        assert!(
            started.elapsed().as_millis() < 100,
            "refusal ran the KDF instead of short-circuiting"
        );
        // Clear it so we leave clean state.
        write_lockout(Lockout::default()).unwrap();
        lock_vault();
    }

    /// Regression pin for the live on-device find (2026-06-13): concurrent
    /// wrong-passphrase attempts must EACH advance the counter — the lost
    /// update came from the read-modify-write spanning the KDF. With the
    /// UNLOCK_GATE they serialize; the count is exact, never racy.
    #[test]
    fn concurrent_failed_unlocks_are_all_counted() {
        let (_g, _dir) = enter();
        seal_test_vault(b"the-real-one".to_vec(), cheap_params());
        lock_vault();

        std::thread::scope(|s| {
            for _ in 0..2 {
                s.spawn(|| {
                    assert!(unlock_with_passphrase(b"wrong".to_vec()).is_err());
                });
            }
        });

        assert_eq!(
            current_status().failed_attempts,
            2,
            "a concurrent failure was lost (attempt counter raced)"
        );
        write_lockout(Lockout::default()).unwrap();
    }

    #[test]
    fn init_vault_is_idempotent_but_refuses_to_re_home() {
        let (_g, dir) = enter();
        let same = dir.to_string_lossy().to_string();
        // Same path again (hot restart): fine.
        init_vault(same.clone()).unwrap();
        // A different path: refused, and the original home is kept.
        let other = fresh_dir().to_string_lossy().to_string();
        assert!(init_vault(other).is_err());
        assert_eq!(vault_dir().unwrap(), dir);
        // Same path still accepted after the refusal.
        init_vault(same).unwrap();
    }

    #[test]
    fn export_seed_requires_unlocked_and_matches_the_sealed_seed() {
        let (_g, _dir) = enter();
        seal_test_vault(b"pw".to_vec(), cheap_params());
        // Unlocked: export yields 64 bytes (the live seed the Keystore wraps).
        let exported = export_seed_for_keystore().unwrap();
        assert_eq!(exported.len(), 64);

        lock_vault();
        // Locked: refuse to export.
        assert!(export_seed_for_keystore().is_err());

        // Path-A unlock with those same bytes restores the vault.
        load_vault_from_seed_bytes(Box::new(*exported)).unwrap();
        assert!(current_status().unlocked);
        lock_vault();
    }

    // ── P1.4 create-ceremony + restore (D-037 / D-038) ────────────────────

    #[test]
    fn create_ceremony_begin_reveal_seal_round_trip() {
        let (_g, _dir) = enter();
        assert!(!vault_exists());
        begin_create().unwrap();
        // The reveal lane yields exactly 12 space-separated words.
        let revealed = reveal_ceremony_words().unwrap();
        let phrase = std::str::from_utf8(&revealed).unwrap();
        assert_eq!(phrase.split(' ').count(), 12, "reveal must expose 12 words");
        // Sealing consumes the ceremony, persists, leaves the vault unlocked.
        seal_and_persist(
            b"correct horse".to_vec(),
            Vec::new(),
            cheap_params(),
            VaultInputKind::Passphrase,
        )
        .unwrap();
        assert!(vault_exists());
        assert!(current_status().unlocked);
        // Consumed: the reveal lane now refuses.
        assert!(reveal_ceremony_words().is_err());
        lock_vault();
    }

    #[test]
    fn begin_refuses_double_ceremony_and_existing_vault() {
        let (_g, _dir) = enter();
        begin_create().unwrap();
        assert!(begin_create().is_err(), "a second ceremony must refuse");
        abandon_create();
        seal_test_vault(b"pw".to_vec(), cheap_params());
        assert!(
            begin_create().is_err(),
            "begin must refuse when a vault exists"
        );
        lock_vault();
    }

    #[test]
    fn abandon_and_lifecycle_lock_drop_the_ceremony() {
        let (_g, _dir) = enter();
        begin_create().unwrap();
        assert!(reveal_ceremony_words().is_ok());
        abandon_create();
        assert!(
            reveal_ceremony_words().is_err(),
            "abandon must drop the held ceremony"
        );
        // lock_vault is the §0.11 lifecycle hook: it also drops an in-progress
        // ceremony, so a backgrounded reveal leaves no phrase resident.
        begin_create().unwrap();
        lock_vault();
        assert!(
            reveal_ceremony_words().is_err(),
            "lifecycle lock must drop the held ceremony"
        );
    }

    #[test]
    fn seal_refuses_non_ascii_extra_word_without_consuming_the_ceremony() {
        let (_g, _dir) = enter();
        begin_create().unwrap();
        let non_ascii = "café".as_bytes().to_vec(); // é is non-ASCII
        assert!(
            seal_and_persist(
                b"pw".to_vec(),
                non_ascii,
                cheap_params(),
                VaultInputKind::Passphrase,
            )
            .is_err(),
            "create path must refuse a non-ASCII extra word (D-031.5)"
        );
        // The rejected attempt did NOT consume the ceremony — a retry can seal.
        assert!(reveal_ceremony_words().is_ok());
        seal_and_persist(
            b"pw".to_vec(),
            b"backup-word".to_vec(),
            cheap_params(),
            VaultInputKind::Passphrase,
        )
        .unwrap();
        assert!(current_status().unlocked);
        lock_vault();
    }

    #[test]
    fn restore_preview_derives_an_address_without_persisting() {
        let (_g, _dir) = enter();
        // Upstream's 24-word vector (keychain.rs / mnemonic.rs).
        let phrase = b"fringe ceiling crater inject pilot travel gas nurse bulb bullet horn segment snack harbor dice laugh vital cigar push couple plastic into slender worry".to_vec();
        let addr = restore_preview(phrase, Vec::new()).unwrap();
        assert!(
            addr.starts_with("kaspa:"),
            "preview must be a mainnet address"
        );
        assert!(!vault_exists(), "a preview must never create a vault");
    }

    #[test]
    fn restore_preview_extra_word_changes_the_derived_address() {
        let (_g, _dir) = enter();
        let phrase =
            b"abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"
                .to_vec();
        let plain = restore_preview(phrase.clone(), Vec::new()).unwrap();
        let salted = restore_preview(phrase, b"TREZOR".to_vec()).unwrap();
        assert_ne!(
            plain, salted,
            "the extra word must derive a visibly different wallet (decoy property)"
        );
    }

    #[test]
    fn restore_and_persist_round_trips_through_passphrase_unlock() {
        let (_g, _dir) = enter();
        let phrase =
            b"abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"
                .to_vec();
        restore_and_persist(
            phrase,
            Vec::new(),
            b"pw".to_vec(),
            cheap_params(),
            VaultInputKind::Passphrase,
        )
        .unwrap();
        assert!(vault_exists());
        assert!(current_status().unlocked);
        lock_vault();
        // The restored vault unlocks with the same passphrase.
        unlock_with_passphrase(b"pw".to_vec()).unwrap();
        assert!(current_status().unlocked);
        lock_vault();
    }
}
