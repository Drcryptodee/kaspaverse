pub mod api;
mod frb_generated;

// The Path-A seed lane (P1 §0.4) is Android-only: it links the JVM via `jni`.
// On the host it does not exist, so its callers in `api::vault` are reached
// only by tests there — hence the targeted dead-code allow on those fns.
#[cfg(target_os = "android")]
mod jni_seed;
