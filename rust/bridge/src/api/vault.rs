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
use std::sync::{Mutex, OnceLock, PoisonError};
use std::time::{SystemTime, UNIX_EPOCH};

use kaspaverse_core::{
    seal_seed, unseal_seed, KeyChain, MnemonicCeremony, Prefix, SealParams, SecretSeed,
    UnlockedVault,
};
use tokio::sync::broadcast::{self, error::RecvError};
use zeroize::Zeroizing;

use crate::api::error::AppError;
use crate::frb_generated::StreamSink;

// ── Process-wide state ────────────────────────────────────────────────────

/// The sole strong owner of the unlocked vault (None = locked).
static VAULT: Mutex<Option<UnlockedVault>> = Mutex::new(None);
/// App-private directory the platform hands us at init; the sealed blob and the
/// lockout counter live here (INV-3 — never SharedPreferences).
static VAULT_DIR: Mutex<Option<PathBuf>> = Mutex::new(None);
/// Status fan-out; lazily created so `send` works without a runtime.
static STATUS_TX: OnceLock<broadcast::Sender<VaultStatus>> = OnceLock::new();

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

/// Argon2id cost parameters chosen by on-device tuning (P1.2 §0.3). Mapped onto
/// the core `SealParams`, which bounds-checks them (8 MiB..=256 MiB, D-031.2).
#[derive(Clone, Copy, Debug)]
pub struct VaultKdfParams {
    pub m_cost_kib: u32,
    pub t_cost: u32,
    pub p_cost: u32,
}

impl VaultKdfParams {
    /// The v1 starting grid (P1 §0.3): m = 64 MiB, t = 3, p = 1. P1.2 device
    /// tuning replaces this with a measured point recorded in
    /// PERFORMANCE_BUDGET.md.
    pub fn starting_grid() -> Self {
        let d = SealParams::default();
        Self {
            m_cost_kib: d.m_cost_kib,
            t_cost: d.t_cost,
            p_cost: d.p_cost,
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
fn atomic_write(path: &Path, bytes: &[u8]) -> io::Result<()> {
    let dir = path
        .parent()
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "path has no parent dir"))?;
    let name = path
        .file_name()
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "path has no file name"))?;
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

