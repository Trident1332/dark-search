from pathlib import Path
import io
import json
import sys
import threading
import time
import unittest
from unittest.mock import patch
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from line_selection import BoundSession, Provider, SelectionError
from number_selector import Busy, FreeSWITCH, Selector, bearer, report_failure
from test_line_selection import FakeProvider, SESSION, profile


class FakeFS:
    def __init__(self):
        self.live = True
        self.authorized = True
        self.other = False
        self.checked = []

    def exists(self, uuid): return self.live

    def require_call(self, uuid, line, destination):
        self.checked.append((uuid, line, destination))
        if not self.live or not self.authorized:
            raise SelectionError("call_not_authorized")

    def another_numero_call(self, uuid, session): return self.other

    def require_gateway(self, gateway):
        if gateway not in ("numero", "numero_ca"): raise SelectionError("gateway_unavailable")


class SelectorTests(unittest.TestCase):
    def test_provider_expiry_is_identifiable_without_logging_response(self):
        for code in (-9999, "-9999", -9999.0, None):
            response = io.BytesIO(json.dumps({"response_code": code,
                "response_message": "private provider detail"}).encode())
            response.status = 200
            provider = Provider(SESSION)
            with patch.object(provider.opener, "open", return_value=response):
                expected = "session_expired" if type(code) in (int, str) else "provider_rejected"
                with self.assertRaisesRegex(SelectionError, "^" + expected + "$"):
                    provider.request("my-active-numbers-dial")

    def test_diagnostics_allowlist_never_logs_arbitrary_exception_details(self):
        for error, expected in ((SelectionError("session_expired"), "session_expired"),
                                (SelectionError("private token detail"), "selection_unavailable"),
                                (RuntimeError("private token detail"), "selection_unavailable"),
                                (SelectionError({"secret": "value"}), "selection_unavailable")):
            with self.assertLogs("numero_selector", level="WARNING") as logs:
                self.assertEqual(report_failure(error), expected)
            self.assertEqual(logs.output, ["WARNING:numero_selector:selection_failed reason=" + expected])

    def setUp(self):
        self.fs = FakeFS()
        self.provider = FakeProvider([profile(), {"response_code": 1}, profile("ca")])
        self.created = []
        self.selector = Selector(self.fs, lambda **kwargs: BoundSession(SESSION.account_user, SESSION.owned, SESSION.headers, "numero_ca"), self.factory)
        self.uuid = str(uuid.uuid4())

    def factory(self, session):
        self.created.append(session)
        return self.provider

    def select(self, identifier=None):
        return self.selector.select(identifier or self.uuid, "ca", "12025550125")

    def test_fake_uuid_or_unauthorized_call_cannot_reach_provider(self):
        with self.assertRaises(SelectionError): self.select("fake;curl attacker.invalid")
        self.fs.authorized = False
        with self.assertRaises(SelectionError): self.select()
        self.assertEqual(self.created, [])
        self.assertEqual(self.selector.leases, {})

    def test_verified_selection_holds_lease_until_actual_call_ends(self):
        result = self.select()
        self.assertEqual(result["status"], 200)
        self.assertEqual(result["account_user"], SESSION.account_user)
        with self.assertRaises(Busy): self.select(str(uuid.uuid4()))
        self.selector.release(self.uuid, result["lease"])
        self.assertTrue(self.selector.leases, "A live call cannot release its account early")
        self.fs.live = False
        self.selector.reap()
        self.assertEqual(self.selector.leases, {})
        self.assertEqual(len(self.created), 1)

    def test_wrong_release_token_does_not_release_live_lease(self):
        result = self.select()
        with self.assertRaises(SelectionError): self.selector.release(self.uuid, "not-the-token")
        self.assertTrue(self.selector.leases)

    def test_service_restart_guard_checks_existing_numero_channels(self):
        self.fs.other = True
        with self.assertRaises(Busy): self.select()
        self.assertEqual(self.created, [])
        self.assertEqual(self.selector.leases, {})

    def test_missing_line_fails_before_post_and_releases_lease(self):
        data = profile()
        data["data"]["my_numbers"].pop()
        self.provider = FakeProvider([data])
        with self.assertRaises(SelectionError): self.select()
        self.assertEqual(self.provider.calls, [("my-active-numbers-dial", None)])
        self.assertEqual(self.selector.leases, {})

    def test_inflight_api_operation_is_not_reaped_on_call_hangup(self):
        entered, release = threading.Event(), threading.Event()
        original = self.provider.request
        def request(path, fields=None):
            if path == "my-active-numbers-dial" and not self.provider.calls:
                entered.set()
                release.wait(2)
            return original(path, fields)
        self.provider.request = request
        failures = []
        def select():
            try: self.select()
            except SelectionError: failures.append(True)
        thread = threading.Thread(target=select)
        thread.start()
        self.assertTrue(entered.wait(1))
        started = time.monotonic()
        with self.assertRaises(Busy): self.select(str(uuid.uuid4()))
        self.assertLess(time.monotonic() - started, 0.5)
        self.fs.live = False
        self.selector.reap()
        self.assertTrue(self.selector.leases)
        release.set()
        thread.join(2)
        self.assertEqual(failures, [True])
        self.assertEqual(self.provider.calls, [("my-active-numbers-dial", None)])
        self.assertEqual(self.selector.leases, {})

    def test_unavailable_pbx_does_not_release_an_existing_call(self):
        self.select()
        def unavailable(uuid): raise SelectionError("calling_server_unavailable")
        self.fs.exists = unavailable
        self.selector.reap()
        self.assertTrue(self.selector.leases)

    def test_provider_surface_cannot_login_or_select_an_arbitrary_number(self):
        provider = Provider(SESSION)
        with self.assertRaises(SelectionError): provider.request("auth/login", {"mobile": "synthetic"})
        with self.assertRaises(SelectionError): provider.request("change-number")
        with self.assertRaises(SelectionError): provider.request("change-number", {"new_number": "+12025550199"})

    def test_local_bearer_is_read_from_private_config_without_command_arguments(self):
        key = "s" * 64
        with patch("number_selector.private_bytes", return_value=("header = Authorization: Bearer " + key + "\n").encode()):
            self.assertEqual(bearer(), "Bearer " + key)
        with patch("number_selector.private_bytes", return_value=b"header = Authorization: Bearer short\n"):
            with self.assertRaises(SelectionError): bearer()

    def test_independent_accounts_can_select_without_releasing_other_accounts_lease(self):
        mappings = {"us": "numero", "ca": "numero_ca"}
        def session(*, line):
            headers = dict(SESSION.headers, **{"Id-Client": "123" if line == "us" else "456"})
            return BoundSession("447700900001" if line == "us" else "447700900002",
                {line: SESSION.owned[line]}, headers, mappings[line], mappings)
        def provider(session):
            line = next(iter(session.owned))
            return FakeProvider([profile(), {"response_code": 1}, profile(line)])
        selector = Selector(self.fs, session, provider)
        ca = selector.select(self.uuid, "ca", "12025550125")
        us_uuid = str(uuid.uuid4())
        us = selector.select(us_uuid, "us", "12025550125")
        self.assertEqual(ca["gateway"], "numero_ca")
        self.assertEqual(us["gateway"], "numero")
        self.assertEqual(len(selector.leases), 2)
        selector.release(self.uuid, ca["lease"])
        self.assertEqual(len(selector.leases), 2)
        with self.assertRaises(Busy): selector.select(str(uuid.uuid4()), "ca", "12025550125")

    def test_gateway_aliases_with_same_provider_account_share_one_lease(self):
        self.select()
        self.selector.session_loader = lambda **kwargs: BoundSession(SESSION.account_user, SESSION.owned, SESSION.headers, "numero")
        with self.assertRaises(Busy): self.selector.select(str(uuid.uuid4()), "us", "12025550125")
        self.assertEqual(len(self.created), 1)

    def test_unavailable_gateway_cannot_change_provider_selection(self):
        def missing(gateway): raise SelectionError("gateway_unavailable")
        self.fs.require_gateway = missing
        with self.assertRaises(SelectionError): self.select()
        self.assertEqual(self.created, [])
        self.assertEqual(self.selector.leases, {})

    def test_missing_canada_session_never_loads_or_selects_us_account(self):
        loaded = []
        def missing(*, line):
            loaded.append(line)
            raise SelectionError("session_binding_invalid")
        self.selector.session_loader = missing
        with self.assertRaises(SelectionError): self.select()
        self.assertEqual(loaded, ["ca"])
        self.assertEqual(self.created, [])

    def test_canada_cannot_use_legacy_us_gateway_even_if_loader_returns_it(self):
        self.selector.session_loader = lambda **kwargs: SESSION
        with self.assertRaises(SelectionError): self.select()
        self.assertEqual(self.created, [])

    def test_restart_guard_distinguishes_other_accounts_authenticated_channel(self):
        other = str(uuid.uuid4())
        session = BoundSession(SESSION.account_user, {"ca": SESSION.owned["ca"]}, SESSION.headers,
            "numero_ca", {"us": "numero", "ca": "numero_ca"}, {"numero": "456", "numero_ca": "123"})
        fs = FreeSWITCH()
        for destination, expected in (("numero-us-12025550125", False), ("numero-ca-12025550125", True), ("numero-other-12025550125", True)):
            with patch.object(fs, "api", return_value='{"rows":[{"uuid":"' + other + '","dest":"' + destination + '"}]}'):
                self.assertEqual(fs.another_numero_call(self.uuid, session), expected)

    def test_restart_guard_checks_gateway_of_existing_upstream_leg(self):
        other = str(uuid.uuid4())
        session = BoundSession(SESSION.account_user, SESSION.owned, SESSION.headers, "numero_ca",
            gateway_accounts={"numero": "456", "numero_ca": "123"})
        fs = FreeSWITCH()
        for gateway, expected in (("numero", False), ("numero_ca", True), ("_undef_", True)):
            answers = ['{"rows":[{"uuid":"' + other + '","name":"sofia/external/target@numeroesimapp.com"}]}', gateway]
            if gateway == "_undef_": answers.append(gateway)
            with patch.object(fs, "api", side_effect=answers):
                self.assertEqual(fs.another_numero_call(self.uuid, session), expected)

    def test_restart_guard_cannot_exempt_unknown_or_same_account_gateway_alias(self):
        other = str(uuid.uuid4())
        fs = FreeSWITCH()
        for accounts in (None, {"numero_ca": "123"}, {"numero": "123", "numero_ca": "123"}):
            session = BoundSession(SESSION.account_user, SESSION.owned, SESSION.headers, "numero_ca",
                {"us": "numero", "ca": "numero_ca"}, accounts)
            with patch.object(fs, "api", return_value='{"rows":[{"uuid":"' + other + '","dest":"numero-us-12025550125"}]}'):
                self.assertTrue(fs.another_numero_call(self.uuid, session))

    def test_real_freeswitch_empty_response_omits_rows_only_with_integer_zero_count(self):
        fs = FreeSWITCH()
        for response in ('{"row_count":0}', '{"row_count":0,"rows":[]}'):
            with patch.object(fs, "api", return_value=response):
                self.assertFalse(fs.another_numero_call(self.uuid, SESSION))

    def test_missing_rows_or_mismatched_channel_counts_fail_closed(self):
        fs = FreeSWITCH()
        for response in ('[]', 'null', '{}', '{"rows":[null]}', '{"row_count":1}', '{"row_count":"0"}', '{"row_count":false}',
                         '{"row_count":0.0}', '{"row_count":1,"rows":[]}',
                         '{"row_count":"0","rows":[]}', '{"row_count":0,"rows":[{}]}'):
            with patch.object(fs, "api", return_value=response):
                with self.assertRaises(SelectionError): fs.another_numero_call(self.uuid, SESSION)


if __name__ == "__main__": unittest.main()
