"""Offline policy checks; no SIP client, provider login, or network is used."""

from __future__ import annotations

from contextlib import redirect_stderr, redirect_stdout
import copy
import importlib.util
import io
import json
import os
from pathlib import Path
import re
import tempfile
import unittest
import xml.etree.ElementTree as ET


SOURCE = Path(__file__).resolve().parents[1] / "generate_dialplan.py"
SPEC = importlib.util.spec_from_file_location("numero_dialplan", SOURCE)
GENERATOR = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(GENERATOR)

# Reserved fictional 555-01xx numbers, never production account data.
CONFIG = {"gateway": "numero", "authorized_seat": "1001",
          "lines": {"us": "+12025550143", "ca": "+14165550143"}}


def routed(xml, destination, seat="1001", authorized="true", caller_id="untrusted"):
    """Evaluate generated sequential condition/terminal-extension policy.

    This bounded fixture models only the constructs this generator emits. It
    does not claim to be FreeSWITCH or verify SIP/media/provider behavior.
    """
    document = ET.fromstring(xml)
    variables = {"destination_number": destination, "sip_auth_username": seat,
                 "sip_authorized": authorized, "caller_id_number": caller_id,
                 "sip_from_user": caller_id, "sip_h_X-Caller-ID": caller_id}
    for extension in document.findall("extension"):
        actions = []
        captures = ()
        for condition in extension.findall("condition"):
            field = condition.get("field", "")
            key = field[2:-1] if field.startswith("${") and field.endswith("}") else field
            # FreeSWITCH uses PCRE's absolute-end \z; Python's equivalent is \Z.
            expression = condition.get("expression", "").replace(r"\z", r"\Z")
            match = re.search(expression, variables.get(key, ""))
            if match is None:
                break
            captures = match.groups()
            for action in condition.findall("action"):
                data = action.get("data", "")
                for index, captured in enumerate(captures, 1):
                    data = data.replace(f"${index}", captured)
                actions.append((action.get("application"), data))
        else:
            if actions:
                return extension.get("name"), actions
    return None, []