fn set_vault(v: UnlockedVault) {
    *VAULT.lock().unwrap_or_else(PoisonError::into_inner) = Some(v);
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

/// Enroll mechanism (P1 §0.4, Path B). Generates a fresh 12-word seed, seals it
/// under `passphrase`, writes the blob atomically, leaves the vault unlocked.
///
/// **The word-reveal + verification ceremony is P1.4** — this mechanism stands
/// up a recoverable vault so the unlock/lock loop is testable; it deliberately
/// never surfaces the phrase (INV-1: words never cross FRB). Path-A biometric is
/// layered on afterwards by the Kotlin Keystore path via the JNI enroll export.
pub fn create_vault(passphrase: Vec<u8>, params: VaultKdfParams) -> Result<(), AppError> {
    let passphrase = Zeroizing::new(passphrase);
    if blob_path()?.exists() {
        return Err(AppError::msg(
            "a vault already exists; refusing to overwrite",
        ));
    }
    let seed = MnemonicCeremony::generate()
        .map_err(AppError::core)?
        .into_seed(b"")
        .map_err(AppError::core)?;
    let blob = seal_seed(&seed, &passphrase, params.into()).map_err(AppError::core)?;
    atomic_write(&blob_path()?, &blob).map_err(|e| AppError::io("write blob", e))?;
    set_vault(UnlockedVault::new(
        KeyChain::from_seed(seed, Prefix::Mainnet).map_err(AppError::core)?,
    ));
    log::info!("vault created (path=passphrase scheme=argon2id)"); // no secret values
    broadcast_status();
    Ok(())
}

/// Unlock via passphrase (Path B). Rate-limit is checked BEFORE the KDF runs
/// (wallet-security 11), so a locked-out attempt costs nothing. On failure the
/// attempt counter advances and persists; on success it resets.
pub fn unlock_with_passphrase(passphrase: Vec<u8>) -> Result<(), AppError> {
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
    let blob = read_blob()?;
    match unseal_seed(&blob, &passphrase) {
        Ok(seed) => {
            let keychain = KeyChain::from_seed(seed, Prefix::Mainnet).map_err(AppError::core)?;
            set_vault(UnlockedVault::new(keychain));
            let _ = write_lockout(Lockout::default()); // reset on success
            log::info!("vault unlock ok (path=passphrase)");
            broadcast_status();
            Ok(())
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
    if let Some(vault) = VAULT.lock().unwrap_or_else(PoisonError::into_inner).take() {
        vault.lock(); // consumes; drops the bridge's strong Arc
        log::info!("vault locked");
    }
    broadcast_status();
}

fn read_blob() -> Result<Vec<u8>, AppError> {
    fs::read(blob_path()?).map_err(|e| AppError::io("read blob", e))
}

// ── JNI lane entry points (called by `jni_seed`, Android-only) ────────────
// Not `pub`, so FRB never exposes them to Dart — they are the Kotlin↔Rust
// seed lane only.

/// Path-A unlock: load the vault from the raw seed bytes the Keystore Cipher
/// decrypted (delivered over JNI). A biometric unlock is a success like a
/// passphrase one, so it resets the lockout.
#[cfg_attr(not(target_os = "android"), allow(dead_code))]
pub(crate) fn load_vault_from_seed_bytes(seed: Box<[u8; 64]>) -> Result<(), AppError> {
    let keychain = KeyChain::from_seed(SecretSeed::from_seed_bytes(seed), Prefix::Mainnet)
        .map_err(AppError::core)?;
    set_vault(UnlockedVault::new(keychain));
    let _ = write_lockout(Lockout::default());
    log::info!("vault unlock ok (path=biometric)");
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

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicU64, Ordering};

    // Serializes every test that touches the process-wide VAULT/VAULT_DIR so
    // cargo's default parallel runner can't let them clobber each other (L7).
    static TEST_LOCK: Mutex<()> = Mutex::new(());
    static COUNTER: AtomicU64 = AtomicU64::new(0);

    // Fast, in-bounds KDF so the suite stays quick (mirrors core's TEST_PARAMS).
    fn cheap_params() -> VaultKdfParams {
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
    fn enter() -> (std::sync::MutexGuard<'static, ()>, PathBuf) {
        let guard = TEST_LOCK.lock().unwrap_or_else(PoisonError::into_inner);
        let dir = fresh_dir();
        *VAULT_DIR.lock().unwrap_or_else(PoisonError::into_inner) = Some(dir.clone());
        *VAULT.lock().unwrap_or_else(PoisonError::into_inner) = None;
        (guard, dir)
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

    #[test]
    fn create_lock_unlock_round_trip() {
        let (_g, _dir) = enter();
        let pw = b"correct horse battery".to_vec();

        assert!(!vault_exists());
        create_vault(pw.clone(), cheap_params()).unwrap();
        assert!(vault_exists());
        assert!(current_status().unlocked);

        lock_vault();
        assert!(!current_status().unlocked);
        assert!(current_status().exists); // blob persists across lock

        unlock_with_passphrase(pw).unwrap();
        assert!(current_status().unlocked);
        lock_vault();
    }

    #[test]
    fn create_refuses_to_overwrite_existing_vault() {
        let (_g, _dir) = enter();
        create_vault(b"pw-one".to_vec(), cheap_params()).unwrap();
        let again = create_vault(b"pw-two".to_vec(), cheap_params());
        assert!(again.is_err(), "second create must refuse");
        lock_vault();
    }

    #[test]
    fn wrong_passphrase_advances_lockout_and_survives_restart() {
        let (_g, dir) = enter();
        create_vault(b"the-real-one".to_vec(), cheap_params()).unwrap();
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
        create_vault(b"pw".to_vec(), cheap_params()).unwrap();
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
        create_vault(b"pw".to_vec(), cheap_params()).unwrap();
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
}
