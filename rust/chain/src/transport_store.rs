//! Transport stores — contacts/conversations + messages (P2.3, §0.4/§0.7).
//!
//! Two borsh append-logs on the proven P1.5 activity-store pattern
//! (`wallet_sync.rs`): `[u32 LE len][borsh frame]` frames, upsert +
//! tombstone, torn-tail-tolerant replay, in-memory map as source of truth
//! with the file as its durable replay log. App-private dir, `transport/`
//! subdir next to the P1.5 `wallet/` one.
//!
//! **Ciphertext-at-rest, always (§0.4):** a [`MessageRecord`] carries the
//! sealed envelope bytes — received envelopes exactly as received; SENT
//! plaintext re-sealed to our own bound address key (same construction, own
//! pubkey) by the bridge BEFORE it reaches this store. No decrypt path exists
//! in this crate; plaintext never touches this module.
//!
//! **Dedup keys on txid, NEVER envelope bytes/hash (D-065 law):** envelope
//! byte 12 (SEC1 parity bit) is malleable in both implementations — two
//! byte-different envelopes can be the same message. The DAG also
//! legitimately delivers one tx in several blocks (P2.1 session note); a
//! txid-keyed `record_message` makes both collapse to one row and keeps the
//! append log from growing on replays.
//!
//! **Conversation metadata is public-wire-class data** (INV-3 posture, same
//! class as the P1.5 activity log): every field here is either on-chain
//! public (addresses, txids), on-WIRE public (aliases travel plaintext in
//! every `comm:{alias}:` head), or local bookkeeping (status, ids). The
//! sealed message BODIES are the §0.4-protected content — those live in the
//! message store as ciphertext.
//!
//! Conversations bind to the address key they were established with
//! ([`KeyBranch`] + index, §0.7) — the carried receive-rotation item can
//! never break an existing thread. Reorg-tombstone discipline: the V1
//! acceptance tracker drives [`TransportStore::tombstone_message`] when a
//! message's accepting block is displaced past the observed window — a
//! REVERSIBLE ghost flag (`kvlog::Frame::Tombstone`), never a delete,
//! because a late re-acceptance must bring the row back. Frames are hints
//! (§0.3), nothing here bears value.

use std::path::PathBuf;

use borsh::{BorshDeserialize, BorshSerialize};

use crate::error::Result;
use crate::kvlog::Log;

/// Which derivation branch a conversation's bound key lives on. Mirrors
/// `kaspaverse-core::Branch` (this crate deliberately has no core
/// dependency); the bridge maps 1:1.
#[derive(BorshSerialize, BorshDeserialize, Debug, Clone, Copy, PartialEq, Eq)]
pub enum KeyBranch {
    Receive,
    Change,
}

/// Conversation lifecycle, matching the live population's model (pending →
/// active on the acceptance response; `legacy-cases.ts` shows the same
/// states).
#[derive(BorshSerialize, BorshDeserialize, Debug, Clone, Copy, PartialEq, Eq)]
pub enum ConversationStatus {
    /// We initiated; awaiting their acceptance response.
    PendingOutbound,
    /// They initiated; awaiting our accept (the accept card).
    PendingInbound,
    /// Both aliases known — messages flow.
    Active,
}

/// One conversation ↔ contact row (§0.7: minimal `address ↔ alias ↔
/// conversation`; identity stays pubkeys + aliases, no name service).
#[derive(BorshSerialize, BorshDeserialize, Debug, Clone, PartialEq, Eq)]
pub struct ConversationRecord {
    /// Local id (never on the wire).
    pub conversation_id: String,
    /// Counterparty address — the encrypt target for outbound sealing.
    /// Empty on a PendingInbound row until the accept flow resolves the
    /// sender (node return-address RPC).
    pub contact_address: String,
    /// Our alias for this conversation (12 hex; the one we write to the wire).
    /// Empty on a PendingInbound row until we accept.
    pub my_alias: String,
    /// Their alias, once known (their handshake's `alias` field).
    pub their_alias: Option<String>,
    pub status: ConversationStatus,
    pub initiated_by_me: bool,
    /// The §0.7 binding: which of OUR address keys this conversation was
    /// established with (inbound envelopes open with this slot first).
    pub bound_branch: KeyBranch,
    pub bound_index: u32,
    pub created_unix_ms: u64,
    pub last_activity_unix_ms: u64,
    /// The establishing handshake tx (inbound rows: the bond tx — also the
    /// accept flow's sender-resolution key into the P1.5 activity record).
    pub handshake_txid: Option<String>,
}

