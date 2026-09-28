//! **LINK-Q2 (D-338): the kernel's own view of the wRPC socket** — the
//! platform half of `kaspaverse_chain::devab`'s witness. Dev flags only, logs
//! only: nothing here runs unless the flags file says `on=1`.
//!
//! **Why this is the bridge's.** Finding the socket needs the dialer's registry
//! (`rust/vendor/tokio-tungstenite`, the `kaspaverse` module), and reading a
//! descriptor needs `unsafe` — which the chain crate forbids and keeps.
//!
//! **The descriptor is never ours.** The registry records which descriptor the
//! dialer produced for which host, and takes no ownership: the websocket client
//! may close it at any moment, after which the number can name another file. So
//! every use is bracketed — the descriptor must still name the same local and
//! peer address pair before AND after the call, or the answer is discarded. A
//! closed descriptor answers `EBADF`; one reused by another socket answers with a
//! different pair; either way the caller gets `None`. Nothing here closes,
//! duplicates or keeps a descriptor.
//!
//! **The `unsafe`, all of it:** four libc calls — `getsockname`, `getpeername`,
//! `getsockopt`, `setsockopt` — each given a buffer on this stack frame with its
//! exact length beside it. No pointer outlives its call and no structure is read
//! through a cast: everything is parsed from bytes at fixed offsets, the socket
//! addresses per `<netinet/in.h>` and `struct tcp_info` per the kernel's UAPI
//! (`include/uapi/linux/tcp.h`, a struct that only ever grows at its end), because
//! libc 0.2.186 defines no `tcp_info` for Android. A kernel too old for a field
//! returns fewer bytes, and that field reads as absent.
//!
//! **What a wrong answer could cost** — the reason the bracket is enough: the
//! reads write only into our own buffers; the one write, `TCP_NODELAY`, run on a
//! descriptor reused in the instant between the first check and the call would
//! set Nagle's option on another TCP socket of this process, which changes its
//! latency and nothing else, and the second check then discards the answer.

use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr};
use std::os::unix::io::RawFd;

use kaspaverse_chain::devab::{SocketOps, TcpSample};
use tokio_tungstenite::kaspaverse;

/// Hand the chain crate its platform half. Called once at bridge init.
pub(crate) fn install() {
    kaspaverse_chain::devab::install_socket_ops(SocketOps {
        remember: kaspaverse::remember_sockets,
        read,
        set_nodelay,
    });
}

/// The wRPC socket for `host`, as the kernel sees it: of the sockets the dialer
/// recorded for that host that still name their own address pair, the one that
/// has received the most bytes — the long-lived stream, never a short probe or
/// a "Test node" dial to the same host (`consensus-auditor`, LINK-Q2). A port in
/// `host`, if any, is ignored (the registry keeps the host TLS names). An
/// IPv6-literal host never matches (it splits on its own colons): the witness is
/// silent for one, and the public nodes are all named by DNS.
fn choose(host: &str) -> Option<(kaspaverse::DialedSocket, TcpSample, bool)> {
    let bare = host.split(':').next().unwrap_or(host);
    let live: Vec<(kaspaverse::DialedSocket, TcpSample, bool)> = kaspaverse::recent_sockets()
        .into_iter()
        .filter(|s| s.host == bare)
        .filter_map(|s| read_fd(s.fd, s.local, s.peer).map(|(t, nd)| (s, t, nd)))
        .collect();
    let at = busiest(
        &live
            .iter()
            .map(|(s, t, _)| (s.seq, t.bytes_received))
            .collect::<Vec<_>>(),
    )?;
    live.into_iter().nth(at)
}

/// Index of the socket that has received the most bytes; on a tie, or where a
/// kernel reports none, the newer (higher sequence) one.
fn busiest(sockets: &[(u64, Option<u64>)]) -> Option<usize> {
    sockets
        .iter()
        .enumerate()
        .max_by_key(|(_, (seq, bytes))| (bytes.unwrap_or(0), *seq))
        .map(|(at, _)| at)
}

fn read(host: &str) -> Option<(TcpSample, bool)> {
    let (s, mut sample, nodelay) = choose(host)?;
    sample.sock_seq = s.seq;
    Some((sample, nodelay))
}

fn set_nodelay(host: &str, nodelay: bool) -> Option<(bool, u64)> {
    let (s, _, _) = choose(host)?;
    set_nodelay_fd(s.fd, s.local, s.peer, nodelay).map(|v| (v, s.seq))
}

