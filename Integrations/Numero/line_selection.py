"""Numero's observed per-call selection contract. No login, purchase, or retries."""
from __future__ import annotations

from dataclasses import dataclass
import datetime as dt
import json
import os
from pathlib import Path
import re
import ssl
import stat
import time
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET

API = "https://new-api.numeroesim.com/api/v2/"
HEADERS = {"language", "app_Version", "os", "Access-Key", "Security-Token", "Id-Client"}
LINE_GATEWAYS = {"us": "numero", "ca": "numero_ca"}


class SelectionError(Exception):
    """Only fixed diagnostic tags; never include provider bodies or credentials."""


def number(value):
    if isinstance(value, bool) or not isinstance(value, (str, int)):
        raise SelectionError("invalid_number")
    text = str(value)
    if not re.fullmatch(r"\+?1[2-9][0-9]{2}[2-9][0-9]{6}", text):
        raise SelectionError("invalid_number")
    return "+" + text.lstrip("+")


def flag(value, expected):
    return value is bool(expected) or (type(value) is int and value == expected)


def success(response):
    return isinstance(response, dict) and ((type(response.get("response_code")) is int and response["response_code"] == 1)
        or (type(response.get("response_code")) is str and response["response_code"] == "1"))


def owned_profile(response, owned, required_line):
    if required_line not in owned:
        raise SelectionError("line_not_bound_to_account")
    if not success(response) or not isinstance(response.get("data"), dict):
        raise SelectionError("profile_rejected")
    data = response["data"]
    rows = data.get("my_numbers")
    if not isinstance(rows, list) or len(rows) > 1000 or any(not isinstance(r, dict) for r in rows):
        raise SelectionError("profile_invalid")
    found = {}
    for line in owned:
        matches = []
        for row in rows:
            try:
                if number(row.get("number")) == owned[line]:
                    matches.append(row)
            except SelectionError:
                continue
        if len(matches) > 1 or (line == required_line and len(matches) != 1):
            raise SelectionError("owned_line_missing_or_ambiguous")
        found[line] = matches[0] if matches else None
    return data, found


def verify_selected(response, owned, line):
    data, found = owned_profile(response, owned, line)
    if not flag(data.get("private_number_is_selected"), 0):
        raise SelectionError("selection_not_verified")
    selected = []
    for row in data["my_numbers"]:
        value = row.get("is_selected")
        if not flag(value, 0) and not flag(value, 1):
            raise SelectionError("selection_not_verified")
        if flag(value, 1):
            selected.append(row)
    if len(selected) != 1 or selected[0] is not found[line] or any(
            row is not None and not flag(row.get("is_selected"), 0)
            for key, row in found.items() if key != line):
        raise SelectionError("selection_not_verified")


def private_bytes(path: Path, *, parent_private=False, owner=0):
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_uid != owner or info.st_nlink != 1 or stat.S_IMODE(info.st_mode) != 0o600 or info.st_size > 1048576:
        raise SelectionError("private_file_invalid")
    if parent_private:
        parent = path.parent.lstat()
        if not stat.S_ISDIR(parent.st_mode) or parent.st_uid != owner or stat.S_IMODE(parent.st_mode) != 0o700:
            raise SelectionError("private_directory_invalid")
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    try:
        actual = os.fstat(fd)
        if (actual.st_ino, actual.st_dev) != (info.st_ino, info.st_dev):
            raise SelectionError("private_file_changed")
        with os.fdopen(fd, "rb", closefd=False) as stream:
            return stream.read(1048577)
    finally:
        os.close(fd)


@dataclass(frozen=True, repr=False)
class BoundSession:
    account_user: str
    owned: dict
    headers: dict
    gateway: str = "numero"
    line_gateways: dict | None = None
    gateway_accounts: dict | None = None

    @property
    def account_key(self):
        # Id-Client identifies the provider account, including aliases sharing
        # a single selected-number state. It is never returned to the browser.
        return self.headers["Id-Client"]


