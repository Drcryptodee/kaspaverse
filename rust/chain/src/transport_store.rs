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
use crate::transport::WireNamespace;

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
    /// When this conversation was established.
    ///
    /// **Two clock domains, by status.** While `PendingInbound` it is the
    /// handshake's BLOCK time (indexer-claimed on a fill-sourced row, node
    /// truth once our own scan overrides it); on the transition to `Active`
    /// the accept re-stamps it from our LOCAL clock. That is deliberate: this
    /// field now orders which of two threads with one contact is live
    /// (`superseded_by`), and an ordering key must not be a value an archive
    /// supplied. `invite_expired` reads the pending-side value only, so the
    /// pruning-horizon gate is unaffected.
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
/// **Trailing-optional field law (V5, extended V6):** [`Self::provenance`]
/// and [`Self::wire`] are decoded by a manual [`BorshDeserialize`] that treats
/// end-of-input as "field absent" (pre-V5 frame ⇒ [`RowSource::Unknown`];
/// pre-V6 frame ⇒ [`WireNamespace::CiphMsg`]) — the record-level twin of the
/// kvlog frame-compatibility law, needed because `replay()` STOPS at the
/// first undecodable frame (a naive new field would replay every older log
/// to zero rows). Corollaries: new fields are append-only, each must be
/// readable-as-absent-on-EOF in declaration order, and `MessageRecord` must
/// remain the FINAL borsh element of any enclosing frame (true today: it only
/// ever rides `Frame::Upsert`'s single payload slot).
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
    /// Row provenance (V5, finding 14). Trailing-optional — see the law above.
    pub provenance: RowSource,
    /// The namespace the row rode under (V6, kasia_messaging §K11): which
    /// dialect the counterparty's client speaks, learned from their traffic.
    /// Absent on every frame written before V6, which is correct — the scan
    /// matched nothing but `ciph_msg:` until then. MUST stay the last field.
    pub wire: WireNamespace,
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
        // V6, same law, same technique: a V5 frame ENDS here. (A pre-V5 frame
        // ended one field earlier and the read above already returned 0; this
        // read returns 0 again — end-of-input is sticky, so the two absences
        // compose without a flag.)
        let wire = if reader.read(&mut tag)? == 0 {
            WireNamespace::CiphMsg
        } else {
            WireNamespace::deserialize_reader(&mut &tag[..])?
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
            wire,
        })
    }
}

/// What [`TransportStore::merge_duplicate_contacts`] folded. Counts only.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct ContactMergeReport {
    /// Contact addresses that held more than one row.
    pub contacts: usize,
    /// Rows folded away (each contact keeps exactly one).
    pub rows_folded: usize,
    /// Message rows re-homed onto the kept conversation.
    pub messages_rehomed: usize,
}

