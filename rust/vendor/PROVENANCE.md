# Vendored dependency provenance — `tokio-tungstenite 0.23.1`

Ratified by **D-217**. This directory exists so the websocket dial races the two
address families instead of walking them serially; the argument, the measurements
and the four options considered are in that entry and are not repeated here.

**Everything below is checkable by a reviewer with no network access and no trust in
whoever wrote it.**

**One thing this page does NOT give you, stated plainly.** `cargo deny check advisories`
**cannot see a `[patch.crates-io]` path crate at all** — measured, not assumed: an
identical crate at an identical version reports its RustSec advisories from the registry
and reports `advisories ok` behind a path patch. So vendoring this crate removed it from
the advisory sweep, and D-025d's twice-weekly cron is blind to it. The gate lane
compensates with a tripwire that reds the day any advisory file appears for
`tokio-tungstenite` in the RustSec DB, but that is a tripwire, not cargo-deny's
version-range matching: it fires on ANY advisory and a human then checks it against
0.23.1. Note the likelier CVE surface — `tungstenite 0.23.0`, which does the framing and
parsing — stays registry-sourced and fully covered.

**And a second blind spot, which is easier to forget because nothing ever errors.**
A path-patched crate also leaves **version-currency** tracking: `cargo update` can no
longer surface a newer `tokio-tungstenite 0.23.x`, and the tripwire above fires only on
RustSec advisories. So a `0.23.2` that fixes a bug without an advisory is invisible here
indefinitely — and this directory's *deletion trigger* depends on somebody noticing a
release that nothing now reports. **Check crates.io for a newer `tokio-tungstenite` on
the D-025d dependency cadence**, by hand; that check is the trigger's only sensor.

## Provenance chain

The tree was extracted from the crates.io `.crate` tarball, not copied out of an
already-unpacked registry directory, so the bytes can be tied back to something
cargo itself verified:

```
sha256(tokio-tungstenite-0.23.1.crate)
  = c6989540ced10490aaf14e6bad2e3d33728a2813310a0c71d1574304c49631cd
  = the `checksum` cargo recorded for this package in rust/Cargo.lock
    BEFORE the patch stanza was added (git show HEAD:rust/Cargo.lock)
```

That equality is the whole point: the checksum in the lockfile was written by
cargo after it verified the download against the crates.io index. Matching it
proves the vendored tree descends from the published crate rather than from
anyone's working copy.

## What differs from upstream — exactly two files

| file | why |
|:--|:--|
| `src/connect.rs` | **The patch.** `TcpStream::connect("host:port")` becomes a concurrent v4/v6 race with a 300 ms fallback delay, mirrored from `hyper-util`'s `ConnectingTcp`. The file's own header block explains it. Public API unchanged. |
| `Cargo.toml` | **One word.** `"time"` added to the `tokio` feature list, because the 300 ms stagger needs a timer and the crate declared only `io-util` (+ `net` via `connect`). |

`Cargo.toml.orig` is upstream's pre-normalisation manifest; cargo never reads it,
so it is left verbatim and its hash below is the tarball's.

**On the `Cargo.toml` delta.** The prompt for this work asked for exactly one
changed file. The stagger cannot be written without a timer, and relying on
another crate in our graph to enable `tokio/time` for us would leave the vendored
crate unbuildable on its own and one unrelated dependency edit away from breaking.
The feature was **already enabled** in this workspace (`tokio = { features = [...,
"time"] }` in `rust/Cargo.toml`), so declaring it here compiles **zero additional
code into the binary** — it only makes the crate honest about what it uses. The
`--lib` test lane below is what proves it now stands alone.

## Verify it yourself

```bash
# 1. every file except the two named above is byte-identical to the published crate
diff -r --exclude=target rust/vendor/tokio-tungstenite \
  ~/.cargo/registry/src/*/tokio-tungstenite-0.23.1
#    expected output, and nothing else:
#      Only in ~/.cargo/.../tokio-tungstenite-0.23.1: .cargo-ok   <- cargo's unpack marker,
#                                                                    not part of the tarball
#      diff ... Cargo.toml
#      diff ... src/connect.rs

# 2. the patch is actually the one being compiled, not the registry copy
cargo metadata --format-version 1 --manifest-path rust/Cargo.toml \
  | python3 -c "import json,sys; [print(p['name'],p['version'],p['manifest_path']) \
      for p in json.load(sys.stdin)['packages'] if p['name']=='tokio-tungstenite']"
#    expected: exactly one line, pointing at rust/vendor/tokio-tungstenite

# 3. the dialer's own tests (gate lane "vendored dialer (D-217)")
CARGO_TARGET_DIR=rust/target/vendor-tests \
  cargo test --lib --manifest-path rust/vendor/tokio-tungstenite/Cargo.toml
```