/// `TCP_INFO` and `TCP_NODELAY` for `fd`, if it still names `(local, peer)`.
fn read_fd(fd: RawFd, local: SocketAddr, peer: SocketAddr) -> Option<(TcpSample, bool)> {
    if !names(fd, local, peer) {
        return None;
    }
    let mut info = [0u8; 256];
    let info_len = getsockopt_bytes(fd, libc::IPPROTO_TCP, libc::TCP_INFO, &mut info)?;
    let mut flag = [0u8; 4];
    let flag_len = getsockopt_bytes(fd, libc::IPPROTO_TCP, libc::TCP_NODELAY, &mut flag)?;
    if !names(fd, local, peer) {
        return None;
    }
    let sample = parse_tcp_info(&info[..info_len])?;
    Some((sample, flag_len == 4 && i32::from_ne_bytes(flag) != 0))
}

/// Set `TCP_NODELAY` on `fd` if it still names `(local, peer)`; the value read back.
fn set_nodelay_fd(fd: RawFd, local: SocketAddr, peer: SocketAddr, nodelay: bool) -> Option<bool> {
    if !names(fd, local, peer) {
        return None;
    }
    let value = libc::c_int::from(nodelay);
    let len = libc::socklen_t::try_from(std::mem::size_of::<libc::c_int>()).ok()?;
    // SAFETY: `value` is a live `c_int` on this frame and `len` is its exact
    // size; the kernel only reads it, within this call.
    let rc = unsafe {
        libc::setsockopt(
            fd,
            libc::IPPROTO_TCP,
            libc::TCP_NODELAY,
            std::ptr::from_ref(&value).cast(),
            len,
        )
    };
    if rc != 0 {
        return None;
    }
    let mut flag = [0u8; 4];
    let flag_len = getsockopt_bytes(fd, libc::IPPROTO_TCP, libc::TCP_NODELAY, &mut flag)?;
    if !names(fd, local, peer) {
        return None;
    }
    Some(flag_len == 4 && i32::from_ne_bytes(flag) != 0)
}

/// Does `fd` still name the socket between `local` and `peer`? Compared on
/// address and port only. A reused descriptor naming a different socket fails
/// it; one naming a NEW socket with the identical four-tuple (same local port,
/// same peer) would pass — harmlessly: it is then the same connection endpoint
/// the witness was asked about.
fn names(fd: RawFd, local: SocketAddr, peer: SocketAddr) -> bool {
    let same = |a: Option<SocketAddr>, b: SocketAddr| {
        a.is_some_and(|a| a.ip() == b.ip() && a.port() == b.port())
    };
    same(address(fd, Side::Local), local) && same(address(fd, Side::Peer), peer)
}

#[derive(Clone, Copy)]
enum Side {
    Local,
    Peer,
}

fn address(fd: RawFd, side: Side) -> Option<SocketAddr> {
    // `sockaddr_storage` is 128 bytes on Linux and Android. A byte buffer, not
    // a `sockaddr_storage`: the kernel copies bytes into it (no alignment
    // needed for a user buffer), and it is only ever read here as bytes, so
    // the misaligned pointer the call receives is never dereferenced by Rust.
    let mut buf = [0u8; 128];
    let mut len = libc::socklen_t::try_from(buf.len()).ok()?;
    let ptr = buf.as_mut_ptr().cast::<libc::sockaddr>();
    // SAFETY: `buf` is a live 128-byte buffer on this frame and `len` says so;
    // the kernel writes at most `len` bytes into it and stores the address's
    // true length in `len`. Nothing reads `buf` through a pointer afterwards.
    let rc = unsafe {
        match side {
            Side::Local => libc::getsockname(fd, ptr, &mut len),
            Side::Peer => libc::getpeername(fd, ptr, &mut len),
        }
    };
    if rc != 0 {
        return None;
    }
    let len = usize::try_from(len).ok()?.min(buf.len());
    parse_sockaddr(&buf[..len])
}

fn getsockopt_bytes(
    fd: RawFd,
    level: libc::c_int,
    name: libc::c_int,
    buf: &mut [u8],
) -> Option<usize> {
    let mut len = libc::socklen_t::try_from(buf.len()).ok()?;
    // SAFETY: `buf` is a live buffer the caller owns for this call and `len` is
    // its exact length; the kernel writes at most `len` bytes and stores the
    // count it wrote in `len`.
    let rc = unsafe { libc::getsockopt(fd, level, name, buf.as_mut_ptr().cast(), &mut len) };
    if rc != 0 {
        return None;
    }
    Some(usize::try_from(len).ok()?.min(buf.len()))
}