/// What a [`TransportStore::wipe`] destroyed. Counts only — a report about
/// erasing user content may not carry any of it.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct WipeReport {
    pub conversations: usize,
    pub messages: usize,
    /// Unanswered inbound invitations — each holding a bond only an Accept can
    /// return.
    pub pending_bonds: usize,
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
    /// convention.
    ///
    /// **Status RANKS the candidates; it does not filter them.** That
    /// distinction is the whole design.
    ///
    /// An alias is public wire data and ours are validated for shape only, so
    /// a stranger may declare one equal to a live thread's. The old
    /// `min(conversation_id)` tie-break made that **grindable**: our ids are
    /// random hex, and while every attempt must pay an output to a watched
    /// address, the bond *amount* is only checked at accept — so invitations
    /// can be minted at the dust floor until one lands with a lower id, after
    /// which the real contact's messages file themselves into an invisible
    /// pending row. Ranking by status defeats that outright: an unaccepted
    /// invitation can never outrank a live conversation, whatever its id.
    ///
    /// **Filtering by status would have been a different bug.** The live
    /// population's own send gate is `active || (pending && initiatedByMe)`,
    /// the same rule we grant ourselves, so a counterparty legitimately sends
    /// comms BEFORE we accept. Our `PendingInbound` row already knows their
    /// alias, and excluding it would drop that traffic on the node lane —
    /// recoverable only through an untrusted indexer, if at all. We would be
    /// claiming a right we refuse from the other side.
    ///
    /// Ordering, most significant first. `created_unix_ms` sits ABOVE
    /// `last_activity` deliberately: establishment order is not
    /// attacker-editable, whereas an attacker bumps `last_activity` simply by
    /// sending, which would otherwise let them climb the ranking with the very
    /// traffic being judged.
    ///
    /// The prior docstring cited Kasia's `aliasToConversation` (which maps
    /// both sides) as licence for a GATE. That was the wrong citation — their
    /// gate is `getMonitoredConversations`, `theirAlias` only.
    ///
    /// Hidden (tombstoned) rows still match, deliberately — see
    /// [`Self::tombstone_conversation`].
    pub fn conversation_by_alias(&self, alias: &str) -> Option<&ConversationRecord> {
        /// Higher wins. A conversation we can actually talk in outranks one
        /// still awaiting our accept.
        fn rank(c: &ConversationRecord) -> u8 {
            match c.status {
                ConversationStatus::Active => 2,
                ConversationStatus::PendingOutbound if c.initiated_by_me => 1,
                _ => 0,
            }
        }
        self.conversations
            .records
            .values()
            .filter(|c| c.my_alias == alias || c.their_alias.as_deref() == Some(alias))
            .max_by(|a, b| {
                rank(a)
                    .cmp(&rank(b))
                    // WITHIN a rank, a live row beats a hidden one — so a
                    // dismissed invitation cannot shadow a live invitation
                    // that shares its alias and get that stranger's genuine
                    // pre-accept traffic dropped as "dismissed".
                    //
                    // This sits BELOW rank on purpose. Demoting hidden rows
                    // outright would let a squatter's pending row capture a
                    // hidden ACTIVE thread's alias, and the un-hide would then
                    // never fire — breaking the promise that a contact can
                    // still reach you.
                    .then(
                        (!self.conversations.is_tombstoned(&a.conversation_id))
                            .cmp(&!self.conversations.is_tombstoned(&b.conversation_id)),
                    )
                    // Older establishment wins: the squatter arrived later.
                    .then(b.created_unix_ms.cmp(&a.created_unix_ms))
                    .then(a.last_activity_unix_ms.cmp(&b.last_activity_unix_ms))
                    // Reversed, so `max_by` lands on the lowest id.
                    .then(b.conversation_id.cmp(&a.conversation_id))
            })
    }

    /// Find the PendingOutbound conversation whose `my_alias` an acceptance
    /// response echoed back (`theirAlias` from the responder's perspective).
    pub fn conversation_awaiting_response(
        &self,
        echoed_alias: &str,
    ) -> Option<&ConversationRecord> {
        // RANKED, not `.find`. This used to take the first match out of a
        // `HashMap`'s values, whose order is `RandomState` — reseeded every
        // process start. With two `PendingOutbound` rows sharing `my_alias`,
        // which conversation a counterparty's acceptance completed was a coin
        // flip that could land differently on the next app launch, over a bond
        // already spent. Its siblings above have carried a deterministic
        // `max_by` since c917dd6; this one was missed.
        self.conversations
            .records
            .values()
            .filter(|c| {
                c.status == ConversationStatus::PendingOutbound && c.my_alias == echoed_alias
            })
            .max_by(|a, b| {
                // A live row beats a hidden one; then the older establishment
                // (the one that actually sent the handshake being answered);
                // then the lowest id, purely to break the last tie somewhere
                // fixed. Same ordering as `conversation_by_alias`.
                (!self.conversations.is_tombstoned(&a.conversation_id))
                    .cmp(&!self.conversations.is_tombstoned(&b.conversation_id))
                    .then(b.created_unix_ms.cmp(&a.created_unix_ms))
                    .then(b.conversation_id.cmp(&a.conversation_id))
            })
    }

    /// Find a conversation by the counterparty's own address — **the live
    /// population's conversation key** (D-139).
    ///
    /// Kasia looks a handshake up "strictly by sender address only"
    /// (`conversation-manager-service.ts:181-183` @ `acd3cf65`): the address
    /// is the identity, and the alias is refreshable metadata hanging off it.
    /// Our model keyed on the alias alone, which is why a counterparty who
    /// already knew us could never complete a conversation — they answer an
    /// existing contact idempotently and emit no response, so the alias we
    /// were waiting on never arrived.
    ///
    /// Empty addresses never match: a `PendingInbound` row carries none until
    /// its accept resolves the sender, and matching those together would fuse
    /// every unaccepted invitation into one conversation.
    ///
    /// **Several rows can share one address**, and this picks between them on
    /// PURPOSE rather than on a lexical accident. A user whose handshake hangs
    /// re-sends it; both attempts land as `PendingOutbound` to the same
    /// contact, each having spent a bond. Breaking that tie by
    /// `min(conversation_id)` — random hex — meant a coin flip: draw the wrong
    /// row and the other stays stuck forever with its 0.2 KAS gone, which is
    /// the exact symptom D-141 exists to end.
    ///
    /// So: prefer the row an inbound handshake can actually COMPLETE (one we
    /// initiated and are still waiting on), then the most recently active, and
    /// only then `conversation_id` so the answer stays identical across
    /// process starts — a misroute must be reproducible, never per-boot.
    pub fn conversation_by_contact_address(&self, address: &str) -> Option<&ConversationRecord> {
        if address.is_empty() {
            return None;
        }
        self.conversations
            .records
            .values()
            .filter(|c| c.contact_address == address)
            .max_by(|a, b| {
                let completable = |c: &ConversationRecord| {
                    c.initiated_by_me && c.status == ConversationStatus::PendingOutbound
                };
                completable(a)
                    .cmp(&completable(b))
                    .then(a.last_activity_unix_ms.cmp(&b.last_activity_unix_ms))
                    // Reversed, so the deterministic fallback stays "lowest id"
                    // under `max_by` (which also takes the LAST maximum).
                    .then(b.conversation_id.cmp(&a.conversation_id))
            })
    }

    /// Every conversation we hold with this counterparty, most-established
    /// first (`Active`, then by creation order).
    ///
    /// Distinct from [`Self::conversation_by_contact_address`] on purpose:
    /// that one ranks a completable `PendingOutbound` ABOVE an `Active` row,
    /// because an inbound handshake is looking for the row it can complete.
    /// A caller deciding whether to START a conversation needs the opposite
    /// bias, and reusing the wrong selector would offer to re-handshake a
    /// contact you are already talking to.
    pub fn conversations_for_contact_address(&self, address: &str) -> Vec<&ConversationRecord> {
        if address.is_empty() {
            return Vec::new();
        }
        let mut rows: Vec<&ConversationRecord> = self
            .conversations
            .records
            .values()
            .filter(|c| c.contact_address == address)
            .collect();
        rows.sort_by(|a, b| {
            (b.status == ConversationStatus::Active)
                .cmp(&(a.status == ConversationStatus::Active))
                .then(a.created_unix_ms.cmp(&b.created_unix_ms))
                .then(a.conversation_id.cmp(&b.conversation_id))
        });
        rows
    }

    /// Destroy every conversation and every message. Returns what was there.
    ///
    /// This is the total erase, and it is total ON PURPOSE. A per-conversation
    /// delete is a different and much more dangerous operation: a conversation
    /// row is the ONLY place a counterparty's alias lives, and a client that
    /// already knows us never re-announces itself, so deleting one row leaves
    /// them writing to a thread we can no longer route (the July regression —
    /// see [`Self::tombstone_conversation`], which exists because of it).
    ///
    /// Erasing everything is safe precisely because it leaves nothing
    /// half-bound: there is no surviving row for a lost alias to orphan, and
    /// the user knows they are starting over with everyone. That is also how
    /// the live population's own "delete all" behaves, and — measured on the
    /// founder's device — how a broken conversation actually gets repaired: a
    /// client that has forgotten you is the only one that will handshake you
    /// afresh.
    ///
    /// Messages first: if the conversation wipe fails after this, the store is
    /// left with rows whose threads are empty, which is recoverable and
    /// visible. The reverse leaves messages that belong to nothing, routable
    /// by no lookup and invisible to every screen.
    pub fn wipe(&mut self) -> Result<WipeReport> {
        let report = self.wipe_preview();
        self.messages.wipe()?;
        self.conversations.wipe()?;
        Ok(report)
    }

    /// What [`Self::wipe`] WOULD destroy, without destroying it.
    ///
    /// Exists so a confirmation can name a true number. The obvious source for
    /// that number — the conversation list the user is looking at — is the
    /// wrong one: it filters tombstoned rows, and the wipe does not. A user
    /// with three visible and four hidden conversations would be asked to
    /// confirm "delete 3" and then told "deleted 7", which is worse than no
    /// number at all on the one screen where the number IS the consent.
    ///
    /// Deliberately the same expression as `wipe`'s own accounting, called by
    /// it, so the two cannot drift.
    pub fn wipe_preview(&self) -> WipeReport {
        WipeReport {
            conversations: self.conversations.records.len(),
            messages: self.messages.records.len(),
            // Counted separately because it is somebody else's money. An
            // unaccepted invitation holds a bond the counterparty paid, and
            // accepting is the only route to returning it — so destroying the
            // row keeps their 0.2 KAS with no way to give it back. The user is
            // entitled to know that before they agree, not after.
            //
            // **Deliberately NOT the same set the wipe destroys.** The wipe
            // takes tombstoned rows too, but a DISMISSED invitation's bond is
            // already permanently unreturnable — un-hiding refuses a
            // `PendingInbound` row and the accept refuses a tombstoned one — so
            // the wipe is not what strands it, and the sheet's causal claim
            // ("can no longer be returned") would be false about them.
            pending_bonds: self
                .conversations
                .records
                .values()
                .filter(|c| c.status == ConversationStatus::PendingInbound)
                .filter(|c| !self.conversations.is_tombstoned(&c.conversation_id))
                .count(),
        }
    }

    /// The LIVE conversation that has replaced this one with the same
    /// counterparty, if any — the row a message typed here would have to go
    /// through to arrive.
    ///
    /// ## Why this is derived and not a stored flag
    ///
    /// A Kasia-family conversation is a pair of locally-minted aliases. The
    /// protocol's only repair for a broken one is for a side to FORGET and
    /// re-handshake — a client that still remembers you answers a repeat
    /// handshake with silence (`conversation-manager-service.ts:181-213`), so
    /// forgetting is the mechanism, not a mistake. We therefore must keep
    /// accepting a fresh handshake from an address we already talk to.
    ///
    /// What we must NOT do is keep the old row sendable afterwards. Measured
    /// on the founder's device 2026-08-17: the counterparty wiped and
    /// re-handshaked at 2026-08-15 21:34:38Z, 78 seconds after the last
    /// message on the old row. Both conversations were left `Active` against
    /// the same address, both listed, both sendable — and the old one's alias
    /// is monitored by nobody. Every message typed there is built, signed,
    /// broadcast, charged a fee, and read by no one. Silence is the whole
    /// failure mode: nothing errors.
    ///
    /// Derived rather than stored because [`ConversationRecord`] is
    /// `#[derive(BorshDeserialize)]` and positional — appending a field makes
    /// every existing frame undecodable and `replay()` stops at the first
    /// failure, replaying a live device to zero conversations. The rule needs
    /// no migration: it reads correctly against records written months ago.
    ///
    /// Newest-wins by `created_unix_ms`, because establishment order is the
    /// only thing that says which alias pair the counterparty is actually
    /// listening on. `conversation_id` breaks a tie so the answer is
    /// deterministic rather than HashMap-ordered.
    ///
    /// A tombstoned successor cannot supersede anything: the user hid it, so
    /// it is not somewhere their messages should be routed either.
    pub fn superseded_by(&self, conversation_id: &str) -> Option<&ConversationRecord> {
        let row = self.conversations.records.get(conversation_id)?;
        // No address, nothing to be superseded BY — a PendingInbound row that
        // has not resolved its sender shares no identity with anything.
        if row.contact_address.is_empty() {
            return None;
        }
        // AN INVITATION IS NEVER SUPERSEDED, however many live threads we have
        // with that address.
        //
        // "Superseded" means "do not type here" — a statement about SENDING.
        // The action on a `PendingInbound` row is Accept, which returns the
        // 0.2 KAS bond the counterparty already paid. Marking one superseded
        // takes that button away and strands their money with no other route
        // to it (`wallet-security-auditor`, 2026-08-17). Their bond is not
        // ours to strand because we happen to have a newer thread.
        //
        // D-305 NARROWS the row set this rule ever sees: an invitation from an
        // address we already hold a conversation with is FOLDED into that
        // conversation by [`Self::merge_contact`] (no accept card survives —
        // the population's own semantics for a repeat handshake), so the
        // invitations that reach here are ones with no other row to fold into.
        if row.status == ConversationStatus::PendingInbound {
            return None;
        }
        self.conversations
            .records
            .values()
            .filter(|c| {
                c.conversation_id != row.conversation_id
                    && c.contact_address == row.contact_address
                    && c.status == ConversationStatus::Active
                    // Sendable, not merely Active. The refusal this rule
                    // drives points the user at the successor, so a successor
                    // that would ALSO refuse turns one dead end into two —
                    // exactly the no-exit shape INV-6 forbids. An `Active` row
                    // with an empty alias is narrow (only the restore path can
                    // mint one) but it is reachable, and the send gate's own
                    // predicate requires the alias.
                    && !c.my_alias.is_empty()
                    && !self.conversations.is_tombstoned(&c.conversation_id)
            })
            .filter(|c| {
                (c.created_unix_ms, c.conversation_id.as_str())
                    > (row.created_unix_ms, row.conversation_id.as_str())
            })
            .max_by(|a, b| {
                a.created_unix_ms
                    .cmp(&b.created_unix_ms)
                    .then_with(|| a.conversation_id.cmp(&b.conversation_id))
            })
    }

    /// Whether any conversation knows WHO it is talking to but not what alias
    /// they write under — the precondition for learning an alias back from an
    /// inbound message.
    ///
    /// It gates a full key-window decrypt attempt on every otherwise-unroutable
    /// comm, and on a public chain that is every stranger's traffic. So the
    /// expensive path runs only while we are genuinely missing something, and
    /// costs nothing once every conversation knows its contact's alias.
    pub fn has_conversation_awaiting_alias(&self) -> bool {
        self.conversations
            .records
            .values()
            .any(|c| c.their_alias.is_none() && !c.contact_address.is_empty())
    }

    /// Whether ANY conversation knows its counterparty's address — the free
    /// pre-check that keeps the inbound fold from paying an RPC round trip
    /// when no address could possibly match. Answers without cloning or
    /// sorting the record set, which [`Self::list_conversations`] does.
    pub fn conversations_have_any_contact_address(&self) -> bool {
        self.conversations
            .records
            .values()
            .any(|c| !c.contact_address.is_empty())
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
    /// **Destroys the conversation row, including the counterparty's alias.**
    ///
    /// Do not reach for this as a "cleanup". Hiding uses
    /// [`Self::tombstone_conversation`]; this primitive exists only for a true
    /// purge, and it has no caller today. The alias it deletes is the single
    /// field nothing else on the device can re-derive — a client that already
    /// knows us never re-announces itself — and destroying it silently
    /// unroutes every message that contact sends afterwards. That is not
    /// hypothetical: it cost a live thread in July 2026 (D-141).
    pub fn remove_conversation(&mut self, conversation_id: &str) -> Result<()> {
        self.conversations.remove(conversation_id)
    }

    /// When a conversation's alias in `direction` was last put on the wire:
    /// the newest surviving handshake row in that direction (`Outbound` = our
    /// handshake or acceptance, so OUR alias; `Inbound` = theirs, so THEIRS),
    /// falling back to the row's establishment when none survives. A reused
    /// request re-announces our alias on every retry without moving
    /// `created_unix_ms`, which is why this reads the rows and not the clock.
    fn announced_at(&self, row: &ConversationRecord, direction: MessageDirection) -> u64 {
        self.messages
            .records
            .values()
            .filter(|m| {
                m.conversation_id == row.conversation_id
                    && m.direction == direction
                    && m.kind == StoredKind::Handshake
                    && !self.messages.is_tombstoned(&m.txid)
            })
            .map(|m| m.unix_ms)
            .max()
            .unwrap_or(row.created_unix_ms)
    }

    /// The wire dialect this conversation's counterparty speaks — the
    /// namespace of their most recent inbound comm, `ciph_msg` until they have
    /// said anything (kasia_messaging §K11).
    ///
    /// **Derived, never stored on the conversation.** [`ConversationRecord`]
    /// is positional borsh with no trailing-field law, and a stored flag would
    /// go stale the day the counterparty updates their app; the newest thing
    /// they sent is the only honest evidence of what they run. Inbound comms
    /// only: our own rows say what WE chose, handshakes say nothing (we
    /// compose those in `ciph_msg` for everyone), and a reorg ghost is a
    /// transaction the chain took back.
    pub fn conversation_wire(&self, conversation_id: &str) -> WireNamespace {
        self.messages
            .records
            .values()
            .filter(|m| {
                m.conversation_id == conversation_id
                    && m.direction == MessageDirection::Inbound
                    && m.kind == StoredKind::Comm
                    && !self.messages.is_tombstoned(&m.txid)
            })
            .max_by(|a, b| a.unix_ms.cmp(&b.unix_ms).then(a.txid.cmp(&b.txid)))
            .map_or(WireNamespace::CiphMsg, |m| m.wire)
    }

    /// Move one message row onto another conversation. The row keeps its txid
    /// (the dedup key), its sealed bytes, its clock and its ghost flag — only
    /// the thread it belongs to changes. `false` when there is no such row or
    /// it is already there (no log growth).
    pub fn rehome_message(&mut self, txid: &str, conversation_id: &str) -> Result<bool> {
        let Some(existing) = self.messages.records.get(txid) else {
            return Ok(false);
        };
        if existing.conversation_id == conversation_id {
            return Ok(false);
        }
        let moved = MessageRecord {
            conversation_id: conversation_id.to_string(),
            ..existing.clone()
        };
        self.messages.upsert(txid.to_string(), moved)?;
        Ok(true)
    }

    /// **One conversation per contact address** — D-141's rule ("the
    /// counterparty's address is the conversation key") applied to the rows
    /// this store already holds.
    ///
    /// Duplicates arose on one lane: an inbound handshake from an address we
    /// already talk to is folded before our node can name its sender, so the
    /// address-keyed merge is skipped and a fresh invitation is minted beside
    /// the row it belongs to. Measured on the founder's device 2026-09-07: a
    /// conversation we opened on 08-23 and the counterparty's own handshake
    /// back on 08-24, held as two rows for a fortnight — one that could read
    /// and one that could never complete. `superseded_by` was built to paper
    /// over exactly that pair. The live population never holds two: Kasia's
    /// `processHandshake` looks up "strictly by sender address" and updates
    /// the alias in place (`conversation-manager-service.ts:181-213`).
    ///
    /// **Which row is kept** (the host), best first: one we can SEND in
    /// (`my_alias` set), then one that can READ (`their_alias` set), then
    /// `Active`, then visible, then the NEWER `created_unix_ms` — the last
    /// announced alias pair is the one a Kasia-class client is listening on —
    /// then the lowest id for determinism.
    ///
    /// **What the host takes from each folded row — the NEWEST announcement
    /// of each alias wins, in both directions.** Their alias and the slot they
    /// sealed to, when the host has none or the folded row's newest inbound
    /// handshake is later (a wipe-and-rehandshake carries a NEW alias, and
    /// the old one is monitored by nobody); OUR alias when the host has none
    /// or the folded row's newest outbound handshake is later (a *Start over*
    /// mints a fresh alias and pays 0.2 KAS to announce it — a Kasia-class
    /// counterparty refreshes ours in place on that handshake and fetches
    /// comms by it, so keeping the older one is deafness); the handshake txid
    /// when the host has none; the earliest establishment and the latest
    /// activity. A host that ends up holding both aliases and an address is
    /// `Active` unless it is an invitation still owed an accept.
    ///
    /// **Hidden means two things and the merge keeps both** (D-142): a hidden
    /// invitation is a block, and the block protects an accept card — so it
    /// carries only while the host IS one; otherwise a hidden host is a mute,
    /// and it comes back if the user could see any of the rows that fold
    /// into it.
    ///
    /// **No bond moves.** Folding a `PendingInbound` row into a conversation
    /// we opened takes the accept card away, which is correct: their
    /// handshake already refunded ours, and arming a second refund would pay
    /// them twice for one conversation. Folding one into an `Active` row
    /// leaves their second bond with us, which is the live population's own
    /// semantics for a repeat handshake (D-139/D-141).
    ///
    /// Every write is a durable frame; a failure part-way leaves a store that
    /// is still consistent (rows re-homed onto a host that exists), and the
    /// next start re-runs the pass.
    pub fn merge_duplicate_contacts(&mut self) -> Result<ContactMergeReport> {
        let mut addresses: Vec<String> = self
            .conversations
            .records
            .values()
            .filter(|c| !c.contact_address.is_empty())
            .map(|c| c.contact_address.clone())
            .collect();
        addresses.sort();
        addresses.dedup();
        let mut report = ContactMergeReport::default();
        for address in addresses {
            if let Some((_, one)) = self.merge_contact(&address)? {
                report.contacts += 1;
                report.rows_folded += one.rows_folded;
                report.messages_rehomed += one.messages_rehomed;
            }
        }
        Ok(report)
    }

    /// [`Self::merge_duplicate_contacts`] for one address. Returns the kept
    /// row's id with the counts, or `None` when there was nothing to fold.
    pub fn merge_contact(&mut self, address: &str) -> Result<Option<(String, ContactMergeReport)>> {
        if address.is_empty() {
            return Ok(None);
        }
        let mut rows: Vec<(ConversationRecord, bool)> = self
            .conversations
            .records
            .values()
            .filter(|c| c.contact_address == address)
            .map(|c| {
                (
                    c.clone(),
                    self.conversations.is_tombstoned(&c.conversation_id),
                )
            })
            .collect();
        if rows.len() < 2 {
            return Ok(None);
        }
        rows.sort_by(|(a, a_hidden), (b, b_hidden)| {
            merge_rank(a, *a_hidden)
                .cmp(&merge_rank(b, *b_hidden))
                // Reversed id order so the LOWEST id sorts last among equals,
                // where `pop` finds it.
                .then_with(|| b.conversation_id.cmp(&a.conversation_id))
        });
        let Some((mut host, host_hidden)) = rows.pop() else {
            return Ok(None);
        };
        // The block protects an ACCEPT CARD, so it carries only while the host
        // is still one (`consensus-auditor`, 2026-09-07). On a pre-D-305 store
        // the counterparty's own answer sat as an "Unknown sender" card — the
        // very thing a user dismisses — and carrying that dismissal onto the
        // conversation they opened and paid for would hide it with no gesture
        // to bring it back (hide has no manual restore; only their next
        // message reopens a mute, and a KaChat-4.0 contact may never send
        // one). Once no card survives, nothing is being protected.
        let blocked = host.status == ConversationStatus::PendingInbound
            && (host_hidden
                || rows
                    .iter()
                    .any(|(c, hidden)| *hidden && c.status == ConversationStatus::PendingInbound));
        let any_visible = !host_hidden || rows.iter().any(|(_, hidden)| !hidden);

        // Announcement times, snapshotted BEFORE the loop lowers `created`
        // (`consensus-auditor`, 2026-09-07: comparing against a value the loop
        // itself mutates let an older invitation read as "announced later" on
        // the third row). One rule for both aliases: the newest announcement
        // wins, because a Kasia-class client refreshes the alias in place on
        // every handshake it sees (`conversation-manager-service.ts:181-213`)
        // and fetches comms by (sender, alias) — an alias nobody listens on
        // is deafness, not history.
        let mut theirs_at = self.announced_at(&host, MessageDirection::Inbound);
        let mut mine_at = self.announced_at(&host, MessageDirection::Outbound);
        let mut created = host.created_unix_ms;
        let mut last = host.last_activity_unix_ms;

        let mut report = ContactMergeReport {
            contacts: 1,
            ..ContactMergeReport::default()
        };
        for (dup, _) in &rows {
            let dup_theirs_at = self.announced_at(dup, MessageDirection::Inbound);
            let dup_mine_at = self.announced_at(dup, MessageDirection::Outbound);
            if let Some(alias) = dup.their_alias.as_ref() {
                if host.their_alias.is_none() || dup_theirs_at > theirs_at {
                    host.their_alias = Some(alias.clone());
                    host.bound_branch = dup.bound_branch;
                    host.bound_index = dup.bound_index;
                    theirs_at = dup_theirs_at;
                }
            }
            if !dup.my_alias.is_empty() && (host.my_alias.is_empty() || dup_mine_at > mine_at) {
                host.my_alias = dup.my_alias.clone();
                mine_at = dup_mine_at;
            }
            if host.handshake_txid.is_none() {
                host.handshake_txid = dup.handshake_txid.clone();
            }
            created = created.min(dup.created_unix_ms);
            last = last.max(dup.last_activity_unix_ms);
        }
        host.created_unix_ms = created;
        host.last_activity_unix_ms = last;
        if host.status != ConversationStatus::PendingInbound
            && !host.my_alias.is_empty()
            && host.their_alias.is_some()
        {
            host.status = ConversationStatus::Active;
        }

        // Writes, in an order that never strands a row: the host first (so
        // every re-homed message lands on a conversation that exists), then
        // the messages, then the folded rows.
        let host_id = host.conversation_id.clone();
        self.conversations.upsert(host_id.clone(), host)?;
        for (dup, _) in &rows {
            let txids: Vec<String> = self
                .messages
                .records
                .values()
                .filter(|m| m.conversation_id == dup.conversation_id)
                .map(|m| m.txid.clone())
                .collect();
            for txid in txids {
                if self.rehome_message(&txid, &host_id)? {
                    report.messages_rehomed += 1;
                }
            }
            self.conversations.remove(&dup.conversation_id)?;
            report.rows_folded += 1;
        }
        if blocked {
            self.conversations.tombstone(&host_id)?;
        } else if any_visible {
            self.conversations.untombstone(&host_id)?;
        }
        Ok(Some((host_id, report)))
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

    /// Hide a conversation REVERSIBLY.
    ///
    /// Hiding used to call [`Self::remove_conversation`], and that hard delete
    /// destroyed the only copy of the counterparty's alias on the device —
    /// the one field that can never be re-derived from anything we keep. It
    /// cost a real user a working thread: he hid a conversation in July, and
    /// when the same contact kept messaging him, every message was dropped
    /// because the alias that routed them had been deleted. The counterparty
    /// never re-declares it in a handshake, because their client answers a
    /// contact it already knows idempotently.
    ///
    /// The reversible primitive was already here, wired only to the messages
    /// log for reorg ghosts. D-068 ratified hide as a "local tombstone" and
    /// the UI called it reversible; only the code disagreed.
    ///
    /// **Tombstoned rows must keep matching** in [`Self::conversation_by_alias`],
    /// [`Self::conversation_by_contact_address`] and
    /// [`Self::conversation_awaiting_response`] — that is the whole point.
    /// Only the user-facing list and the fill sweep filter them.
    pub fn tombstone_conversation(&mut self, conversation_id: &str) -> Result<bool> {
        self.conversations.tombstone(conversation_id)
    }

    /// Bring a hidden conversation back — the counterparty wrote again.
    pub fn untombstone_conversation(&mut self, conversation_id: &str) -> Result<bool> {
        self.conversations.untombstone(conversation_id)
    }

    /// Whether a conversation is currently hidden.
    pub fn is_conversation_tombstoned(&self, conversation_id: &str) -> bool {
        self.conversations.is_tombstoned(conversation_id)
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

/// The host-selection key for [`TransportStore::merge_contact`] — greater is
/// better, in the order the doc there gives. A tuple so the precedence is
/// visible rather than encoded in a chain of `then`s.
fn merge_rank(c: &ConversationRecord, hidden: bool) -> (bool, bool, bool, bool, u64) {
    (
        !c.my_alias.is_empty(),
        c.their_alias.is_some(),
        c.status == ConversationStatus::Active,
        !hidden,
        c.created_unix_ms,
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    /// HIDING MUST NOT DESTROY IDENTITY.
    ///
    /// The July regression in miniature: a user hides a conversation, the
    /// counterparty keeps writing, and every message must still find its home.
    /// Content goes; the alias binding stays.
    #[test]
    fn a_hidden_conversation_still_routes_its_counterpartys_messages() {
        let dir = test_dir("hide-keeps-identity");
        let mut store = TransportStore::load(dir.clone()).unwrap();
        let mut c = conversation("hidden-one", 10);
        c.their_alias = Some("90b4a1b640eb".to_string());
        c.status = ConversationStatus::Active;
        store.upsert_conversation(c).unwrap();

        assert!(store.tombstone_conversation("hidden-one").unwrap());
        assert!(store.is_conversation_tombstoned("hidden-one"));

        // Still matchable — this is the entire point of the change.
        assert_eq!(
            store
                .conversation_by_alias("90b4a1b640eb")
                .map(|c| c.conversation_id.as_str()),
            Some("hidden-one"),
            "a hidden conversation must still route its contact's messages"
        );
        assert!(
            store.conversation("hidden-one").is_some(),
            "the row survives"
        );

        // And it survives a reload — a tombstone is a frame, not memory.
        let reloaded = TransportStore::load(dir.clone()).unwrap();
        assert!(reloaded.is_conversation_tombstoned("hidden-one"));
        assert!(reloaded.conversation_by_alias("90b4a1b640eb").is_some());

        // Reversible: the counterparty wrote again.
        let mut store = TransportStore::load(dir.clone()).unwrap();
        assert!(store.untombstone_conversation("hidden-one").unwrap());
        assert!(!store.is_conversation_tombstoned("hidden-one"));

        // THE OTHER END OF THE AXIS, and it is the one with money on it.
        // A DISMISSED INVITATION must stay dismissed: a `PendingInbound` row
        // is the accept affordance, and accepting spends the bond refund, so
        // a stranger must never be able to re-arm it by writing again. The
        // store still MATCHES the row by alias (that is what the intake needs
        // in order to recognise and drop it); the refusal lives in
        // `handle_inbound_comm`, which is why this asserts the two facts that
        // guard combines: still matchable, still tombstoned.
        let mut invite = conversation("dismissed-invite", 10);
        invite.their_alias = Some("beefbeef0001".to_string());
        invite.status = ConversationStatus::PendingInbound;
        invite.initiated_by_me = false;
        invite.contact_address = String::new();
        store.upsert_conversation(invite).unwrap();
        assert!(store.tombstone_conversation("dismissed-invite").unwrap());

        let matched = store.conversation_by_alias("beefbeef0001").unwrap();
        assert_eq!(matched.conversation_id, "dismissed-invite");
        assert_eq!(matched.status, ConversationStatus::PendingInbound);
        assert!(
            store.is_conversation_tombstoned("dismissed-invite"),
            "the intake must be able to SEE that this row was dismissed"
        );
        // And it is unreachable by address, so no handshake path can revive it.
        assert!(
            store.conversation_by_contact_address("").is_none(),
            "an invitation carries no contact address until its accept"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// An alias is public wire data, and a handshake costs nothing until it is
    /// accepted — so an attacker could mint cheap invitations declaring a
    /// victim thread's alias until one landed with a lower random id, and the
    /// old `min(conversation_id)` tie-break would hand them the thread.
    #[test]
    fn a_ground_alias_collision_cannot_steal_a_live_thread() {
        let dir = test_dir("alias-grind");
        let mut store = TransportStore::load(dir.clone()).unwrap();

        // The real thread. Its id deliberately sorts LAST.
        let mut real = conversation("zzz-real", 500);
        real.their_alias = Some("90b4a1b640eb".to_string());
        real.status = ConversationStatus::Active;
        store.upsert_conversation(real).unwrap();

        // The attacker's unaccepted invitation, id ground to sort FIRST and
        // `last_activity` bumped by the very traffic being judged.
        let mut squat = conversation("aaa-squatter", 900);
        squat.their_alias = Some("90b4a1b640eb".to_string());
        squat.status = ConversationStatus::PendingInbound;
        squat.initiated_by_me = false;
        store.upsert_conversation(squat).unwrap();

        assert_eq!(
            store
                .conversation_by_alias("90b4a1b640eb")
                .map(|c| c.conversation_id.as_str()),
            Some("zzz-real"),
            "an unaccepted invitation must never capture a live thread's alias"
        );

        // …but a pending invitation is still REACHABLE on its OWN alias.
        // Status ranks, it does not filter: the live population sends before
        // we accept (their gate is `active || (pending && initiatedByMe)`),
        // so dropping pre-accept traffic would claim a right we refuse from
        // their side.
        let mut invitation = conversation("pending-invite", 20);
        invitation.their_alias = Some("d0d0cafe9999".to_string());
        invitation.status = ConversationStatus::PendingInbound;
        invitation.initiated_by_me = false;
        invitation.contact_address = String::new();
        store.upsert_conversation(invitation).unwrap();
        assert_eq!(
            store
                .conversation_by_alias("d0d0cafe9999")
                .map(|c| c.conversation_id.as_str()),
            Some("pending-invite"),
            "a pending invitation must still receive its own alias's traffic"
        );

        // Two EQUALLY eligible Active rows: the older establishment wins,
        // because an attacker can bump `last_activity` at will but cannot
        // rewrite when a conversation was created.
        let mut newer = conversation("aaa-newer", 9_999);
        newer.their_alias = Some("cafebabe1234".to_string());
        newer.status = ConversationStatus::Active;
        newer.created_unix_ms = 900;
        store.upsert_conversation(newer).unwrap();
        let mut older = conversation("zzz-older", 5);
        older.their_alias = Some("cafebabe1234".to_string());
        older.status = ConversationStatus::Active;
        older.created_unix_ms = 100;
        store.upsert_conversation(older).unwrap();
        assert_eq!(
            store
                .conversation_by_alias("cafebabe1234")
                .map(|c| c.conversation_id.as_str()),
            Some("zzz-older"),
            "establishment order decides between two live rows, not activity"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// ONE CONVERSATION PER CONTACT. Starting a conversation must find the
    /// row that already exists, and it needs the OPPOSITE ranking bias from
    /// the inbound fold — which deliberately prefers the row it can complete.
    #[test]
    fn starting_a_conversation_finds_the_one_that_already_exists() {
        let dir = test_dir("per-contact");
        let mut store = TransportStore::load(dir.clone()).unwrap();
        let addr = "kaspa:qqwsnxvukqew5hx5r7y5dr938hnw7hmgs7ca87zlvwlrps6rxdy2ja3xknpvj";

        assert!(
            store.conversations_for_contact_address(addr).is_empty(),
            "a stranger has no rows"
        );
        assert!(
            store.conversations_for_contact_address("").is_empty(),
            "an empty address must never match unaccepted invitations"
        );

        let mut pending = conversation("zzz-pending", 50);
        pending.contact_address = addr.to_string();
        pending.status = ConversationStatus::PendingOutbound;
        pending.created_unix_ms = 50;
        store.upsert_conversation(pending).unwrap();

        let mut live = conversation("aaa-live", 10);
        live.contact_address = addr.to_string();
        live.status = ConversationStatus::Active;
        live.created_unix_ms = 900;
        store.upsert_conversation(live).unwrap();

        let rows = store.conversations_for_contact_address(addr);
        assert_eq!(rows.len(), 2);
        assert_eq!(
            rows[0].conversation_id, "aaa-live",
            "an Active conversation leads — you are already talking to them, \
             so a new invitation is refused rather than reusing a stale row"
        );
        // …and the inbound fold's selector still biases the other way, toward
        // the row an arriving handshake can actually complete.
        assert_eq!(
            store
                .conversation_by_contact_address(addr)
                .map(|c| c.conversation_id.as_str()),
            Some("zzz-pending"),
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// The address lookup decides which conversation an inbound handshake
    /// rewrites, so its edges are money- and identity-relevant, not
    /// bookkeeping. (wallet-security + consensus auditors, 2026-08-14.)
    #[test]
    fn the_address_lookup_never_fuses_unaccepted_invitations() {
        let dir = test_dir("addr-lookup");
        let mut store = TransportStore::load(dir.clone()).unwrap();

        // Two PendingInbound invitations, neither accepted yet, so neither
        // knows its counterparty address. Matching them on "" would fuse every
        // pending invitation in the wallet into one conversation.
        for id in ["inbound-a", "inbound-b"] {
            let mut c = conversation(id, 10);
            c.contact_address = String::new();
            c.status = ConversationStatus::PendingInbound;
            c.initiated_by_me = false;
            store.upsert_conversation(c).unwrap();
        }
        assert!(
            store.conversation_by_contact_address("").is_none(),
            "an empty address must never match"
        );
        assert!(
            !store.conversations_have_any_contact_address(),
            "no address is known yet, so the fold must skip the RPC entirely"
        );

        // A known contact matches, and only itself.
        let known = "kaspa:qr0277xfclmv23fy7fxjp8dmnavac722cwaf8aja8p9762l5hg0ejkpgqujy6";
        let mut c = conversation("outbound-1", 20);
        c.contact_address = known.to_string();
        c.status = ConversationStatus::PendingOutbound;
        store.upsert_conversation(c).unwrap();
        assert!(store.conversations_have_any_contact_address());
        assert_eq!(
            store
                .conversation_by_contact_address(known)
                .map(|c| c.conversation_id.as_str()),
            Some("outbound-1")
        );
        assert!(
            store
                .conversation_by_contact_address("kaspa:qzsomeoneelse")
                .is_none(),
            "a stranger's address matches nothing"
        );

        // Two rows sharing one address: the one an inbound handshake can
        // actually COMPLETE wins, even though it is older and its id sorts
        // later. A user whose handshake hangs re-sends it — picking the wrong
        // row strands a spent bond forever.
        let mut active_already = conversation("aaa-active", 99);
        active_already.contact_address = known.to_string();
        active_already.status = ConversationStatus::Active;
        store.upsert_conversation(active_already).unwrap();
        assert_eq!(
            store
                .conversation_by_contact_address(known)
                .map(|c| c.conversation_id.as_str()),
            Some("outbound-1"),
            "the completable PendingOutbound row wins over a newer Active one"
        );

        // And the answer never varies with hash iteration order.
        let first = store
            .conversation_by_contact_address(known)
            .map(|c| c.conversation_id.clone());
        for _ in 0..8 {
            assert_eq!(
                store
                    .conversation_by_contact_address(known)
                    .map(|c| c.conversation_id.clone()),
                first,
                "the tie-break must not vary with hash iteration order"
            );
        }

        // With no completable row, the most recently active wins.
        let mut only_active = conversation("zzz-newer", 500);
        only_active.contact_address = "kaspa:qzother".to_string();
        only_active.status = ConversationStatus::Active;
        store.upsert_conversation(only_active).unwrap();
        let mut older = conversation("aaa-older", 100);
        older.contact_address = "kaspa:qzother".to_string();
        older.status = ConversationStatus::Active;
        store.upsert_conversation(older).unwrap();
        assert_eq!(
            store
                .conversation_by_contact_address("kaspa:qzother")
                .map(|c| c.conversation_id.as_str()),
            Some("zzz-newer"),
            "without a completable row, most-recent activity decides"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// A WIPE THAT COMES BACK IS NOT A WIPE.
    ///
    /// The log is append-only and replayed at load, so clearing the in-memory
    /// maps alone would look perfect until the next app start put every
    /// conversation back. The reload is the assertion that matters.
    #[test]
    fn a_wipe_survives_a_reload() {
        let dir = test_dir("wipe-survives-reload");
        let mut store = TransportStore::load(dir.clone()).unwrap();

        for id in ["one", "two", "three"] {
            store.upsert_conversation(conversation(id, 10)).unwrap();
            store
                .record_message(message(&format!("tx-{id}"), id, 10, 1))
                .unwrap();
        }
        // A tombstone must not outlive the wipe either — it is a claim about a
        // record that no longer exists.
        assert!(store.tombstone_conversation("two").unwrap());

        let report = store.wipe().unwrap();
        assert_eq!(report.conversations, 3);
        assert_eq!(report.messages, 3);
        assert!(store.list_conversations().is_empty());

        let reloaded = TransportStore::load(dir).unwrap();
        assert!(
            reloaded.list_conversations().is_empty(),
            "a wiped store must still be empty after the log replays"
        );
        assert!(reloaded.conversation("one").is_none());
        assert!(reloaded.message("tx-one").is_none());
        assert!(
            !reloaded.is_conversation_tombstoned("two"),
            "a tombstone for a destroyed record must not replay"
        );
    }

    /// The store stays USABLE after a wipe — this is a clear, not a close.
    /// The user carries on in the same session: new handshakes land, and they
    /// must survive their own reload too.
    #[test]
    fn a_wiped_store_still_accepts_and_persists_new_rows() {
        let dir = test_dir("wipe-then-write");
        let mut store = TransportStore::load(dir.clone()).unwrap();
        store.upsert_conversation(conversation("old", 10)).unwrap();
        store.wipe().unwrap();

        store
            .upsert_conversation(conversation("fresh", 20))
            .unwrap();
        store
            .record_message(message("tx-fresh", "fresh", 20, 2))
            .unwrap();

        let reloaded = TransportStore::load(dir).unwrap();
        assert_eq!(reloaded.list_conversations().len(), 1);
        assert!(reloaded.conversation("fresh").is_some());
        assert!(
            reloaded.conversation("old").is_none(),
            "the wiped row must not come back underneath the new one"
        );
    }

    /// THE COUNT THE USER CONSENTS TO IS THE COUNT THAT DIES.
    ///
    /// Both auditors caught this independently: the confirm sheet used to take
    /// its number from the conversation LIST, which filters hidden rows, while
    /// the wipe destroys them too. Ask to delete 1, be told 3 died.
    #[test]
    fn the_preview_counts_hidden_rows_because_the_wipe_destroys_them() {
        let dir = test_dir("wipe-preview-counts-hidden");
        let mut store = TransportStore::load(dir).unwrap();

        store
            .upsert_conversation(conversation("visible", 10))
            .unwrap();
        for id in ["hidden-a", "hidden-b"] {
            store.upsert_conversation(conversation(id, 10)).unwrap();
            assert!(store.tombstone_conversation(id).unwrap());
        }

        // One live invitation and one dismissed: only the live one names a
        // bond the wipe is responsible for stranding.
        let mut live_invite = conversation("invite-live", 10);
        live_invite.status = ConversationStatus::PendingInbound;
        store.upsert_conversation(live_invite).unwrap();
        let mut dead_invite = conversation("invite-dismissed", 10);
        dead_invite.status = ConversationStatus::PendingInbound;
        store.upsert_conversation(dead_invite).unwrap();
        assert!(store.tombstone_conversation("invite-dismissed").unwrap());

        let preview = store.wipe_preview();
        assert_eq!(
            preview.conversations, 5,
            "the preview must count what the wipe kills, hidden rows included"
        );
        assert_eq!(
            preview.pending_bonds, 1,
            "a dismissed invitation's bond was already unreturnable — the wipe \
             is not what stranded it, so claiming it would be false"
        );
        // The list — what the old count came from — sees one.
        assert_eq!(
            store
                .list_conversations()
                .iter()
                .filter(|c| !store.is_conversation_tombstoned(&c.conversation_id))
                .count(),
            2
        );
        assert_eq!(
            store.wipe().unwrap(),
            preview,
            "preview promised, wipe kept"
        );
    }

    /// AN INVITATION KEEPS ITS ACCEPT BUTTON, WHATEVER ELSE WE HAVE.
    ///
    /// Accepting is the only route to refunding the 0.2 KAS bond the
    /// counterparty already paid. Marking a `PendingInbound` row superseded
    /// took that button off the card and stranded their money with no other
    /// way to it — the card rendered the "Replaced" body instead.
    #[test]
    fn an_invitation_is_never_superseded_so_its_bond_can_always_be_refunded() {
        let dir = test_dir("superseded-never-an-invitation");
        let mut store = TransportStore::load(dir).unwrap();

        // An invitation that HAS resolved its sender — the case that could
        // actually collide with a live thread on the same address.
        let mut invitation = conversation("invitation", 10);
        invitation.contact_address = KASIA.to_string();
        invitation.created_unix_ms = 100;
        invitation.status = ConversationStatus::PendingInbound;
        invitation.my_alias = String::new();
        invitation.initiated_by_me = false;
        store.upsert_conversation(invitation).unwrap();

        let mut live = conversation("live", 20);
        live.contact_address = KASIA.to_string();
        live.created_unix_ms = 200;
        store.upsert_conversation(live).unwrap();

        assert!(
            store.superseded_by("invitation").is_none(),
            "an unaccepted invitation must never be marked replaced — accepting \
             it is how their bond comes back"
        );
    }

    /// A successor that cannot itself be sent in must not silence anything —
    /// pointing a refusal at a second refusal is a no-exit (INV-6).
    #[test]
    fn an_aliasless_successor_supersedes_nothing() {
        let dir = test_dir("superseded-needs-alias");
        let mut store = TransportStore::load(dir).unwrap();

        let mut old = conversation("old", 10);
        old.contact_address = KASIA.to_string();
        old.created_unix_ms = 100;
        store.upsert_conversation(old).unwrap();

        // Active, same contact, newer — but with no alias of ours it has
        // nothing to put on the wire, so `comm_sendable` refuses it too.
        let mut mute = conversation("mute", 20);
        mute.contact_address = KASIA.to_string();
        mute.created_unix_ms = 200;
        mute.my_alias = String::new();
        store.upsert_conversation(mute).unwrap();

        assert!(store.superseded_by("old").is_none());
    }

    /// Wiping an empty store is a no-op success, not an error — the user may
    /// press it twice, and the second press must not look like a failure.
    #[test]
    fn wiping_nothing_reports_nothing_and_succeeds() {
        let dir = test_dir("wipe-empty");
        let mut store = TransportStore::load(dir).unwrap();
        let report = store.wipe().unwrap();
        assert_eq!(report, WipeReport::default());
        assert_eq!(store.wipe().unwrap(), WipeReport::default());
    }

    /// THE FOUNDER'S DEVICE, 2026-08-17 — the shape this rule exists for.
    ///
    /// Pulled with `run-as` and decoded: two `Active` rows against
    /// `kaspa:qqwsnxvu…`, the second created 78 seconds after the last message
    /// on the first, because the counterparty wiped its state and re-handshaked.
    /// Both listed, both sendable, and only the newer alias pair is monitored
    /// by anyone. The timestamps below are the real ones.
    #[test]
    fn a_replaced_conversation_names_its_successor() {
        let dir = test_dir("superseded-founder-shape");
        let mut store = TransportStore::load(dir).unwrap();

        let mut old = conversation("ec272a74601a639f52d7c3ac7a4beafb", 1_755_293_600_000);
        old.contact_address = KASIA.to_string();
        old.my_alias = "8caa5e3c79ff".to_string();
        old.created_unix_ms = 1_755_124_758_000; // 2026-08-13 22:39:18Z
        store.upsert_conversation(old).unwrap();

        let mut new = conversation("be2aefdb54ce91378e2047029ed7f26d", 1_755_376_251_000);
        new.contact_address = KASIA.to_string();
        new.my_alias = "cf53a09c0d81".to_string();
        new.created_unix_ms = 1_755_293_678_000; // 2026-08-15 21:34:38Z
        store.upsert_conversation(new).unwrap();

        assert_eq!(
            store
                .superseded_by("ec272a74601a639f52d7c3ac7a4beafb")
                .map(|c| c.conversation_id.as_str()),
            Some("be2aefdb54ce91378e2047029ed7f26d"),
            "the old row must name the thread that replaced it"
        );
        assert!(
            store
                .superseded_by("be2aefdb54ce91378e2047029ed7f26d")
                .is_none(),
            "the live row is superseded by nothing — otherwise both go silent"
        );
    }

    /// A successor the user HID cannot claim traffic either. Hiding it says
    /// "not here"; routing the user's typing into it would say the opposite.
    #[test]
    fn a_hidden_successor_supersedes_nothing() {
        let dir = test_dir("superseded-hidden-successor");
        let mut store = TransportStore::load(dir).unwrap();

        let mut old = conversation("old", 10);
        old.contact_address = KASIA.to_string();
        old.created_unix_ms = 100;
        store.upsert_conversation(old).unwrap();

        let mut new = conversation("new", 20);
        new.contact_address = KASIA.to_string();
        new.created_unix_ms = 200;
        store.upsert_conversation(new).unwrap();
        assert!(store.tombstone_conversation("new").unwrap());

        assert!(
            store.superseded_by("old").is_none(),
            "a hidden successor must not silence the row it replaced"
        );
    }

    /// Only an `Active` row replaces anything. An invitation we have not
    /// accepted has no alias of ours on the wire, so nothing routes to it —
    /// letting it supersede would break a working thread for a card the user
    /// never touched.
    #[test]
    fn only_an_active_successor_supersedes() {
        let dir = test_dir("superseded-needs-active");
        let mut store = TransportStore::load(dir).unwrap();

        let mut old = conversation("old", 10);
        old.contact_address = KASIA.to_string();
        old.created_unix_ms = 100;
        store.upsert_conversation(old).unwrap();

        let mut pending = conversation("pending", 20);
        pending.contact_address = KASIA.to_string();
        pending.created_unix_ms = 200;
        pending.status = ConversationStatus::PendingInbound;
        pending.my_alias = String::new();
        store.upsert_conversation(pending).unwrap();

        assert!(store.superseded_by("old").is_none());
    }

    /// Different counterparties share nothing. The address is the identity.
    #[test]
    fn distinct_contacts_never_supersede_each_other() {
        let dir = test_dir("superseded-distinct");
        let mut store = TransportStore::load(dir).unwrap();

        let mut a = conversation("a", 10);
        a.contact_address = KASIA.to_string();
        a.created_unix_ms = 100;
        store.upsert_conversation(a).unwrap();

        let mut b = conversation("b", 20);
        b.contact_address = KACHAT.to_string();
        b.created_unix_ms = 200;
        store.upsert_conversation(b).unwrap();

        assert!(store.superseded_by("a").is_none());
        assert!(store.superseded_by("b").is_none());
    }

    /// A `PendingInbound` row carries no contact address until its accept
    /// resolves the sender. Empty is not a value — every unresolved invitation
    /// would otherwise supersede every other one.
    #[test]
    fn an_addressless_row_is_never_superseded() {
        let dir = test_dir("superseded-addressless");
        let mut store = TransportStore::load(dir).unwrap();

        let mut orphan = conversation("orphan", 10);
        orphan.contact_address = String::new();
        orphan.created_unix_ms = 100;
        orphan.status = ConversationStatus::PendingInbound;
        store.upsert_conversation(orphan).unwrap();

        let mut other = conversation("other", 20);
        other.contact_address = String::new();
        other.created_unix_ms = 200;
        store.upsert_conversation(other).unwrap();

        assert!(store.superseded_by("orphan").is_none());
    }

    /// Two rows minted in the same millisecond must still resolve to ONE
    /// answer, and the same answer every call — the record set is a HashMap.
    #[test]
    fn an_equal_creation_time_breaks_deterministically_on_id() {
        let dir = test_dir("superseded-tiebreak");
        let mut store = TransportStore::load(dir).unwrap();

        for id in ["aaa", "bbb", "ccc"] {
            let mut c = conversation(id, 10);
            c.contact_address = KASIA.to_string();
            c.created_unix_ms = 500;
            store.upsert_conversation(c).unwrap();
        }

        assert_eq!(
            store
                .superseded_by("aaa")
                .map(|c| c.conversation_id.as_str()),
            Some("ccc"),
            "highest id wins the tie, every time"
        );
        assert!(
            store.superseded_by("ccc").is_none(),
            "the tie-break winner is superseded by nobody — no cycles"
        );
        // Called repeatedly: a HashMap-ordered answer would eventually differ.
        for _ in 0..64 {
            assert_eq!(
                store
                    .superseded_by("bbb")
                    .map(|c| c.conversation_id.as_str()),
                Some("ccc")
            );
        }
    }

    /// The founder's Kasia counterpart.
    const KASIA: &str = "kaspa:qqwsnxvukqew5hx5r7y5dr938hnw7hmgs7ca87zlvwlrps6rxdy2ja3xknpvj";
    /// A different counterparty entirely.
    const KACHAT: &str = "kaspa:qqcwl7zlmt6d3cwwvmsdkktfnkd2r0mzx4pu4xcvfdfpnukka7ezy4zn86jlr";

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
            wire: WireNamespace::CiphMsg,
        }
    }

    /// A row shaped like the ones the merge cases below fold.
    #[allow(clippy::too_many_arguments)]
    fn row(
        id: &str,
        status: ConversationStatus,
        by_me: bool,
        my_alias: &str,
        their_alias: Option<&str>,
        created: u64,
    ) -> ConversationRecord {
        ConversationRecord {
            conversation_id: id.to_string(),
            contact_address: "kaspa:qqcwl7zlmt6d3cwwvmsdkktfnkd2r0mzx4pu4xcvfdfpnukka7ezy4zn86jlr"
                .to_string(),
            my_alias: my_alias.to_string(),
            their_alias: their_alias.map(str::to_string),
            status,
            initiated_by_me: by_me,
            bound_branch: KeyBranch::Receive,
            bound_index: if their_alias.is_some() { 3 } else { 0 },
            created_unix_ms: created,
            last_activity_unix_ms: created,
            handshake_txid: Some(format!("hs-{id}")),
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

    /// V6's anti-history-loss pin: a V5 frame (provenance present, no wire)
    /// and a pre-V5 frame (neither) both load complete, and the absent wire
    /// reads as `ciph_msg` — the only prefix the scan matched before V6.
    #[test]
    fn pre_v6_message_frames_replay_with_ciph_msg_wire() {
        #[derive(BorshSerialize)]
        struct V5MessageRecord {
            txid: String,
            conversation_id: String,
            direction: MessageDirection,
            kind: StoredKind,
            envelope: Vec<u8>,
            unix_ms: u64,
            alias_on_wire: Option<String>,
            sealed_to: Option<(KeyBranch, u32)>,
            provenance: RowSource,
        }
        let record = V5MessageRecord {
            txid: "tx-v5".to_string(),
            conversation_id: "c1".to_string(),
            direction: MessageDirection::Inbound,
            kind: StoredKind::Comm,
            envelope: vec![5u8; 61],
            unix_ms: 500,
            alias_on_wire: Some("822deb62da52".to_string()),
            sealed_to: None,
            provenance: RowSource::NodeScanned,
        };
        let body = borsh::to_vec(&(0u8, record)).unwrap();
        let mut frame = (body.len() as u32).to_le_bytes().to_vec();
        frame.extend_from_slice(&body);

        let dir = test_dir("prev6");
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join("messages.kvlog"), &frame).unwrap();

        let mut store = TransportStore::load(dir.clone()).unwrap();
        let row = store.message("tx-v5").expect("the V5 frame loads");
        assert_eq!(row.provenance, RowSource::NodeScanned, "V5 field intact");
        assert_eq!(row.wire, WireNamespace::CiphMsg, "absent ⇒ ciph_msg");

        // A NEW write round-trips with the namespace, beside the old frame.
        let mut kachat = message_from("tx-k", "c1", 600, 9, RowSource::NodeScanned);
        kachat.wire = WireNamespace::KChat;
        store.record_message(kachat).unwrap();
        let reloaded = TransportStore::load(dir.clone()).unwrap();
        assert_eq!(reloaded.message("tx-k").unwrap().wire, WireNamespace::KChat);
        assert_eq!(
            reloaded.message("tx-v5").unwrap().wire,
            WireNamespace::CiphMsg
        );
        assert_eq!(reloaded.messages_for("c1").len(), 2);

        let _ = std::fs::remove_dir_all(&dir);
    }

    /// A corrupt WIRE tag (present but invalid) is a hard decode error, like
    /// a corrupt provenance tag — never a live row wearing the default.
    #[test]
    fn a_corrupt_wire_tag_never_masquerades_as_ciph_msg() {
        let dir = test_dir("badwire");
        let mut store = TransportStore::load(dir.clone()).unwrap();
        store
            .record_message(message("tx-good", "c1", 1, 1))
            .unwrap();
        store.record_message(message("tx-bad", "c1", 2, 2)).unwrap();

        // The last byte of the last frame is now the wire tag.
        let path = dir.join("messages.kvlog");
        let mut bytes = std::fs::read(&path).unwrap();
        let last = bytes.len() - 1;
        bytes[last] = 0xFF;
        std::fs::write(&path, &bytes).unwrap();

        let reloaded = TransportStore::load(dir.clone()).unwrap();
        assert!(reloaded.message("tx-good").is_some());
        assert!(reloaded.message("tx-bad").is_none(), "dropped at replay");

        let _ = std::fs::remove_dir_all(&dir);
    }

    /// §K11: the dialect follows the counterparty's NEWEST inbound comm —
    /// not our own rows, not handshakes, not reorg ghosts — and is `ciph_msg`
    /// until they have spoken.
    #[test]
    fn conversation_wire_follows_the_latest_inbound_comm() {
        let dir = test_dir("dialect");
        let mut store = TransportStore::load(dir.clone()).unwrap();
        assert_eq!(
            store.conversation_wire("c1"),
            WireNamespace::CiphMsg,
            "silent ⇒ ciph_msg"
        );

        store.record_message(message("in-1", "c1", 100, 1)).unwrap();
        assert_eq!(store.conversation_wire("c1"), WireNamespace::CiphMsg);

        let mut later = message("in-2", "c1", 200, 2);
        later.wire = WireNamespace::KChat;
        store.record_message(later).unwrap();
        assert_eq!(
            store.conversation_wire("c1"),
            WireNamespace::KChat,
            "they moved"
        );

        // Our own row in either dialect says nothing about THEM.
        let mut ours = message("out-1", "c1", 300, 3);
        ours.direction = MessageDirection::Outbound;
        ours.wire = WireNamespace::CiphMsg;
        store.record_message(ours).unwrap();
        assert_eq!(store.conversation_wire("c1"), WireNamespace::KChat);

        // A handshake row carries no dialect evidence either.
        let mut hs = message("hs-1", "c1", 400, 4);
        hs.kind = StoredKind::Handshake;
        store.record_message(hs).unwrap();
        assert_eq!(store.conversation_wire("c1"), WireNamespace::KChat);

        // A ghosted newest row is a transaction the chain took back.
        store.tombstone_message("in-2").unwrap();
        assert_eq!(store.conversation_wire("c1"), WireNamespace::CiphMsg);
        store.untombstone_message("in-2").unwrap();
        assert_eq!(store.conversation_wire("c1"), WireNamespace::KChat);

        // Another conversation is another counterparty.
        assert_eq!(store.conversation_wire("c2"), WireNamespace::CiphMsg);

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn rehome_message_moves_a_row_and_keeps_its_ghost_flag() {
        let dir = test_dir("rehome");
        let mut store = TransportStore::load(dir.clone()).unwrap();
        store.record_message(message("tx1", "old", 1, 1)).unwrap();
        store.tombstone_message("tx1").unwrap();

        assert!(store.rehome_message("tx1", "new").unwrap());
        assert!(
            !store.rehome_message("tx1", "new").unwrap(),
            "already there"
        );
        assert!(
            !store.rehome_message("nope", "new").unwrap(),
            "unknown txid"
        );

        let reloaded = TransportStore::load(dir.clone()).unwrap();
        assert!(reloaded.messages_for("old").is_empty());
        let moved = &reloaded.messages_for("new")[0];
        assert_eq!(moved.txid, "tx1");
        assert_eq!(moved.envelope[60], 1, "bytes untouched");
        assert!(reloaded.is_message_tombstoned("tx1"), "ghost flag survives");

        let _ = std::fs::remove_dir_all(&dir);
    }

    /// Case A — the founder's device, 2026-09-07: a thread we opened that never
    /// completed (visible) beside the counterparty's own thread that could
    /// read (hidden by Start over). One row, the readable pair, visible, with
    /// every message under it.
    #[test]
    fn merge_folds_our_stuck_request_into_the_thread_that_can_read() {
        let dir = test_dir("merge-a");
        let mut store = TransportStore::load(dir.clone()).unwrap();
        let ours = row(
            "e734",
            ConversationStatus::PendingOutbound,
            true,
            "5f06f494ee33",
            None,
            100,
        );
        let theirs = row(
            "f6ef",
            ConversationStatus::Active,
            false,
            "fff0e2b54564",
            Some("822deb62da52"),
            200,
        );
        store.upsert_conversation(ours).unwrap();
        store.upsert_conversation(theirs).unwrap();
        store.tombstone_conversation("f6ef").unwrap();
        let mut sent = message("out-1", "e734", 300, 1);
        sent.direction = MessageDirection::Outbound;
        store.record_message(sent).unwrap();
        // Our re-handshake (Start over, 09-07): the newest announcement of OUR
        // alias, on a row whose `created` never moved.
        let mut hs = message("hs", "e734", 310, 2);
        hs.kind = StoredKind::Handshake;
        hs.direction = MessageDirection::Outbound;
        store.record_message(hs).unwrap();

        let report = store.merge_duplicate_contacts().unwrap();
        assert_eq!(
            report,
            ContactMergeReport {
                contacts: 1,
                rows_folded: 1,
                messages_rehomed: 2
            }
        );

        let reloaded = TransportStore::load(dir.clone()).unwrap();
        assert!(
            reloaded.conversation("e734").is_none(),
            "the stuck row is gone"
        );
        let kept = reloaded
            .conversation("f6ef")
            .expect("the readable row is kept");
        assert_eq!(kept.status, ConversationStatus::Active);
        assert_eq!(
            kept.my_alias, "5f06f494ee33",
            "the alias we announced LAST — the one a Kasia-class client now listens on"
        );
        assert_eq!(kept.their_alias.as_deref(), Some("822deb62da52"));
        assert_eq!(kept.created_unix_ms, 100, "earliest establishment");
        assert_eq!(kept.last_activity_unix_ms, 200);
        assert!(
            !reloaded.is_conversation_tombstoned("f6ef"),
            "the user could see the other row"
        );
        assert_eq!(
            reloaded.messages_for("f6ef").len(),
            2,
            "every message re-homed"
        );
        assert!(reloaded.superseded_by("f6ef").is_none());
        // Idempotent.
        let mut again = reloaded;
        assert_eq!(
            again.merge_duplicate_contacts().unwrap(),
            ContactMergeReport::default()
        );

        let _ = std::fs::remove_dir_all(&dir);
    }

    /// Case B — their handshake back to a request we opened, folded before the
    /// sender resolved: the invitation folds into OUR row, which activates
    /// with their alias and the slot they sealed to. No accept card survives,
    /// because their handshake already refunded our bond.
    #[test]
    fn merge_activates_our_request_from_their_late_resolved_invitation() {
        let dir = test_dir("merge-b");
        let mut store = TransportStore::load(dir.clone()).unwrap();
        store
            .upsert_conversation(row(
                "ours",
                ConversationStatus::PendingOutbound,
                true,
                "5f06f494ee33",
                None,
                100,
            ))
            .unwrap();
        store
            .upsert_conversation(row(
                "inv",
                ConversationStatus::PendingInbound,
                false,
                "",
                Some("822deb62da52"),
                150,
            ))
            .unwrap();
        let mut hs = message("their-hs", "inv", 150, 1);
        hs.kind = StoredKind::Handshake;
        store.record_message(hs).unwrap();

        let address = row("x", ConversationStatus::Active, true, "", None, 0).contact_address;
        let (host, report) = store
            .merge_contact(&address)
            .unwrap()
            .expect("two rows fold");
        assert_eq!(host, "ours");
        assert_eq!(
            report,
            ContactMergeReport {
                contacts: 1,
                rows_folded: 1,
                messages_rehomed: 1
            }
        );
        let kept = store.conversation("ours").expect("our row is the host");
        assert!(store.conversation("inv").is_none());
        assert_eq!(kept.status, ConversationStatus::Active);
        assert_eq!(kept.my_alias, "5f06f494ee33");
        assert_eq!(kept.their_alias.as_deref(), Some("822deb62da52"));
        assert_eq!(
            (kept.bound_branch, kept.bound_index),
            (KeyBranch::Receive, 3),
            "rebound to the slot they sealed to"
        );
        assert_eq!(store.messages_for("ours").len(), 1);
        assert!(
            store
                .list_conversations()
                .iter()
                .all(|c| c.status != ConversationStatus::PendingInbound),
            "no accept card"
        );

        let _ = std::fs::remove_dir_all(&dir);
    }

    /// Case C — they wiped and re-handshaked with a NEW alias while we held an
    /// Active thread: the new alias replaces the old one in place (Kasia's
    /// own `theirAlias = payload.alias`), and there is still one row.
    #[test]
    fn merge_takes_the_newer_alias_from_a_re_handshake() {
        let dir = test_dir("merge-c");
        let mut store = TransportStore::load(dir.clone()).unwrap();
        store
            .upsert_conversation(row(
                "live",
                ConversationStatus::Active,
                false,
                "fff0e2b54564",
                Some("old0old0old0"),
                100,
            ))
            .unwrap();
        store
            .upsert_conversation(row(
                "inv",
                ConversationStatus::PendingInbound,
                false,
                "",
                Some("new1new1new1"),
                900,
            ))
            .unwrap();
        store.merge_duplicate_contacts().unwrap();
        let kept = store.conversation("live").unwrap();
        assert_eq!(
            kept.their_alias.as_deref(),
            Some("new1new1new1"),
            "the pair they now listen on"
        );
        assert_eq!(kept.status, ConversationStatus::Active);
        assert_eq!(kept.my_alias, "fff0e2b54564");
        assert!(store.conversation("inv").is_none());

        // …but an OLDER invitation (an archive replay) does not overwrite a
        // live alias.
        store
            .upsert_conversation(row(
                "stale",
                ConversationStatus::PendingInbound,
                false,
                "",
                Some("stalestale00"),
                50,
            ))
            .unwrap();
        store.merge_duplicate_contacts().unwrap();
        assert_eq!(
            store.conversation("live").unwrap().their_alias.as_deref(),
            Some("new1new1new1")
        );

        let _ = std::fs::remove_dir_all(&dir);
    }

    /// Case D — two Active threads with one contact (their wipe + our accept
    /// of the fresh invitation, the 2026-08-17 shape): the NEWER pair hosts,
    /// the older thread's messages come along.
    #[test]
    fn merge_keeps_the_newest_active_pair() {
        let dir = test_dir("merge-d");
        let mut store = TransportStore::load(dir.clone()).unwrap();
        store
            .upsert_conversation(row(
                "old",
                ConversationStatus::Active,
                true,
                "aaaaaaaaaaaa",
                Some("111111111111"),
                100,
            ))
            .unwrap();
        store
            .upsert_conversation(row(
                "new",
                ConversationStatus::Active,
                false,
                "bbbbbbbbbbbb",
                Some("222222222222"),
                200,
            ))
            .unwrap();
        store
            .record_message(message("m-old", "old", 120, 1))
            .unwrap();
        store
            .record_message(message("m-new", "new", 220, 2))
            .unwrap();
        let report = store.merge_duplicate_contacts().unwrap();
        assert_eq!(report.messages_rehomed, 1);
        let kept = store.conversation("new").expect("newest pair hosts");
        assert_eq!(
            (kept.my_alias.as_str(), kept.their_alias.as_deref()),
            ("bbbbbbbbbbbb", Some("222222222222"))
        );
        assert_eq!(kept.created_unix_ms, 100);
        assert_eq!(store.messages_for("new").len(), 2);
        assert!(store.conversation("old").is_none());

        let _ = std::fs::remove_dir_all(&dir);
    }

    /// A dismissed invitation stays dismissed (D-142's block): a second
    /// invitation from the same address folds into the hidden one and stays
    /// hidden — the user's exit from a money-spending card is not revocable
    /// by the party they dismissed.
    #[test]
    fn merge_keeps_a_dismissed_invitation_dismissed() {
        let dir = test_dir("merge-block");
        let mut store = TransportStore::load(dir.clone()).unwrap();
        store
            .upsert_conversation(row(
                "first",
                ConversationStatus::PendingInbound,
                false,
                "",
                Some("111111111111"),
                100,
            ))
            .unwrap();
        store.tombstone_conversation("first").unwrap();
        store
            .upsert_conversation(row(
                "second",
                ConversationStatus::PendingInbound,
                false,
                "",
                Some("222222222222"),
                200,
            ))
            .unwrap();
        store.merge_duplicate_contacts().unwrap();
        let live: Vec<ConversationRecord> = store.list_conversations();
        assert_eq!(live.len(), 1);
        let kept = &live[0];
        assert_eq!(
            kept.status,
            ConversationStatus::PendingInbound,
            "still owed an accept, never auto-active"
        );
        assert!(
            store.is_conversation_tombstoned(&kept.conversation_id),
            "blocked stays blocked"
        );

        let _ = std::fs::remove_dir_all(&dir);
    }

    /// Rows with no address (an invitation whose sender is still unknown)
    /// are never folded — there is nothing to key them on.
    #[test]
    fn merge_ignores_address_less_rows_and_singletons() {
        let dir = test_dir("merge-none");
        let mut store = TransportStore::load(dir.clone()).unwrap();
        let mut a = row(
            "a",
            ConversationStatus::PendingInbound,
            false,
            "",
            Some("111111111111"),
            1,
        );
        a.contact_address.clear();
        let mut b = row(
            "b",
            ConversationStatus::PendingInbound,
            false,
            "",
            Some("222222222222"),
            2,
        );
        b.contact_address.clear();
        store.upsert_conversation(a).unwrap();
        store.upsert_conversation(b).unwrap();
        store
            .upsert_conversation(row(
                "solo",
                ConversationStatus::Active,
                true,
                "cccccccccccc",
                Some("333333333333"),
                3,
            ))
            .unwrap();
        assert_eq!(
            store.merge_duplicate_contacts().unwrap(),
            ContactMergeReport::default()
        );
        assert_eq!(store.list_conversations().len(), 3);

        let _ = std::fs::remove_dir_all(&dir);
    }

    /// `consensus-auditor` 2026-09-07 (a): a Start over hid the working thread
    /// (aliases intact) and paid 0.2 KAS to announce a NEW alias on a fresh
    /// request. The readable row hosts, but it carries the alias the user
    /// just announced — not the one nobody listens on any more.
    #[test]
    fn merge_keeps_the_alias_we_announced_last_when_the_older_row_hosts() {
        let dir = test_dir("merge-announce");
        let mut store = TransportStore::load(dir.clone()).unwrap();
        store
            .upsert_conversation(row(
                "old",
                ConversationStatus::Active,
                false,
                "m1m1m1m1m1m1",
                Some("t1t1t1t1t1t1"),
                100,
            ))
            .unwrap();
        store.tombstone_conversation("old").unwrap();
        store
            .upsert_conversation(row(
                "new",
                ConversationStatus::PendingOutbound,
                true,
                "m2m2m2m2m2m2",
                None,
                200,
            ))
            .unwrap();
        let mut ours = message("our-hs", "new", 200, 1);
        ours.kind = StoredKind::Handshake;
        ours.direction = MessageDirection::Outbound;
        store.record_message(ours).unwrap();

        store.merge_duplicate_contacts().unwrap();
        let kept = store.conversation("old").expect("the readable row hosts");
        assert_eq!(kept.my_alias, "m2m2m2m2m2m2", "OUR newest announcement");
        assert_eq!(
            kept.their_alias.as_deref(),
            Some("t1t1t1t1t1t1"),
            "THEIR only announcement"
        );
        assert!(
            !store.is_conversation_tombstoned("old"),
            "un-hidden: the user could see the request"
        );
        assert_eq!(kept.status, ConversationStatus::Active);

        let _ = std::fs::remove_dir_all(&dir);
    }

    /// `consensus-auditor` 2026-09-07 (b): three rows. Lowering `created` on
    /// the first fold must not make the second fold read as "announced
    /// later" — the host keeps the alias that was genuinely announced last.
    #[test]
    fn merge_compares_announcements_against_a_snapshot_not_the_lowered_clock() {
        let dir = test_dir("merge-three");
        let mut store = TransportStore::load(dir.clone()).unwrap();
        store
            .upsert_conversation(row(
                "host",
                ConversationStatus::Active,
                true,
                "mmmmmmmmmmmm",
                Some("t3t3t3t3t3t3"),
                900,
            ))
            .unwrap();
        store
            .upsert_conversation(row(
                "inv1",
                ConversationStatus::PendingInbound,
                false,
                "",
                Some("t1t1t1t1t1t1"),
                100,
            ))
            .unwrap();
        store
            .upsert_conversation(row(
                "inv2",
                ConversationStatus::PendingInbound,
                false,
                "",
                Some("t2t2t2t2t2t2"),
                500,
            ))
            .unwrap();
        store.merge_duplicate_contacts().unwrap();
        let kept = store.conversation("host").unwrap();
        assert_eq!(
            kept.their_alias.as_deref(),
            Some("t3t3t3t3t3t3"),
            "the newest announcement, whatever order the folds ran in"
        );
        assert_eq!(
            kept.created_unix_ms, 100,
            "earliest establishment still wins for the clock"
        );
        assert_eq!(store.list_conversations().len(), 1);

        let _ = std::fs::remove_dir_all(&dir);
    }

    /// `consensus-auditor` 2026-09-07 (c): a dismissed "Unknown sender" card
    /// beside the request we opened and paid for. The block protected a card;
    /// no card survives the fold, so the conversation the user can see stays
    /// visible — and is now Active with the alias that card carried.
    #[test]
    fn merge_does_not_carry_a_dismissed_card_block_onto_our_own_request() {
        let dir = test_dir("merge-nocarry");
        let mut store = TransportStore::load(dir.clone()).unwrap();
        store
            .upsert_conversation(row(
                "ours",
                ConversationStatus::PendingOutbound,
                true,
                "mmmmmmmmmmmm",
                None,
                100,
            ))
            .unwrap();
        store
            .upsert_conversation(row(
                "card",
                ConversationStatus::PendingInbound,
                false,
                "",
                Some("tttttttttttt"),
                150,
            ))
            .unwrap();
        store.tombstone_conversation("card").unwrap();
        store.merge_duplicate_contacts().unwrap();
        let kept = store.conversation("ours").expect("our request hosts");
        assert_eq!(kept.status, ConversationStatus::Active);
        assert_eq!(kept.their_alias.as_deref(), Some("tttttttttttt"));
        assert!(
            !store.is_conversation_tombstoned("ours"),
            "visible: nothing left to block"
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

    /// An acceptance must land on the SAME conversation every process start.
    ///
    /// This selector used to be a bare `.find` over a `HashMap`'s values, whose
    /// iteration order is reseeded per process. With two `PendingOutbound` rows
    /// sharing `my_alias`, the counterparty's acceptance completed whichever row
    /// the map happened to yield first — a coin flip over a spent 0.2 KAS bond,
    /// re-tossed on every launch.
    #[test]
    fn awaiting_response_picks_the_same_row_every_process_start() {
        let dir = test_dir("awaiting-determinism");
        let mut store = TransportStore::load(dir.clone()).unwrap();

        let mut older = conversation("aaa", 10);
        older.status = ConversationStatus::PendingOutbound;
        older.my_alias = "fa6d1afa79e1".to_string();
        older.created_unix_ms = 100;
        let mut newer = conversation("bbb", 20);
        newer.status = ConversationStatus::PendingOutbound;
        newer.my_alias = "fa6d1afa79e1".to_string();
        newer.created_unix_ms = 900;

        // Insert in both orders; the answer must not depend on it.
        store.upsert_conversation(older.clone()).unwrap();
        store.upsert_conversation(newer.clone()).unwrap();
        let first = store
            .conversation_awaiting_response("fa6d1afa79e1")
            .unwrap()
            .conversation_id
            .clone();

        let dir2 = test_dir("awaiting-determinism-2");
        let mut store2 = TransportStore::load(dir2.clone()).unwrap();
        store2.upsert_conversation(newer).unwrap();
        store2.upsert_conversation(older).unwrap();
        let second = store2
            .conversation_awaiting_response("fa6d1afa79e1")
            .unwrap()
            .conversation_id
            .clone();

        assert_eq!(first, second, "insertion order must not decide");
        assert_eq!(first, "aaa", "the older establishment wins");

        let _ = std::fs::remove_dir_all(&dir);
        let _ = std::fs::remove_dir_all(&dir2);
    }

    /// A hidden row must not absorb an acceptance ahead of a live one — the
    /// same rule `conversation_by_alias` already carries.
    #[test]
    fn awaiting_response_prefers_a_live_row_over_a_hidden_one() {
        let dir = test_dir("awaiting-hidden");
        let mut store = TransportStore::load(dir.clone()).unwrap();

        let mut hidden = conversation("aaa", 10);
        hidden.status = ConversationStatus::PendingOutbound;
        hidden.my_alias = "fa6d1afa79e1".to_string();
        hidden.created_unix_ms = 100; // older, so it would win on age alone
        let mut live = conversation("bbb", 20);
        live.status = ConversationStatus::PendingOutbound;
        live.my_alias = "fa6d1afa79e1".to_string();
        live.created_unix_ms = 900;

        store.upsert_conversation(hidden).unwrap();
        store.upsert_conversation(live).unwrap();
        store.tombstone_conversation("aaa").unwrap();

        assert_eq!(
            store
                .conversation_awaiting_response("fa6d1afa79e1")
                .unwrap()
                .conversation_id,
            "bbb",
            "live beats hidden, even though hidden is older"
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
