# Debug Session: invalid-proof-proof-mismatch

## Status
OPEN

## Symptom
L1 contract `verifyBatchesTrustedAggregator` reverts with `InvalidProof()` (`0x09bde339`) when aggregator submits batch-1 proof.

## Latest Observations
- `cast estimate` for `verifyBatchesTrustedAggregator(..., newStateRoot=0xf03d90657b5d9308d5fb39145ca5e7ce7af6485715c6f8286712a38af47edf47, ...)` with the current proof from the aggregator DB succeeds (gas = 636337). This means the proof **is** valid for that `newStateRoot`.
- The sequencer/RPC reports batch-1 stateRoot as `0x71903432...` (SMT root), which is different from the prover's `newStateRoot=0xf03d9065...`.
- L1 `batchNumToStateRoot[0]` is the MPT genesis root `0xd96db188...`, while the prover's `oldStateRoot` is `5379256407...` (decimal) / `0x7743...` (likely SMT root).

## Falsifiable Hypotheses
1. **H1: Prover uses a witness whose SMT oldStateRoot does not match the sequencer's actual SMT state at batch 0**, because the witness is built from RPC data that returns the MPT header root instead of the SMT root.
2. **H2: The prover recomputes the SMT root differently from cdk-erigon's OLD smt / smtv2 implementations**, producing a `newStateRoot` that is internally consistent for the witness but does not match the sequencer's block header root.
3. **H3: The aggregator passes wrong public inputs to the prover** (e.g., `oldAccInputHash` or `L1InfoRoot`), causing the prover to generate a proof for a different virtual batch than the one sequenced on L1.
4. **H4: The witness is built before the sequencer has fully processed batch 1**, so the prover proves an intermediate state that never becomes the canonical batch-1 stateRoot.
5. **H5: The L1 contract's expected `oldStateRoot` for batch 1 (i.e., `batchNumToStateRoot[0]`) is wrong**, but the proof itself is fine for the sequencer's actual state transition.

## Evidence to Collect
- [ ] Decode the current `publics.json` / aggregator DB proof and print `oldStateRoot`, `newStateRoot`, `oldAccInputHash`, `newAccInputHash`.
- [ ] Query sequencer/RPC for `zkevm_getBatchByNumber(0)` and `zkevm_getBatchByNumber(1)` state roots.
- [ ] Extract the witness bytes from the aggregator DB and compare the SMT root embedded in it.
- [ ] Run `compare-invalidproof.py` with current containers.
- [ ] (Instrumentation) Add debug logging in `cdk/aggregator/aggregator.go` and/or `cdk-erigon/zk/witness/witness.go` to capture the exact values used to build the witness and request the proof.
