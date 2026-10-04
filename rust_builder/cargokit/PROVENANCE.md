# Vendored build tool provenance: `cargokit` from `flutter_rust_bridge_codegen 2.12.0`

Cargokit is the build glue that compiles `rust/bridge` into `libkaspaverse_bridge.so`
for every APK. It runs on the build machine, so it is part of the toolchain that makes
the shipped binary, and it is held to the same rule as any dependency (INV-7): every
byte is accounted for, and the three files we changed are named and anchored here. The
gate lane `vendored cargokit (INV-7)` asserts this record.

**Everything below is checkable by a reviewer with no network access and no trust in
whoever wrote it.**

## Provenance chain

The tree came from `flutter_rust_bridge_codegen`'s integration template, at
`assets/integration_template/app/rust_builder/cargokit/` inside the published crate:

```
sha256(flutter_rust_bridge_codegen-2.12.0.crate)
  = 13823e8157bada9dc828d67cd23e4bcebcfffa9313175dacad0325fc3188940c
  = the `cksum` crates.io's index records for version 2.12.0
    (https://index.crates.io/fl/ut/flutter_rust_bridge_codegen)
```

FRB's integrate step prepends a three-line header to each file it copies (`/// This is
copied from Cargokit ...`, a details link, a blank line; `#` comments in YAML). With that
header removed, every file below is byte-identical to the template except the three
marked `← PATCHED`. The template's `build_tool/test/`, `docs/` and `.github/` (eight
files: upstream's tests, documentation and CI) were never vendored; none is on the build
path.

## What differs from upstream: three files

| file | why |
|:--|:--|
| `gradle/plugin.gradle` | Upstream added `android-x86` and `android-x64` to every debug build (emulator support). `kaspa-hashes` at the pinned rusty-kaspa rev cannot build for x86_64 Android (its build script panics "Unsupported OS"), and the app ships arm64 only, so debug builds use exactly the platforms Flutter requests. |
| `build_tool/lib/src/builder.dart` | **The toolchain.** Upstream ran `rustup run stable cargo build`, and an explicit `rustup run` outranks `rust-toolchain.toml`, so the shipped library was compiled by whatever `stable` the build machine had. The builder now reads the channel from the nearest `rust-toolchain.toml` at or above the crate (with the TOML parser cargokit already depends on), fails the build when that file names no channel, and keeps upstream's choice only when no toolchain file exists. It also passes `--locked`, so the shipped build uses the committed `Cargo.lock` or fails. |
| `build_tool/lib/src/rustup.dart` | **Finding an installed pin.** Upstream's toolchain listing kept only `stable`, `beta` and `nightly`, so an installed `1.94.0` toolchain looked absent and was handed to `rustup toolchain install`, which syncs the channel over the network on every build and fails offline. Version toolchains are now listed too; custom toolchains (such as `esp`) stay excluded, as upstream's tests expect. |

The two shipped-binary witnesses that prove the toolchain change works are read by
`tools/shipped_toolchain.sh`: the `.so`'s `.comment` section and its standard-library
source paths (`/rustc/<commit>/`), both compared against `rustup run <pin> rustc -vV`.

## Known gap: the build tool's own Dart dependencies are not locked

`run_build_tool.sh` writes a small runner package into the build directory and runs
`dart pub get` there whenever `build_tool`'s files change. `build_tool/pubspec.lock` is
not used by that resolution: the versions in force are whatever the runner's own,
untracked `pubspec.lock` under `build/` recorded the first time it resolved, and
`flutter clean` or a new machine resolves them fresh. Upstream pins the direct
dependencies exactly in `pubspec.yaml` for this reason; the transitive ones float within
their ranges, and pub verifies each download against pub.dev's published hash.

## Verify it yourself

```bash
# 1. the crate's checksum is the one crates.io published
sha256sum ~/.cargo/registry/cache/index.crates.io-*/flutter_rust_bridge_codegen-2.12.0.crate

# 2. unpack it and compare every vendored file to the template, header removed
mkdir -p /tmp/frb && tar xzf ~/.cargo/registry/cache/index.crates.io-*/flutter_rust_bridge_codegen-2.12.0.crate -C /tmp/frb
T=/tmp/frb/flutter_rust_bridge_codegen-2.12.0/assets/integration_template/app/rust_builder/cargokit
git ls-files rust_builder/cargokit | grep -v PROVENANCE.md | while read -r f; do
  rel="${f#rust_builder/cargokit/}"
  if head -2 "$f" | grep -q "This is copied from Cargokit"; then tail -n +4 "$f"; else cat "$f"; fi \
    | cmp -s - "$T/$rel" || echo "differs: $rel"
done
#    expected output, and nothing else:
#    differs: build_tool/lib/src/builder.dart
#    differs: build_tool/lib/src/rustup.dart
#    differs: gradle/plugin.gradle
```

## Manifest

SHA-256 of every file as committed (this record excluded). The gate re-hashes all of
them, requires the file set to be exactly this list, and requires the files marked
`← PATCHED` to be exactly the anchored set below.

