//! The Path-A seed lane (P1 §0.4, D-033) — Android-only.
//!
//! Seed/phrase plaintext crosses **Kotlin ↔ Rust by direct JNI** into this same
//! `.so`, never via FRB and never as anything in the Dart heap (INV-1). Three
//! entries — the two Keystore directions plus the P1.4 reveal lane:
//!
//! - `nativeUnlockWithSeed(byte[])` — after a biometric unlock, Kotlin hands the
//!   Keystore Cipher's GCM plaintext here; we load the vault.
//! - `nativeExportSeedForKeystore()` — at enroll, we hand the live seed to Kotlin
//!   so the hardware Keystore key can wrap it; Kotlin wipes the `byte[]` in
//!   `finally` (L9).
//! - `nativeRevealCeremonyWords()` — during a create ceremony (P1.4, D-037), we
//!   hand the space-joined 12 words to the native FLAG_SECURE reveal/verify
//!   surface to render; Kotlin wipes the `byte[]` after rendering (L9). The words
//!   never reach Dart (INV-1).
//!
//! Invariants this module enforces (ffi-leak full):
//! - **No panic crosses the boundary** (INV-2): every entry is wrapped in
//!   `catch_unwind`; a logical error becomes a thrown Java exception, an
//!   unexpected panic a generic one — the JVM never sees an unwind.
//! - **No un-wiped plaintext copy**: every transient seed buffer on the Rust
//!   side is `Zeroizing`; the only lasting home is the `SecretSeed` the vault
//!   owns (itself `ZeroizeOnDrop`).
//! - `GetByteArrayRegion`/`SetByteArrayRegion` copy directly between the Java
//!   `byte[]` and our own buffers — no JNI-owned intermediate we cannot wipe.

use std::panic::{catch_unwind, AssertUnwindSafe};

use jni::objects::{JByteArray, JClass};
use jni::sys::{jbyteArray, jint};
use jni::JNIEnv;
use zeroize::Zeroizing;

use crate::api::error::AppError;
use crate::api::vault::{
    export_seed_for_keystore, load_vault_from_seed_bytes, reveal_ceremony_words,
};

const SEED_LEN: usize = 64;

/// Best-effort: throw a Java exception carrying `msg`. If even this fails there
/// is nothing left to do but return the sentinel; the caller handles a missing
/// exception defensively.
fn throw(env: &mut JNIEnv, msg: &str) {
    let _ = env.throw_new("java/lang/RuntimeException", msg);
}

/// Path-A unlock. Returns 0 on success; on any error throws a Java exception and
/// returns a negative sentinel (the JVM ignores the value once an exception is
/// pending, but we stay explicit).
///
/// # Safety
/// Standard JNI contract: `env`/`seed` are valid for the call, supplied by the
/// JVM. No Rust unwinding may escape — `catch_unwind` guarantees it.
#[no_mangle]
pub extern "system" fn Java_org_kaspaverse_app_VaultBridge_nativeUnlockWithSeed(
    mut env: JNIEnv,
    _class: JClass,
    seed: JByteArray,
) -> jint {
    match catch_unwind(AssertUnwindSafe(|| unlock_with_seed(&mut env, &seed))) {
        Ok(Ok(())) => 0,
        Ok(Err(e)) => {
            throw(&mut env, &e.message);
            -1
        }
        Err(_) => {
            throw(&mut env, "internal error in native seed lane (unlock)");
            -2
        }
    }
}

fn unlock_with_seed(env: &mut JNIEnv, seed: &JByteArray) -> Result<(), AppError> {
    let len = env
        .get_array_length(seed)
        .map_err(|e| AppError::msg(format!("jni get_array_length: {e}")))?;
    if len as usize != SEED_LEN {
        return Err(AppError::msg("seed must be exactly 64 bytes"));
    }
    // Copy straight into our own zeroizing buffer (JNI bytes are i8).
    let mut signed = Zeroizing::new([0i8; SEED_LEN]);
    env.get_byte_array_region(seed, 0, signed.as_mut())
        .map_err(|e| AppError::msg(format!("jni get_byte_array_region: {e}")))?;
    // Reinterpret to u8 (bit-preserving) into the box the SecretSeed will own;
    // the box's memory becomes the seed's storage (zeroized on vault drop).
    let mut bytes = Box::new([0u8; SEED_LEN]);
    for (d, s) in bytes.iter_mut().zip(signed.iter()) {
        *d = *s as u8;
    }
    load_vault_from_seed_bytes(bytes)
    // `signed` zeroizes here on drop.
}

