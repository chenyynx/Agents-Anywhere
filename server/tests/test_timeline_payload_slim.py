"""Egress-only payload slimming: duplicate aliases and image summaries."""

from __future__ import annotations

import base64
import json
import random

import pytest

from agent_server.services import timeline_payload
from agent_server.services.timeline_payload import (
    SLIM_ENV,
    image_dimensions,
    normalize_item_json,
    normalize_item_payload,
    normalize_content,
    slim_enabled,
    summarize_images,
)


@pytest.fixture(autouse=True)
def _isolated_slim(monkeypatch):
    monkeypatch.delenv(SLIM_ENV, raising=False)
    timeline_payload._cache_clear()
    yield
    timeline_payload._cache_clear()


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------


def _png(width: int = 1170, height: int = 4100, padding: int = 0) -> bytes:
    return (
        b"\x89PNG\r\n\x1a\n"
        + (13).to_bytes(4, "big")
        + b"IHDR"
        + width.to_bytes(4, "big")
        + height.to_bytes(4, "big")
        + bytes([8, 6, 0, 0, 0])
        + b"\x00\x00\x00\x00"
        + b"\x00" * padding
    )


def _gif(width: int = 10, height: int = 20) -> bytes:
    return b"GIF89a" + width.to_bytes(2, "little") + height.to_bytes(2, "little") + b"\x00" * 8


def _jpeg(width: int = 10, height: int = 20) -> bytes:
    # SOF0 with a segment length of 17, then precision/height/width.
    return (
        b"\xff\xd8\xff\xc0\x00\x11\x08"
        + height.to_bytes(2, "big")
        + width.to_bytes(2, "big")
        + b"\x00" * 12
    )


def _webp(width: int = 10, height: int = 20) -> bytes:
    return (
        b"RIFF"
        + (22).to_bytes(4, "little")
        + b"WEBP"
        + b"VP8X"
        + (10).to_bytes(4, "little")
        + b"\x00" * 4
        + (width - 1).to_bytes(3, "little")
        + (height - 1).to_bytes(3, "little")
        + b"\x00"
    )


def _b64(value: bytes) -> str:
    return base64.b64encode(value).decode("ascii")


def _image_result(data: str, *, media_type: str = "image/png") -> list[dict]:
    return [
        {
            "type": "image",
            "source": {
                "type": "base64",
                "media_type": media_type,
                "data": data,
            },
        }
    ]


def _tool_item(
    *,
    item_id: str = "tool-1",
    updated_seq: int = 7,
    result=None,
    output: str | None = None,
    text: str | None = None,
    output_text: str | None = None,
    extra: dict | None = None,
) -> dict:
    if result is not None and output is None:
        output = json.dumps(
            result,
            ensure_ascii=False,
            sort_keys=True,
            separators=(",", ":"),
        )
    content = {
        "kind": "tool_result",
        "toolUseId": item_id,
        "output": output,
        "text": output if text is None else text,
        "outputText": output if output_text is None else output_text,
        "outputPreview": (output or "")[-4000:],
        "outputLength": len(output or ""),
    }
    if result is not None:
        content["result"] = result
    if extra:
        content.update(extra)
    return {
        "id": item_id,
        "sessionId": "session-1",
        "type": "tool",
        "status": "done",
        "role": "tool",
        "content": content,
        "source": {"runtime": "claude", "sessionId": "thread-1", "itemId": item_id},
        "orderSeq": 1,
        "revision": 1,
        "updatedSeq": updated_seq,
        "contentHash": f"sha256:{item_id}",
    }


# ---------------------------------------------------------------------------
# Dimensions
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    ("payload", "expected"),
    [
        (_png(1170, 4100), (1170, 4100)),
        (_gif(12, 34), (12, 34)),
        (_jpeg(56, 78), (56, 78)),
        (_webp(90, 123), (90, 123)),
        (b"not an image", None),
        (b"", None),
    ],
)
def test_image_dimensions_reads_each_supported_header(payload, expected) -> None:
    assert image_dimensions(payload) == expected


# ---------------------------------------------------------------------------
# Summaries
# ---------------------------------------------------------------------------