/// A socket address from `sockaddr_in` / `sockaddr_in6` bytes: family (native
/// order) at 0, port (network order) at 2, then the IPv4 address at 4 or the
/// IPv6 address at 8.
fn parse_sockaddr(b: &[u8]) -> Option<SocketAddr> {
    let family = i32::from(u16::from_ne_bytes([*b.first()?, *b.get(1)?]));
    let port = u16::from_be_bytes([*b.get(2)?, *b.get(3)?]);
    let ip = match family {
        libc::AF_INET => IpAddr::V4(Ipv4Addr::from(<[u8; 4]>::try_from(b.get(4..8)?).ok()?)),
        libc::AF_INET6 => IpAddr::V6(Ipv6Addr::from(<[u8; 16]>::try_from(b.get(8..24)?).ok()?)),
        _ => return None,
    };
    Some(SocketAddr::new(ip, port))
}

// Offsets into the kernel's `struct tcp_info` (`include/uapi/linux/tcp.h`),
// measured with `offsetof` against the header, never counted by hand.
const CA_STATE: usize = 1;
const UNACKED: usize = 24;
const LOST: usize = 32;
const RTT: usize = 68;
const RTTVAR: usize = 72;
const SND_CWND: usize = 80;
const RCV_RTT: usize = 92;
const TOTAL_RETRANS: usize = 100;
const BYTES_RECEIVED: usize = 128;
const MIN_RTT: usize = 148;

fn u32_at(b: &[u8], at: usize) -> Option<u32> {
    Some(u32::from_ne_bytes(
        <[u8; 4]>::try_from(b.get(at..at + 4)?).ok()?,
    ))
}

fn u64_at(b: &[u8], at: usize) -> Option<u64> {
    Some(u64::from_ne_bytes(
        <[u8; 8]>::try_from(b.get(at..at + 8)?).ok()?,
    ))
}

