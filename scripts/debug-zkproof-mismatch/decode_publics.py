#!/usr/bin/env python3
"""Decode publics array from proof JSON using the zkevm-prover layout.

Publics layout (from zkevm-prover/src/prover/prover.cpp):
  publics[0..7]   = oldStateRoot
  publics[8..15]  = oldAccInputHash
  publics[16]     = oldBatchNum
  publics[17]     = chainID
  publics[18]     = forkID
  publics[19..26] = newStateRoot
  publics[27..34] = newAccInputHash
  publics[35..42] = newLocalExitRoot
  publics[43]     = newBatchNum

Verified correct fea2scalar (via cross-check with L1 sequencedBatches[1].accInputHash):
  pairs[0] = (publics[2i+1] << 32) | publics[2i]   # 2 elements -> 64 bits
  chunk[0] = (pairs[0] << 192) | (pairs[1] << 128) | (pairs[2] << 64) | pairs[3]   # 4 pairs -> 256 bits
  But the 4 chunks of 64 bits must be reversed in byte order within the 32 bytes:
    full 32-byte = chunk3 || chunk2 || chunk1 || chunk0  (in big-endian wire order)
  Equivalently: divide the 32-byte result into 4 big-endian 64-bit words and reverse.
"""
import sys, json

def fea2scalar(field_elements):
    """Convert 8 Goldilocks field elements to 32-byte big-endian scalar.

    Verified algorithm: each pair (fe[2i+1], fe[2i]) -> 64-bit word (high 32, low 32).
    Four words -> 256 bits. Then split into 4 big-endian 8-byte chunks and reverse.
    """
    if len(field_elements) != 8:
        raise ValueError(f"expected 8 elements, got {len(field_elements)}")
    pairs = [
        (int(field_elements[1]) << 32) | int(field_elements[0]),
        (int(field_elements[3]) << 32) | int(field_elements[2]),
        (int(field_elements[5]) << 32) | int(field_elements[4]),
        (int(field_elements[7]) << 32) | int(field_elements[6]),
    ]
    scalar = (pairs[0] << 192) | (pairs[1] << 128) | (pairs[2] << 64) | pairs[3]
    b = scalar.to_bytes(32, 'big')
    # Reverse 8-byte chunks
    chunks = [b[i:i+8] for i in range(0, 32, 8)]
    return '0x' + b''.join(reversed(chunks)).hex()

if __name__ == '__main__':
    if len(sys.argv) > 1:
        publics = sys.argv[1].split(',')
    else:
        d = json.load(sys.stdin)
        publics = d.get('publics', d.get('public', []))

    print(f"Total publics: {len(publics)}")
    print()
    print("Per-field decoding (44 publics):")
    print(f"  oldStateRoot         = {fea2scalar(publics[0:8])}")
    print(f"  oldAccInputHash      = {fea2scalar(publics[8:16])}")
    print(f"  oldBatchNum          = {publics[16]}")
    print(f"  chainID              = {publics[17]}")
    print(f"  forkID               = {publics[18]}")
    print(f"  newStateRoot         = {fea2scalar(publics[19:27])}")
    print(f"  newAccInputHash      = {fea2scalar(publics[27:35])}")
    print(f"  newLocalExitRoot     = {fea2scalar(publics[35:43])}")
    print(f"  newBatchNum          = {publics[43]}")