def test_summary_uses_the_single_image_form_and_reports_a_readable_size() -> None:
    summary = summarize_images(_image_result(_b64(_png(padding=600_000))))

    # Exact string: iOS suppresses its text card only when the summary it
    # generates is byte-identical to this one.
    assert summary == "[Image] PNG · 1170×4100 · 586 KB"


def test_summary_numbers_multiple_images_and_puts_each_on_its_own_line() -> None:
    summary = summarize_images(
        _image_result(_b64(_png(10, 20)))
        + _image_result(_b64(_jpeg(30, 40)), media_type="image/jpeg")
    )

    assert summary is not None
    lines = summary.split("\n")
    assert len(lines) == 2
    assert lines[0].startswith("[Image 1] PNG · 10×20 · ")
    assert lines[1].startswith("[Image 2] JPEG · 30×40 · ")


def test_summary_omits_dimensions_when_the_header_is_unknown() -> None:
    summary = summarize_images(_image_result(_b64(b"hello world")))

    assert summary == "[Image] PNG · 11 B"


def test_summary_uppercases_an_unknown_image_subtype() -> None:
    summary = summarize_images(
        _image_result(_b64(b"hello world"), media_type="image/x-weird")
    )

    assert summary == "[Image] X-WEIRD · 11 B"


def test_summary_accepts_a_wrapper_mapping_and_data_url() -> None:
    data_url = "data:image/png;base64," + _b64(_png(3, 4))
    summary = summarize_images({"type": "tool_result", "content": _image_result(data_url)})

    assert summary is not None
    assert summary.startswith("[Image] PNG · 3×4 · ")


def test_summary_decodes_only_the_header_prefix(monkeypatch) -> None:
    """A multi-megabyte body is summarized from its header and length alone."""

    decoded_sizes: list[int] = []
    real_b64decode = timeline_payload.base64.b64decode

    def spy(data, *args, **kwargs):
        decoded_sizes.append(len(data))
        return real_b64decode(data, *args, **kwargs)

    monkeypatch.setattr(timeline_payload.base64, "b64decode", spy)
    data = _b64(_png(padding=5_000_000))
    summary = summarize_images(_image_result(data))

    assert summary == "[Image] PNG · 1170×4100 · 4.8 MB"
    assert decoded_sizes
    max_decoded_bytes = max(decoded_sizes) // 4 * 3
    assert max_decoded_bytes <= timeline_payload.IMAGE_HEADER_BYTES + 2


def test_block_cap_limits_the_summary_to_one_hundred_images() -> None:
    summary = summarize_images(_image_result(_b64(_png(10, 20))) * 150)

    assert summary is not None
    assert len(summary.split("\n")) == 100


def test_invalid_base64_refuses_to_summarize() -> None:
    assert summarize_images(_image_result("!!!!")) is None
    assert summarize_images(_image_result("abc")) is None


def test_invalid_base64_never_reaches_the_output_field() -> None:
    item = _tool_item(result=_image_result("!!!!"))
    original_output = item["content"]["output"]

    normalized, _saved = normalize_item_payload(item)

    assert normalized["content"]["output"] == original_output
    assert "[Image" not in normalized["content"]["output"]
    assert normalized["content"]["result"] == item["content"]["result"]


# ---------------------------------------------------------------------------
# Normalization
# ---------------------------------------------------------------------------


def test_image_item_replaces_output_and_removes_identical_aliases() -> None:
    result = _image_result(_b64(_png()))
    item = _tool_item(result=result)
    original_result = json.loads(json.dumps(result))

    normalized, saved = normalize_item_payload(item)

    content = normalized["content"]
    assert saved > 0
    assert content["result"] == original_result
    assert content["output"].startswith("[Image] PNG · 1170×4100 · ")
    assert "base64" not in content["output"]
    assert content["outputPreview"] == content["output"]
    assert content["outputLength"] == len(content["output"])
    assert "text" not in content
    assert "outputText" not in content
    assert normalized["contentHash"] == item["contentHash"]
    # The stored (input) item is untouched.
    assert item["content"]["text"] == item["content"]["output"]
    assert "base64" in item["content"]["output"]


def test_different_alias_copies_are_kept() -> None:
    result = _image_result(_b64(_png()))
    item = _tool_item(result=result)
    item["content"]["text"] = "a genuinely different rendering"
    item["content"]["outputText"] = "another different rendering"

    normalized, _saved = normalize_item_payload(item)

    assert normalized["content"]["text"] == "a genuinely different rendering"
    assert normalized["content"]["outputText"] == "another different rendering"


