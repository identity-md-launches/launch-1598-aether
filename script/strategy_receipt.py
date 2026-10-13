#!/usr/bin/env python3
"""Prepare AetherStrategy commitments/reveals locally. Requires Python 3 and Foundry's cast.

No RPC, wallet, private key or transaction submission. The private receipt is needed to reveal.
"""
import argparse
import json
import os
import re
import secrets
import subprocess


def cast(*args):
    return subprocess.run(["cast", *map(str, args)], check=True, capture_output=True, text=True).stdout.strip()


def validate(receipt):
    for field in ("contract", "player"):
        address = receipt[field]
        if not isinstance(address, str) or not re.fullmatch(r"0x[0-9a-fA-F]{40}", address) or int(address, 16) == 0:
            raise ValueError(f"{field} must be a nonzero Ethereum address")
    for field in ("chainId", "roundId", "tickets", "machine"):
        if type(receipt[field]) is not int:
            raise ValueError(f"{field} must be an integer")
    if not 0 < receipt["chainId"] < 2**256 or not 0 < receipt["roundId"] < 2**256:
        raise ValueError("chainId and roundId must be positive uint256 values")
    if not 1 <= receipt["tickets"] <= 500 or not 0 <= receipt["machine"] < 4:
        raise ValueError("tickets must be 1..500 and machine must be 0..3")
    if not isinstance(receipt["salt"], str) or not re.fullmatch(r"0x[0-9a-fA-F]{64}", receipt["salt"]):
        raise ValueError("salt must be 32 bytes")


def commitment(receipt):
    validate(receipt)
    encoded = cast(
        "abi-encode", "f(uint256,address,uint256,address,uint256,uint8,bytes32)",
        receipt["chainId"], receipt["contract"], receipt["roundId"], receipt["player"],
        receipt["tickets"], receipt["machine"], receipt["salt"],
    )
    return cast("keccak", encoded)


def prepare(chain_id, contract, player, round_id, tickets, machine, output):
    receipt = {
        "version": 1, "chainId": chain_id, "contract": contract, "player": player,
        "roundId": round_id, "tickets": tickets, "machine": machine, "salt": "0x" + secrets.token_hex(32),
    }
    receipt["commitment"] = commitment(receipt)
    calldata = cast("calldata", "commit(uint256,bytes32,uint256)", round_id, receipt["commitment"], tickets)
    # Never overwrite an earlier ticket's secret; owner-only permissions on POSIX systems.
    descriptor = os.open(output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, "w") as stream:
        json.dump(receipt, stream, indent=2)
        stream.write("\n")
    return {
        "contract": contract, "roundId": round_id, "commitment": receipt["commitment"],
        "approveAmount": str(tickets * 10**16), "commitCalldata": calldata,
        "receipt": str(output),
    }


def reveal(receipt_path, entry_id):
    if not 0 < entry_id < 2**256:
        raise ValueError("entryId must be the positive uint256 ID from your Committed event")
    with open(receipt_path) as stream:
        receipt = json.load(stream)
    if receipt.get("version") != 1 or commitment(receipt) != receipt.get("commitment"):
        raise ValueError("receipt version or commitment does not match")
    return {
        "contract": receipt["contract"], "chainId": receipt["chainId"], "player": receipt["player"],
        "roundId": receipt["roundId"], "entryId": entry_id,
        "revealCalldata": cast("calldata", "reveal(uint256,uint8,bytes32)", entry_id, receipt["machine"], receipt["salt"]),
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    create = commands.add_parser("prepare", help="generate a fresh salt and save a private receipt")
    create.add_argument("--chain-id", type=int, required=True)
    create.add_argument("--contract", required=True)
    create.add_argument("--player", required=True)
    create.add_argument("--round", type=int, required=True, dest="round_id")
    create.add_argument("--tickets", type=int, required=True)
    create.add_argument("--machine", type=int, required=True)
    create.add_argument("--output", required=True, help="new private receipt path, preferably outside the repository")
    show = commands.add_parser("reveal", help="show reveal calldata; only use once the commit window has closed")
    show.add_argument("--receipt", required=True)
    show.add_argument("--entry-id", type=int, required=True)
    args = parser.parse_args()
    try:
        if args.command == "prepare":
            result = prepare(args.chain_id, args.contract, args.player, args.round_id, args.tickets, args.machine, args.output)
        else:
            result = reveal(args.receipt, args.entry_id)
        print(json.dumps(result, indent=2))
    except (ValueError, KeyError, TypeError, OSError, subprocess.CalledProcessError) as error:
        parser.error(str(error))


if __name__ == "__main__":
    main()