/// The fields the witness logs. `None` if the kernel returned too little to
/// hold even the round trip; the later fields are optional by kernel age.
fn parse_tcp_info(b: &[u8]) -> Option<TcpSample> {
    Some(TcpSample {
        ca_state: *b.get(CA_STATE)?,
        rtt_us: u32_at(b, RTT)?,
        rttvar_us: u32_at(b, RTTVAR)?,
        min_rtt_us: u32_at(b, MIN_RTT),
        rcv_rtt_us: u32_at(b, RCV_RTT)?,
        snd_cwnd: u32_at(b, SND_CWND)?,
        unacked: u32_at(b, UNACKED)?,
        lost: u32_at(b, LOST)?,
        total_retrans: u32_at(b, TOTAL_RETRANS)?,
        bytes_received: u64_at(b, BYTES_RECEIVED),
        sock_seq: 0,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::io::AsRawFd;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    use tokio::net::{TcpListener, TcpStream};

    /// A connected loopback pair, with a few bytes exchanged so the kernel has
    /// a round trip to report.
    async fn pair() -> (TcpStream, TcpStream) {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let client = TcpStream::connect(listener.local_addr().unwrap())
            .await
            .unwrap();
        let (mut server, _) = listener.accept().await.unwrap();
        let mut client = client;
        client.write_all(b"ping").await.unwrap();
        let mut buf = [0u8; 4];
        server.read_exact(&mut buf).await.unwrap();
        server.write_all(b"pong").await.unwrap();
        client.read_exact(&mut buf).await.unwrap();
        (client, server)
    }

    fn ends(s: &TcpStream) -> (RawFd, SocketAddr, SocketAddr) {
        (
            s.as_raw_fd(),
            s.local_addr().unwrap(),
            s.peer_addr().unwrap(),
        )
    }

    #[tokio::test]
    async fn the_kernel_answers_for_a_live_socket() {
        let (client, _server) = pair().await;
        let (fd, local, peer) = ends(&client);
        let (sample, _) = read_fd(fd, local, peer).expect("a live socket must answer");
        // Values only the right field can hold — a moved offset lands on a
        // neighbour (`tcpi_pmtu`, `tcpi_rcv_ssthresh`: tens of thousands).
        assert_eq!(sample.bytes_received, Some(4), "{sample:?}");
        assert!(
            (1..20_000).contains(&sample.rtt_us),
            "a loopback round trip is microseconds, not {} µs: {sample:?}",
            sample.rtt_us
        );
        assert!((1..=64).contains(&sample.snd_cwnd), "{sample:?}");
        assert_eq!(
            sample.ca_state, 0,
            "a fresh loopback socket is in the open state"
        );
    }

    #[tokio::test]
    async fn a_descriptor_that_names_another_socket_is_refused() {
        let (a, _a_server) = pair().await;
        let (b, _b_server) = pair().await;
        let (fd_a, _, _) = ends(&a);
        let (_, local_b, peer_b) = ends(&b);
        assert!(
            read_fd(fd_a, local_b, peer_b).is_none(),
            "the pair belongs to b, the fd to a"
        );
        // The write is refused BEFORE it happens: a's option must not move.
        a.set_nodelay(false).unwrap();
        assert!(set_nodelay_fd(fd_a, local_b, peer_b, true).is_none());
        assert!(
            !a.nodelay().unwrap(),
            "a socket the pair does not name was written to"
        );
    }

    #[tokio::test]
    async fn a_closed_descriptor_is_refused() {
        let (client, _server) = pair().await;
        let (fd, local, peer) = ends(&client);
        drop(client);
        assert!(
            read_fd(fd, local, peer).is_none(),
            "the descriptor is closed or names another file"
        );
    }

    #[tokio::test]
    async fn nodelay_is_set_and_read_back() {
        let (client, _server) = pair().await;
        let (fd, local, peer) = ends(&client);
        assert_eq!(set_nodelay_fd(fd, local, peer, false), Some(false));
        assert!(!client.nodelay().unwrap());
        assert_eq!(read_fd(fd, local, peer).map(|(_, nd)| nd), Some(false));
        assert_eq!(set_nodelay_fd(fd, local, peer, true), Some(true));
        assert!(client.nodelay().unwrap());
    }

    /// Written at the offsets `offsetof` reports against the kernel's UAPI
    /// header — literal numbers, independent of the constants under test, so a
    /// moved constant reds this (a test through the constants could not).
    #[test]
    fn tcp_info_fields_come_from_their_offsets() {
        let mut b = vec![0u8; 232];
        b[1] = 3; // tcpi_ca_state
        let mut put = |at: usize, v: u32| b[at..at + 4].copy_from_slice(&v.to_ne_bytes());
        put(68, 41_000); // tcpi_rtt
        put(72, 9_000); // tcpi_rttvar
        put(80, 13); // tcpi_snd_cwnd
        put(92, 52_000); // tcpi_rcv_rtt
        put(100, 7); // tcpi_total_retrans
        put(24, 2); // tcpi_unacked
        put(32, 1); // tcpi_lost
        put(148, 30_500); // tcpi_min_rtt
        b[128..136].copy_from_slice(&123_456_789u64.to_ne_bytes()); // tcpi_bytes_received
        let s = parse_tcp_info(&b).unwrap();
        assert_eq!(
            (s.ca_state, s.rtt_us, s.rttvar_us, s.snd_cwnd, s.rcv_rtt_us),
            (3, 41_000, 9_000, 13, 52_000)
        );
        assert_eq!((s.total_retrans, s.unacked, s.lost), (7, 2, 1));
        assert_eq!(
            (s.min_rtt_us, s.bytes_received),
            (Some(30_500), Some(123_456_789))
        );
        // An old kernel's shorter struct: the late fields are absent, not zero.
        let old = parse_tcp_info(&b[..104]).unwrap();
        assert_eq!((old.min_rtt_us, old.bytes_received), (None, None));
        assert!(
            parse_tcp_info(&b[..70]).is_none(),
            "too short to hold the round trip"
        );
    }

    /// The stream, not the newest dial: the socket that has received the most
    /// bytes is the one the witness reads; newer breaks a tie.
    #[test]
    fn the_busiest_socket_is_the_one_read() {
        assert_eq!(busiest(&[]), None);
        assert_eq!(busiest(&[(1, Some(9_000_000)), (2, Some(4_000))]), Some(0));
        assert_eq!(busiest(&[(1, Some(500)), (2, Some(500))]), Some(1));
        assert_eq!(busiest(&[(3, None), (4, Some(1))]), Some(1));
    }

    #[test]
    fn socket_addresses_parse_from_their_offsets() {
        let mut v4 = [0u8; 16];
        v4[..2].copy_from_slice(&(libc::AF_INET as u16).to_ne_bytes());
        v4[2..4].copy_from_slice(&443u16.to_be_bytes());
        v4[4..8].copy_from_slice(&[57, 144, 38, 3]);
        assert_eq!(
            parse_sockaddr(&v4),
            Some("57.144.38.3:443".parse().unwrap())
        );
        let mut v6 = [0u8; 28];
        v6[..2].copy_from_slice(&(libc::AF_INET6 as u16).to_ne_bytes());
        v6[2..4].copy_from_slice(&35160u16.to_be_bytes());
        let ip: Ipv6Addr = "2606:4700:3031::6815:4b10".parse().unwrap();
        v6[8..24].copy_from_slice(&ip.octets());
        assert_eq!(
            parse_sockaddr(&v6),
            Some(SocketAddr::new(IpAddr::V6(ip), 35160))
        );
        assert_eq!(parse_sockaddr(&v4[..6]), None);
        assert_eq!(parse_sockaddr(&[0u8; 16]), None, "an unknown family");
    }
}
