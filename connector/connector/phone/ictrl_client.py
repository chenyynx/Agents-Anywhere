"""Minimal iCTRL v1 client for the AA Phone Bridge.

Only the request-path primitives are implemented here: X25519 pairing (pure
Python, same as the official ``ictrl_rpc.py``; Apache-2.0) and the HMAC-SHA256
envelope. The device's own ``/skill`` and ``/schema`` stay the source of truth;
this client never hard-codes method semantics.

The token store is keyed by the local bridge address (``127.0.0.1:18200``), so
several runs of AA share one pairing and a re-pair overwrites it.
"""

from __future__ import annotations

import base64
import hashlib
import hmac
import json
import os
import secrets
import tempfile
import time
from pathlib import Path
from typing import Any

import httpx

LABEL_MAC = b"ictrl-v1|mac"
LABEL_ENC_REQ = b"ictrl-v1|enc-req"
LABEL_ENC_RESP = b"ictrl-v1|enc-resp"
LABEL_PAIR = b"ictrl-pair"
LABEL_WRAP = b"ictrl-wrap"
X25519_BASE = (9).to_bytes(32, "little")


class IctrlError(RuntimeError):
    pass


class IctrlPairingRequired(IctrlError):
    pass


def _hmac(key: bytes, data: bytes) -> bytes:
    return hmac.new(key, data, hashlib.sha256).digest()


def _keystream_xor(key: bytes, nonce: bytes, data: bytes) -> bytes:
    out = bytearray()
    counter = 0
    while len(out) < len(data):
        out += _hmac(key, nonce + counter.to_bytes(4, "big"))
        counter += 1
    return bytes(a ^ b for a, b in zip(data, out))


def _x25519(scalar: bytes, u: bytes) -> bytes:
    """RFC 7748 X25519; the same pure-Python ladder as iCTRL's official client."""
    p = 2**255 - 19
    k = bytearray(scalar)
    k[0] &= 248
    k[31] &= 127
    k[31] |= 64
    k = int.from_bytes(k, "little")
    x1 = int.from_bytes(u, "little") & ((1 << 255) - 1)
    x2, z2, x3, z3, swap = 1, 0, x1, 1, 0
    for t in reversed(range(255)):
        bit = (k >> t) & 1
        swap ^= bit
        if swap:
            x2, x3, z2, z3 = x3, x2, z3, z2
        swap = bit
        a, b = (x2 + z2) % p, (x2 - z2) % p
        aa, bb = a * a % p, b * b % p
        e = (aa - bb) % p
        c, d = (x3 + z3) % p, (x3 - z3) % p
        da, cb = d * a % p, c * b % p
        x3 = (da + cb) ** 2 % p
        z3 = x1 * (da - cb) ** 2 % p
        x2 = aa * bb % p
        z2 = e * (aa + 121665 * e) % p
    if swap:
        x2, z2 = x3, z3
    return (x2 * pow(z2, p - 2, p) % p).to_bytes(32, "little")


def default_token_path() -> Path:
    from connector.paths import connector_data_dir

    return connector_data_dir() / "ictrl-token.json"


