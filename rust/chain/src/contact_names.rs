//! Local contact names — the one piece of a conversation the user writes.
//!
//! **Keyed on the ADDRESS, never the conversation id.** A name belongs to a
//! person, and a conversation is only the current thread with them: ids are
//! minted fresh on a re-handshake and can change across a restore, while the
//! address is the identity the whole transport lane already routes on (§0.7).
//! Keying on the id would silently lose every name the first time a
//! conversation was rebuilt.
//!
//! **serde JSON, not a borsh field on `ConversationRecord`.** The conversation
//! log's `replay()` stops at the first undecodable frame, so appending a field
//! would replay an existing device's whole store to zero rows (D-143). This is
//! the same lane `FillCursors` and `StashState` use, for the same reason.
//!
//! **Device-local by construction.** Nothing here is ever sealed onto the wire
//! or into a backup: a name is frequently a real person's, and an immutable
//! public ledger is a poor place for one even encrypted. Whether that changes
//! is a founder call, not a code one.

use std::collections::HashMap;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

use crate::error::Result;
use crate::history_fill::{read_json, write_json};

/// Longest name we store. Long enough for any real label, short enough that a
/// pasted blob cannot wreck a list row or a thread header — and the cap is
/// enforced at the WRITE, so no reader has to defend against it.
pub const MAX_CONTACT_NAME: usize = 40;

const NAMES_FILE: &str = "contact.names";

/// Address → the name the user gave it.
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq, Eq)]
pub struct ContactNames {
    #[serde(default)]
    pub names: HashMap<String, String>,
}

impl ContactNames {
    /// Infallible: an absent or corrupt file reads as "no names", which costs
    /// the user labels and never a conversation.
    pub fn load(dir: &Path) -> Self {
        read_json(&dir.join(NAMES_FILE))
    }

    pub fn save(&self, dir: &Path) -> Result<()> {
        write_json(&dir.join(NAMES_FILE), self)
    }

    pub fn path(dir: &Path) -> PathBuf {
        dir.join(NAMES_FILE)
    }

    pub fn get(&self, address: &str) -> Option<&str> {
        self.names.get(address).map(String::as_str)
    }

    /// Set or clear a name. An empty (or whitespace-only) name REMOVES the
    /// entry rather than storing a blank, so clearing a name restores the
    /// address rather than showing an empty row.
    ///
    /// Returns the stored name, or `None` when it was cleared.
    pub fn set(&mut self, address: &str, name: &str) -> Option<String> {
        let cleaned = sanitize_name(name);
        if cleaned.is_empty() {
            self.names.remove(address);
            return None;
        }
        self.names.insert(address.to_string(), cleaned.clone());
        Some(cleaned)
    }
}

/// Trim, collapse whitespace, drop control characters, and bound the length.
///
/// The user typed this, so it is not foreign text — but it is still going into
/// a list row, a thread header and (one day) a log line, and a name containing
/// a newline would forge structure into any of them. Cleaning at the write
/// means every reader gets something already safe to render.
pub fn sanitize_name(name: &str) -> String {
    let mut out = String::with_capacity(name.len().min(MAX_CONTACT_NAME));
    let mut last_was_space = true; // leading whitespace never survives
    for ch in name.chars() {
        // Whitespace is tested BEFORE control, because a newline is both — and
        // dropping it outright would fuse "Alice\nBob" into one word rather
        // than separating it. Only non-whitespace control characters vanish.
        if ch.is_whitespace() {
            if !last_was_space {
                out.push(' ');
                last_was_space = true;
            }
            continue;
        }
        if ch.is_control() || is_deceptive_format(ch) {
            continue;
        }
        // Count CHARACTERS, not bytes: truncating a multi-byte character
        // mid-sequence would store invalid text.
        if out.chars().count() >= MAX_CONTACT_NAME {
            break;
        }
        out.push(ch);
        last_was_space = false;
    }
    out.trim_end().to_string()
}

/// Characters that carry no glyph but change how surrounding text READS —
/// bidi overrides, zero-width joiners, the BOM.
///
/// `char::is_control` is Unicode category Cc only and misses all of them.
/// Deliberately duplicated from the attachment parser rather than shared: this
/// crate has no `kaspaverse-core` dependency by design (see the module docs on
/// `transport_store`), and a six-line table is a smaller price than a crate
/// edge. If a third copy ever appears, that is the signal to move it.
fn is_deceptive_format(ch: char) -> bool {
    matches!(ch,
        '\u{00AD}'
        | '\u{200B}'..='\u{200F}'
        | '\u{202A}'..='\u{202E}'
        | '\u{2060}'..='\u{2064}'
        | '\u{2066}'..='\u{2069}'
        | '\u{FEFF}'
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    fn dir(tag: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("kv-names-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn names_round_trip_and_survive_a_missing_or_corrupt_file() {
        let d = dir("roundtrip");
        assert_eq!(ContactNames::load(&d), ContactNames::default());

        std::fs::write(ContactNames::path(&d), b"{ not json").unwrap();
        assert_eq!(ContactNames::load(&d), ContactNames::default(), "corrupt");

        let mut names = ContactNames::default();
        names.set("kaspa:a", "Alice");
        names.save(&d).unwrap();
        assert_eq!(ContactNames::load(&d).get("kaspa:a"), Some("Alice"));

        let _ = std::fs::remove_dir_all(&d);
    }

    /// Clearing a name must restore the address, not leave a blank row.
    #[test]
    fn an_empty_name_clears_rather_than_storing_a_blank() {
        let mut names = ContactNames::default();
        names.set("kaspa:a", "Alice");
        assert_eq!(names.set("kaspa:a", "   "), None);
        assert_eq!(names.get("kaspa:a"), None);
        assert!(names.names.is_empty(), "cleared, not blanked");
    }

    /// The user typed it, so it is not hostile — but it still lands in a list
    /// row, a header and possibly a log, and a newline forges structure in all
    /// three. Cleaning at the write means no reader has to defend.
    #[test]
    fn a_name_cannot_carry_structure_or_unbounded_length() {
        assert_eq!(sanitize_name("  Alice  "), "Alice");
        assert_eq!(sanitize_name("Alice\nBob"), "Alice Bob");
        assert_eq!(sanitize_name("Alice\u{0}\u{1}Bob"), "AliceBob");
        // Bidi/zero-width characters are invisible but reorder what a row
        // reads as — a name is a display string, so they go too.
        assert_eq!(sanitize_name("Ali\u{202E}ce"), "Alice");
        assert_eq!(sanitize_name("A\u{200B}B\u{FEFF}"), "AB");
        assert_eq!(sanitize_name("A   B"), "A B", "runs collapse");

        let long = "x".repeat(MAX_CONTACT_NAME + 50);
        assert_eq!(sanitize_name(&long).chars().count(), MAX_CONTACT_NAME);

        // Character-counted, so a multi-byte name is never cut mid-sequence.
        let emoji = "🙂".repeat(MAX_CONTACT_NAME + 10);
        let cut = sanitize_name(&emoji);
        assert_eq!(cut.chars().count(), MAX_CONTACT_NAME);
        assert!(std::str::from_utf8(cut.as_bytes()).is_ok());
    }
}
