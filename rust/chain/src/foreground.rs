//! foreground: a send in progress goes first on the socket.
//!
//! The app speaks to its node over one WebSocket, and the node answers in the
//! order it is asked. A walk's catch-up page is a large reply: the acceptance
//! tracker's carries up to `mergeset_size_limit × 10` chain blocks with every
//! transaction id they accepted, and the message walk's the same span with
//! every accepted transaction at High verbosity. While one streams, everything
//! behind it on the socket waits: a submit's answer, the notification that
//! names its acceptance, the read of its accepting block. Measured on a phone,
//! a submit made 17 s after an unlock took 2.47 s against a 211 ms median, with
//! the round trip at 1.0 to 1.2 s for as long as both walks paged.
//!
//! So while a send is in progress no catch-up page is asked for: a walk waits
//! at its next page until the send gives the socket back or its claim runs
//! out. A page already in flight cannot be recalled, so the claim begins when
//! the send is reviewed, and the pages in flight have drained by the time the
//! transaction goes out.
//!
//! **Prior art.** A client that carries urgent and bulk requests on one
//! connection holds the bulk ones back while an urgent one is outstanding:
//! Chromium's `ResourceScheduler` delays "delayable" requests while the
//! render-blocking ones load, and RFC 9218's urgency levels ask a server for
//! the same order. A Kaspa node serves its socket in arrival order, so the
//! holding back is the client's to do.
//!
//! **Bounded by construction:** every claim carries its own deadline, so a send
//! that is never committed, or never answered, holds no walk past it.

use std::sync::{Arc, Mutex, PoisonError};
use std::time::Duration;

use tokio::sync::Notify;
use tokio::time::Instant;

/// The sends that hold the socket, each until its deadline.
#[derive(Default)]
pub struct Foreground {
    claims: Mutex<Claims>,
    changed: Notify,
}

#[derive(Default)]
struct Claims {
    next_id: u64,
    live: Vec<(u64, Instant)>,
}

impl Claims {
    /// The latest deadline among claims still live, dropping the rest.
    fn until(&mut self, now: Instant) -> Option<Instant> {
        self.live.retain(|(_, deadline)| *deadline > now);
        self.live.iter().map(|(_, deadline)| *deadline).max()
    }
}

impl Foreground {
    pub fn new() -> Arc<Self> {
        Arc::new(Self::default())
    }

    /// A send claims the socket for at most `hold`. Returns the claim's id,
    /// which [`Self::renew`] and [`Self::release`] take.
    pub fn claim(&self, hold: Duration) -> u64 {
        let mut claims = self.claims.lock().unwrap_or_else(PoisonError::into_inner);
        claims.next_id += 1;
        let id = claims.next_id;
        claims.live.push((id, Instant::now() + hold));
        id
    }

    /// The same send moves on (its review became a commit): its claim now
    /// runs `hold` from here, and is taken again if it had run out.
    pub fn renew(&self, id: u64, hold: Duration) {
        let mut claims = self.claims.lock().unwrap_or_else(PoisonError::into_inner);
        let deadline = Instant::now() + hold;
        match claims.live.iter_mut().find(|(live, _)| *live == id) {
            Some(claim) => claim.1 = deadline,
            None => claims.live.push((id, deadline)),
        }
    }

    /// The send gave the socket back. Unknown or expired ids are ignored.
    pub fn release(&self, id: u64) {
        self.claims
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .live
            .retain(|(live, _)| *live != id);
        self.changed.notify_waiters();
    }

    /// Whether any send holds the socket now.
    pub fn is_claimed(&self) -> bool {
        self.claims
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .until(Instant::now())
            .is_some()
    }

    /// Wait until no send holds the socket: at once when none does, else until
    /// every claim is released or past its deadline. `who` names the walk in
    /// the line that says how long it waited.
    pub async fn wait_turn(&self, who: &str) {
        let started = Instant::now();
        loop {
            let changed = self.changed.notified();
            tokio::pin!(changed);
            // Registered before the claims are read, so a release between the
            // read and the wait still wakes it.
            changed.as_mut().enable();
            let until = self
                .claims
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .until(Instant::now());
            let Some(until) = until else { break };
            tokio::select! {
                () = &mut changed => {}
                () = tokio::time::sleep_until(until) => {}
            }
        }
        let waited = started.elapsed();
        if !waited.is_zero() {
            log::info!(
                "{who}: the catch-up page waited {} ms for a send to have the socket",
                waited.as_millis()
            );
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// No claim: no wait.
    #[tokio::test(start_paused = true)]
    async fn an_unclaimed_socket_never_waits() {
        let gate = Foreground::new();
        let started = Instant::now();
        gate.wait_turn("test").await;
        assert_eq!(started.elapsed(), Duration::ZERO);
        assert!(!gate.is_claimed());
    }

    /// A claim that is never released ends at its deadline.
    #[tokio::test(start_paused = true)]
    async fn a_claim_holds_a_walk_until_its_deadline() {
        let gate = Foreground::new();
        gate.claim(Duration::from_secs(20));
        let started = Instant::now();
        gate.wait_turn("test").await;
        assert_eq!(started.elapsed(), Duration::from_secs(20));
        assert!(!gate.is_claimed());
    }

    /// A release lets the walk go at once.
    #[tokio::test(start_paused = true)]
    async fn a_release_lets_the_walk_go_at_once() {
        let gate = Foreground::new();
        let id = gate.claim(Duration::from_secs(20));
        let waiter = {
            let gate = gate.clone();
            tokio::spawn(async move {
                let started = Instant::now();
                gate.wait_turn("test").await;
                started.elapsed()
            })
        };
        tokio::time::sleep(Duration::from_secs(3)).await;
        gate.release(id);
        assert_eq!(waiter.await.unwrap(), Duration::from_secs(3));
    }

    /// Two sends: the walk waits for both, and one's release does not end the
    /// other's claim.
    #[tokio::test(start_paused = true)]
    async fn a_walk_waits_for_every_send() {
        let gate = Foreground::new();
        let first = gate.claim(Duration::from_secs(20));
        let second = gate.claim(Duration::from_secs(20));
        gate.release(first);
        assert!(gate.is_claimed());
        let started = Instant::now();
        let waiter = {
            let gate = gate.clone();
            tokio::spawn(async move { gate.wait_turn("test").await })
        };
        tokio::time::sleep(Duration::from_secs(5)).await;
        gate.release(second);
        waiter.await.unwrap();
        assert_eq!(started.elapsed(), Duration::from_secs(5));
    }

    /// A renewal runs from its own moment, and takes a claim that had run out.
    #[tokio::test(start_paused = true)]
    async fn a_renewal_runs_from_its_own_moment() {
        let gate = Foreground::new();
        let id = gate.claim(Duration::from_secs(20));
        tokio::time::sleep(Duration::from_secs(25)).await;
        assert!(!gate.is_claimed());
        gate.renew(id, Duration::from_secs(10));
        let started = Instant::now();
        gate.wait_turn("test").await;
        assert_eq!(started.elapsed(), Duration::from_secs(10));
    }
}
