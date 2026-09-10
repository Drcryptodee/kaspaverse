//! Blocked contacts — the one refusal a user can make about a person (D-308).
//!
//! **Keyed on the ADDRESS, like [`crate::ContactNames`], never the
//! conversation id.** A block is about a person; the conversation is only the
//! current thread with them, and the block's first act is to destroy that
//! thread. What survives is the address, because the address is the identity
//! every lane already routes on (§0.7) and the only one a stranger cannot
//! change for the price of a fresh alias.
//!
//! **It sits in FRONT of the revival path (D-307), and that is why it
//! exists.** Once an unroutable message that opens under one of our keys can
//! mint the conversation it belongs to, erasing stops being a way to stop
//! hearing from someone — the next message rebuilds the thread. So a block
//! survives a wipe on purpose: `transport_wipe_all` clears the names and the
//! backup record and leaves this file standing, or the wipe would hand the
//! user's decision back to the people they refused.
//!
//! **A reset to strangers, not a wall.** The founder's own design: the alias
//! memory is cut, the thread is gone, and the way back in is the one every
//! stranger uses — a handshake, which costs them the bond and puts the choice
//! in the user's hands. So a blocked address's *handshake* still surfaces as a
//! request (marked), and accepting it lifts the block; only its *comms* are
//! refused, before they cost a decrypt and before they mint anything.
//!
//! **Never on the wire.** Telling someone they are blocked is a feature nobody
//! asked for, and on a public ledger it would be permanent. This file is not
//! stashed, not backed up, and not in any DTO beyond a bool.
//!
//! **Durable write** (`write_json_durable`), unlike `contact.names`: a torn
//! name costs a label; a torn block list reads as *nobody is blocked*, which
//! silently un-does a refusal the user made on purpose.

use std::collections::HashMap;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

use crate::error::Result;
use crate::history_fill::write_json_durable;

const BLOCK_LIST_FILE: &str = "block.list";

/// One refused address.
///
/// **No alias is kept, deliberately.** A first cut remembered the alias they
/// last wrote under so the comm lane could refuse their traffic before the
/// key-window decrypt; the `consensus-auditor` priced it: the alias on a
/// request is the *sender's own* choice of twelve hex characters, so a
/// stranger who handshakes under a real contact's alias and is blocked from
/// the card would have that contact's revival refused pre-decrypt, silently.
/// The address — the node's own sender resolution — is the only key, and the
/// revival budget is the bound on what a blocked spammer can cost.
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq, Eq)]
pub struct BlockedContact {
    /// When the user blocked them (local clock). Ordering and display only.
    pub since_unix_ms: u64,
}

/// Address → the refusal.
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq, Eq)]
pub struct BlockList {
    #[serde(default)]
    pub blocked: HashMap<String, BlockedContact>,
}

impl BlockList {
    /// Infallible: an absent file is "nobody is blocked". A PRESENT file that
    /// does not parse also reads that way, and says so in the log — this is
    /// the one side file where reading as empty un-does a decision rather
    /// than costing a label, which is why [`Self::save`] is the durable write.
    pub fn load(dir: &Path) -> Self {
        match std::fs::read(dir.join(BLOCK_LIST_FILE)) {
            Err(_) => Self::default(),
            Ok(bytes) => serde_json::from_slice(&bytes).unwrap_or_else(|e| {
                log::warn!("block-list: unreadable ({e}) — reading as empty until it is rewritten");
                Self::default()
            }),
        }
    }

    /// **Absent and UNREADABLE, told apart** — `None` for either, for a
    /// caller that wants to know rather than assume.
    pub fn read(dir: &Path) -> Option<Self> {
        let bytes = std::fs::read(dir.join(BLOCK_LIST_FILE)).ok()?;
        serde_json::from_slice(&bytes).ok()
    }

    /// Temp file, fsync, rename: a refusal must not be the one write left to
    /// chance.
    pub fn save(&self, dir: &Path) -> Result<()> {
        write_json_durable(&dir.join(BLOCK_LIST_FILE), self)
    }

    pub fn path(dir: &Path) -> PathBuf {
        dir.join(BLOCK_LIST_FILE)
    }

    pub fn is_blocked(&self, address: &str) -> bool {
        !address.is_empty() && self.blocked.contains_key(address)
    }