/// Message direction relative to us.
#[derive(BorshSerialize, BorshDeserialize, Debug, Clone, Copy, PartialEq, Eq)]
pub enum MessageDirection {
    Inbound,
    Outbound,
}

/// Wire kind of a stored message (kind-level generations, §0.7).
#[derive(BorshSerialize, BorshDeserialize, Debug, Clone, Copy, PartialEq, Eq)]
pub enum StoredKind {
    Handshake,
    Comm,
    /// The unversioned `ciph_msg:` form — still live on the wire.
    Legacy,
}

/// One stored message: sealed bytes plus public routing metadata. See the
/// module docs for the at-rest law.
#[derive(BorshSerialize, BorshDeserialize, Debug, Clone, PartialEq, Eq)]
pub struct MessageRecord {
    /// The dedup key (D-065 law — never envelope bytes/hash).
    pub txid: String,
    pub conversation_id: String,
    pub direction: MessageDirection,
    pub kind: StoredKind,
    /// Sealed envelope bytes (ciphertext at rest, §0.4).
    pub envelope: Vec<u8>,
    pub unix_ms: u64,
    /// The alias that rode the comm head, when one did (public wire data).
    pub alias_on_wire: Option<String>,
    /// For OUTBOUND rows: the key slot the re-seal-to-self was sealed to at
    /// send time — decrypt-on-view uses it even if the conversation's §0.7
    /// binding later rebinds (a rebind must never strand old rows). Inbound
    /// rows carry `None` (they open with the conversation's bound slot).
    pub sealed_to: Option<(KeyBranch, u32)>,
}

/// The P2.3 transport store: conversations + messages over two logs in an
/// app-private `transport/` dir. Not thread-safe by itself — the bridge holds
/// it under one lock (same discipline as the activity store's `Mutex`).
pub struct TransportStore {
    conversations: Log<ConversationRecord>,
    messages: Log<MessageRecord>,
}

impl TransportStore {
    /// Load both logs from `dir` (missing files = empty stores).
    pub fn load(dir: PathBuf) -> Result<Self> {
        Ok(Self {
            conversations: Log::load(dir.join("conversations.kvlog"), |c: &ConversationRecord| {
                c.conversation_id.clone()
            })?,
            messages: Log::load(dir.join("messages.kvlog"), |m: &MessageRecord| {
                m.txid.clone()
            })?,
        })
    }

    // ── conversations ────────────────────────────────────────────────────

    /// Insert or update a conversation (keyed by `conversation_id`).
    pub fn upsert_conversation(&mut self, record: ConversationRecord) -> Result<()> {
        self.conversations
            .upsert(record.conversation_id.clone(), record)
    }

    pub fn conversation(&self, conversation_id: &str) -> Option<&ConversationRecord> {
        self.conversations.records.get(conversation_id)
    }

    /// Find by a wire alias — matches EITHER side's alias, because inbound
    /// comm heads may carry ours or theirs depending on the sender's
    /// convention (the live app maps both, `aliasToConversation`).
    pub fn conversation_by_alias(&self, alias: &str) -> Option<&ConversationRecord> {
        self.conversations
            .records
            .values()
            .find(|c| c.my_alias == alias || c.their_alias.as_deref() == Some(alias))
    }

    /// Find the PendingOutbound conversation whose `my_alias` an acceptance
    /// response echoed back (`theirAlias` from the responder's perspective).
    pub fn conversation_awaiting_response(
        &self,
        echoed_alias: &str,
    ) -> Option<&ConversationRecord> {
        self.conversations
            .records
            .values()
            .find(|c| c.status == ConversationStatus::PendingOutbound && c.my_alias == echoed_alias)
    }