def load_session(directory=Path("/root/search-numero"), gateway=None, *, line="us", owner=0, now=None,
                 gateway_directory=Path("/root/telicall/fs/conf/sip_profiles/external"), include_peer_accounts=True):
    lines = json.loads(private_bytes(directory / "lines.json", parent_private=True, owner=owner))
    if line not in LINE_GATEWAYS or not isinstance(lines, dict):
        raise SelectionError("line_configuration_invalid")
    if not isinstance(lines.get("lines"), dict):
        raise SelectionError("line_configuration_invalid")
    owned_config = {key: number(lines["lines"].get(key)) for key in LINE_GATEWAYS}
    if owned_config["us"] == owned_config["ca"] or lines.get("gateway") != "numero" or lines.get("authorized_seat") != "1001":
        raise SelectionError("line_configuration_invalid")
    explicit = "line_gateways" in lines
    mappings = lines.get("line_gateways") if explicit else {key: "numero" for key in LINE_GATEWAYS}
    if explicit and (not isinstance(mappings, dict) or any(
            key not in LINE_GATEWAYS or value != LINE_GATEWAYS[key] for key, value in mappings.items())):
        raise SelectionError("line_configuration_invalid")
    if line not in mappings:
        raise SelectionError("line_gateway_missing")
    gateway_name = mappings[line]
    session_directory = directory
    if explicit and line == "ca":
        accounts = directory / "accounts"
        info = accounts.lstat()
        if not stat.S_ISDIR(info.st_mode) or info.st_uid != owner or stat.S_IMODE(info.st_mode) != 0o700:
            raise SelectionError("private_directory_invalid")
        session_directory = accounts / "ca"
    saved = json.loads(private_bytes(session_directory / "api-session.json", parent_private=True, owner=owner))
    if not isinstance(saved, dict):
        raise SelectionError("session_binding_invalid")
    gateway = gateway or gateway_directory / (gateway_name + ".xml")
    xml = private_bytes(gateway, owner=owner)
    if b"<!DOCTYPE" in xml.upper() or b"<!ENTITY" in xml.upper():
        raise SelectionError("gateway_invalid")
    roots = [g for g in ET.fromstring(xml).iter("gateway") if g.get("name") == gateway_name]
    if len(roots) != 1:
        raise SelectionError("gateway_invalid")
    if explicit:
        identity = roots[0].findall("param[@name='caller-id-in-from']")
        if len(identity) != 1 or identity[0].get("value", "").lower() not in ("false", "true"):
            raise SelectionError("gateway_identity_invalid")
    usernames = roots[0].findall("param[@name='username']")
    if len(usernames) != 1:
        raise SelectionError("gateway_invalid")
    user = usernames[0].get("value", "")
    if not re.fullmatch(r"\+?[1-9][0-9]{5,14}", user) or user == "1001":
        raise SelectionError("gateway_invalid")
    saved_owned = saved.get("owned_lines")
    if not isinstance(saved_owned, dict) or not saved_owned or line not in saved_owned or any(
            key not in owned_config or value != owned_config[key] for key, value in saved_owned.items()):
        raise SelectionError("session_binding_invalid")
    # A legacy US session may name both historical DIDs. Explicit mapping
    # limits its effective allowlist to this account's requested line.
    owned = {key: value for key, value in saved_owned.items() if mappings.get(key) == gateway_name}
    binding, headers = saved.get("account_binding"), saved.get("headers")
    if type(saved.get("schema_version")) is not int or saved["schema_version"] != 1 or not isinstance(binding, dict) or binding.get("gateway") != gateway_name or binding.get("username") != user:
        raise SelectionError("session_binding_invalid")
    if not isinstance(headers, dict) or set(headers) != HEADERS or headers.get("language") != "english" or headers.get("Id-Client") != binding.get("id_client"):
        raise SelectionError("session_headers_invalid")
    for value in headers.values():
        if not isinstance(value, str) or not value or len(value) > 8192 or any(ord(c) < 32 or ord(c) == 127 for c in value):
            raise SelectionError("session_headers_invalid")
    if not re.fullmatch(r"[1-9][0-9]{0,19}", headers["Id-Client"]):
        raise SelectionError("session_binding_invalid")
    if "provider_expires_utc" in saved:
        try:
            if not isinstance(saved["provider_expires_utc"], str):
                raise ValueError()
            expiry = dt.datetime.fromisoformat(saved["provider_expires_utc"].replace("Z", "+00:00"))
            if expiry.tzinfo is None or expiry <= (now or dt.datetime.now(dt.timezone.utc)):
                raise ValueError()
        except (ValueError, TypeError):
            raise SelectionError("session_expired") from None
    accounts = {gateway_name: headers["Id-Client"]}
    if explicit and include_peer_accounts:
        other = "ca" if line == "us" else "us"
        if other in mappings:
            try:
                peer = load_session(directory, line=other, owner=owner, now=now,
                    gateway_directory=gateway_directory, include_peer_accounts=False)
                accounts[peer.gateway] = peer.account_key
            except (SelectionError, OSError, ValueError, TypeError, ET.ParseError):
                pass  # Unknown peer identity cannot exempt its active calls.
    return BoundSession(user, owned, dict(headers), gateway_name, dict(mappings), accounts)


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None


