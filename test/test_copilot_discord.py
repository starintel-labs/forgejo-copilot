import importlib
import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
bridge = importlib.import_module("copilot_discord")


class Discord(unittest.TestCase):
    def test_default_deny_and_thread_binding(self):
        config = {"channels": {"20": {"guild_id": "10", "repo": "o/r", "users": {"30": "writer"}}}}
        self.assertEqual(bridge.binding(config, 10, 21, 20, 30)["repo"], "o/r")
        for guild, channel, parent, user in ((None, 20, None, 30), (11, 20, None, 30), (10, 99, None, 30), (10, 20, None, 31)):
            with self.assertRaises(PermissionError):
                bridge.binding(config, guild, channel, parent, user)

    def test_text_and_slash_style_routing(self):
        self.assertEqual(bridge.route("task Fix the bug"), bridge.route("/task Fix the bug"))
        self.assertEqual(bridge.route("@star /task Fix the bug"), ("star", "task", "Fix the bug"))
        self.assertEqual(bridge.route("status")[1], "status")
        self.assertEqual(bridge.route("cancel")[1], "cancel")
        self.assertEqual(bridge.route("forget")[1], "forget")
        self.assertEqual(bridge.route("ask Why does it fail?"), ("mara", "ask", "Why does it fail?"))

    def test_conversations_do_not_cross_privacy_boundaries(self):
        scope = bridge.conversation_scope("o/r", 10, 20, 30, "mara")
        for args in (("o/other", 10, 20, 30, "mara"), ("o/r", 11, 20, 30, "mara"),
                     ("o/r", 10, 21, 30, "mara"), ("o/r", 10, 20, 31, "mara"), ("o/r", 10, 20, 30, "star")):
            self.assertNotEqual(scope, bridge.conversation_scope(*args))

    def test_bounded_history_and_delivery_cache(self):
        with tempfile.TemporaryDirectory() as directory:
            state = bridge.DiscordState(Path(directory) / "discord.sqlite3")
            for index in range(20):
                state.remember("scope", "question " + str(index), "answer")
            self.assertEqual(len(state.history("scope")), 12)
            self.assertEqual(state.history("other"), [])
            state.save("event", "answer")
            state.save("event", "duplicate")
            self.assertEqual(state.cached("event"), ("answer", 0))
            state.delivered("event")
            self.assertEqual(state.cached("event"), ("answer", 1))
            state.forget("scope")
            self.assertEqual(state.history("scope"), [])

    @unittest.skipUnless(importlib.util.find_spec("discord"), "optional Discord SDK gate")
    def test_sdk_command_construction_without_network_or_credentials(self):
        import discord
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            token = root / "token"
            token.write_text("fake-test-token")
            token.chmod(0o600)
            config = root / "config.json"
            config.write_text(json.dumps({"enabled": True, "channels": {"20": {"guild_id": "10"}},
                                          "application_id": "12345", "token_file": str(token)}))
            with patch.object(bridge, "Router"), patch.object(discord.Client, "run", autospec=True) as run:
                with patch.object(sys, "argv", ["copilot_discord", "--config", str(config)]):
                    bridge.main()
                client = run.call_args.args[0]
                payload = client.tree.get_command("copilot").to_dict(client.tree)
                self.assertEqual(payload["name"], "copilot")
                self.assertEqual(payload["description"], "Forgejo Copilot repository assistant")
                self.assertEqual(payload["options"][0]["name"], "action")


if __name__ == "__main__":
    unittest.main()
