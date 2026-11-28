from __future__ import annotations

import base64
import hashlib
import hmac
import json

import pytest

from connector.phone import ictrl_client


class FakeResponse:
    def __init__(self, status_code: int, payload: dict):
        self.status_code = status_code
        self._payload = payload
        self.text = json.dumps(payload)

    def json(self):
        return self._payload


class FakeHttpClient:
    def __init__(self, handler):
        self.handler = handler

    async def __aenter__(self):
        return self

    async def __aexit__(self, *args):
        return False

    async def post(self, url, *, json=None, **kwargs):
        return self.handler(url, json)


def test_keystream_roundtrip():
    key = b"k" * 32
    nonce = b"n" * 16
    plaintext = b"hello phone bridge" * 100
    ciphertext = ictrl_client._keystream_xor(key, nonce, plaintext)
    assert ciphertext != plaintext
    assert ictrl_client._keystream_xor(key, nonce, ciphertext) == plaintext


def test_token_store_roundtrip(tmp_path):
    path = tmp_path / "token.json"
    record = {"key": "00" * 32, "tok": "aabbccdd", "client_name": "AA"}
    ictrl_client.save_record(path, "127.0.0.1:18200", record)
    assert ictrl_client.load_record(path, "127.0.0.1:18200") == record
    assert ictrl_client.load_record(path, "127.0.0.1:9999") is None
    assert oct(path.stat().st_mode & 0o777) == "0o600"


def test_pair_derives_the_same_key(monkeypatch, tmp_path):
    device_private = bytes(range(1, 33))

    def handler(url, payload):
        assert url.endswith("/pair")
        client_pub = base64.b64decode(payload["pub"])
        device_pub = ictrl_client._x25519(
            device_private, ictrl_client.X25519_BASE
        )
        shared = ictrl_client._x25519(device_private, client_pub)
        wrap = ictrl_client._hmac(
            shared, ictrl_client.LABEL_PAIR + client_pub + device_pub
        )
        pad = ictrl_client._hmac(wrap, ictrl_client.LABEL_WRAP)
        key = b"a" * 32
        token_ct = bytes(a ^ b for a, b in zip(key, pad))
        return FakeResponse(
            200,
            {
                "pub": base64.b64encode(device_pub).decode(),
                "token_ct": token_ct.hex(),
                "expires": "2026-12-28T00:00:00Z",
            },
        )

    monkeypatch.setattr(
        ictrl_client.httpx,
        "AsyncClient",
        lambda **kwargs: FakeHttpClient(handler),
    )
    path = tmp_path / "token.json"

    import asyncio

    result = asyncio.run(
        ictrl_client.pair("http://127.0.0.1:18200", "AA", token_path=path)
    )
    record = ictrl_client.load_record(path, "http://127.0.0.1:18200")
    assert result["fingerprint"]
    assert record is not None
    assert record["key"] == (b"a" * 32).hex()


def test_call_seals_and_opens_the_response(monkeypatch, tmp_path):
    key = bytes(range(32))
    tok = hashlib.sha256(key).digest()[:4].hex()
    path = tmp_path / "token.json"
    ictrl_client.save_record(
        path,
        "http://127.0.0.1:18200",
        {"key": key.hex(), "tok": tok, "client_name": "AA"},
    )

    def handler(url, envelope):
        assert url.endswith("/rpc")
        assert envelope["v"] == 1
        assert envelope["tok"] == tok
        nonce = bytes.fromhex(envelope["nonce"])
        ct = base64.b64decode(envelope["ct"])
        k_mac = ictrl_client._hmac(key, ictrl_client.LABEL_MAC + nonce)
        signed = (
            b"v1"
            + bytes.fromhex(tok)
            + int(envelope["ts"]).to_bytes(8, "big")
            + nonce
            + ct
        )
        assert hmac.compare_digest(
            bytes.fromhex(envelope["tag"]),
            ictrl_client._hmac(k_mac, signed),
        )
        k_enc = ictrl_client._hmac(key, ictrl_client.LABEL_ENC_REQ + nonce)
        request = json.loads(ictrl_client._keystream_xor(k_enc, nonce, ct))
        assert request["method"] == "device_info"
        response = json.dumps(
            {"jsonrpc": "2.0", "id": 1, "result": {"ok": True}}
        ).encode()
        k_enc_resp = ictrl_client._hmac(
            key, ictrl_client.LABEL_ENC_RESP + nonce
        )
        response_ct = ictrl_client._keystream_xor(k_enc_resp, nonce, response)
        response_tag = ictrl_client._hmac(
            k_mac, b"resp" + nonce + response_ct
        )
        return FakeResponse(
            200,
            {
                "ct": base64.b64encode(response_ct).decode(),
                "tag": response_tag.hex(),
            },
        )

    monkeypatch.setattr(
        ictrl_client.httpx,
        "AsyncClient",
        lambda **kwargs: FakeHttpClient(handler),
    )

    import asyncio

    result = asyncio.run(
        ictrl_client.call(
            "http://127.0.0.1:18200",
            "device_info",
            token_path=path,
        )
    )
    assert result["result"] == {"ok": True}


def test_call_without_token_requires_pairing(tmp_path):
    import asyncio

    with pytest.raises(ictrl_client.IctrlPairingRequired):
        asyncio.run(
            ictrl_client.call(
                "http://127.0.0.1:18200",
                "device_info",
                token_path=tmp_path / "missing.json",
            )
        )