```
a8b0a7a8cac48d2a70c146a1ca1f2406f14f9628883ac8291d212c11f941f568  build_pod.sh
6cb5ec6808a5fd2a2acc4a866cff8761f34efa536f691219251f93688ffa8f53  build_tool/analysis_options.yaml
12b0b44884ee36164b2f71111efc859b1fb0b5d690bb68c8213074e9dfe38e90  build_tool/bin/build_tool.dart
363b9137fcffb4d0a2b15b869cd6e8ebacf7ec13a36b8b3ae808304f12c17684  build_tool/lib/build_tool.dart
59fffcd7d3a60df93d52b14fd2052660036404c73678ecb792d18cca7ed5498c  build_tool/lib/src/android_environment.dart
46ef875c9191acfb3f06625bf0d3e2d5da5f6fb12bd36f9bb59f20d2edfadc0d  build_tool/lib/src/artifacts_provider.dart
4eb4b5f884d3688421876b8713456f68c51fbbdf4ff56ae059109fdc5897fb4b  build_tool/lib/src/build_cmake.dart
6e5b70c26810dd2e8792ae0d25ae917aab4e997e2294afc100ab8277e1a48cbd  build_tool/lib/src/builder.dart  ← PATCHED
6ba441ff0c579ae4a85a756ff978b6f724821bb2fefd49c124a7363ee1b6df49  build_tool/lib/src/build_gradle.dart
eef48296bfbce61164c71596775c4400f6a15441d7895dbca1f7f264746f53e7  build_tool/lib/src/build_pod.dart
8f93b6df784f67375568775de72641a3e32e25cdca89a798bf603615ef1e9d55  build_tool/lib/src/build_tool.dart
dbd19f431dc2a3347b64b23c06929e88d0ae0077b173e70016648b20b5e67741  build_tool/lib/src/cargo.dart
4fbe239a8d42faede8c23b57721159980ea57bba21f5f003abc3bec6bf352f68  build_tool/lib/src/crate_hash.dart
c5ebb73b34e185377ffcc051ba86d61fa6777ce789c6904d6af59f6c40e3bc4c  build_tool/lib/src/environment.dart
a9040b71b546027bc22fdee1f4367f8bbabc1a2c9ed89f8e821bc3565e97f3d0  build_tool/lib/src/logging.dart
abcf4e0afb96058a074e53fe797518c47c589e4440df0afb262d27dd25e98381  build_tool/lib/src/options.dart
3148e241cb33c663b58b4ad6e80c98e7ac91ef6f8dc155b6c155fbe256a80578  build_tool/lib/src/precompile_binaries.dart
1a93c85ea1414f916780f2ade67f3ad85f2bf8b1fdf097b1b7df6fdc6feabefa  build_tool/lib/src/rustup.dart  ← PATCHED
409938b6217ee23b3f642d2d4e0466ef47b2888877059d8275bd289ab124dc95  build_tool/lib/src/target.dart
7baa9fff80a3da72383698f1205b17c96e8acb5b7499413072ba70a371852a0a  build_tool/lib/src/util.dart
1f26883a2cc42ce868512f7633cfc145753340cfc4f8012b5507dcbee23361d1  build_tool/lib/src/verify_binaries.dart
d16c36cbd3089b521fab03a8ced72e46f768021438486835233a1f655913372a  build_tool/pubspec.lock
b49e13fa7bd97fc05b9ff40eb58ae749981c1b7f1ca81b7ef54db542c1c04d3f  build_tool/pubspec.yaml
610c79f3c40e1807d4731cf9f530d4d1218be4ba9b97dda87a01d02ff5295dbb  build_tool/README.md
020a2c9a86f8266b51ef8ee5612471c74a421ff498c8ec6d76910126fb701cea  cmake/cargokit.cmake
5a14a8bbea2ff777a761d47e223cac0a1f52747fd188eb495402ef3c8a0dd60f  cmake/resolve_symlinks.ps1
ca39177a5e71fc3d705e49e3f2a86cc6beb4ebc86a5b3f0bd2eb101d57bded0a  .gitignore
caaba585614e064b3d33b4962c4bc12af1cab0504c1cd424de704b6452fab695  gradle/plugin.gradle  ← PATCHED
e4256b48bc6c7bafa4bca007f4f5545861e9d6d97c66b68158d162ca83bcc536  LICENSE
23fd3759d7825db0864f9176547b537ff3c18ff496cd1fca61dec379c2d100af  README
52c0a2f95055e2b275d996af807c96f4b0cf73f99e153b0c5ccd3e1779f667db  run_build_tool.cmd
babfe8e93dce2d0ee88eb3a62a3936b2f09efba58c10e5e8446a80094a3d91b6  run_build_tool.sh
```

Patched-file anchors (the hash of our version of each changed file):

```
PATCHED  caaba585614e064b3d33b4962c4bc12af1cab0504c1cd424de704b6452fab695  gradle/plugin.gradle
PATCHED  6e5b70c26810dd2e8792ae0d25ae917aab4e997e2294afc100ab8277e1a48cbd  build_tool/lib/src/builder.dart
PATCHED  1a93c85ea1414f916780f2ade67f3ad85f2bf8b1fdf097b1b7df6fdc6feabefa  build_tool/lib/src/rustup.dart
```

## Re-vendoring

An FRB upgrade brings a new template. Re-vendor from the new crate, re-apply the three
changes above, and rebuild this record from the verify steps. The re-apply is required:
without the `plugin.gradle` change a debug build fails, and without the `builder.dart`
change the shipped library is compiled by the machine's `stable` again, which the
`shipped toolchain (INV-7)` lane reports on the next APK.
