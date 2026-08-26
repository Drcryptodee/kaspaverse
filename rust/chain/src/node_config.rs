//! The user's chosen node — the INV-8 escape hatch, persisted.
//!
//! **Why this is not the endpoint cache.** [`DagMonitor::set_endpoint_cache`]
//! already remembers the last endpoint that worked, and that file looks almost
//! identical to this one: an app-private path holding one public `wss://` URL.
//! They are different things and collapsing them would be a sovereignty bug.
//!
//! | | `endpoint.cache` | `node.config` (here) |
//! |:--|:--|:--|
//! | whose choice | the resolver's, remembered | **the user's, declared** |
//! | why it exists | skip an HTTP round trip on reconnect | INV-8: name your own node |
//! | when it changes | every successful connect | only when the user says so |
//! | when it is wrong | one slow reconnect | the wallet talks to a stranger |
//! | may the app overwrite it | yes, constantly | **never** |
//!
//! So a pinned node is never silently replaced by the cache, and clearing the
//! pin never wipes the cache: the two files do not read or write each other.
//!
//! Persistence seeds `history_fill`'s idiom rather than inventing a second one
//! — same JSON encoding, same infallible-load contract, same cheap write. An
//! absent or corrupt file reads as [`NodeConfig::default`] (resolver mode),
//! which is the honest answer and the safe one: a wallet whose config file
//! got truncated falls back to public node discovery and keeps working,
//! rather than refusing to start or dialling a half-parsed URL.

use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

use crate::error::Result;
use crate::history_fill::write_json_durable;
use crate::link::validate_node_url;

const NODE_CONFIG_FILE: &str = "node.config";

/// The user's node choice. Default = resolver mode (today's behaviour).
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq, Eq)]
pub struct NodeConfig {
    /// `None` — discover public nodes via the PNN resolver race (the default).
    /// `Some(url)` — **this node and only this node**; no resolver, no race,
    /// no demotion, and no silent fallback when it dies (D-187).
    #[serde(default)]
    pub url: Option<String>,
}

impl NodeConfig {
    /// Infallible: an absent or corrupt file reads as resolver mode.
    pub fn load(dir: &Path) -> Self {
        Self::load_reporting(dir).0
    }

    /// `(config, dropped)` — `dropped` is true when a pin **was** stored and
    /// this load refused it.
    ///
    /// The bit exists because the degradation is otherwise indistinguishable
    /// from a user who never pinned anything, and D-187 Decision 2 says the
    /// failure must have a name (wallet-security audit). A pin that is *down*
    /// was already nameable; a pin that was *lost* was not, and silently
    /// reverting to public discovery is the exact outcome that ruling forbids.
    pub fn load_reporting(dir: &Path) -> (Self, bool) {
        // Deliberately NOT `history_fill::read_json`: it collapses *absent*
        // and *unparseable* into `Default`, and those are the two states this
        // function exists to tell apart. An empty or truncated file is exactly
        // the ENOSPC / power-loss residue `write_json_durable` was adopted
        // against (consensus audit) — durability lowers its probability but
        // does not make it nameable, and a pin lost that way must not read as
        // a pin never set.
        let Ok(bytes) = std::fs::read(dir.join(NODE_CONFIG_FILE)) else {
            return (Self { url: None }, false); // absent = never pinned
        };
        let Ok(config) = serde_json::from_slice::<Self>(&bytes) else {
            log::warn!(
                "node-config: the stored pin file is unreadable ({} bytes) — using node discovery",
                bytes.len()
            );
            return (Self { url: None }, true);
        };
        // A hand-edited or partially-written file must never redirect the
        // wallet somewhere undialable — re-validate on the way OUT too, and
        // degrade to resolver mode rather than carrying garbage to the dialer.
        match config.url.as_deref().map(validate_node_url) {
            None => (Self { url: None }, false),
            Some(Ok(url)) => (Self { url: Some(url) }, false),
            Some(Err(e)) => {
                log::warn!("node-config: stored node URL rejected ({e}) — using node discovery");
                (Self { url: None }, true)
            }
        }
    }

    /// Persist the choice. The URL is validated here, so a rejected save
    /// leaves the previous config untouched (the `FillConfig::save` contract).
    ///
    /// **Durable**, unlike its `FillConfig` sibling (wallet-security audit).
    /// The cheap `write_json` is documented for *"state whose loss costs a
    /// redundant network round trip and nothing else"*, and that contract is
    /// false for this file: `std::fs::write` truncates before it writes, so an
    /// ENOSPC or a power loss leaves either an empty file — which reads as
    /// discovery, silently reverting the wallet to public nodes — or a
    /// TRUNCATED-BUT-VALID URL like `wss://my-node.exa`, which passes every
    /// check and pins the wallet to a host that does not exist, forever,
    /// because a pinned node by design never falls back. Losing this file
    /// un-does a user's declaration, which is precisely the bar
    /// [`write_json_durable`] was written for.
    pub fn save(&self, dir: &Path) -> Result<()> {
        let config = Self {
            url: self.url.as_deref().map(validate_node_url).transpose()?,
        };
        write_json_durable(&dir.join(NODE_CONFIG_FILE), &config)
    }

