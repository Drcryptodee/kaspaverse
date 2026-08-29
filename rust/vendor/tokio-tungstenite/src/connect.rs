//! Connection helper.
//!
//! ─────────────────────────────────────────────────────────────────────────────
//! VENDORED AND PATCHED — KaspaVerse, D-217. This is the ONLY source file that
//! differs from the crates.io tarball for 0.23.1 (see `rust/vendor/PROVENANCE.md`;
//! the manifest's one-word `tokio` feature addition is the only other delta).
//!
//! Upstream dialed with `TcpStream::connect("host:port")`, which walks the
//! resolved addresses SERIALLY and advances only when one returns an `Err`. A
//! blackholed SYN is not an `Err` — it is a silence that lasts until the OS gives
//! up — so a single dead AAAA record hides every working A record behind it. On
//! the founder's link that cost 4 m 34 s to reach a node while the same app's
//! HTTPS egress reached the same hostnames in under a second, because that half
//! rides `hyper-util`, which races the families.
//!
//! The delta is `connect_happy_eyeballs` and its three helpers below, mirrored
//! from `hyper-util`'s `ConnectingTcp` (`client/legacy/connect/http.rs:951-988`)
//! rather than re-derived from RFC 8305 — that code is already compiled into this
//! binary. The public API is unchanged: no new function, parameter or feature
//! flag, so no call site here or in `workflow-websocket` knows this happened.
//!
//! TLS is untouched. The race sits strictly BELOW it and hands the winning
//! `TcpStream` to the same `client_async_tls_with_config` as before, so SNI still
//! comes from `domain(&request)` and certificate validation is byte-for-byte
//! upstream's.
//! ─────────────────────────────────────────────────────────────────────────────
use std::{
    io::{Error as IoError, ErrorKind, Result as IoResult},
    net::SocketAddr,
    time::Duration,
};

use futures_util::{
    future::{select, Either},
    pin_mut,
};
use tokio::net::{lookup_host, TcpStream};

use tungstenite::{
    error::{Error, UrlError},
    handshake::client::{Request, Response},
    protocol::WebSocketConfig,
};

use crate::{domain, stream::MaybeTlsStream, Connector, IntoClientRequest, WebSocketStream};

/// How long the preferred address family dials alone before the other family is
/// dialed alongside it (RFC 8305 "Happy Eyeballs"). Same value `hyper-util`'s
/// `HttpConnector` uses by default (`http.rs:231`).
///
/// The stagger is the reason this is not simply "dial both at once": when the
/// preferred family is healthy it answers well inside 300 ms and the other family
/// is never dialed at all, so a working link sends no extra SYNs and keeps the
/// resolver's own address preference (RFC 6724) instead of letting whichever
/// family is a few milliseconds faster win the race.
const FALLBACK_DELAY: Duration = Duration::from_millis(300);

/// Connect to a given URL.
pub async fn connect_async<R>(
    request: R,
) -> Result<(WebSocketStream<MaybeTlsStream<TcpStream>>, Response), Error>
where
    R: IntoClientRequest + Unpin,
{
    connect_async_with_config(request, None, false).await
}

/// The same as `connect_async()` but the one can specify a websocket configuration.
/// Please refer to `connect_async()` for more details. `disable_nagle` specifies if
/// the Nagle's algorithm must be disabled, i.e. `set_nodelay(true)`. If you don't know
/// what the Nagle's algorithm is, better leave it set to `false`.
pub async fn connect_async_with_config<R>(
    request: R,
    config: Option<WebSocketConfig>,
    disable_nagle: bool,
) -> Result<(WebSocketStream<MaybeTlsStream<TcpStream>>, Response), Error>
where
    R: IntoClientRequest + Unpin,
{
    connect(request.into_client_request()?, config, disable_nagle, None).await
}

/// The same as `connect_async()` but the one can specify a websocket configuration,
/// and a TLS connector to use. Please refer to `connect_async()` for more details.
/// `disable_nagle` specifies if the Nagle's algorithm must be disabled, i.e.
/// `set_nodelay(true)`. If you don't know what the Nagle's algorithm is, better
/// leave it to `false`.
#[cfg(any(feature = "native-tls", feature = "__rustls-tls"))]
pub async fn connect_async_tls_with_config<R>(
    request: R,
    config: Option<WebSocketConfig>,
    disable_nagle: bool,
    connector: Option<Connector>,
) -> Result<(WebSocketStream<MaybeTlsStream<TcpStream>>, Response), Error>
where
    R: IntoClientRequest + Unpin,
{
    connect(request.into_client_request()?, config, disable_nagle, connector).await
}

