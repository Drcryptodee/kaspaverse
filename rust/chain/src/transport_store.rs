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

/// Where a stored row's bytes came from — the V5 provenance dimension
/// (register finding 14, D-070): a node-scanned row is chain truth; a
/// fill-sourced row is an indexer CLAIM whose txid label the verify-by-decrypt
/// cannot check. The dedup/override rule reads this
/// ([`TransportStore::override_message`]).
///
/// Borsh law: variants are append-only and positional (kvlog.rs) — never
/// reorder or remove.
#[derive(BorshSerialize, BorshDeserialize, Debug, Clone, Copy, PartialEq, Eq)]
pub enum RowSource {
    /// Written before V5 introduced provenance — claimable by the next node
    /// scan (deliberately NOT assumed node-scanned: a wrong default here is
    /// exactly the suppression window finding 14 closes).
    Unknown,
    /// Self-authored at commit (our own outbound send) — never overridable.
    Own,
    /// Folded from the node's BlockAdded scan / catch-up walk (chain truth).
    NodeScanned,
    /// Folded from an indexer fill row (D-074) — an unverifiable txid label;
    /// yields to node truth on the same txid.
    FillSourced,
}

/// One stored message: sealed bytes plus public routing metadata. See the
/// module docs for the at-rest law.
///
/// **Trailing-optional field law (V5):** [`Self::provenance`] is decoded by a
/// manual [`BorshDeserialize`] that treats end-of-input as "field absent"
/// (pre-V5 frame ⇒ [`RowSource::Unknown`]) — the record-level twin of the
/// kvlog frame-compatibility law, needed because `replay()` STOPS at the
/// first undecodable frame (a naive new field would replay every pre-V5 log
/// to zero rows). Corollaries: new fields are append-only, each must be
/// readable-as-absent-on-EOF, and `MessageRecord` must remain the FINAL
/// borsh element of any enclosing frame (true today: it only ever rides
/// `Frame::Upsert`'s single payload slot).
#[derive(BorshSerialize, Debug, Clone, PartialEq, Eq)]
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
    /// Row provenance (V5, finding 14). MUST stay the last field — see the
    /// trailing-optional law above.
    pub provenance: RowSource,
}