    pub fn path(dir: &Path) -> PathBuf {
        dir.join(NODE_CONFIG_FILE)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tmp(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("kv-node-config-{name}"));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn absent_config_reads_as_node_discovery() {
        let dir = tmp("absent");
        assert_eq!(NodeConfig::load(&dir), NodeConfig { url: None });
    }

    #[test]
    fn a_pinned_url_survives_the_write_and_read_back() {
        let dir = tmp("roundtrip");
        let pinned = NodeConfig {
            url: Some("wss://my-node.example/kaspa/mainnet/wrpc/borsh".into()),
        };
        pinned.save(&dir).unwrap();
        assert_eq!(NodeConfig::load(&dir), pinned);
        // Clearing the pin is a save like any other, and returns the wallet
        // to discovery rather than leaving the last URL behind.
        NodeConfig { url: None }.save(&dir).unwrap();
        assert_eq!(NodeConfig::load(&dir), NodeConfig { url: None });
    }

    #[test]
    fn a_rejected_url_leaves_the_previous_config_untouched() {
        let dir = tmp("reject");
        let good = NodeConfig {
            url: Some("wss://good.example/borsh".into()),
        };
        good.save(&dir).unwrap();
        for bad in [
            "https://good.example",      // REST port — the likely honest typo
            "wss://good.example/ borsh", // whitespace (ledger-row forgery)
            "wss://good.example/\tforged",
            // Credentials: logged IN FULL at the bind and at the run-ended
            // line, used as a health-ledger key, and carried across the FFI
            // into an unzeroable Dart String (INV-3, ffi-leak audit).
            "wss://user:hunter2@good.example/borsh",
            "",
        ] {
            assert!(
                NodeConfig {
                    url: Some(bad.into())
                }
                .save(&dir)
                .is_err(),
                "{bad:?} must be refused"
            );
        }
        assert_eq!(NodeConfig::load(&dir), good, "the good pin survived");
    }

    #[test]
    fn a_corrupt_file_degrades_to_discovery_never_to_a_bad_dial() {
        let dir = tmp("corrupt");
        std::fs::write(NodeConfig::path(&dir), b"{not json").unwrap();
        assert_eq!(NodeConfig::load(&dir), NodeConfig { url: None });
        // Well-formed JSON carrying an undialable URL is the nastier case:
        // it parses, so only the load-side re-validation catches it.
        std::fs::write(
            NodeConfig::path(&dir),
            br#"{"url":"http://evil.example/rest"}"#,
        )
        .unwrap();
        assert_eq!(NodeConfig::load(&dir), NodeConfig { url: None });
    }

    #[test]
    fn a_dropped_pin_is_reported_not_just_logged() {
        let dir = tmp("dropped");
        // Never pinned → not a drop. This is the control: the bit must
        // distinguish "lost your pin" from "never had one", which is the
        // whole reason it exists.
        assert_eq!(
            NodeConfig::load_reporting(&dir),
            (NodeConfig { url: None }, false)
        );

        // A stored pin that no longer validates → discovery, AND said so.
        std::fs::write(
            NodeConfig::path(&dir),
            br#"{"url":"http://evil.example/rest"}"#,
        )
        .unwrap();
        assert_eq!(
            NodeConfig::load_reporting(&dir),
            (NodeConfig { url: None }, true)
        );

        // An EMPTY file is a drop, not a fresh wallet: it is the ENOSPC /
        // power-loss residue, and it is the whole reason the write is durable.
        std::fs::write(NodeConfig::path(&dir), b"").unwrap();
        assert_eq!(
            NodeConfig::load_reporting(&dir),
            (NodeConfig { url: None }, true)
        );
        // Truncated mid-JSON: same answer.
        std::fs::write(NodeConfig::path(&dir), br#"{"url":"wss://my-no"#).unwrap();
        assert_eq!(
            NodeConfig::load_reporting(&dir),
            (NodeConfig { url: None }, true)
        );
        // An ABSENT file is still not a drop — the control that keeps the bit
        // meaning "you lost a pin" rather than "there is no pin".
        std::fs::remove_file(NodeConfig::path(&dir)).unwrap();
        assert_eq!(
            NodeConfig::load_reporting(&dir),
            (NodeConfig { url: None }, false)
        );
    }

    #[test]
    fn the_pin_and_the_endpoint_cache_are_different_files() {
        // The sovereignty pin must never be the file the connect path
        // overwrites on every successful dial (module docs).
        assert_ne!(
            NodeConfig::path(Path::new("/v")),
            Path::new("/v/endpoint.cache")
        );
    }
}