def test_missing_output_is_left_completely_alone() -> None:
    result = _image_result(_b64(_png()))
    item = _tool_item(result=result)
    del item["content"]["output"]

    normalized, saved = normalize_item_payload(item)

    assert saved == 0
    assert normalized is item
    assert "base64" in normalized["content"]["text"]


def test_non_image_item_only_drops_identical_output_aliases() -> None:
    item = _tool_item(output="plain output")

    normalized, saved = normalize_item_payload(item)

    assert saved > 0
    assert normalized["content"]["output"] == "plain output"
    assert "text" not in normalized["content"]
    assert "outputText" not in normalized["content"]


def test_mixed_text_and_image_result_keeps_the_human_readable_output() -> None:
    result = [
        {"type": "text", "text": "Screenshot captured of the checkout page."},
        *_image_result(_b64(_png())),
    ]
    item = _tool_item(
        result=result,
        output="Screenshot captured of the checkout page.",
    )

    normalized, saved = normalize_item_payload(item)

    assert saved > 0
    # The output keeps the human text; only the exact aliases disappear.
    assert normalized["content"]["output"] == "Screenshot captured of the checkout page."
    assert "text" not in normalized["content"]
    assert "outputText" not in normalized["content"]
    assert normalized["content"]["result"] == result


def test_url_only_image_block_fails_open() -> None:
    result = [
        {
            "type": "image",
            "source": {"type": "url", "url": "https://example.invalid/shot.png"},
        }
    ]
    item = _tool_item(result=result)
    original_output = item["content"]["output"]

    normalized, _saved = normalize_item_payload(item)

    # No summary is invented; the URL stays recoverable from `output`.
    assert normalized["content"]["output"] == original_output
    assert "https://example.invalid/shot.png" in normalized["content"]["output"]
    assert "[Image" not in normalized["content"]["output"]


def test_node_budget_fails_open_instead_of_summarizing_a_partial_walk() -> None:
    filler = [{"type": "tool_use", "id": f"block-{index}"} for index in range(2000)]
    result = [*filler, *_image_result(_b64(_png()))]

    assert summarize_images(result) is None
    item = _tool_item(result=result)
    original_output = item["content"]["output"]
    normalized, _saved = normalize_item_payload(item)

    assert normalized["content"]["output"] == original_output
    assert "base64" in normalized["content"]["output"]
    assert normalized["content"]["result"] == result


def test_node_budget_counts_nodes_at_the_depth_boundary() -> None:
    # The big list sits at depth 4; its entries are at depth 5 and are not
    # scanned, but they are still iterated. They must consume the budget.
    big = [{"x": index} for index in range(2000)]
    result = [{"content": [{"content": big}]}]

    assert summarize_images(result) is None
    item = _tool_item(result=result)
    normalized, _saved = normalize_item_payload(item)

    assert normalized["content"]["output"] == item["content"]["output"]


def test_depth_bound_ignores_an_image_nested_too_deep() -> None:
    nested: dict = {"type": "image", "source": {
        "type": "base64", "media_type": "image/png", "data": _b64(_png())}}
    for _ in range(8):
        nested = {"content": nested}

    assert summarize_images(nested) is None


def test_non_image_item_without_duplicate_aliases_is_unchanged() -> None:
    item = _tool_item(output="plain output", text="other", output_text="third")

    normalized, saved = normalize_item_payload(item)

    assert saved == 0
    assert normalized is item


def test_output_that_is_not_a_string_is_left_alone() -> None:
    item = _tool_item(result=None, output=None)
    item["content"]["output"] = {"result": [1, 2, 3]}
    item["content"]["text"] = {"result": [1, 2, 3]}

    normalized, saved = normalize_item_payload(item)

    assert saved == 0
    assert normalized is item


def test_normalization_is_idempotent() -> None:
    item = _tool_item(result=_image_result(_b64(_png())))

    first, first_saved = normalize_item_payload(item)
    second, second_saved = normalize_item_payload(first)

    assert first_saved > 0
    assert second_saved == 0
    assert second == first