## Pristine manifest (sha256 of the tarball's own bytes, all 22 files)

The two `← PATCHED` rows are the hashes **before** our change, so this table stays
a record of upstream rather than of us.

```
4ac467f038174643eed4aa74247bcd0f18ef597393f0147e39a9e6a7c5fa11f8  .cargo_vcs_info.json
4cf5b0943c3ce3f87bcb8a8ee16a90d4a9aa9d6c213bf1308753fdfc96f82933  CHANGELOG.md
5045d115c3405439c80bebbc6b467866076013d8cb2a4d96b5fd2a805279f5b3  Cargo.lock
9edb2c3bf7831a75ecc1ce136f37065d6f1a6955a4b0edabc9812389088e229a  Cargo.toml  ← PATCHED
7c8bca10e915eec5cda193fb986872aeb223d9565311937bb3d39e4ec871efc2  Cargo.toml.orig
fdd55e2b2da854b0fbdc1e607df7c2ba1e1ebf91ecb77c515511ebeef972bc8f  LICENSE
10544c21c0f73c2c7203c4e2532d4f1cf710fda32c16952cdfb43fa8f44e3256  README.md
067ceaf7b70949f087fd582d71bb114e88ef0313560dbd33b345158ffa33eff3  examples/README.md
d480d922f19bb5ec5ac55a700ffbe2ea0c918751a9d7b8bcc68512a045c8fd9a  examples/autobahn-client.rs
bb5286c2dbb2d2a5e758c4f7c345afe0d4d9b43efc365be512ec4a31728df452  examples/autobahn-server.rs
a4e5f1e82c4b352b99aea71f47eb2e5f0289d6e8eb67c8d719341115f506c3b7  examples/client.rs
5bb6b5d84a10086edd28d3d5b6d402e851b7558b90e2a9327bba8d1034a49b52  examples/echo-server.rs
d99c345ae58c6a450fb1b53d48e002dba9c4c71038351a1c826305a6899030bc  examples/interval-server.rs
66a2811054c188e74dcf393b776ca2040107f5a813bbbdc9960c89dd74f0c535  examples/server-custom-accept.rs
f04770383986cf020b895ece939931c1a6b4ecd722f7df307e25bd577bf8d483  examples/server-headers.rs
b3f8369b474af3e73ae544dae200e5634c45f84a62788c7d6ce50d2eefc8dd1e  examples/server.rs
691667016a1f818d8370f98db177896ce7f03f04a18a929ea521348da1814df7  src/compat.rs
bb8130f2150addda8ffc1cd9a834f3f28f089e6b827108f7fe50e0ae6266a3b7  src/connect.rs  ← PATCHED
2030d6e704a97606cd88c3cf16404e9fded9beef9b9f661c9ddb988528e1873d  src/handshake.rs
9dae674dbfa530abf7a93e36a2148e546d49ccefc9fa80b8e69ce11fe9f6890e  src/lib.rs
735aed6eabec038a9789c2f94723c10dcbc26e052b0126642ac77f8cd8afbf25  src/stream.rs
c42474f07f5e7f145f22b95bc98f8441744649e09b59865f8f68a3e810c24cb5  src/tls.rs
```

## Post-patch anchors — the two files that are ours

The table above deliberately records the **upstream** hashes of the two patched files, so
it stays a record of the published crate. These are what those files hash to **as
shipped**, so drift in our own patch also requires a deliberate record update rather than
passing unnoticed. The gate lane checks these too.

```
PATCHED  bbc996232ec642a8a7cf4ac8167df5247b73448c6f1c8efba775a7fe8792217a  Cargo.toml
PATCHED  96901a72fdf4aa788c60bee68a296e927f496c53e6c065d72490a34845cc9f90  src/connect.rs
```

## Scope of the standalone test lane, honestly

`cargo test --lib` on this manifest resolves the crate's **own** upstream `Cargo.lock`
— ~147 packages (hyper, env_logger, http-body-util…) that are not in our workspace
lockfile and are therefore outside `cargo deny` entirely. That exposure is bounded and
deliberate: the lockfile is one of the 20 hash-verified verbatim files above, and the
lane passes `--locked` so it cannot be silently re-resolved. Nothing from that graph is
compiled into the app — it exists only to run the dialer's own tests.

## Deletion trigger

Delete `rust/vendor/tokio-tungstenite/`, the `[patch.crates-io]` stanza and the
`exclude` line in `rust/Cargo.toml`, and the `vendored dialer (D-217)` lane in
`tools/gate.sh`, on the day a **released** `tokio-tungstenite` dials concurrently.
The build then returns to the registry crate. That is also the entire reversal if
this turns out to be wrong.

Upstreaming the patch is **not** ratified (D-217): it is outward-facing and stays
the founder's call. It remains the only defined end date for this directory.