/// Path-A enroll. Returns a fresh Java `byte[]` holding the live seed for the
/// Keystore Cipher to wrap; on error throws and returns null.
///
/// # Safety
/// Standard JNI contract, as above; no unwinding escapes.
#[no_mangle]
pub extern "system" fn Java_org_kaspaverse_app_VaultBridge_nativeExportSeedForKeystore(
    mut env: JNIEnv,
    _class: JClass,
) -> jbyteArray {
    match catch_unwind(AssertUnwindSafe(|| export_seed(&mut env))) {
        Ok(Ok(arr)) => arr,
        Ok(Err(e)) => {
            throw(&mut env, &e.message);
            std::ptr::null_mut()
        }
        Err(_) => {
            throw(&mut env, "internal error in native seed lane (export)");
            std::ptr::null_mut()
        }
    }
}

fn export_seed(env: &mut JNIEnv) -> Result<jbyteArray, AppError> {
    let seed = export_seed_for_keystore()?; // Zeroizing<[u8; 64]>
    let arr = env
        .new_byte_array(SEED_LEN as i32)
        .map_err(|e| AppError::msg(format!("jni new_byte_array: {e}")))?;
    // Transient signed copy, wiped on drop; then handed to the JVM byte[].
    let mut signed = Zeroizing::new([0i8; SEED_LEN]);
    for (d, s) in signed.iter_mut().zip(seed.iter()) {
        *d = *s as i8;
    }
    env.set_byte_array_region(&arr, 0, signed.as_ref())
        .map_err(|e| AppError::msg(format!("jni set_byte_array_region: {e}")))?;
    Ok(arr.into_raw())
    // `signed` and `seed` zeroize here on drop.
}

/// Reveal lane (P1.4, D-037). Returns a fresh Java `byte[]` holding the
/// space-joined words of the in-progress create ceremony, for the native
/// FLAG_SECURE surface to render; on error throws and returns null. The caller
/// MUST wipe the `byte[]` after rendering (L9). Words never touch Dart (INV-1).
///
/// # Safety
/// Standard JNI contract, as above; no unwinding escapes (`catch_unwind`).
#[no_mangle]
pub extern "system" fn Java_org_kaspaverse_app_VaultBridge_nativeRevealCeremonyWords(
    mut env: JNIEnv,
    _class: JClass,
) -> jbyteArray {
    match catch_unwind(AssertUnwindSafe(|| reveal_words(&mut env))) {
        Ok(Ok(arr)) => arr,
        Ok(Err(e)) => {
            throw(&mut env, &e.message);
            std::ptr::null_mut()
        }
        Err(_) => {
            throw(&mut env, "internal error in native seed lane (reveal)");
            std::ptr::null_mut()
        }
    }
}

fn reveal_words(env: &mut JNIEnv) -> Result<jbyteArray, AppError> {
    let words = reveal_ceremony_words()?; // Zeroizing<Vec<u8>>, wiped on drop
    let arr = env
        .new_byte_array(words.len() as i32)
        .map_err(|e| AppError::msg(format!("jni new_byte_array: {e}")))?;
    // Transient signed copy, wiped on drop; then handed to the JVM byte[] via
    // SetByteArrayRegion — no JNI-owned intermediate we cannot wipe.
    let signed: Zeroizing<Vec<i8>> = Zeroizing::new(words.iter().map(|&b| b as i8).collect());
    env.set_byte_array_region(&arr, 0, signed.as_slice())
        .map_err(|e| AppError::msg(format!("jni set_byte_array_region: {e}")))?;
    Ok(arr.into_raw())
    // `signed` and `words` zeroize here on drop.
}
