#!/usr/bin/env bash
# Is hand-written unsafe code in the bridge only where it is allowed? (INV-2)
#
# The bridge denies unsafe code at its root. It is allowed at the declarations of
# the generated FFI glue and the socket witness's libc calls, and on each of the
# seed lane's five JNI exports. Any other line naming the lint (an allow, an
# expect, a warn, alone or inside a list) would switch the deny off for what it
# covers, so every such line is pinned, each allow with the item after it.
#
# Which files to read comes from the compiler: the dep-info rustc wrote for the
# crate names every file it compiled, so a `#[path]` module, an `include!` in any
# spelling or through a macro, or a moved crate root shows up as a file outside
# rust/bridge/src. A dep-info describes one build, so lines that could pull in a
# file under another configuration (a `path = "..."` attribute, an `include!`, a
# `debug_assertions` cfg) are pinned too, and so is any `macro_rules!`, whose
# expansion inside an allowed item would carry what the scan never sees written.
# In the files whose allows cover whole items (the seed lane's exports, the
# socket witness's module and any file under it), anything the lint would report
# or that exports a symbol is pinned: an `unsafe` token, the edition-2021
# attributes that carry none (`no_mangle`, `export_name`, `link_section`), and the
# `global_asm!` macro. A native method can also be bound by a safe registration
# call, so `register_native`/`RegisterNatives` is pinned everywhere. A
# `#[macro_export]` macro from a path crate the bridge compiles would bring code in
# with no lint at all, so none of them, by cargo's own resolution, may define one.
# And because a source scan cannot see what a dependency's macro emits, the built
# library's exported JNI symbols are read too: exactly the five the Kotlin side
# declares, and the app declares no other native method.
#
# Usage: tools/bridge_unsafe.sh <dep-info>
#   the gate passes the arm64 debug build's, rust/target/aarch64-linux-android/
#   debug/deps/kaspaverse_bridge.d; the release script passes cargokit's release
#   build's, build/kaspaverse_bridge/build/aarch64-linux-android/release/deps/
#   kaspaverse_bridge.d.
# Exit: 0 the pinned set holds; 1 it does not, or the dep-info cannot be trusted.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
dep="${1:-}"

if [ -z "$dep" ] || [ ! -f "$dep" ]; then
  echo "   no dep-info for the bridge at ${dep:-(none given)}, so the files compiled into it are unknown"
  exit 1
fi
stale="$(find "$ROOT/rust/bridge/src" "$ROOT/rust/bridge/Cargo.toml" -type f -newer "$dep" -print -quit)"
if [ -n "$stale" ]; then
  echo "   the dep-info is older than ${stale#"$ROOT"/}, so it does not describe this tree"
  exit 1
fi

# The first line is "<output>: <source> <source> ...", sources relative to rust/.
compiled="$(head -1 "$dep" | tr ' ' '\n' | tail -n +2 | grep -v '^$' | sed 's|^|rust/|' | sort)"
src="$(cd "$ROOT" && find rust/bridge/src -type f -name '*.rs' | sort)"
if [ -z "$compiled" ] || [ "$compiled" != "$src" ]; then
  echo "   the files compiled into the bridge are not the files in rust/bridge/src:"
  diff <(echo "$src") <(echo "$compiled") | sed 's/^/     /'
  exit 1
fi

got="$(cd "$ROOT" && printf '%s\n' "$compiled" | xargs awk '
  pending != "" { print pending " " $0; pending = ""; next }
  /^#\[allow\(unsafe_code\)\]$/ { pending = FILENAME ":" $0; next }
  /unsafe_code|(^|[^[:alnum:]_])path[[:space:]]*=[[:space:]]*r?#*"|include[[:space:]]*!|debug_assertions|macro_rules|register_native|RegisterNatives/ { print FILENAME ":" $0; next }
  FILENAME ~ /\/(jni_seed|sockstat)(\.rs$|\/)/ && /unsafe|no_mangle|export_name|link_section|global_asm/ { print FILENAME ":" $0 }')"
