"""Offline receipt tests: python3 -m unittest discover -s test -p 'test_strategy_receipt.py'."""
import json
import stat
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from script.strategy_receipt import commitment, prepare, reveal


class StrategyReceiptTest(unittest.TestCase):
    # These addresses and salts are local encoding fixtures, never deployment configuration.
    game = "0x" + "11" * 20
    player = "0x" + "22" * 20

    def test_encoding_vector_matches_foundry_contract_test(self):
        receipt = {
            "chainId": 1, "contract": self.game, "roundId": 7, "player": self.player,
            "tickets": 3, "machine": 2, "salt": "0x" + "33" * 32,
        }
        self.assertEqual(commitment(receipt), "0x50a948757244988133b44a399e3d5788278831470434857c4dddaf91775df20b")

    def test_receipt_roundtrip_is_private_and_does_not_print_secret(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "ticket.json"
            result = prepare(1, self.game, self.player, 7, 3, 2, path)
            saved = json.loads(path.read_text())
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
            self.assertEqual(result["approveAmount"], "30000000000000000")
            self.assertNotIn(saved["salt"][2:], json.dumps(result))
            self.assertEqual(saved["commitment"], commitment(saved))
            outgoing = reveal(path, 23)
            self.assertIn(saved["salt"][2:], outgoing["revealCalldata"])
            self.assertEqual(outgoing["player"], self.player)
            self.assertEqual(outgoing["entryId"], 23)
            with self.assertRaises(FileExistsError):
                prepare(1, self.game, self.player, 7, 3, 2, path)
            self.assertEqual(json.loads(path.read_text()), saved)

    def test_tampered_receipt_and_invalid_parameters_fail(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "ticket.json"
            prepare(1, self.game, self.player, 7, 3, 2, path)
            saved = json.loads(path.read_text())
            saved["tickets"] = 4
            path.write_text(json.dumps(saved))
            with self.assertRaisesRegex(ValueError, "commitment"):
                reveal(path, 23)
            with self.assertRaisesRegex(ValueError, "entryId"):
                reveal(path, 0)
            for tickets, machine in [(0, 0), (501, 0), (1, 4), (1, -1)]:
                with self.assertRaises(ValueError):
                    prepare(1, self.game, self.player, 7, tickets, machine, path)

    def test_fresh_salts_and_binding_prevent_replay(self):
        with tempfile.TemporaryDirectory() as directory:
            first = prepare(1, self.game, self.player, 7, 3, 2, Path(directory) / "first.json")
            second = prepare(1, self.game, self.player, 7, 3, 2, Path(directory) / "second.json")
            self.assertNotEqual(first["commitment"], second["commitment"])
            saved = json.loads((Path(directory) / "first.json").read_text())
            for field, value in [("chainId", 2), ("roundId", 8), ("player", self.game), ("contract", self.player)]:
                changed = dict(saved, **{field: value})
                self.assertNotEqual(commitment(changed), saved["commitment"])

    def test_tool_failure_does_not_leave_an_unusable_receipt(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "ticket.json"
            with patch("script.strategy_receipt.cast", side_effect=FileNotFoundError("cast absent")):
                with self.assertRaises(FileNotFoundError):
                    prepare(1, self.game, self.player, 7, 3, 2, path)
            self.assertFalse(path.exists())


if __name__ == "__main__":
    unittest.main()