    /// Whether a handshake tx has already been folded into a conversation
    /// (inbound dedup — the DAG can deliver the same handshake repeatedly).
    pub fn has_handshake_txid(&self, txid: &str) -> bool {
        self.conversations
            .records
            .values()
            .any(|c| c.handshake_txid.as_deref() == Some(txid))
    }

    /// All conversations, most recently active first.
    pub fn list_conversations(&self) -> Vec<ConversationRecord> {
        let mut rows: Vec<ConversationRecord> =
            self.conversations.records.values().cloned().collect();
        rows.sort_by(|a, b| {
            b.last_activity_unix_ms
                .cmp(&a.last_activity_unix_ms)
                .then(a.conversation_id.cmp(&b.conversation_id))
        });
        rows
    }

    /// Remove a conversation row (tombstone frame).
    pub fn remove_conversation(&mut self, conversation_id: &str) -> Result<()> {
        self.conversations.remove(conversation_id)
    }

    // ── messages ─────────────────────────────────────────────────────────

    /// Record a message, deduplicating by txid (the D-065 law). Returns
    /// `false` — without touching the log — when the txid is already stored,
    /// so BlockAdded re-deliveries and parity-bit-malleated duplicates
    /// collapse to one row.
    pub fn record_message(&mut self, record: MessageRecord) -> Result<bool> {
        if self.messages.records.contains_key(&record.txid) {
            return Ok(false);
        }
        self.messages.upsert(record.txid.clone(), record)?;
        Ok(true)
    }

    /// Whether a txid is already stored — the cheap pre-crypto skip for our
    /// own outbound txs echoing back through the BlockAdded scan.
    pub fn has_message_txid(&self, txid: &str) -> bool {
        self.messages.records.contains_key(txid)
    }

    /// The conversation a stored message belongs to (None = txid not stored)
    /// — the V1 tombstone consumer's routing lookup.
    pub fn message_conversation(&self, txid: &str) -> Option<String> {
        self.messages
            .records
            .get(txid)
            .map(|m| m.conversation_id.clone())
    }

    /// A conversation's messages, oldest first (thread order).
    pub fn messages_for(&self, conversation_id: &str) -> Vec<MessageRecord> {
        let mut rows: Vec<MessageRecord> = self
            .messages
            .records
            .values()
            .filter(|m| m.conversation_id == conversation_id)
            .cloned()
            .collect();
        rows.sort_by(|a, b| a.unix_ms.cmp(&b.unix_ms).then(a.txid.cmp(&b.txid)));
        rows
    }

    /// Hard-remove a message row (the hide-conversation purge path — a
    /// deliberate local delete, NOT the reversible reorg tombstone below).
    pub fn remove_message(&mut self, txid: &str) -> Result<()> {
        self.messages.remove(txid)
    }

    /// Reorg tombstone (V1 acceptance-spine lane): flags the row as a ghost —
    /// the record and its sealed envelope STAY, replay reconstructs the flag,
    /// and a late re-acceptance reverses it ([`Self::untombstone_message`]).
    /// Idempotent: returns `false` (no log growth) for an unknown or
    /// already-tombstoned txid.
    pub fn tombstone_message(&mut self, txid: &str) -> Result<bool> {
        self.messages.tombstone(txid)
    }

    /// Reverse a reorg tombstone — the displaced tx was re-accepted after the
    /// window fired; the ghost comes back as a live row. Idempotent.
    pub fn untombstone_message(&mut self, txid: &str) -> Result<bool> {
        self.messages.untombstone(txid)
    }

    /// Whether a stored message is currently ghost-flagged (the DTO surfaces
    /// this so the thread can render displacement honestly).
    pub fn is_message_tombstoned(&self, txid: &str) -> bool {
        self.messages.is_tombstoned(txid)
    }
}

