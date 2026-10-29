"""Validate the scalar SIP credential returned by an approved account login.

Captured Numero responses use an integer for data.password. Preserve its
decimal representation instead of treating a successful response as missing.
This module performs no login, network request, logging, or persistence.
"""


def sip_password(value: object) -> str | None:
    if isinstance(value, bool):
        return None
    if isinstance(value, int):
        if value <= 0:
            return None
        try:
            value = str(value)
        except ValueError:
            return None
    if not isinstance(value, str) or not value or len(value) > 4096:
        return None
    if any(ord(character) < 32 or ord(character) == 127 for character in value):
        return None
    return value
