import importlib.util
from pathlib import Path
import unittest


SOURCE = Path(__file__).resolve().parents[1] / "credential_value.py"
SPEC = importlib.util.spec_from_file_location("numero_credential_value", SOURCE)
CREDENTIAL = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CREDENTIAL)


class NumeroCredentialValueTests(unittest.TestCase):
    def test_numeric_response_credential_keeps_exact_decimal_representation(self):
        # Synthetic fixture, not an account credential.
        self.assertEqual(CREDENTIAL.sip_password(54321098), "54321098")
        self.assertEqual(CREDENTIAL.sip_password(12345678901234567890), "12345678901234567890")

    def test_string_credential_is_not_trimmed_or_numerically_reinterpreted(self):
        self.assertEqual(CREDENTIAL.sip_password("00123456"), "00123456")
        self.assertEqual(CREDENTIAL.sip_password(" a-test-value "), " a-test-value ")

    def test_noncredential_types_and_control_characters_are_rejected(self):
        for value in [None, True, False, 0, -1, 12.5, {}, [], "", "x" * 4097,
                      "line\rbreak", "line\nbreak", "zero\0byte", "tab\tbyte", "del\x7fbyte"]:
            with self.subTest(value_type=type(value).__name__):
                self.assertIsNone(CREDENTIAL.sip_password(value))


if __name__ == "__main__":
    unittest.main()