impl BorshDeserialize for MessageRecord {
    fn deserialize_reader<R: borsh::io::Read>(reader: &mut R) -> borsh::io::Result<Self> {
        // The eight pre-V5 fields, in declaration order (borsh is positional).
        let txid = String::deserialize_reader(reader)?;
        let conversation_id = String::deserialize_reader(reader)?;
        let direction = MessageDirection::deserialize_reader(reader)?;
        let kind = StoredKind::deserialize_reader(reader)?;
        let envelope = Vec::<u8>::deserialize_reader(reader)?;
        let unix_ms = u64::deserialize_reader(reader)?;
        let alias_on_wire = Option::<String>::deserialize_reader(reader)?;
        let sealed_to = Option::<(KeyBranch, u32)>::deserialize_reader(reader)?;
        // Trailing-optional: a pre-V5 frame ENDS here — clean EOF means
        // "absent", decoded as Unknown. Detected via the `Read` contract
        // (`Ok(0)` = end of input), NEVER via borsh's error kinds: borsh 1.x
        // remaps EOF into InvalidData("Unexpected length of input")
        // (de/mod.rs:138, pinned 1.6.1), indistinguishable by kind from a
        // corrupt tag — and a corrupt frame must stay a hard error so
        // replay()'s stop-at-corruption posture holds instead of the frame
        // masquerading as Unknown. The tag byte itself still decodes through
        // `RowSource::deserialize_reader` (one mapping, no duplicated table).
        let mut tag = [0u8; 1];
        let provenance = if reader.read(&mut tag)? == 0 {
            RowSource::Unknown
        } else {
            RowSource::deserialize_reader(&mut &tag[..])?
        };
        Ok(Self {
            txid,
            conversation_id,
            direction,
            kind,
            envelope,
            unix_ms,
            alias_on_wire,
            sealed_to,
            provenance,
        })
    }
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
    /// Ties break by `conversation_id`, NOT by HashMap iteration order.
    ///
    /// Aliases are validated for shape only, so a hostile handshake may declare
    /// one equal to an existing conversation's. `.values().find(..)` then routed
    /// a genuine contact's messages to whichever record the hash order happened
    /// to reach first — a different answer per process start, for the same
    /// stored state (product-audit run 1, F2 adjacent). Deterministic misrouting
    /// is still misrouting, but it is diagnosable, reproducible, and cannot
    /// silently change under a rebuild.
    pub fn conversation_by_alias(&self, alias: &str) -> Option<&ConversationRecord> {
        self.conversations
            .records
            .values()
            .filter(|c| c.my_alias == alias || c.their_alias.as_deref() == Some(alias))
            .min_by(|a, b| a.conversation_id.cmp(&b.conversation_id))
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

    /// The stored row for a txid (None = not stored) — the override gate's
    /// pre-crypto provenance probe.
    pub fn message(&self, txid: &str) -> Option<&MessageRecord> {
        self.messages.records.get(txid)
    }

    /// Node truth replaces an indexer claim on the same txid (V5, finding 14
    /// — the residual suppression window): the row is REPLACED (last-write-
    /// wins upsert; replay agrees; a reorg tombstone flag, keyed on the same
    /// txid, is untouched) **only when**
    /// - the existing row is `Inbound` (an outbound row is self-authored —
    ///   the `wallet_sync` "incoming never downgrades an originated send"
    ///   discipline), and
    /// - its provenance is `FillSourced` or `Unknown` (pre-V5 rows are
    ///   claimed by the next node scan), and
    /// - the incoming row is `NodeScanned`.
    ///
    /// Returns the replaced record; `None` = refused, store untouched.
    /// Everything else keeps [`Self::record_message`]'s first-write-wins.
    pub fn override_message(&mut self, record: MessageRecord) -> Result<Option<MessageRecord>> {
        let overridable = match self.messages.records.get(&record.txid) {
            Some(existing) => {
                existing.direction == MessageDirection::Inbound
                    && matches!(
                        existing.provenance,
                        RowSource::FillSourced | RowSource::Unknown
                    )
                    && record.provenance == RowSource::NodeScanned
            }
            None => false,
        };
        if !overridable {
            return Ok(None);
        }
        let replaced = self.messages.records.get(&record.txid).cloned();
        self.messages.upsert(record.txid.clone(), record)?;
        Ok(replaced)
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
        message_from(
            txid,
            conversation_id,
            unix_ms,
            envelope_tail,
            RowSource::NodeScanned,
        )
    }

    fn message_from(
        txid: &str,
        conversation_id: &str,
        unix_ms: u64,
        envelope_tail: u8,
        provenance: RowSource,
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
            provenance,
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

    /// THE anti-history-loss pin (V5, finding 14). kvlog's `replay()` STOPS
    /// at the first undecodable frame — if the provenance decode mishandled a
    /// pre-V5 frame, every pre-V5 log would silently replay to ZERO rows
    /// (outbound reseals unrecoverable). Hand-encoded V1-layout frames (the
    /// exact bytes a pre-V5 build wrote) must load complete, as `Unknown`.
    #[test]
    fn pre_v5_message_frames_replay_with_unknown_provenance() {
        /// Byte-for-byte mirror of the pre-V5 `MessageRecord` layout.
        #[derive(BorshSerialize)]
        struct V1MessageRecord {
            txid: String,
            conversation_id: String,
            direction: MessageDirection,
            kind: StoredKind,
            envelope: Vec<u8>,
            unix_ms: u64,
            alias_on_wire: Option<String>,
            sealed_to: Option<(KeyBranch, u32)>,
        }
        let v1_frame = |txid: &str, unix_ms: u64| {
            // Frame::Upsert = variant index 0, then the record fields —
            // the same technique as kvlog's `pre_v1_logs_replay_unchanged`.
            let record = V1MessageRecord {
                txid: txid.to_string(),
                conversation_id: "c1".to_string(),
                direction: MessageDirection::Inbound,
                kind: StoredKind::Comm,
                envelope: vec![7u8; 61],
                unix_ms,
                alias_on_wire: Some("fa6d1afa79e1".to_string()),
                sealed_to: Some((KeyBranch::Receive, 3)),
            };
            let body = borsh::to_vec(&(0u8, record)).unwrap();
            let mut frame = (body.len() as u32).to_le_bytes().to_vec();
            frame.extend_from_slice(&body);
            frame
        };

        let dir = test_dir("prev5");
        std::fs::create_dir_all(&dir).unwrap();
        let mut bytes = v1_frame("tx-old-1", 100);
        bytes.extend_from_slice(&v1_frame("tx-old-2", 200));
        std::fs::write(dir.join("messages.kvlog"), &bytes).unwrap();

        let store = TransportStore::load(dir.clone()).unwrap();
        let thread = store.messages_for("c1");
        assert_eq!(thread.len(), 2, "every pre-V5 row survives the upgrade");
        for row in &thread {
            assert_eq!(row.provenance, RowSource::Unknown, "absent ⇒ Unknown");
            assert_eq!(row.envelope, vec![7u8; 61]);
            assert_eq!(row.sealed_to, Some((KeyBranch::Receive, 3)));
        }

        // And a NEW write into the same log round-trips WITH provenance.
        let mut store = store;
        store
            .record_message(message_from("tx-new", "c1", 300, 1, RowSource::FillSourced))
            .unwrap();
        let reloaded = TransportStore::load(dir.clone()).unwrap();
        assert_eq!(reloaded.messages_for("c1").len(), 3);
        assert_eq!(
            reloaded.message("tx-new").unwrap().provenance,
            RowSource::FillSourced
        );
        assert_eq!(
            reloaded.message("tx-old-1").unwrap().provenance,
            RowSource::Unknown
        );

        let _ = std::fs::remove_dir_all(&dir);
    }

    /// A corrupt provenance TAG (present but invalid) is a hard decode error
    /// — the frame keeps replay()'s stop-at-corruption posture and never
    /// masquerades as a live row with `Unknown` provenance.
    #[test]
    fn a_corrupt_provenance_tag_never_masquerades_as_unknown() {
        let dir = test_dir("badtag");
        let mut store = TransportStore::load(dir.clone()).unwrap();
        store
            .record_message(message("tx-good", "c1", 1, 1))
            .unwrap();
        store.record_message(message("tx-bad", "c1", 2, 2)).unwrap();

        // Corrupt the LAST frame's final byte (its provenance tag) in place.
        let path = dir.join("messages.kvlog");
        let mut bytes = std::fs::read(&path).unwrap();
        let last = bytes.len() - 1;
        bytes[last] = 0xFF;
        std::fs::write(&path, &bytes).unwrap();

        let reloaded = TransportStore::load(dir.clone()).unwrap();
        assert!(reloaded.message("tx-good").is_some(), "intact frame kept");
        assert!(
            reloaded.message("tx-bad").is_none(),
            "the corrupt frame is dropped at replay, not decoded as Unknown"
        );

        let _ = std::fs::remove_dir_all(&dir);
    }

    /// The finding-14 deliverable proof: a node-scanned row REPLACES a
    /// fill-sourced one on the same txid (never dedupe-suppressed), replay
    /// agrees, and a reorg tombstone on that txid is untouched by the swap.
    #[test]
    fn node_scan_overrides_a_fill_sourced_row_on_the_same_txid() {
        let dir = test_dir("override");
        let mut store = TransportStore::load(dir.clone()).unwrap();

        // The hostile-indexer shape: a fill row wearing a live txid over the
        // WRONG envelope bytes.
        let fill = message_from("tx1", "c1", 100, 0xAA, RowSource::FillSourced);
        assert!(store.record_message(fill.clone()).unwrap());
        assert!(store.tombstone_message("tx1").unwrap());

        // Node truth arrives: same txid, the real envelope.
        let node = message_from("tx1", "c1", 100, 0xBB, RowSource::NodeScanned);
        let replaced = store.override_message(node.clone()).unwrap();
        assert_eq!(replaced.as_ref().map(|r| r.envelope[60]), Some(0xAA));

        let row = store.message("tx1").unwrap();
        assert_eq!(row.provenance, RowSource::NodeScanned);
        assert_eq!(row.envelope[60], 0xBB, "node envelope replaced the claim");
        assert!(
            store.is_message_tombstoned("tx1"),
            "the reorg ghost flag tracks the txid, not the row bytes"
        );

        // Replay agrees (last-write-wins on the upsert log).
        let reloaded = TransportStore::load(dir.clone()).unwrap();
        assert_eq!(reloaded.message("tx1").unwrap().envelope[60], 0xBB);
        assert_eq!(
            reloaded.message("tx1").unwrap().provenance,
            RowSource::NodeScanned
        );

        // A node row is now settled truth — a second override is refused.
        assert!(store
            .override_message(message_from("tx1", "c1", 100, 0xCC, RowSource::NodeScanned))
            .unwrap()
            .is_none());

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn fill_never_overrides_and_outbound_rows_are_never_overridable() {
        let dir = test_dir("noover");
        let mut store = TransportStore::load(dir.clone()).unwrap();

        // Fill vs node-scanned: first-write-wins holds, override refused.
        store
            .record_message(message_from("tx1", "c1", 100, 0xAA, RowSource::NodeScanned))
            .unwrap();
        assert!(!store
            .record_message(message_from("tx1", "c1", 100, 0xBB, RowSource::FillSourced))
            .unwrap());
        assert!(store
            .override_message(message_from("tx1", "c1", 100, 0xBB, RowSource::FillSourced))
            .unwrap()
            .is_none());
        assert_eq!(store.message("tx1").unwrap().envelope[60], 0xAA);

        // An OUTBOUND row is self-authored — node "truth" never rewrites it
        // (the wallet_sync incoming-never-downgrades discipline), even when
        // its provenance is a pre-V5 Unknown.
        let mut outbound = message_from("tx2", "c1", 200, 0xDD, RowSource::Unknown);
        outbound.direction = MessageDirection::Outbound;
        store.record_message(outbound).unwrap();
        assert!(store
            .override_message(message_from("tx2", "c1", 200, 0xEE, RowSource::NodeScanned))
            .unwrap()
            .is_none());
        assert_eq!(store.message("tx2").unwrap().envelope[60], 0xDD);

        // Overriding a txid that was never stored is a refusal, not a write.
        assert!(store
            .override_message(message_from("tx-none", "c1", 1, 1, RowSource::NodeScanned))
            .unwrap()
            .is_none());
        assert!(store.message("tx-none").is_none());

        let _ = std::fs::remove_dir_all(&dir);
    }

    /// Pre-V5 rows default Unknown — and the next node scan CLAIMS them
    /// (the deliberate migration posture: never assume node-scanned).
    #[test]
    fn unknown_rows_are_claimed_by_the_next_node_scan() {
        let dir = test_dir("claim");
        let mut store = TransportStore::load(dir.clone()).unwrap();
        store
            .record_message(message_from("tx1", "c1", 100, 0xAA, RowSource::Unknown))
            .unwrap();

        let replaced = store
            .override_message(message_from("tx1", "c1", 100, 0xBB, RowSource::NodeScanned))
            .unwrap();
        assert!(replaced.is_some());
        assert_eq!(
            store.message("tx1").unwrap().provenance,
            RowSource::NodeScanned
        );

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn provenance_round_trips_across_reload() {
        let dir = test_dir("prov");
        let mut store = TransportStore::load(dir.clone()).unwrap();
        store
            .record_message(message_from("tx-n", "c1", 1, 1, RowSource::NodeScanned))
            .unwrap();
        store
            .record_message(message_from("tx-f", "c1", 2, 2, RowSource::FillSourced))
            .unwrap();
        let mut own = message_from("tx-o", "c1", 3, 3, RowSource::Own);
        own.direction = MessageDirection::Outbound;
        store.record_message(own).unwrap();

        let reloaded = TransportStore::load(dir.clone()).unwrap();
        assert_eq!(
            reloaded.message("tx-n").unwrap().provenance,
            RowSource::NodeScanned
        );
        assert_eq!(
            reloaded.message("tx-f").unwrap().provenance,
            RowSource::FillSourced
        );
        assert_eq!(reloaded.message("tx-o").unwrap().provenance, RowSource::Own);

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
