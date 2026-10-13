#!/usr/bin/env python3
"""Build the airdrop Merkle root and proofs from a snapshot CSV (address,nft_count).

Usage: python3 sim/merkle_tool.py snapshot.csv > proofs.json
Leaf = keccak256(bytes.concat(keccak256(abi.encode(account, amount)))), amount = 0.5e18 * count,
sorted-pair hashing (same layout as AetherAirdrop.sol and OpenZeppelin StandardMerkleTree).
Requires pycryptodome (pip install pycryptodome); run without -I so site-packages are visible.
"""
import csv
import json
import sys

from Crypto.Hash import keccak

PER_NFT = 500_000_000_000_000_000  # 0.5e18


def k(b: bytes) -> bytes:
    return keccak.new(digest_bits=256, data=b).digest()


def leaf(addr: str, amount: int) -> bytes:
    a = bytes.fromhex(addr[2:].rjust(64, "0"))
    return k(k(a + amount.to_bytes(32, "big")))


def pair(a: bytes, b: bytes) -> bytes:
    return k(a + b) if a < b else k(b + a)


def build(leaves):
    layers = [leaves]
    while len(layers[-1]) > 1:
        cur = layers[-1]
        nxt = [pair(cur[i], cur[i + 1]) if i + 1 < len(cur) else cur[i] for i in range(0, len(cur), 2)]
        layers.append(nxt)
    return layers


def proof(layers, idx):
    out = []
    for layer in layers[:-1]:
        sib = idx ^ 1
        if sib < len(layer):
            out.append("0x" + layer[sib].hex())
        idx //= 2
    return out


def main():
    rows = []
    with open(sys.argv[1]) as f:
        for addr, count in csv.reader(f):
            addr = addr.strip().lower()
            if not addr.startswith("0x"):
                continue
            rows.append((addr, PER_NFT * int(count)))
    rows.sort()
    leaves = [leaf(a, amt) for a, amt in rows]
    layers = build(leaves)
    root = "0x" + layers[-1][0].hex()
    out = {"root": root, "total": sum(amt for _, amt in rows), "claims": {}}
    for i, (a, amt) in enumerate(rows):
        out["claims"][a] = {"amount": str(amt), "proof": proof(layers, i)}
    json.dump(out, sys.stdout, indent=1)


if __name__ == "__main__":
    main()
