#!/bin/bash
# Manually submit batch 1 proof using the latest proof in aggregator DB
# Usage: ./try-manual-submit-batch1.sh

set -e

# === Configuration ===
L1_RPC="http://172.31.13.187:3030"
ROLLUP_MANAGER="0xDF9b97b40b90B7fdd2a2EDC5dd7ec7b107C763F5"  # from logs
ROLLUP_ID=1
AGGREGATOR_ADDR="0x63c1eb6738EaAC638Fe5e3ff64796C53ADaf58fa"  # from logs
PRIV_KEY_FILE="/home/ubuntu/workspace/ydyl-deployment-suite/cdk-work/output/aggregator.priv"

# === Read latest proof from aggregator DB ===
PROOFDIR=$(docker ps --filter "name=cdk-node-1" --format "{{.ID}}")
if [ -z "$PROOFDIR" ]; then
    echo "ERROR: cdk-node-1 container not running"
    exit 1
fi

# Read proof from sqlite DB
PROOF_JSON=$(docker exec $PROOFDIR sqlite3 /tmp/aggregator_db.sqlite "SELECT proof FROM proof WHERE batch_num = 1;" 2>/dev/null | tail -n 1)
if [ -z "$PROOF_JSON" ]; then
    echo "ERROR: no proof for batch 1 in aggregator DB"
    exit 1
fi

echo "Proof loaded, size: $(echo "$PROOF_JSON" | wc -c) bytes"

# Extract publics and final proof array
# The proof is a JSON with: publics (44 fields), root1..4, evals, etc.
# We need to format publics and the proof as 24 bytes32 values
# Actually for verifyBatchesTrustedAggregator:
# - proof: bytes32[24]
# - public inputs are derived from publics

# Get rollup contract
echo ""
echo "=== Fetching rollup contract address ==="
ROLLUP_CONTRACT=$(cast call $ROLLUP_MANAGER "rollupIDToRollupData(uint32)(address,uint64,address,uint64,bytes32,uint64,uint64,uint64,uint64,uint64,uint64,uint8)" $ROLLUP_ID --rpc-url $L1_RPC 2>&1 | head -n 1)
echo "Rollup contract: $ROLLUP_CONTRACT"

# Get sequenced batch 1
SEQ1=$(cast call $ROLLUP_CONTRACT "sequencedBatches(uint64)((bytes32,bytes32,uint64,address,bytes32))" 1 --rpc-url $L1_RPC 2>&1)
echo "Sequenced batch 1: $SEQ1"

# Get sequenced batch 0
SEQ0=$(cast call $ROLLUP_CONTRACT "sequencedBatches(uint64)((bytes32,bytes32,uint64,address,bytes32))" 0 --rpc-url $L1_RPC 2>&1)
echo "Sequenced batch 0: $SEQ0"

# Decode publics to extract newStateRoot, newAccInputHash, newLocalExitRoot
# publics[8:16] = newStateRoot (4 goldilocks per 32-byte half, then concat 2 halves)
# publics[24:32] = newAccInputHash
# publics[32:40] = newLocalExitRoot
# publics[40] = oldBatchNum
# publics[41] = chainID
# publics[42] = forkID
# publics[43] = newBatchNum

# Save to file
echo "$PROOF_JSON" > /tmp/proof_full.json

# Use Python to parse and extract
python3 << 'PYEOF'
import json, sys

GOLDILOCKS = 2**64 - 2**32 + 1

def g2b32(v):
    """Convert goldilocks 64-bit value to big-endian 32-byte (treating 64-bit as 256-bit)."""
    v = int(v) % (1 << 256)
    return v.to_bytes(32, 'big').hex()

def publics_to_bytes32(parts):
    """8 goldilocks -> 64 bytes (2x 32-byte halves, each 4 goldilocks little-endian)"""
    # Each half is 4 goldilocks encoded as 32 bytes:
    # The standard FFLONK encoding of 32-byte value is 4 goldilocks in little-endian
    # Result is 32 bytes total
    hex_out = b''
    for half_idx in range(2):
        half = parts[half_idx*4:(half_idx+1)*4]
        # 4 goldilocks little-endian = 32 bytes
        b = b''
        for v in reversed(half):  # big-endian when concatenating little-endian goldilocks
            g = int(v) % (1 << 64)
            b = g.to_bytes(8, 'little') + b
        hex_out += b
    return '0x' + hex_out.hex()

with open('/tmp/proof_full.json') as f:
    p = json.load(f)

publics = p['publics']
print(f"publics ({len(publics)}): {publics}")

old_state = publics_to_bytes32(publics[0:8])
new_state = publics_to_bytes32(publics[8:16])
old_acc = publics_to_bytes32(publics[16:24])
new_acc = publics_to_bytes32(publics[24:32])
new_ler = publics_to_bytes32(publics[32:40])

print(f"oldStateRoot:     {old_state}")
print(f"newStateRoot:     {new_state}")
print(f"oldAccInputHash:  {old_acc}")
print(f"newAccInputHash:  {new_acc}")
print(f"newLocalExitRoot: {new_ler}")
print(f"oldBatchNum:      {publics[40]}")
print(f"chainID:          {publics[41]}")
print(f"forkID:           {publics[42]}")
print(f"newBatchNum:      {publics[43]}")

# The proof bytes32[24] is encoded from the rest of the proof structure
# The proof structure is too complex to manually encode here.
# Instead, we'll just use the existing call from the aggregator log:
# The error data already includes the encoded calldata attempt.

# Save key values
with open('/tmp/proof_values.json', 'w') as f:
    json.dump({
        'oldStateRoot': old_state,
        'newStateRoot': new_state,
        'oldAccInputHash': old_acc,
        'newAccInputHash': new_acc,
        'newLocalExitRoot': new_ler,
        'oldBatchNum': publics[40],
        'chainID': publics[41],
        'forkID': publics[42],
        'newBatchNum': publics[43],
    }, f, indent=2)
PYEOF

echo ""
echo "=== Reading values ==="
cat /tmp/proof_values.json