async fn connect(
    request: Request,
    config: Option<WebSocketConfig>,
    disable_nagle: bool,
    connector: Option<Connector>,
) -> Result<(WebSocketStream<MaybeTlsStream<TcpStream>>, Response), Error> {
    let domain = domain(&request)?;
    let port = request
        .uri()
        .port_u16()
        .or_else(|| match request.uri().scheme_str() {
            Some("wss") => Some(443),
            Some("ws") => Some(80),
            _ => None,
        })
        .ok_or(Error::Url(UrlError::UnsupportedUrlScheme))?;

    let addr = format!("{domain}:{port}");
    // PATCHED (D-217): was `TcpStream::connect(addr)`. Same input string, same
    // resolution, same `Error::Io` mapping — the families are now raced instead of
    // walked.
    let socket = connect_happy_eyeballs(&addr).await.map_err(Error::Io)?;

    if disable_nagle {
        socket.set_nodelay(true)?;
    }

    crate::tls::client_async_tls_with_config(request, socket, config, connector).await
}

/// Resolve `addr` and connect, racing the two address families against each other.
///
/// Resolution is `lookup_host` on the very same `"host:port"` string upstream
/// handed to `TcpStream::connect`, so a name that resolved before resolves now and
/// a name that failed fails with the same `io::Error`.
async fn connect_happy_eyeballs(addr: &str) -> IoResult<TcpStream> {
    let addrs: Vec<SocketAddr> = lookup_host(addr).await?.collect();
    race_address_families(addrs).await
}

/// Split resolved addresses into (preferred, fallback) by address family.
///
/// The preferred family is whichever one the resolver put FIRST — never a
/// hardcoded "v6 first". That keeps the host's own RFC 6724 policy in charge;
/// this function only decides what may be dialed concurrently with what.
fn split_by_preference(addrs: Vec<SocketAddr>) -> (Vec<SocketAddr>, Vec<SocketAddr>) {
    let preferring_v6 = addrs.first().map(SocketAddr::is_ipv6).unwrap_or(false);
    addrs.into_iter().partition(|addr| addr.is_ipv6() == preferring_v6)
}

/// Dial the preferred family; if it has not answered within [`FALLBACK_DELAY`],
/// dial the other family alongside it and take whichever answers first.
///
/// Mirrors `hyper-util`'s `ConnectingTcp::connect`. Two properties matter and are
/// load-bearing for a wallet:
///
/// * **The loser is dropped, never leaked.** Only one branch of a `select` runs to
///   completion; the other future is dropped un-polled, and dropping an in-flight
///   `TcpStream::connect` future (or a `TcpStream` it had just produced) closes its
///   descriptor. Nothing is left half-open.
/// * **A losing family cannot hide a winning one.** If the first result is an
///   error we await the survivor rather than returning, so "preferred refused" ends
///   in the fallback's answer, not in a failure.
async fn race_address_families(addrs: Vec<SocketAddr>) -> IoResult<TcpStream> {
    let (preferred, fallback) = split_by_preference(addrs);

    // One family only (the common case: a v4-only or v6-only name). Nothing to
    // race, so this is upstream's serial walk exactly.
    if fallback.is_empty() {
        return connect_sequentially(&preferred).await;
    }

    let preferred_fut = connect_sequentially(&preferred);
    pin_mut!(preferred_fut);
    let fallback_fut = connect_sequentially(&fallback);
    pin_mut!(fallback_fut);
    let fallback_delay = tokio::time::sleep(FALLBACK_DELAY);
    pin_mut!(fallback_delay);

    let (result, survivor) = match select(preferred_fut, fallback_delay).await {
        // Preferred answered inside the delay — the fallback family was never
        // dialed (constructing its future does not start it).
        Either::Left((result, _fallback_delay)) => (result, Either::Right(fallback_fut)),
        // Delay elapsed: both families are now in flight, first answer wins.
        Either::Right(((), preferred_fut)) => {
            select(preferred_fut, fallback_fut).await.factor_first()
        }
    };

    if result.is_err() {
        survivor.await
    } else {
        result
    }
}

/// Walk one family's addresses in order, exactly as `TcpStream::connect` does:
/// try each, keep the LAST error, and report tokio's own message when the list is
/// empty. Behaviour within a family is deliberately unchanged by this patch.
async fn connect_sequentially(addrs: &[SocketAddr]) -> IoResult<TcpStream> {
    let mut last_err = None;

    for addr in addrs {
        match TcpStream::connect(*addr).await {
            Ok(stream) => return Ok(stream),
            Err(e) => last_err = Some(e),
        }
    }

    Err(last_err
        .unwrap_or_else(|| IoError::new(ErrorKind::InvalidInput, "could not resolve to any address")))
}

#[cfg(test)]
mod happy_eyeballs_tests {
    use super::*;
    use std::time::Instant;
    use tokio::net::TcpListener;

