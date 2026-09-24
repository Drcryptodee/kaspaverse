//! Address decoding may refuse; it may never panic. Both decode paths, pinned.
//!
//! At rusty-kaspa `cfafeb4` (v2.0.1) an `Address` with a valid checksum could panic on
//! decode at two sites: `Address::new`'s `assert_eq!(payload.len(), …)`
//! (`crypto/addresses/src/lib.rs:232`) on a wrong-length payload, and `payload_u8[0]`
//! (`bech32.rs:143`) on a string with no payload byte. Two of our paths reached them:
//!
//! - **the string path** — `Address::try_from(&str)`, fed by pasted and QR-scanned
//!   destinations and by stored contact rows (the bridge's `validate_mainnet_address`,
//!   pinned separately in `rust/bridge/src/api/send.rs`);
//! - **the Borsh path** — node-supplied. Our wRPC client speaks Borsh, so every
//!   address-bearing response (`get_utxo_return_address`, UTXO entries) is decoded by
//!   `BorshDeserialize for Address`, which at `cfafeb4` called `Self::new`
//!   (`lib.rs:270`): a hostile node could panic the task that decoded it.
//!
//! v2.1.0 (`01b532e`, #1138) decodes both through `split_first` and `Address::try_new`
//! (`bech32.rs:144-145`, `lib.rs:282-289`) and returns an error. Every case below was run
//! against both pins in a scratch crate before it was written here: PANIC at `cfafeb4`,
//! the asserted `Err` at `01b532e`. The variants are asserted, not just `is_err()`, so
//! each case provably got past the checksum to the site that used to panic (D-324).

use kaspa_addresses::{Address, AddressError};
use std::panic::catch_unwind;

/// A real mainnet address (the bridge tests' `MAINNET`), version `PubKey`, 32-byte payload.
const MAINNET: &str = "kaspa:qz7ulu4c25dh7fzec9zjyrmlhnkzrg4wmf89q7gzr3gfrsj3uz6xjellj43pf";
const LENGTHS: [usize; 5] = [0, 1, 31, 33, 64];

fn forged(len: usize) -> Address {
    let mut a = Address::try_from(MAINNET).unwrap();
    a.payload.clear();
    a.payload.extend_from_slice(&vec![7u8; len]);
    a
}

#[test]
fn the_string_path_refuses_a_wrong_length_payload() {
    for len in LENGTHS {
        let s = forged(len).to_string();
        let outcome = catch_unwind(|| Address::try_from(s.as_str()));
        assert!(
            matches!(
                outcome,
                Ok(Err(AddressError::InvalidPayloadLength { expected: 32, actual })) if actual == len
            ),
            "a {len}-byte payload must be InvalidPayloadLength, not a panic or an address: {outcome:?}"
        );
    }
}

#[test]
fn the_string_path_refuses_a_string_with_no_payload_byte() {
    // Checksum-valid with 0 and 1 base32 characters before the checksum.
    for s in ["kaspa:3xjng3c9", "kaspa:qkgdh0z5s"] {
        let outcome = catch_unwind(|| Address::try_from(s));
        assert!(
            matches!(outcome, Ok(Err(AddressError::BadPayload))),
            "{s} must be BadPayload, not a panic or an address: {outcome:?}"
        );
    }
}

#[test]
fn the_borsh_path_refuses_what_a_node_could_send() {
    for len in LENGTHS {
        let bytes = borsh::to_vec(&forged(len)).unwrap();
        let outcome = catch_unwind(|| borsh::from_slice::<Address>(&bytes));
        match outcome {
            Ok(Err(e)) => assert!(
                e.to_string()
                    .contains(&format!("expected 32 bytes, got {len}")),
                "a {len}-byte payload must be refused for its length: {e}"
            ),
            Ok(Ok(a)) => panic!("a {len}-byte payload decoded as {a}"),
            Err(_) => panic!("a {len}-byte payload PANICKED the decoder (the v2.0.1 hole)"),
        }
    }
}

#[test]
fn a_well_formed_address_still_round_trips_both_ways() {
    let a = Address::try_from(MAINNET).unwrap();
    assert_eq!(a.to_string(), MAINNET);
    let back: Address = borsh::from_slice(&borsh::to_vec(&a).unwrap()).unwrap();
    assert_eq!(back, a);
}