class Provider:
    def __init__(self, session):
        self.session = session
        self.deadline = time.monotonic() + 15
        context = ssl.create_default_context()
        context.minimum_version = ssl.TLSVersion.TLSv1_2
        self.opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect(), urllib.request.HTTPSHandler(context=context))

    def request(self, path, fields=None):
        if path not in ("my-active-numbers-dial", "change-number") or (path == "change-number" and fields is None) or (fields is not None and (path != "change-number" or set(fields) != {"new_number"})):
            raise SelectionError("endpoint_not_allowed")
        if fields is not None and (not isinstance(fields["new_number"], str) or number(fields["new_number"]) not in self.session.owned.values()):
            raise SelectionError("number_not_allowed")
        headers = dict(self.session.headers)
        headers["Accept"] = "application/json"
        if fields is not None:
            headers["Content-Type"] = "application/x-www-form-urlencoded; charset=UTF-8"
        request = urllib.request.Request(API + path, headers=headers,
            data=urllib.parse.urlencode(fields).encode("ascii") if fields is not None else None,
            method="POST" if fields is not None else "GET")
        try:
            remaining = self.deadline - time.monotonic()
            if remaining <= 0:
                raise SelectionError("provider_unavailable")
            with self.opener.open(request, timeout=min(5, remaining)) as response:
                data = bytearray()
                while True:
                    if time.monotonic() >= self.deadline:
                        raise SelectionError("provider_unavailable")
                    chunk = response.read1(min(8192, 1048577 - len(data)))
                    if not chunk:
                        break
                    data.extend(chunk)
                    if len(data) > 1048576:
                        raise SelectionError("provider_unavailable")
                if response.status != 200:
                    raise SelectionError("provider_unavailable")
        except urllib.error.HTTPError as error:
            error.close()
            raise SelectionError("provider_rejected") from None
        except (OSError, ValueError):
            raise SelectionError("provider_unavailable") from None
        try:
            answer = json.loads(data)
        except (ValueError, UnicodeError):
            raise SelectionError("provider_response_invalid") from None
        if not success(answer):
            # Observed provider expiry response. Never include its free-form
            # message or body in exceptions/logs.
            code = answer.get("response_code") if isinstance(answer, dict) else None
            if (type(code) is int and code == -9999) or (type(code) is str and code == "-9999"):
                raise SelectionError("session_expired")
            raise SelectionError("provider_rejected")
        return answer


def select_line(session, provider, line, validate_call):
    if line not in ("us", "ca") or line not in session.owned:
        raise SelectionError("invalid_line")
    validate_call()
    _, found = owned_profile(provider.request("my-active-numbers-dial"), session.owned, line)
    # Preserve the provider's exact raw number representation, including its +.
    raw = str(found[line]["number"])
    validate_call()
    if not success(provider.request("change-number", {"new_number": raw})):
        raise SelectionError("provider_rejected")
    validate_call()
    verification = provider.request("my-active-numbers-dial")
    verify_selected(verification, session.owned, line)
    validate_call()
    return {"caller_id": session.owned[line][1:], "account_user": session.account_user,
            "gateway": session.gateway}