    /// Block an address. Re-blocking keeps the original `since`. Returns
    /// whether the entry is new.
    pub fn block(&mut self, address: &str, now_unix_ms: u64) -> bool {
        if address.is_empty() {
            return false;
        }
        if self.blocked.contains_key(address) {
            return false;
        }
        self.blocked.insert(
            address.to_string(),
            BlockedContact {
                since_unix_ms: now_unix_ms,
            },
        );
        true
    }

    /// Lift a block. Returns whether there was one.
    pub fn unblock(&mut self, address: &str) -> bool {
        self.blocked.remove(address).is_some()
    }

    pub fn len(&self) -> usize {
        self.blocked.len()
    }

    pub fn is_empty(&self) -> bool {
        self.blocked.is_empty()
    }

    /// Newest block first; ties on the address so the list is stable.
    pub fn entries(&self) -> Vec<(&str, &BlockedContact)> {
        let mut rows: Vec<(&str, &BlockedContact)> = self
            .blocked
            .iter()
            .map(|(address, entry)| (address.as_str(), entry))
            .collect();
        rows.sort_by(|a, b| b.1.since_unix_ms.cmp(&a.1.since_unix_ms).then(a.0.cmp(b.0)));
        rows
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn dir(tag: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("kv-block-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn a_block_is_keyed_on_the_address() {
        let mut list = BlockList::default();
        assert!(list.block("kaspa:a", 100));
        assert!(list.is_blocked("kaspa:a"));
        assert!(!list.is_blocked("kaspa:b"));
        assert!(!list.is_blocked(""), "an empty address blocks nobody");

        // Re-blocking is idempotent on the entry and keeps its date.
        assert!(!list.block("kaspa:a", 200));
        assert_eq!(list.blocked["kaspa:a"].since_unix_ms, 100);

        assert!(list.unblock("kaspa:a"));
        assert!(!list.unblock("kaspa:a"));
        assert!(!list.is_blocked("kaspa:a"));
        assert!(list.is_empty());
    }

    #[test]
    fn an_empty_address_is_never_blocked() {
        let mut list = BlockList::default();
        assert!(!list.block("", 1));
        assert!(list.is_empty());
    }

    #[test]
    fn entries_come_newest_first() {
        let mut list = BlockList::default();
        list.block("kaspa:b", 10);
        list.block("kaspa:a", 30);
        list.block("kaspa:c", 30);
        let order: Vec<&str> = list.entries().into_iter().map(|(a, _)| a).collect();
        assert_eq!(order, ["kaspa:a", "kaspa:c", "kaspa:b"]);
    }

    #[test]
    fn the_list_round_trips_and_an_absent_or_corrupt_file_reads_as_empty() {
        let d = dir("roundtrip");
        assert_eq!(BlockList::load(&d), BlockList::default());
        assert!(BlockList::read(&d).is_none(), "absent");

        std::fs::write(BlockList::path(&d), b"{ not json").unwrap();
        assert_eq!(
            BlockList::load(&d),
            BlockList::default(),
            "corrupt reads as empty"
        );
        assert!(
            BlockList::read(&d).is_none(),
            "corrupt is told apart by `read`"
        );

        let mut list = BlockList::default();
        list.block("kaspa:a", 7);
        list.save(&d).unwrap();
        assert_eq!(BlockList::load(&d), list);
        assert_eq!(BlockList::read(&d), Some(list));
        // The durable write leaves no temp file behind.
        assert!(!BlockList::path(&d).with_extension("tmp").exists());
        let _ = std::fs::remove_dir_all(&d);
    }

    /// An entry written by the first cut carried an alias; it still loads,
    /// and the alias is simply ignored (serde drops unknown fields).
    #[test]
    fn an_entry_written_with_an_alias_still_loads() {
        let d = dir("old-alias");
        std::fs::write(
            BlockList::path(&d),
            br#"{"blocked":{"kaspa:a":{"alias":"822deb62da52","since_unix_ms":5}}}"#,
        )
        .unwrap();
        let list = BlockList::load(&d);
        assert!(list.is_blocked("kaspa:a"));
        assert_eq!(list.blocked["kaspa:a"].since_unix_ms, 5);
        let _ = std::fs::remove_dir_all(&d);
    }
}
