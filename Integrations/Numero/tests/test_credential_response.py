import importlib.util
import json
from pathlib import Path
import sys
import unittest


DIRECTORY = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("credential_value", DIRECTORY / "credential_value.py")
VALUE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = VALUE
SPEC.loader.exec_module(VALUE)
SPEC = importlib.util.spec_from_file_location("numero_credential_response", DIRECTORY / "credential_response.py")
RESPONSE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(RESPONSE)


class NumeroCredentialResponseTests(unittest.TestCase):
    def test_captured_integer_password_and_success_code_contract(self):
        self.assertEqual(RESPONSE.extract_sip_password({"response_code": 1, "data": {"password": 54321098}}), "54321098")
        self.assertEqual(RESPONSE.extract_sip_password({"response_code": 1, "data": {"password": "00123456"}}), "00123456")

    def test_http_success_alone_or_wrong_application_code_is_insufficient(self):
        for code in [None, False, True, 0, 2, 200, 1.0, "1"]:
            with self.subTest(code_type=type(code).__name__):
                with self.assertRaises(RESPONSE.CredentialResponseError):
                    RESPONSE.extract_sip_password({"response_code": code, "data": {"password": 54321098}})

    def test_malformed_data_or_password_types_do_not_become_credentials(self):
        for data in [None, [], {}, {"password": False}, {"password": 123.5}, {"password": ""}]:
            with self.assertRaises(RESPONSE.CredentialResponseError):
                RESPONSE.extract_sip_password({"response_code": 1, "data": data})

    def test_challenge_or_locked_account_stops_even_with_a_password_field(self):
        for message in ["Enter OTP", "CAPTCHA required", "Account locked", "SMS code required"]:
            with self.assertRaises(RESPONSE.CredentialResponseError):
                RESPONSE.extract_sip_password({"response_code": 1, "data": {"password": 54321098}, "response_message": message})

    def test_diagnostics_keep_schema_and_classification_without_secret_values(self):
        response = {"response_code": 1, "response_message": "Success synthetic-secret-value",
                    "data": {"password": 54321098, "token": "synthetic-token-value"},
                    "synthetic-private-key": "synthetic-private-value"}
        metadata = RESPONSE.diagnostic_metadata(response)
        self.assertEqual(metadata["response_code"], 1)
        self.assertEqual(metadata["password_field_type"], "int")
        self.assertEqual(metadata["message_class"], "success")
        self.assertEqual(metadata["other_root_fields_count"], 1)
        encoded = json.dumps(metadata)
        for forbidden in ["54321098", "synthetic-secret-value", "synthetic-token-value", "synthetic-private-key", "synthetic-private-value"]:
            self.assertNotIn(forbidden, encoded)


if __name__ == "__main__":
    unittest.main()