def load_record(token_path: Path, base_url: str) -> dict[str, Any] | None:
    try:
        data = json.loads(token_path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    record = data.get(base_url) if isinstance(data, dict) else None
    if (
        not isinstance(record, dict)
        or not isinstance(record.get("key"), str)
        or not isinstance(record.get("tok"), str)
    ):
        return None
    return record


def save_record(token_path: Path, base_url: str, record: dict[str, Any]) -> None:
    try:
        data = json.loads(token_path.read_text(encoding="utf-8"))
        if not isinstance(data, dict):
            data = {}
    except (OSError, ValueError):
        data = {}
    data[base_url] = record
    token_path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(
        prefix=".ictrl-token-", dir=str(token_path.parent)
    )
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(data, handle, indent=2)
        os.chmod(tmp, 0o600)
        os.replace(tmp, token_path)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


async def pair(
    base_url: str,
    client_name: str,
    *,
    token_path: Path | None = None,
    timeout: float = 90.0,
) -> dict[str, Any]:
    """Pair through the local bridge; blocks until the phone taps Allow."""
    token_path = token_path or default_token_path()
    priv = secrets.token_bytes(32)
    pub = _x25519(priv, X25519_BASE)
    async with httpx.AsyncClient(timeout=timeout, trust_env=False) as client:
        response = await client.post(
            f"{base_url}/pair",
            json={
                "client_name": client_name,
                "pub": base64.b64encode(pub).decode("ascii"),
            },
        )
    if response.status_code != 200:
        raise IctrlError(
            f"pair failed ({response.status_code}): {response.text[:200]}"
        )
    payload = response.json()
    device_pub = base64.b64decode(payload["pub"])
    shared = _x25519(priv, device_pub)
    wrap = _hmac(shared, LABEL_PAIR + pub + device_pub)
    pad = _hmac(wrap, LABEL_WRAP)
    wrapped = bytes.fromhex(payload["token_ct"])
    key = bytes(a ^ b for a, b in zip(wrapped, pad))
    record = {
        "tok": hashlib.sha256(key).digest()[:4].hex(),
        "key": key.hex(),
        "client_name": client_name,
        "expires": payload.get("expires"),
    }
    save_record(token_path, base_url, record)
    return {
        "deviceId": payload.get("device_id"),
        "expires": payload.get("expires"),
        "fingerprint": hashlib.sha256(pub).hexdigest()[:8],
    }


async def call(
    base_url: str,
    method: str,
    params: dict[str, Any] | None = None,
    *,
    token_path: Path | None = None,
    timeout: float = 60.0,
) -> dict[str, Any]:
    token_path = token_path or default_token_path()
    record = load_record(token_path, base_url)
    if record is None:
        raise IctrlPairingRequired("no iCTRL token; run phone_pair first")
    key = bytes.fromhex(record["key"])
    tok = record["tok"]
    body = json.dumps(
        {
            "jsonrpc": "2.0",
            "method": method,
            "params": params or {},
            "id": 1,
        }
    ).encode()
    nonce = secrets.token_bytes(16)
    ts = int(time.time())
    k_enc = _hmac(key, LABEL_ENC_REQ + nonce)
    k_mac = _hmac(key, LABEL_MAC + nonce)
    ciphertext = _keystream_xor(k_enc, nonce, body)
    signed = (
        b"v1"
        + bytes.fromhex(tok)
        + ts.to_bytes(8, "big")
        + nonce
        + ciphertext
    )
    tag = _hmac(k_mac, signed)
    envelope = {
        "v": 1,
        "tok": tok,
        "ts": ts,
        "nonce": nonce.hex(),
        "ct": base64.b64encode(ciphertext).decode("ascii"),
        "tag": tag.hex(),
    }
    async with httpx.AsyncClient(timeout=timeout, trust_env=False) as client:
        response = await client.post(f"{base_url}/rpc", json=envelope)
    if response.status_code == 401:
        raise IctrlPairingRequired("iCTRL rejected the token; pair again")
    if response.status_code != 200:
        raise IctrlError(
            f"rpc failed ({response.status_code}): {response.text[:200]}"
        )
    payload = response.json()
    try:
        response_ct = base64.b64decode(payload["ct"])
        expected = _hmac(k_mac, b"resp" + nonce + response_ct)
        if not hmac.compare_digest(expected, bytes.fromhex(payload["tag"])):
            raise IctrlError("response MAC mismatch")
        k_enc_resp = _hmac(key, LABEL_ENC_RESP + nonce)
        plaintext = _keystream_xor(k_enc_resp, nonce, response_ct)
        decoded = json.loads(plaintext)
    except (KeyError, ValueError, TypeError) as exc:
        raise IctrlError("malformed encrypted response") from exc
    if not isinstance(decoded, dict):
        raise IctrlError("rpc response is not an object")
    return decoded


async def get_text(base_url: str, path: str, *, timeout: float = 10.0) -> str:
    async with httpx.AsyncClient(timeout=timeout, trust_env=False) as client:
        response = await client.get(f"{base_url}{path}")
    if response.status_code != 200:
        raise IctrlError(f"GET {path} failed ({response.status_code})")
    return response.text