def test_cache_separates_revisions_by_content_hash() -> None:
    png = _tool_item(result=_image_result(_b64(_png())))
    png["contentHash"] = "sha256:png"
    jpeg = _tool_item(
        result=_image_result(_b64(_jpeg()), media_type="image/jpeg"))
    jpeg["contentHash"] = "sha256:jpeg"

    first, _first_saved = normalize_item_payload(png)
    second, _second_saved = normalize_item_payload(jpeg)

    assert first["content"]["output"].startswith("[Image] PNG")
    assert second["content"]["output"].startswith("[Image] JPEG")


def test_cache_separates_revisions_by_updated_seq() -> None:
    png = _tool_item(updated_seq=1, result=_image_result(_b64(_png())))
    jpeg = _tool_item(
        updated_seq=2,
        result=_image_result(_b64(_jpeg()), media_type="image/jpeg"))

    first, _first_saved = normalize_item_payload(png)
    second, _second_saved = normalize_item_payload(jpeg)

    assert first["content"]["output"].startswith("[Image] PNG")
    assert second["content"]["output"].startswith("[Image] JPEG")


def test_second_normalization_uses_the_cached_summary(monkeypatch) -> None:
    item = _tool_item(result=_image_result(_b64(_png())))
    first, first_saved = normalize_item_payload(item)
    assert first_saved > 0

    calls = 0
    real_summarize = timeline_payload._summarize_blocks

    def spy(blocks):
        nonlocal calls
        calls += 1
        return real_summarize(blocks)

    monkeypatch.setattr(timeline_payload, "_summarize_blocks", spy)
    second, second_saved = normalize_item_payload(item)

    assert calls == 0
    assert second_saved == first_saved
    assert second["content"]["output"] == first["content"]["output"]


def test_switch_off_returns_the_original_object(monkeypatch) -> None:
    monkeypatch.setenv(SLIM_ENV, "0")
    item = _tool_item(result=_image_result(_b64(_png())))

    assert slim_enabled() is False
    normalized, saved = normalize_item_payload(item)

    assert saved == 0
    assert normalized is item


def test_content_without_result_does_not_gain_one() -> None:
    item = _tool_item(output="plain output")
    item["content"].pop("result", None)

    normalized, _saved = normalize_item_payload(item)

    assert "result" not in normalized["content"]


def test_encoded_item_round_trip_only_parses_image_candidates() -> None:
    item = _tool_item(result=_image_result(_b64(_png())))
    raw = json.dumps(item, ensure_ascii=False, sort_keys=True, separators=(",", ":"))

    encoded, saved = normalize_item_json(raw)
    assert saved > 0
    assert "[Image] PNG" in encoded

    plain_raw = json.dumps(
        _tool_item(output="plain"),
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
    )
    encoded_plain, plain_saved = normalize_item_json(plain_raw)
    assert plain_saved == 0
    assert encoded_plain is plain_raw


def test_cache_is_bounded() -> None:
    for index in range(250):
        normalize_item_payload(
            _tool_item(
                item_id=f"tool-{index}",
                updated_seq=index + 1,
                result=_image_result(_b64(_png(1, 1))),
            )
        )

    assert len(timeline_payload._cache) <= 200


def test_random_structured_content_never_raises() -> None:
    rng = random.Random(20261102)

    def build(depth: int):
        if depth <= 0:
            return rng.choice([None, True, 0, 1.5, "x", "y" * 20])
        choice = rng.randrange(4)
        if choice == 0:
            return [build(depth - 1) for _ in range(rng.randrange(4))]
        if choice == 1:
            return {
                "type": rng.choice(["image", "text", "tool_result", "base64"]),
                "content": build(depth - 1),
                "source": {"media_type": "image/png", "data": build(depth - 1)},
            }
        return build(depth - 1)

    for index in range(200):
        item = {
            "id": f"random-{index}",
            "updatedSeq": index,
            "content": {
                "result": build(3),
                "output": "x" * rng.randrange(200),
                "text": "x" * rng.randrange(200),
                "outputText": "x" * rng.randrange(200),
            },
        }
        normalized, saved = normalize_item_payload(item)
        assert isinstance(normalized, dict)
        assert saved >= 0


def test_normalize_content_reports_zero_for_empty_content() -> None:
    content, saved = normalize_content(item_id="x", updated_seq=1, content={})

    assert content == {}
    assert saved == 0