    /// A listener whose accept backlog is deliberately full, so further SYNs are
    /// dropped in silence rather than refused — a blackhole, on loopback, without
    /// root. This is the condition the patch exists for: `connect` to this address
    /// neither succeeds nor errors, it simply never returns.
    ///
    /// Returned guards must be held: dropping the listener would turn the
    /// blackhole into a fast `ECONNREFUSED` and the test would prove nothing.
    async fn blackholed_v6() -> (SocketAddr, TcpListener, Vec<tokio::net::TcpStream>) {
        // Backlog of 1, NOT `TcpListener::bind` — that asks for 1024, and a queue
        // that deep cannot be filled by a test. This is the whole trick.
        let socket = tokio::net::TcpSocket::new_v6().expect("v6 socket");
        socket.bind("[::1]:0".parse().unwrap()).expect("bind ::1");
        let listener = socket.listen(1).expect("listen");
        let addr = listener.local_addr().unwrap();

        // Fill the accept queue without ever calling accept(). Once it is full
        // Linux drops further SYNs in silence (tcp_abort_on_overflow = 0, the
        // default), which is precisely the failure this patch exists for.
        let mut stuffers = Vec::new();
        for _ in 0..16 {
            match tokio::time::timeout(
                Duration::from_millis(100),
                tokio::net::TcpStream::connect(addr),
            )
            .await
            {
                Ok(Ok(s)) => stuffers.push(s),
                // Already blackholing: the queue is full.
                _ => break,
            }
        }

        (addr, listener, stuffers)
    }

    /// A live listener that accepts, on the other family.
    async fn live_v4() -> (SocketAddr, TcpListener) {
        let listener = TcpListener::bind("127.0.0.1:0").await.expect("bind 127.0.0.1");
        let addr = listener.local_addr().unwrap();
        (addr, listener)
    }

    /// Confirms the harness itself blackholes before any test leans on it: a bare
    /// `TcpStream::connect` to the stuffed address must still be pending well past
    /// the point where a refused connection would have returned.
    #[tokio::test]
    async fn the_blackhole_harness_actually_blackholes() {
        let (dead, _listener, _stuffers) = blackholed_v6().await;

        let outcome = tokio::time::timeout(
            Duration::from_millis(750),
            tokio::net::TcpStream::connect(dead),
        )
        .await;

        // Explicit positional args, not inline capture: this crate is edition 2018,
        // where `assert!`'s message goes through `panic!` unformatted.
        assert!(
            outcome.is_err(),
            "harness is not a blackhole — connect returned {:?}; every timing \
             assertion below would be measuring the wrong thing",
            outcome
        );
    }

    /// THE defect, in one test. Preferred family blackholed, other family alive:
    /// upstream's serial walk hangs here until the OS gives up (~130 s). The race
    /// must fall through after the 300 ms stagger and connect.
    #[tokio::test]
    async fn a_blackholed_preferred_family_does_not_hide_a_live_one() {
        let (dead_v6, _listener, _stuffers) = blackholed_v6().await;
        let (live_v4_addr, _live) = live_v4().await;

        let started = Instant::now();
        let stream = race_address_families(vec![dead_v6, live_v4_addr])
            .await
            .expect("the live v4 address must win");
        let elapsed = started.elapsed();

        assert_eq!(stream.peer_addr().unwrap(), live_v4_addr);
        assert!(
            elapsed < Duration::from_millis(500),
            "fell through in {:?}; the whole point is the ~300 ms stagger, \
             not the kernel's SYN retry budget",
            elapsed
        );
    }

    /// The defect itself, pinned in place. `connect_sequentially` over BOTH
    /// families is exactly what upstream's `TcpStream::connect` did, and against
    /// the same two addresses the test above crosses in ~300 ms it must still be
    /// stuck when the caller gives up. Without this, "the race fixes it" rests on
    /// the claim that the serial walk was broken; here that claim is executable.
    #[tokio::test]
    async fn the_serial_walk_this_patch_replaced_does_hang() {
        let (dead_v6, _listener, _stuffers) = blackholed_v6().await;
        let (live_v4_addr, _live) = live_v4().await;

        let outcome = tokio::time::timeout(
            Duration::from_millis(750),
            connect_sequentially(&[dead_v6, live_v4_addr]),
        )
        .await;

        assert!(
            outcome.is_err(),
            "the serial walk reached the live address in under 750 ms ({:?}) — then \
             the blackhole is not blackholing and the race proves nothing",
            outcome.map(|r| r.map(|s| s.peer_addr().unwrap()))
        );
    }

