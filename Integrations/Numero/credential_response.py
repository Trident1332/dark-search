"""Pure parsing of a Numero login response; no network or persistence.

The captured successful contract is response_code=1 and data.password as an
integer. Tokens, account details, and the original message are never returned
by the diagnostic metadata helper.
"""

from credential_value import sip_password


class CredentialResponseError(ValueError):
    pass


def message_class(response: object) -> str:
    message = response.get("response_message") if isinstance(response, dict) else None
    text = message.lower() if isinstance(message, str) else ""
    if any(word in text for word in ("captcha", "otp", "verification code", "one-time", "sms code")):
        return "human_verification_required"
    if any(word in text for word in ("account locked", "account blocked", "too many attempts")):
        return "account_restricted"
    if "version" in text:
        return "app_version_related"
    if "device" in text:
        return "device_related"
    if "success" in text:
        return "success"
    if any(word in text for word in ("invalid", "incorrect", "error", "failed")):
        return "provider_rejected"
    return "unclassified"


def extract_sip_password(response: object) -> str:
    if not isinstance(response, dict):
        raise CredentialResponseError("response_not_object")
    classification = message_class(response)
    if classification in ("human_verification_required", "account_restricted"):
        raise CredentialResponseError(classification)
    code = response.get("response_code")
    if type(code) is not int or code != 1:
        raise CredentialResponseError("provider_success_code_missing_or_rejected")
    data = response.get("data")
    if not isinstance(data, dict):
        raise CredentialResponseError("credential_data_not_object")
    password = sip_password(data.get("password"))
    if password is None:
        raise CredentialResponseError("no_valid_sip_credential")
    return password


def diagnostic_metadata(response: object) -> dict:
    result = {"response_type": type(response).__name__, "message_class": message_class(response)}
    if not isinstance(response, dict):
        return result
    known = ("data", "response_code", "response_message", "platform", "response_time", "response_id", "queries_count")
    result["known_root_fields_types"] = {key: type(response[key]).__name__ for key in known if key in response}
    result["other_root_fields_count"] = len(set(response) - set(known))
    code = response.get("response_code")
    if type(code) is int and -9999 <= code <= 9999:
        result["response_code"] = code
    data = response.get("data")
    if isinstance(data, dict):
        result["password_field_present"] = "password" in data
        if "password" in data:
            result["password_field_type"] = type(data["password"]).__name__
    return result