impl std::fmt::Debug for TransportStore {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        // Counts only — envelopes are sealed but noisy, aliases are public
        // but nobody's business in a log line (§4 logging posture).
        write!(
            f,
            "TransportStore({} conversations, {} messages)",
            self.conversations.records.len(),
            self.messages.records.len()
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn test_dir(tag: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("kv-tstore-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        dir
    }

    fn conversation(id: &str, activity_ms: u64) -> ConversationRecord {
        ConversationRecord {
            conversation_id: id.to_string(),
            contact_address: "kaspa:qp408svlz585vyvj50yaljm8xdxrkcmmed8vxlx0wf0cl5wpt3vzyh74xs46e"
                .to_string(),
            my_alias: format!("{id:0>12}"),
            their_alias: Some("a1e1b60b5fca".to_string()),
            status: ConversationStatus::Active,
            initiated_by_me: true,
            bound_branch: KeyBranch::Receive,
            bound_index: 0,
            created_unix_ms: 1,
            last_activity_unix_ms: activity_ms,
            handshake_txid: Some(format!("hs-{id}")),
        }
    }

    fn message(
        txid: &str,
        conversation_id: &str,
        unix_ms: u64,
        envelope_tail: u8,
    ) -> MessageRecord {
        let mut envelope = vec![0u8; 61];
        envelope[12] = 0x02;
        envelope[60] = envelope_tail;
        MessageRecord {
            txid: txid.to_string(),
            conversation_id: conversation_id.to_string(),
            direction: MessageDirection::Inbound,
            kind: StoredKind::Comm,
            envelope,
            unix_ms,
            alias_on_wire: Some("fa6d1afa79e1".to_string()),
            sealed_to: None,
        }
    }

    #[test]
    fn conversations_round_trip_across_reload() {
        let dir = test_dir("conv");
        let mut store = TransportStore::load(dir.clone()).unwrap();
        store.upsert_conversation(conversation("c1", 10)).unwrap();
        store.upsert_conversation(conversation("c2", 20)).unwrap();

        // Update in place: last write wins on one id.
        let mut updated = conversation("c1", 30);
        updated.status = ConversationStatus::Active;
        updated.their_alias = Some("b2b2b2b2b2b2".to_string());
        store.upsert_conversation(updated.clone()).unwrap();

        let reloaded = TransportStore::load(dir.clone()).unwrap();
        assert_eq!(reloaded.conversation("c1"), Some(&updated));
        assert_eq!(reloaded.list_conversations().len(), 2);
        // Newest activity first.
        assert_eq!(reloaded.list_conversations()[0].conversation_id, "c1");

        let _ = std::fs::remove_dir_all(&dir);
    }

    /// THE D-065 STORE LAW: dedup keys on txid, never envelope bytes — two
    /// byte-DIFFERENT envelopes (the malleable parity bit) with one txid are
    /// one message; the duplicate never reaches the log.
    #[test]
    fn message_dedup_is_by_txid_never_envelope_bytes() {
        let dir = test_dir("dedup");
        let mut store = TransportStore::load(dir.clone()).unwrap();

        let original = message("tx1", "c1", 100, 0xAA);
        assert!(store.record_message(original.clone()).unwrap());

        // Same txid, different envelope bytes (parity-bit malleation).
        let mut malleated = message("tx1", "c1", 100, 0xAA);
        malleated.envelope[12] = 0x03;
        assert!(!store.record_message(malleated).unwrap(), "duplicate txid");

        // Different txid, byte-identical envelope: two real messages.
        assert!(store
            .record_message(message("tx2", "c1", 101, 0xAA))
            .unwrap());

        // The pre-crypto skip the inbound pipeline uses on its own echoes.
        assert!(store.has_message_txid("tx1"));
        assert!(!store.has_message_txid("tx-unknown"));

        assert_eq!(store.messages_for("c1").len(), 2);
        // The stored envelope is the ORIGINAL (first write), untouched.
        assert_eq!(store.messages_for("c1")[0].envelope[12], 0x02);

        // The dedup also kept the log to two frames — reload agrees.
        let reloaded = TransportStore::load(dir.clone()).unwrap();
        assert_eq!(reloaded.messages_for("c1").len(), 2);

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn thread_order_is_oldest_first_and_scoped_to_the_conversation() {
        let dir = test_dir("thread");
        let mut store = TransportStore::load(dir.clone()).unwrap();
        store.record_message(message("tx-b", "c1", 200, 1)).unwrap();
        store.record_message(message("tx-a", "c1", 100, 2)).unwrap();
        store
            .record_message(message("tx-x", "OTHER", 150, 3))
            .unwrap();

        let thread = store.messages_for("c1");
        assert_eq!(thread.len(), 2);
        assert_eq!(thread[0].txid, "tx-a");
        assert_eq!(thread[1].txid, "tx-b");

        let _ = std::fs::remove_dir_all(&dir);
    }

    /// The V1 reorg lane: a tombstone is a reversible GHOST flag — the row
    /// (and its sealed envelope) survives, the flag survives replay, and a
    /// late re-acceptance brings the row back untouched.
    #[test]
    fn tombstones_are_reversible_ghosts_that_survive_replay() {
        let dir = test_dir("tomb");
        let mut store = TransportStore::load(dir.clone()).unwrap();
        store.record_message(message("tx1", "c1", 100, 1)).unwrap();
        store.record_message(message("tx2", "c1", 101, 2)).unwrap();
        assert!(store.tombstone_message("tx1").unwrap());
        // Idempotent + unknown-txid no-ops: no error, no log growth.
        assert!(!store.tombstone_message("tx1").unwrap());
        assert!(!store.tombstone_message("never-seen").unwrap());

        let mut reloaded = TransportStore::load(dir.clone()).unwrap();
        let thread = reloaded.messages_for("c1");
        assert_eq!(thread.len(), 2, "the ghost row is still in the thread");
        assert!(reloaded.is_message_tombstoned("tx1"));
        assert!(!reloaded.is_message_tombstoned("tx2"));
        // Dedup still holds — the ghost's txid can't be re-recorded.
        assert!(!reloaded
            .record_message(message("tx1", "c1", 100, 9))
            .unwrap());

        // Re-acceptance reverses the ghost; the reversal survives replay.
        assert!(reloaded.untombstone_message("tx1").unwrap());
        let again = TransportStore::load(dir.clone()).unwrap();
        assert!(!again.is_message_tombstoned("tx1"));

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn alias_lookup_matches_either_side_and_response_matching_works() {
        let dir = test_dir("alias");
        let mut store = TransportStore::load(dir.clone()).unwrap();

        let mut pending = conversation("c1", 10);
        pending.status = ConversationStatus::PendingOutbound;
        pending.my_alias = "fa6d1afa79e1".to_string();
        pending.their_alias = None;
        store.upsert_conversation(pending).unwrap();

        // Comm heads may carry either alias — both resolve.
        assert!(store.conversation_by_alias("fa6d1afa79e1").is_some());
        assert!(store.conversation_by_alias("a1e1b60b5fca").is_none());

        // An acceptance response echoes OUR alias back.
        assert_eq!(
            store
                .conversation_awaiting_response("fa6d1afa79e1")
                .unwrap()
                .conversation_id,
            "c1"
        );
        assert!(store
            .conversation_awaiting_response("999999999999")
            .is_none());

        // Inbound handshake dedup by establishing txid.
        assert!(store.has_handshake_txid("hs-c1"));
        assert!(!store.has_handshake_txid("hs-unknown"));

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn replay_tolerates_a_torn_tail_and_corrupt_frames() {
        let dir = test_dir("torn");
        let mut store = TransportStore::load(dir.clone()).unwrap();
        store.record_message(message("tx1", "c1", 100, 1)).unwrap();

        // Crash mid-append: a frame that claims 40 bytes but only 3 follow.
        let path = dir.join("messages.kvlog");
        let mut bytes = std::fs::read(&path).unwrap();
        bytes.extend_from_slice(&40u32.to_le_bytes());
        bytes.extend_from_slice(&[9, 9, 9]);
        std::fs::write(&path, &bytes).unwrap();

        let reloaded = TransportStore::load(dir.clone()).unwrap();
        assert_eq!(
            reloaded.messages_for("c1").len(),
            1,
            "intact frame survives"
        );

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn debug_shows_counts_not_contents() {
        let dir = test_dir("debug");
        let mut store = TransportStore::load(dir.clone()).unwrap();
        store.upsert_conversation(conversation("c1", 10)).unwrap();
        let rendered = format!("{store:?}");
        assert_eq!(rendered, "TransportStore(1 conversations, 0 messages)");
        assert!(!rendered.contains("kaspa:"));
        let _ = std::fs::remove_dir_all(&dir);
    }
}
