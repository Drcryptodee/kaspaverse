//! The static P2SH sigop budget, and why duel_ad's mux must be lowered a
//! particular way.
//!
//! **This tests a CONSTRAINT, not shipped code.** The mux does not exist yet — P3.1
//! builds it. The rule it encodes was measured 2026-08-25, before P3.1, precisely so
//! the constraint is written down before anything is built against it.
//!
//! `MAX_STANDARD_P2SH_SIG_OPS = 15` (`mining/src/mempool/check_transaction_standard.rs:19`
//! @ `cfafeb4`) is enforced by `post_toccata_p2sh_sig_scanner`, which is a **purely
//! static linear walk** over the revealed redeem script: it counts every
//! `OpCheckSig`/`OpCheckSigVerify`/`OpCheckSigECDSA`/`OpCheckSigFromStack`/
//! `OpCheckSigFromStackECDSA` it passes, **including opcodes in mutually exclusive
//! branches that can never both execute**, and charges 20 for a multisig whose count it
//! cannot read. It is not a runtime count.
//!
//! That distinction matters because `covenant_engine_architecture.md:601-602` argued the
//! cap was "untouched at one sigop per row" — a RUNTIME count, which is not the quantity
//! this rule measures.
//!
//! **Why it is dangerous rather than merely wrong:** this is a MEMPOOL RELAY rule, not a
//! consensus rule. A mux over the cap is consensus-VALID and UNBROADCASTABLE. So the
//! failure mode is a covenant that funds correctly, plays correctly, and then cannot be
//! exited — INV-6 dying at the worst possible moment, discovered by the victim.
//!
//! Measured result (this file, run against the pinned scanner):
//!   naive lowering  = 16 sigops over a cap of 15 -> WOULD NOT RELAY, by exactly one
//!   careful lowering =  1 sigop                  -> relays, and is 7 bytes SMALLER
//! There is no tradeoff here. The careful lowering wins on both axes.

use kaspa_txscript::opcodes::codes::*;
use kaspa_txscript::script_builder::ScriptBuilder;
use kaspa_txscript::{pay_to_script_hash_script, post_toccata_p2sh_sig_scanner, EngineFlags};

/// Toccata is LIVE on mainnet. `EngineFlags::default()` is `covenants_enabled: false`
/// (lib.rs:133, carrying its own `TODO(post-toccata): change default values`), and
/// `ScriptBuilder::new()` is `with_flags(Default::default())` - so a builder made the
/// obvious way applies PRE-Toccata limits and refuses a 601-byte redeem script with
/// `ElementExceedsMaxSize(601, 520)`. Found here by accident on the first run.
fn covenant_builder() -> ScriptBuilder {
    ScriptBuilder::with_flags(EngineFlags {
        covenants_enabled: true,
        ..Default::default()
    })
}

/// duel_ad's SIGNED entrypoints (STATES.md). Reveals are signature-free
/// (row-9 ruling), dead_man_settle is a crank, genesis is not a spend of
/// this script. Each authenticates actor against session_pk OR payout_pk.
const SIGNED_ROWS: usize = 8;

fn pk(byte: u8) -> [u8; 32] {
    [byte; 32]
}

/// NAIVE lowering: each signed row tries session_pk, falls back to payout_pk.
/// Two CheckSig-class opcodes emitted per row, in mutually exclusive branches.
fn naive_mux() -> Vec<u8> {
    let mut b = covenant_builder();
    for row in 0..SIGNED_ROWS {
        // if <this row selected> ... row body ... endif
        b.add_op(OpDup)
            .unwrap()
            .add_data(&[row as u8])
            .unwrap()
            .add_op(OpEqual)
            .unwrap();
        b.add_op(OpIf).unwrap();
        //   session arm
        b.add_data(&pk(1)).unwrap().add_op(OpCheckSig).unwrap();
        b.add_op(OpNotIf).unwrap();
        //   wallet arm (Law 1) - only reachable when the session arm failed
        b.add_data(&pk(2)).unwrap().add_op(OpCheckSig).unwrap();
        b.add_op(OpEndIf).unwrap();
        b.add_op(OpEndIf).unwrap();
    }
    b.drain()
}

/// CAREFUL lowering: every branch only SELECTS a pubkey onto the stack;
/// one shared CheckSigVerify at the tail does the single verification.
fn careful_mux() -> Vec<u8> {
    let mut b = covenant_builder();
    for row in 0..SIGNED_ROWS {
        b.add_op(OpDup)
            .unwrap()
            .add_data(&[row as u8])
            .unwrap()
            .add_op(OpEqual)
            .unwrap();
        b.add_op(OpIf).unwrap();
        //   select which key this row authenticates against - no sigop here
        b.add_op(OpIf).unwrap();
        b.add_data(&pk(1)).unwrap();
        b.add_op(OpElse).unwrap();
        b.add_data(&pk(2)).unwrap();
        b.add_op(OpEndIf).unwrap();
        b.add_op(OpEndIf).unwrap();
    }
    // ONE verification, shared by every branch.
    b.add_op(OpCheckSigVerify).unwrap();
    b.drain()
}

fn count(redeem: &[u8]) -> u64 {
    let spk = pay_to_script_hash_script(redeem);
    let mut sig = covenant_builder();
    sig.add_data(redeem).unwrap();
    post_toccata_p2sh_sig_scanner(&sig.drain(), &spk)
}

#[test]
fn duel_ad_static_sigop_budget() {
    const CAP: u64 = 15; // MAX_STANDARD_P2SH_SIG_OPS, check_transaction_standard.rs:19

    let naive = count(&naive_mux());
    let careful = count(&careful_mux());

    // The rule P3.1 must build to: one shared verification at the tail.
    assert!(
        careful <= CAP,
        "the careful lowering must relay: {careful} sigops against a cap of {CAP}"
    );
    assert_eq!(
        careful, 1,
        "one shared CheckSigVerify at the tail, not one per row"
    );

    // And the rule it must NOT build to. This is the half that would otherwise be
    // discovered on-chain: it is over by exactly ONE, which is the least forgiving
    // way for a limit to be exceeded.
    assert!(
        naive > CAP,
        "if this ever passes, the cap or the scanner moved - re-derive the lowering \
         rule before trusting it (naive={naive}, cap={CAP})"
    );
    assert_eq!(naive, 2 * SIGNED_ROWS as u64, "two CheckSig per signed row");

    // The naive lowering's real ceiling, stated so nobody rediscovers it by accident:
    // it can afford CAP/2 = 7 signed rows. duel_ad has 8.
    assert!(
        SIGNED_ROWS as u64 > CAP / 2,
        "duel_ad sits above the naive lowering's ceiling - that is the whole finding"
    );
}
