//! Parity-fixture harness for the `kv:1:` game frames (P2.4 §0.5) — the
//! committed, language-agnostic proof that `frames::build_*`/`parse` match the
//! frozen schema. `build[]` pins emission byte-for-byte (the readable line is
//! GENERATED from the fields — it can't lie about the card); `parse[]` pins the
//! classification + the card fields, including that a tampered readable line is
//! ignored in favour of the JSON.
//!
//! Mirrors `transport_crypto_v1.json` + `transport_parity.rs` — the P3
//! contract-vectors seed pattern (§0.10). Vectors: `tests/vectors/frames_v1.json`.

use kaspaverse_core::frames::{build_accept, build_challenge, build_taunt, parse, Parsed};

const VECTORS: &str = include_str!("vectors/frames_v1.json");

fn vectors() -> serde_json::Value {
    serde_json::from_str(VECTORS).expect("fixture JSON parses")
}

fn opt<'a>(v: &'a serde_json::Value, key: &str) -> Option<&'a str> {
    v.get(key).and_then(|x| x.as_str())
}

/// `build_*` emission is byte-identical to the committed wire (determinism +
/// line-generated-from-fields, law P4).
#[test]
fn every_build_vector_matches_bytes() {
    let fixture = vectors();
    let build = fixture["build"].as_array().expect("build section");
    assert!(
        build.len() >= 5,
        "fixture shrank: {} build vectors",
        build.len()
    );
    for v in build {
        let name = v["name"].as_str().unwrap();
        let kind = v["kind"].as_str().unwrap();
        let expected = v["wire"].as_str().unwrap();
        let built = match kind {
            "challenge" => build_challenge(
                opt(v, "game").unwrap(),
                opt(v, "stake"),
                opt(v, "id").unwrap(),
            ),
            "accept" => build_accept(opt(v, "game").unwrap(), opt(v, "ref").unwrap()),
            "taunt" => build_taunt(opt(v, "text").unwrap()),
            other => panic!("{name}: build vector has no builder for kind {other}"),
        }
        .unwrap_or_else(|e| panic!("{name}: build failed: {e}"));
        assert_eq!(built, expected, "{name}: emission drift");
    }
}

/// `parse` classifies every vector and takes the card fields from the JSON.
#[test]
fn every_parse_vector_classifies() {
    let fixture = vectors();
    let parse_vectors = fixture["parse"].as_array().expect("parse section");
    assert!(
        parse_vectors.len() >= 9,
        "fixture shrank: {} parse vectors",
        parse_vectors.len()
    );
    let (mut frames, mut plains, mut unknowns) = (0, 0, 0);
    for v in parse_vectors {
        let name = v["name"].as_str().unwrap();
        let plaintext = v["plaintext"].as_str().unwrap();
        match (v["expect"].as_str().unwrap(), parse(plaintext)) {
            ("plain", Parsed::Plain(text)) => {
                assert_eq!(text, plaintext, "{name}: plain text mismatch");
                plains += 1;
            }
            ("unknown", Parsed::Unknown { line }) => {
                assert_eq!(line, opt(v, "line").unwrap(), "{name}: unknown line");
                unknowns += 1;
            }
            ("frame", Parsed::Frame(f)) => {
                assert_eq!(
                    f.kind.as_token(),
                    v["kind"].as_str().unwrap(),
                    "{name}: kind"
                );
                assert_eq!(f.game.as_deref(), opt(v, "game"), "{name}: game");
                assert_eq!(f.stake.as_deref(), opt(v, "stake"), "{name}: stake");
                assert_eq!(f.id.as_deref(), opt(v, "id"), "{name}: id");
                assert_eq!(f.ref_id.as_deref(), opt(v, "ref"), "{name}: ref");
                assert_eq!(f.detail.as_deref(), opt(v, "detail"), "{name}: detail");
                frames += 1;
            }
            (expect, got) => panic!("{name}: expected {expect}, got {got:?}"),
        }
    }
    // The suite must actually exercise each branch, not just tolerate it.
    assert!(
        frames >= 5 && plains >= 1 && unknowns >= 2,
        "coverage: {frames}/{plains}/{unknowns}"
    );
}