class NumeroDialplanTests(unittest.TestCase):
    def test_each_line_maps_to_its_server_owned_caller_id(self):
        xml = GENERATOR.generate(CONFIG)
        for country, did in CONFIG["lines"].items():
            wire_did = did[1:]
            name, actions = routed(xml, f"numero-{country}-442079460958", caller_id="+19999999999")
            self.assertEqual(name, f"search_numero_{country}")
            self.assertIn(("set", f"effective_caller_id_number={wire_did}"), actions)
            bridge = next(data for app, data in actions if app == "bridge")
            self.assertIn(f"origination_caller_id_number={wire_did}", bridge)
            self.assertIn(f"origination_caller_id_name={wire_did}", bridge)
            self.assertNotIn(f"origination_caller_id_number={did}", bridge)
            self.assertTrue(bridge.endswith("sofia/gateway/numero/+442079460958@numeroesimapp.com"))
            self.assertNotIn("19999999999", bridge)
            self.assertIn(("set", "continue_on_fail=false"), actions)
            self.assertIn(("set", "hangup_after_bridge=true"), actions)
            self.assertEqual(actions[-1], ("hangup", "NORMAL_CLEARING"))

    def test_other_or_unauthenticated_seat_is_rejected(self):
        xml = GENERATOR.generate(CONFIG)
        for seat, authorized in [("1002", "true"), ("", "true"), ("1001", "false"), ("1001", ""), ("1001", "TRUE")]:
            for country in ("us", "ca"):
                name, actions = routed(xml, f"numero-{country}-442079460958", seat=seat, authorized=authorized,
                                       caller_id="1001")
                self.assertEqual(name, "search_numero_reject_unknown")
                self.assertEqual(actions, [("hangup", "CALL_REJECTED")])

    def test_unknown_or_malformed_prefix_cannot_fall_through(self):
        malformed = ["numero-fr-442079460958", "numero-US-442079460958", "NUMERO-ca-442079460958",
                     "numero-ca-+442079460958", "numero-ca-0442079460958", "numero-ca-911",
                     "numero-ca-1001", "numero-ca-12345", "numero-ca-1234567890123456", "numero-ca-",
                     "numero-ca-442079460958@evil.test", "numero-ca-442079460958;caller=123",
                     "numero-ca-442079460958\n", "numero-ca-٤٤٢٠٧٩٤٦٠٩٥٨", "numero-", "numero-evil"]
        xml = GENERATOR.generate(CONFIG)
        for destination in malformed:
            with self.subTest(destination=repr(destination)):
                self.assertEqual(routed(xml, destination),
                                 ("search_numero_reject_unknown", [("hangup", "CALL_REJECTED")]))

    def test_generated_routes_are_terminal_and_precede_rejection(self):
        document = ET.fromstring(GENERATOR.generate(CONFIG))
        extensions = document.findall("extension")
        self.assertEqual([item.get("name") for item in extensions],
                         ["search_numero_us", "search_numero_ca", "search_numero_reject_unknown"])
        self.assertTrue(all(item.get("continue") == "false" for item in extensions))
        self.assertEqual(len(extensions[-1].findall("condition")), 1)
        self.assertEqual(extensions[-1].find("condition").get("field"), "destination_number")

    def test_unrelated_old_numeric_and_feature_routes_are_untouched(self):
        document = ET.fromstring(GENERATOR.generate(CONFIG))
        old = ET.fromstring('<extension name="old_numeric"><condition field="destination_number" expression="^([0-9]{6,15})$">'
                            '<action application="bridge" data="old-route/$1"/></condition></extension>')
        document.append(old)
        xml = ET.tostring(document, encoding="unicode")
        self.assertEqual(routed(xml, "442079460958"), ("old_numeric", [("bridge", "old-route/442079460958")]))
        self.assertEqual(routed(xml, "9199"), (None, []))
        self.assertEqual(routed(xml, "numero-ca-442079460958", seat="1002")[1], [("hangup", "CALL_REJECTED")])
        self.assertFalse(re.search(r"^[0-9]{6,15}$", "numero-ca-442079460958"))

    def test_destination_bounds_are_absolute_and_ascii(self):
        xml = GENERATOR.generate(CONFIG)
        for digits in ("123456", "123456789012345"):
            self.assertEqual(routed(xml, "numero-us-" + digits)[0], "search_numero_us")
        for digits in ("12345", "1234567890123456", "0123456", "123456\n", "１２３４５６"):
            self.assertEqual(routed(xml, "numero-us-" + digits)[0], "search_numero_reject_unknown")

    def test_configured_identifier_is_literal_not_a_regex(self):
        config = copy.deepcopy(CONFIG)
        config["authorized_seat"] = "1001.alpha"
        xml = GENERATOR.generate(config)
        self.assertEqual(routed(xml, "numero-us-123456", seat="1001.alpha")[0], "search_numero_us")
        self.assertEqual(routed(xml, "numero-us-123456", seat="1001xalpha")[0], "search_numero_reject_unknown")

    def test_invalid_or_injected_configuration_is_rejected(self):
        cases = [None, [], {}, {**CONFIG, "password": "must-not-be-configured"},
                 {**CONFIG, "gateway": "numero/other"}, {**CONFIG, "gateway": "${injected}"},
                 {**CONFIG, "gateway": "numero,evil"}, {**CONFIG, "authorized_seat": "1001|.*"},
                 {**CONFIG, "authorized_seat": "1001\n"}, {**CONFIG, "authorized_seat": 1001},
                 {**CONFIG, "lines": {"us": CONFIG["lines"]["us"]}},
                 {**CONFIG, "lines": {"us": CONFIG["lines"]["us"], "ca": CONFIG["lines"]["us"]}},
                 {**CONFIG, "lines": {**CONFIG["lines"], "gb": "+442079460958"}}]
        for field in ("us", "ca"):
            for invalid in ("12025550143", "+442079460958", "+12025550143${evil}", "+12025550143\n", "", None, True):
                config = copy.deepcopy(CONFIG)
                config["lines"][field] = invalid
                cases.append(config)
        for config in cases:
            with self.subTest(config_type=type(config).__name__):
                with self.assertRaises(GENERATOR.ConfigurationError):
                    GENERATOR.generate(config)

    def test_gateway_requires_caller_id_in_from_true(self):
        good = '<include><gateway name="numero"><param name="caller-id-in-from" value="true"/></gateway></include>'
        self.assertIsNone(GENERATOR.verify_gateway(good, "numero"))
        bad = [good.replace('value="true"', 'value="false"'), good.replace('name="numero"', 'name="other"'),
               '<include><gateway name="numero"/></include>',
               good.replace('</gateway>', '<param name="caller-id-in-from" value="true"/></gateway>'),
               '<!DOCTYPE include [<!ENTITY x "bad">]><include/>', '<include>']
        for xml in bad:
            with self.assertRaises(GENERATOR.ConfigurationError):
                GENERATOR.verify_gateway(xml, "numero")

    def test_json_duplicates_are_rejected_without_exposing_input(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "config.json"
            path.write_text('{"gateway":"numero","gateway":"private-value"}', encoding="utf-8")
            with self.assertRaisesRegex(GENERATOR.ConfigurationError, "Duplicate JSON keys") as caught:
                GENERATOR.load_config(path)
            self.assertNotIn("private-value", str(caught.exception))

    def test_cli_writes_a_new_private_candidate_and_refuses_overwrite(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            config, output, gateway = root / "config.json", root / "candidate.xml", root / "gateway.xml"
            config.write_text(json.dumps(CONFIG), encoding="utf-8")
            gateway.write_text('<include><gateway name="numero"><param name="caller-id-in-from" value="true"/></gateway></include>', encoding="utf-8")
            self.assertEqual(GENERATOR.main([str(config), "--output", str(output), "--gateway-xml", str(gateway)]), 0)
            self.assertEqual(os.stat(output).st_mode & 0o777, 0o600)
            first = output.read_text(encoding="utf-8")
            with redirect_stderr(io.StringIO()):
                self.assertEqual(GENERATOR.main([str(config), "--output", str(output)]), 2)
            self.assertEqual(output.read_text(encoding="utf-8"), first)

    def test_cli_refuses_bad_gateway_without_writing_or_logging_config(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            config, output, gateway = root / "config.json", root / "candidate.xml", root / "gateway.xml"
            config.write_text(json.dumps(CONFIG), encoding="utf-8")
            gateway.write_text('<include><gateway name="numero"><param name="password" value="private-password"/></gateway></include>', encoding="utf-8")
            stdout, stderr = io.StringIO(), io.StringIO()
            with redirect_stderr(stderr), redirect_stdout(stdout):
                status = GENERATOR.main([str(config), "--output", str(output), "--gateway-xml", str(gateway)])
            self.assertEqual(status, 2)
            self.assertFalse(output.exists())
            self.assertEqual(stdout.getvalue(), "")
            self.assertNotIn("private-password", stderr.getvalue())
            self.assertNotIn(CONFIG["lines"]["us"], stderr.getvalue())
            self.assertNotIn(CONFIG["lines"]["ca"], stderr.getvalue())


if __name__ == "__main__":
    unittest.main()
