import copy
import datetime as dt
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from line_selection import BoundSession, SelectionError, load_session, select_line, success, verify_selected

OWNED = {"us": "+12025550123", "ca": "+14165550124"}
HEADERS = {"language": "english", "app_Version": "synthetic", "os": "synthetic", "Access-Key": "synthetic-access", "Security-Token": "synthetic-token", "Id-Client": "123"}
SESSION = BoundSession("447700900001", OWNED, HEADERS)


def profile(selected="us", *, raw_plus=False):
    return {"response_code": 1, "data": {"private_number_is_selected": 0, "my_numbers": [
        {"number": number if raw_plus else number[1:], "voice_enabled": 1, "is_selected": int(line == selected)}
        for line, number in OWNED.items()]}}


class FakeProvider:
    def __init__(self, responses):
        self.responses = iter(responses)
        self.calls = []

    def request(self, path, fields=None):
        self.calls.append((path, fields))
        return next(self.responses)


class LineSelectionTests(unittest.TestCase):
    def test_genuine_get_post_get_and_exact_raw_number(self):
        for plus in (False, True):
            provider = FakeProvider([profile(raw_plus=plus), {"response_code": "1"}, profile("ca", raw_plus=plus)])
            checks = []
            result = select_line(SESSION, provider, "ca", lambda: checks.append(True))
            self.assertEqual(provider.calls, [("my-active-numbers-dial", None), ("change-number", {"new_number": OWNED["ca"] if plus else OWNED["ca"][1:]}), ("my-active-numbers-dial", None)])
            self.assertEqual(result, {"caller_id": OWNED["ca"][1:], "account_user": SESSION.account_user, "gateway": "numero"})
            self.assertEqual(len(checks), 4)

    def test_missing_canada_is_refused_before_post(self):
        data = profile()
        data["data"]["my_numbers"].pop()
        provider = FakeProvider([data])
        with self.assertRaises(SelectionError):
            select_line(SESSION, provider, "ca", lambda: None)
        self.assertEqual(provider.calls, [("my-active-numbers-dial", None)])

    def test_eligible_us_still_works_when_other_owned_line_is_not_outgoing(self):
        data = profile()
        data["data"]["my_numbers"].pop()
        provider = FakeProvider([data, {"response_code": 1}, data])
        self.assertEqual(select_line(SESSION, provider, "us", lambda: None)["caller_id"], OWNED["us"][1:])

    def test_duplicate_owned_line_is_refused_before_post(self):
        data = profile()
        data["data"]["my_numbers"].append(copy.deepcopy(data["data"]["my_numbers"][1]))
        provider = FakeProvider([data])
        with self.assertRaises(SelectionError):
            select_line(SESSION, provider, "ca", lambda: None)
        self.assertEqual(len(provider.calls), 1)

    def test_private_or_other_selected_or_unverified_profile_is_refused(self):
        for key in ("private", "both", "unknown"):
            verified = profile("ca")
            if key == "private": verified["data"]["private_number_is_selected"] = 1
            if key == "both": verified["data"]["my_numbers"][0]["is_selected"] = 1
            if key == "unknown": verified["data"]["my_numbers"][0]["is_selected"] = "0"
            with self.assertRaises(SelectionError):
                verify_selected(verified, OWNED, "ca")

    def test_dead_or_unauthorized_call_cannot_reach_provider(self):
        provider = FakeProvider([])
        def invalid(): raise SelectionError("call_invalid")
        with self.assertRaises(SelectionError):
            select_line(SESSION, provider, "ca", invalid)
        self.assertEqual(provider.calls, [])

    def test_call_is_revalidated_before_post(self):
        provider = FakeProvider([profile()])
        count = [0]
        def validate():
            count[0] += 1
            if count[0] == 2: raise SelectionError("call_ended")
        with self.assertRaises(SelectionError):
            select_line(SESSION, provider, "ca", validate)
        self.assertEqual(len(provider.calls), 1)

    def test_success_codes_are_exact_and_do_not_accept_boolean(self):
        for value in (1, "1"):
            self.assertTrue(success({"response_code": value}))
        for value in (True, 1.0, "01", "true", None):
            self.assertFalse(success({"response_code": value}))

    def test_single_line_account_cannot_select_other_accounts_line(self):
        session = BoundSession("447700900002", {"ca": OWNED["ca"]}, HEADERS, "numero_ca")
        data = profile("ca")
        data["data"]["my_numbers"].pop(0)
        provider = FakeProvider([data, {"response_code": 1}, data])
        self.assertEqual(select_line(session, provider, "ca", lambda: None)["gateway"], "numero_ca")
        provider = FakeProvider([])
        with self.assertRaises(SelectionError): select_line(session, provider, "us", lambda: None)
        self.assertEqual(provider.calls, [])

    def test_outgoing_contract_does_not_use_unmodeled_voice_field(self):
        for value in ("absent", 0, "0", None, False):
            initial, selected = profile(), profile("ca")
            for response in (initial, selected):
                for row in response["data"]["my_numbers"]:
                    if value == "absent": row.pop("voice_enabled")
                    else: row["voice_enabled"] = value
            provider = FakeProvider([initial, {"response_code": 1}, selected])
            self.assertEqual(select_line(SESSION, provider, "ca", lambda: None)["caller_id"], OWNED["ca"][1:])
            self.assertEqual(len(provider.calls), 3)


class SessionTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.directory = Path(self.tmp.name)
        self.directory.chmod(0o700)
        self.gateway = self.directory / "gateway.xml"
        self.gateway.write_text('<include><gateway name="numero"><param name="username" value="447700900001"/></gateway></include>')
        self.gateway.chmod(0o600)
        self.saved = {"schema_version": 1, "issued_utc": "2026-10-29T00:00:00+00:00", "account_binding": {"gateway": "numero", "username": SESSION.account_user, "id_client": "123"}, "owned_lines": OWNED, "headers": HEADERS}
        self.write("lines.json", {"gateway": "numero", "authorized_seat": "1001", "lines": OWNED})
        self.write("api-session.json", self.saved)

    def tearDown(self): self.tmp.cleanup()

    def write(self, name, value):
        path = self.directory / name
        path.write_text(json.dumps(value))
        path.chmod(0o600)

    def load(self): return load_session(self.directory, self.gateway, owner=os.getuid(), now=dt.datetime(2026, 10, 29, tzinfo=dt.timezone.utc))

    def test_server_only_session_has_no_invented_ttl(self):
        self.assertEqual(self.load().owned, OWNED)
        self.saved["issued_utc"] = "2000-01-01T00:00:00+00:00"
        self.write("api-session.json", self.saved)
        self.assertEqual(self.load().account_user, SESSION.account_user)

    def test_explicit_provider_expiry_is_enforced(self):
        self.saved["provider_expires_utc"] = "2026-10-28T00:00:00+00:00"
        self.write("api-session.json", self.saved)
        with self.assertRaises(SelectionError): self.load()

    def test_wrong_binding_or_permissions_are_refused(self):
        self.saved["account_binding"]["username"] = "447700900002"
        self.write("api-session.json", self.saved)
        with self.assertRaises(SelectionError): self.load()
        self.saved["account_binding"]["username"] = SESSION.account_user
        self.write("api-session.json", self.saved)
        (self.directory / "api-session.json").chmod(0o644)
        with self.assertRaises(SelectionError): self.load()

    def mapped_fixture(self):
        self.write("lines.json", {"gateway": "numero", "authorized_seat": "1001", "lines": OWNED,
            "line_gateways": {"us": "numero", "ca": "numero_ca"}})
        accounts = self.directory / "accounts"
        accounts.mkdir(mode=0o700)
        ca = accounts / "ca"
        ca.mkdir(mode=0o700)
        session = copy.deepcopy(self.saved)
        session["account_binding"].update(gateway="numero_ca", username="447700900002", id_client="456")
        session["headers"]["Id-Client"] = "456"
        session["owned_lines"] = {"ca": OWNED["ca"]}
        self.write("accounts/ca/api-session.json", session)
        self.gateway.write_text('<include><gateway name="numero_ca"><param name="username" value="447700900002"/><param name="caller-id-in-from" value="false"/></gateway></include>')
        return session

    def load_ca(self):
        return load_session(self.directory, self.gateway, line="ca", owner=os.getuid())

    def test_explicit_canada_mapping_uses_separate_account_and_single_line_binding(self):
        self.mapped_fixture()
        session = self.load_ca()
        self.assertEqual(session.gateway, "numero_ca")
        self.assertEqual(session.account_user, "447700900002")
        self.assertEqual(session.owned, {"ca": OWNED["ca"]})
        self.assertEqual(session.account_key, "456")

    def test_missing_canada_session_does_not_fall_back_to_us_session(self):
        self.mapped_fixture()
        (self.directory / "accounts/ca/api-session.json").unlink()
        with self.assertRaises((SelectionError, OSError)): self.load_ca()

    def test_missing_or_cross_account_mapping_fails_closed(self):
        self.mapped_fixture()
        for mapping in ({"us": "numero"}, {"us": "numero", "ca": "numero"}, {"ca": "../numero"}):
            self.write("lines.json", {"gateway": "numero", "authorized_seat": "1001", "lines": OWNED,
                "line_gateways": mapping})
            with self.assertRaises(SelectionError): self.load_ca()

    def test_canada_account_binding_and_owned_line_cannot_be_swapped(self):
        session = self.mapped_fixture()
        for key in ("gateway", "username", "owned"):
            invalid = copy.deepcopy(session)
            if key == "owned": invalid["owned_lines"] = {"us": OWNED["us"]}
            else: invalid["account_binding"][key] = "numero" if key == "gateway" else SESSION.account_user
            self.write("accounts/ca/api-session.json", invalid)
            with self.assertRaises(SelectionError): self.load_ca()

    def test_explicit_us_mapping_filters_historical_canada_binding(self):
        self.mapped_fixture()
        self.gateway.write_text('<include><gateway name="numero"><param name="username" value="447700900001"/><param name="caller-id-in-from" value="false"/></gateway></include>')
        self.assertEqual(self.load().owned, {"us": OWNED["us"]})

    def test_account_directory_or_identity_setting_must_be_private_and_explicit(self):
        self.mapped_fixture()
        (self.directory / "accounts").chmod(0o755)
        with self.assertRaises(SelectionError): self.load_ca()
        (self.directory / "accounts").chmod(0o700)
        self.gateway.write_text(self.gateway.read_text().replace('value="false"', 'value="unset"'))
        with self.assertRaises(SelectionError): self.load_ca()

    def test_peer_account_identity_is_proved_from_separate_bound_gateway_and_session(self):
        self.mapped_fixture()
        (self.directory / "numero_ca.xml").write_bytes(self.gateway.read_bytes())
        (self.directory / "numero_ca.xml").chmod(0o600)
        (self.directory / "numero.xml").write_text('<include><gateway name="numero"><param name="username" value="447700900001"/><param name="caller-id-in-from" value="true"/></gateway></include>')
        (self.directory / "numero.xml").chmod(0o600)
        session = load_session(self.directory, line="ca", owner=os.getuid(), gateway_directory=self.directory)
        self.assertEqual(session.gateway_accounts, {"numero_ca": "456", "numero": "123"})
        self.write("api-session.json", {"not": "a verified peer binding"})
        session = load_session(self.directory, line="ca", owner=os.getuid(), gateway_directory=self.directory)
        self.assertEqual(session.gateway_accounts, {"numero_ca": "456"})

    def test_invalid_peer_session_cannot_break_the_other_valid_account(self):
        self.mapped_fixture()
        self.gateway.write_text('<include><gateway name="numero"><param name="username" value="447700900001"/><param name="caller-id-in-from" value="true"/></gateway></include>')
        self.write("accounts/ca/api-session.json", [])
        self.assertEqual(self.load().gateway, "numero")


if __name__ == "__main__": unittest.main()