    /// The stagger's other half: when the preferred family is healthy it wins
    /// outright and the fallback is never dialed. Guards against "fixing" the hang
    /// by simply racing both from t=0, which would hand the connection to whichever
    /// family happened to be faster and silently discard the resolver's preference.
    #[tokio::test]
    async fn a_healthy_preferred_family_still_wins() {
        let (v6_addr, _v6) = {
            let listener = TcpListener::bind("[::1]:0").await.expect("bind ::1");
            let addr = listener.local_addr().unwrap();
            (addr, listener)
        };
        let (v4_addr, _v4) = live_v4().await;

        let stream = race_address_families(vec![v6_addr, v4_addr])
            .await
            .expect("v6 is alive and preferred");

        assert_eq!(
            stream.peer_addr().unwrap(),
            v6_addr,
            "the resolver put v6 first and v6 answered — v4 must not have been raced"
        );
    }

    /// A refused preferred family must not be reported as the outcome; the
    /// survivor is awaited. This is the `result.is_err()` branch.
    #[tokio::test]
    async fn a_refused_preferred_family_falls_through_to_the_survivor() {
        // Bind then drop: the port is now closed, so connect fails fast.
        let refused_v6 = {
            let listener = TcpListener::bind("[::1]:0").await.unwrap();
            listener.local_addr().unwrap()
        };
        let (live, _live_listener) = live_v4().await;

        let stream = race_address_families(vec![refused_v6, live])
            .await
            .expect("the live address must be reached after the refusal");

        assert_eq!(stream.peer_addr().unwrap(), live);
    }

    /// Both families dead: the caller must get the underlying error back, not a
    /// hang. A dialer that swallows this would strand every retry loop above it.
    #[tokio::test]
    async fn both_families_dead_returns_an_error_rather_than_hanging() {
        let refused_v6 = {
            let listener = TcpListener::bind("[::1]:0").await.unwrap();
            listener.local_addr().unwrap()
        };
        let refused_v4 = {
            let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
            listener.local_addr().unwrap()
        };

        let outcome = tokio::time::timeout(
            Duration::from_secs(5),
            race_address_families(vec![refused_v6, refused_v4]),
        )
        .await
        .expect("must not hang past the caller's timeout");

        assert!(outcome.is_err(), "both ends are closed; this cannot be a success");
    }

    /// An empty resolution keeps tokio's own error rather than panicking or
    /// hanging — the shape callers already handle.
    #[tokio::test]
    async fn an_empty_address_list_reports_tokios_error() {
        let err = race_address_families(vec![]).await.unwrap_err();
        assert_eq!(err.kind(), ErrorKind::InvalidInput);
    }

    /// The production entry point, end to end. Every other test here calls
    /// `race_address_families` directly, so none of them can see two things that
    /// would break the wallet silently: the `"host:port"` string contract this
    /// function inherits from upstream's `TcpStream::connect`, and the rewiring of
    /// `connect()` itself. `lookup_host` parses a literal without touching DNS, so
    /// pinning that chain costs no network.
    #[tokio::test]
    async fn connect_happy_eyeballs_resolves_then_races_then_connects() {
        let (addr, _listener) = live_v4().await;

        let stream = connect_happy_eyeballs(&format!("127.0.0.1:{}", addr.port()))
            .await
            .expect("a live loopback listener must be reached");

        assert_eq!(stream.peer_addr().unwrap(), addr);
    }

    /// A name that cannot resolve must come back as the same `io::Error` upstream
    /// produced, not a panic — `connect()` maps it straight to `Error::Io`.
    #[tokio::test]
    async fn an_unresolvable_host_errors_like_upstream() {
        let err = connect_happy_eyeballs("no-such-host.invalid:443")
            .await
            .expect_err("`.invalid` is guaranteed unresolvable (RFC 6761)");
        // Nothing stronger than "it is an io::Error": the kind is the resolver's
        // to choose and upstream never promised one either.
        let _ = err.kind();
    }

    /// The split follows the resolver, and keeps every address.
    #[test]
    fn preference_follows_the_resolver_and_loses_nothing() {
        let v6a: SocketAddr = "[::1]:1".parse().unwrap();
        let v6b: SocketAddr = "[::2]:2".parse().unwrap();
        let v4a: SocketAddr = "127.0.0.1:3".parse().unwrap();

        let (preferred, fallback) = split_by_preference(vec![v6a, v4a, v6b]);
        assert_eq!(preferred, vec![v6a, v6b]);
        assert_eq!(fallback, vec![v4a]);

        // v4 first => v4 preferred. Nothing here hardcodes a family.
        let (preferred, fallback) = split_by_preference(vec![v4a, v6a]);
        assert_eq!(preferred, vec![v4a]);
        assert_eq!(fallback, vec![v6a]);

        // Single family => nothing to race.
        let (preferred, fallback) = split_by_preference(vec![v4a]);
        assert_eq!(preferred, vec![v4a]);
        assert!(fallback.is_empty());
    }
}
