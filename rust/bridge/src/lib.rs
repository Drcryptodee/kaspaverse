// Unsafe code is denied crate-wide. The three modules that need it allow it at
// their declaration: the generated FFI glue, the JNI exports of the seed lane and
// the socket witness's libc calls. A new `unsafe` anywhere else fails the build.
#![deny(unsafe_code)]

pub mod api;
#[allow(unsafe_code)]
mod frb_generated;
mod logging;

// The Path-A seed lane (P1 §0.4) is Android-only: it links the JVM via `jni`.
// On the host it does not exist, so its callers in `api::vault` are reached
// only by tests there — hence the targeted dead-code allow on those fns.
#[cfg(target_os = "android")]
#[allow(unsafe_code)]
mod jni_seed;

// LINK-Q2: the TCP_INFO witness's platform half — dev flags only.
#[cfg(any(target_os = "android", target_os = "linux"))]
#[allow(unsafe_code)]
mod sockstat;