want='rust/bridge/src/jni_seed.rs:#[no_mangle]
rust/bridge/src/jni_seed.rs:#[allow(unsafe_code)] pub extern "system" fn Java_org_kaspaverse_app_VaultBridge_nativeUnlockWithSeed(
rust/bridge/src/jni_seed.rs:#[no_mangle]
rust/bridge/src/jni_seed.rs:#[allow(unsafe_code)] pub extern "system" fn Java_org_kaspaverse_app_VaultBridge_nativeExportSeedForKeystore(
rust/bridge/src/jni_seed.rs:#[no_mangle]
rust/bridge/src/jni_seed.rs:#[allow(unsafe_code)] pub extern "system" fn Java_org_kaspaverse_app_VaultBridge_nativeRevealCeremonyWords(
rust/bridge/src/jni_seed.rs:#[no_mangle]
rust/bridge/src/jni_seed.rs:#[allow(unsafe_code)] pub extern "system" fn Java_org_kaspaverse_app_VaultBridge_nativeInstallVaultPepper(
rust/bridge/src/jni_seed.rs:#[no_mangle]
rust/bridge/src/jni_seed.rs:#[allow(unsafe_code)] pub extern "system" fn Java_org_kaspaverse_app_VaultBridge_nativeRegenerateCeremony(
rust/bridge/src/lib.rs:#![deny(unsafe_code)]
rust/bridge/src/lib.rs:#[allow(unsafe_code)] mod frb_generated;
rust/bridge/src/lib.rs:#[allow(unsafe_code)] mod sockstat;
rust/bridge/src/sockstat.rs://! descriptor needs `unsafe` — which the chain crate forbids and keeps.
rust/bridge/src/sockstat.rs://! **The `unsafe`, all of it:** four libc calls — `getsockname`, `getpeername`,
rust/bridge/src/sockstat.rs:    let rc = unsafe {
rust/bridge/src/sockstat.rs:    let rc = unsafe {
rust/bridge/src/sockstat.rs:    let rc = unsafe { libc::getsockopt(fd, level, name, buf.as_mut_ptr().cast(), &mut len) };'
if [ "$got" != "$want" ]; then
  echo "   the bridge's unsafe-code lines are not the pinned set:"
  diff <(echo "$want") <(echo "$got") | sed 's/^/     /'
  exit 1
fi

# Every path crate in the bridge's dependency graph, as cargo resolves it.
if ! tree="$(cd "$ROOT/rust" && cargo tree --locked --offline -p kaspaverse_bridge \
    --target all -e normal,build --prefix none 2>&1)"; then
  echo "   cargo could not list the bridge's dependencies:"
  printf '%s\n' "$tree" | head -3 | sed 's/^/     /'
  exit 1
fi
mapfile -t crates < <(printf '%s\n' "$tree" | sed -n 's|.*(\(/[^)]*\)).*|\1|p' | sort -u)
for need in "$ROOT/rust/core" "$ROOT/rust/chain"; do
  if ! printf '%s\n' "${crates[@]}" | grep -qxF "$need"; then
    echo "   cargo's dependency list does not name ${need#"$ROOT"/}, so it was not read as expected"
    exit 1
  fi
done
exported="$(grep -rln --include='*.rs' 'macro_export' "${crates[@]}")"
if [ $? -gt 1 ]; then
  echo "   the bridge's path crates could not be searched for exported macros"
  exit 1
fi
if [ -n "$exported" ]; then
  echo "   a path crate the bridge compiles exports a macro, which would bring code into it unlinted:"
  printf '%s\n' "$exported" | sed "s|^$ROOT/|     |"
  exit 1
fi

# The library this build wrote, named in the dep-info's own output lines.
so="$(grep -o '^[^:]*libkaspaverse_bridge\.so' "$dep" | head -1)"
if [ -z "$so" ] || [ ! -f "$so" ]; then
  echo "   the dep-info names no built libkaspaverse_bridge.so, so its exports cannot be read"
  exit 1
fi
if ! dynsyms="$(readelf --dyn-syms -W "$so" 2>&1)"; then
  echo "   readelf could not read the exports of ${so#"$ROOT"/}:"
  printf '%s\n' "$dynsyms" | head -3 | sed 's/^/     /'
  exit 1
fi
symbols="$(printf '%s\n' "$dynsyms" \
  | awk '$1 ~ /^[0-9]+:$/ && $0 !~ /[[:space:]]UND([[:space:]]|$)/ && $NF ~ /^(Java_|JNI_On)/ { print $NF }' \
  | sort -u)"
want_symbols='Java_org_kaspaverse_app_VaultBridge_nativeExportSeedForKeystore
Java_org_kaspaverse_app_VaultBridge_nativeInstallVaultPepper
Java_org_kaspaverse_app_VaultBridge_nativeRegenerateCeremony
Java_org_kaspaverse_app_VaultBridge_nativeRevealCeremonyWords
Java_org_kaspaverse_app_VaultBridge_nativeUnlockWithSeed'
if [ "$symbols" != "$want_symbols" ]; then
  echo "   the library's exported JNI symbols are not the five the Kotlin side declares:"
  diff <(echo "$want_symbols") <(echo "$symbols") | sed 's/^/     /'
  exit 1
fi

# The app declares exactly those five native methods: a sixth could be bound
# without an export, by a registration call from code the scans above miss.
declared="$(grep -rhoE --include='*.kt' 'external[[:space:]]+fun[[:space:]]+[A-Za-z0-9_]+' "$ROOT/android/app/src")"
if [ $? -gt 1 ]; then
  echo "   android/app/src could not be searched for native method declarations"
  exit 1
fi
declared="$(printf '%s\n' "$declared" | awk 'NF { print $NF }' | sort -u)"
if [ "$declared" != "$(printf '%s\n' "$want_symbols" | sed 's/^Java_org_kaspaverse_app_VaultBridge_//')" ]; then
  echo "   the app's Kotlin native methods are not the five the library exports:"
  printf '%s\n' "${declared:-(none)}" | sed 's/^/     /'
  exit 1
fi
java_natives="$(grep -rlE --include='*.java' '(^|[[:space:]])native[[:space:]]+[^=;]*\(' "$ROOT/android/app/src")"
if [ $? -gt 1 ]; then
  echo "   android/app/src could not be searched for Java native methods"
  exit 1
fi
if [ -n "$java_natives" ]; then
  echo "   a Java file declares a native method:"
  printf '%s\n' "$java_natives" | sed "s|^$ROOT/|     |"
  exit 1
fi
