"""Egress-only slimming for timeline payloads that carry image tool results.

The connector stores a tool result four ways: the structured ``result``, a
serialized copy in ``output``, and two aliases (``text`` / ``outputText``).
For an image result every copy carries the same base64 body, so one screenshot
can multiply into several megabytes on the wire.  Recovery has a hard byte
gate; a single such row can push an otherwise small delta over it and force a
full snapshot.

This module normalizes a *copy* of the payload at the outbound boundary:

* ``result`` is never touched — it is the source of truth for clients that
  render the image (and for the eventual thumbnail work).
* When (and only when) ``result`` contains a ``type=image`` block, ``output``
  becomes an English one-line summary, ``outputPreview`` repeats it and
  ``outputLength`` is its length.  The huge serialized copy and its aliases
  disappear.
* For every item, ``text`` / ``outputText`` are dropped when they are exactly
  the same string as ``output`` (pure duplicates, no information loss).

Storage is never modified: callers pass the egress copy and keep the stored
row as-is.  Every function is fail-open — any unexpected shape or exception
returns the original payload unchanged.
"""

from __future__ import annotations

import base64
import binascii
import json
import os
import threading
from collections import OrderedDict
from collections.abc import Mapping, Sequence
from dataclasses import dataclass
from typing import Any

from loguru import logger

from agent_server.core.models import TimelineItem

SLIM_ENV = "AA_TIMELINE_SLIM"
_DISABLED_VALUES = frozenset({"0", "false", "off", "no"})

#: Only the first 64 KiB of decoded image data is needed for every header
#: parser here; reading more of a multi-megabyte screenshot is wasted work.
IMAGE_HEADER_BYTES = 64 * 1024
_B64_HEADER_CHARS = ((IMAGE_HEADER_BYTES + 2) // 3) * 4

#: Bound the walk over ``result`` so a pathological/deep payload cannot turn
#: normalization into an unbounded traversal.  Real results are a flat list.
_MAX_BLOCKS = 100
_MAX_DEPTH = 4

_CACHE_MAX_ITEMS = 200
_CACHE_MAX_BYTES = 32 * 1024 * 1024


@dataclass(frozen=True)
class SlimStats:
    normalized: int = 0
    saved_bytes: int = 0

    def add(self, saved_bytes: int) -> SlimStats:
        if saved_bytes <= 0:
            return self
        return SlimStats(self.normalized + 1, self.saved_bytes + saved_bytes)

    def merge(self, other: SlimStats) -> SlimStats:
        return SlimStats(
            self.normalized + other.normalized,
            self.saved_bytes + other.saved_bytes,
        )


def slim_enabled() -> bool:
    """``AA_TIMELINE_SLIM=0`` is the one-switch rollback."""

    raw = os.environ.get(SLIM_ENV)
    if raw is None:
        return True
    return raw.strip().lower() not in _DISABLED_VALUES


# ---------------------------------------------------------------------------
# Cache
# ---------------------------------------------------------------------------

# The cache holds only the summary string, never the normalized content: a
# caller can hand us an already-normalized row with the same (id, seq), and
# reusing a cached "saved bytes" would then double-count it.  Re-applying the
# cached summary is cheap and keeps normalization idempotent.
_cache: OrderedDict[tuple[str, int], tuple[str, int]] = OrderedDict()
_cache_bytes = 0
_cache_lock = threading.Lock()


def _cache_key(item_id: Any, updated_seq: Any) -> tuple[str, int] | None:
    if isinstance(item_id, str) and item_id and isinstance(updated_seq, int):
        return (item_id, updated_seq)
    return None


def _cache_get(key: tuple[str, int] | None) -> str | None:
    if key is None:
        return None
    with _cache_lock:
        cached = _cache.get(key)
        if cached is None:
            return None
        _cache.move_to_end(key)
        return cached[0]


def _cache_put(key: tuple[str, int] | None, summary: str) -> None:
    global _cache_bytes
    if key is None or not summary:
        return
    size = len(summary.encode("utf-8"))
    if size <= 0 or size > _CACHE_MAX_BYTES:
        return
    with _cache_lock:
        previous = _cache.pop(key, None)
        if previous is not None:
            _cache_bytes -= previous[1]
        _cache[key] = (summary, size)
        _cache_bytes += size
        while _cache and (
            len(_cache) > _CACHE_MAX_ITEMS or _cache_bytes > _CACHE_MAX_BYTES
        ):
            _old_key, _old_value = _cache.popitem(last=False)
            _cache_bytes -= _old_value[1]


def _cache_clear() -> None:
    """Test hook; not called by production paths."""

    global _cache_bytes
    with _cache_lock:
        _cache.clear()
        _cache_bytes = 0


# ---------------------------------------------------------------------------
# Image discovery and summaries
# ---------------------------------------------------------------------------


def _collect_image_blocks(value: Any) -> list[Mapping[str, Any]]:
    """Image blocks in document order, bounded in depth and count.

    A tool result arrives as either a flat list of content blocks or a wrapper
    mapping whose ``content`` holds that list (the Anthropic tool_result shape).
    Only those two shapes are real for image results; anything deeper is
    ignored rather than searched, so a large unrelated payload cannot turn
    this into a deep traversal.
    """

    blocks: list[Mapping[str, Any]] = []
    _collect_image_blocks_into(value, blocks, depth=0)
    return blocks


def _collect_image_blocks_into(
    value: Any,
    blocks: list[Mapping[str, Any]],
    *,
    depth: int,
) -> None:
    if depth > _MAX_DEPTH or len(blocks) >= _MAX_BLOCKS:
        return
    if isinstance(value, Mapping):
        if value.get("type") == "image":
            blocks.append(value)
            return
        for key in ("content", "result"):
            nested = value.get(key)
            if nested is not None:
                _collect_image_blocks_into(nested, blocks, depth=depth + 1)
        return
    if isinstance(value, Sequence) and not isinstance(value, str | bytes | bytearray):
        for entry in value:
            if len(blocks) >= _MAX_BLOCKS:
                return
            _collect_image_blocks_into(entry, blocks, depth=depth + 1)


def summarize_images(result: Any) -> str | None:
    """English one-line-per-image summary, or ``None`` when not summarizable.

    ``None`` is deliberate: the caller then leaves the payload untouched.  A
    single image renders ``[Image] PNG · 1170×4100 · 559 KB``; several render
    ``[Image 1] …`` / ``[Image 2] …`` on separate lines.  A segment is omitted
    when the payload does not carry that fact (no dimensions = no size
    segment; no byte body = no size segment).
    """

    blocks = _collect_image_blocks(result)
    if not blocks:
        return None
    parts: list[str] = []
    multiple = len(blocks) > 1
    for index, block in enumerate(blocks, start=1):
        source = block.get("source")
        source = source if isinstance(source, Mapping) else block
        media_type = _first_string(
            source.get("media_type"),
            source.get("mediaType"),
            block.get("media_type"),
            block.get("mediaType"),
        )
        data = _first_string(source.get("data"), block.get("data"))
        url = _first_string(source.get("url"), block.get("url"))
        dimensions: tuple[int, int] | None = None
        byte_count: int | None = None
        if data is not None:
            data_url_type, base64_body = _split_data_url(data)
            if media_type is None:
                media_type = data_url_type
            byte_count = _base64_decoded_size(base64_body)
            if byte_count is None:
                return None
            prefix = _base64_prefix(base64_body)
            if prefix is None:
                return None
            dimensions = image_dimensions(prefix)
        elif url is None:
            # Neither inline bytes nor a URL: not an image block we can
            # describe.  Fail open rather than inventing a summary.
            return None

        segments = [_image_label(media_type)]
        if dimensions is not None:
            width, height = dimensions
            segments.append(f"{width}×{height}")
        if byte_count is not None:
            segments.append(_format_bytes(byte_count))
        prefix = f"[Image {index}]" if multiple else "[Image]"
        parts.append(f"{prefix} " + " · ".join(segments))
    return "\n".join(parts)


def _first_string(*values: Any) -> str | None:
    for value in values:
        if isinstance(value, str) and value:
            return value
    return None


def _split_data_url(value: str) -> tuple[str | None, str]:
    if value.startswith("data:"):
        header, separator, payload = value.partition(",")
        if separator and ";base64" in header.lower():
            media_type = header[len("data:") :].split(";", 1)[0] or None
            return media_type, payload
    return None, value


def _base64_decoded_size(value: str) -> int | None:
    """Decoded byte count without decoding the body.

    Only used for the summary.  Validation is structural (length, padding
    position); the header prefix is decoded strictly below, which is what
    catches a non-base64 body.  This keeps multi-megabyte screenshots from
    being copied/decoded just to state their size.
    """

    if not value or len(value) % 4 != 0:
        return None
    padding = 2 if value.endswith("==") else 1 if value.endswith("=") else 0
    body_end = len(value) - padding
    if "=" in value[:body_end]:
        return None
    return (len(value) // 4) * 3 - padding


def _base64_prefix(value: str) -> bytes | None:
    """Decode (and therefore validate) only the header-sized prefix.

    ``None`` means the body is not base64 at all — the caller then fails open
    and leaves the payload untouched rather than publishing a summary for
    bytes nobody can read.  A body whose first 64 KiB are valid but whose tail
    is not is left to the client; validating multi-megabyte tails on every
    egress would cost more than the summary saves.
    """

    prefix = value[:_B64_HEADER_CHARS]
    prefix = prefix[: len(prefix) - (len(prefix) % 4)]
    if not prefix:
        return None
    try:
        return base64.b64decode(prefix, validate=True)
    except (binascii.Error, ValueError):
        return None


def image_dimensions(data: bytes | bytearray) -> tuple[int, int] | None:
    """``(width, height)`` from a PNG/JPEG/GIF/WebP header, else ``None``."""

    try:
        return (
            _png_dimensions(data)
            or _gif_dimensions(data)
            or _webp_dimensions(data)
            or _jpeg_dimensions(data)
        )
    except Exception:  # noqa: BLE001 - header parsing is best effort
        return None


def _png_dimensions(data: bytes | bytearray) -> tuple[int, int] | None:
    if (
        len(data) >= 24
        and data[:8] == b"\x89PNG\r\n\x1a\n"
        and data[12:16] == b"IHDR"
    ):
        width = int.from_bytes(data[16:20], "big")
        height = int.from_bytes(data[20:24], "big")
        if width and height:
            return width, height
    return None


def _gif_dimensions(data: bytes | bytearray) -> tuple[int, int] | None:
    if len(data) >= 10 and data[:6] in (b"GIF87a", b"GIF89a"):
        width = int.from_bytes(data[6:8], "little")
        height = int.from_bytes(data[8:10], "little")
        if width and height:
            return width, height
    return None


def _webp_dimensions(data: bytes | bytearray) -> tuple[int, int] | None:
    if len(data) < 30 or data[:4] != b"RIFF" or data[8:12] != b"WEBP":
        return None
    chunk = data[12:16]
    if chunk == b"VP8X":
        width = int.from_bytes(data[24:27], "little") + 1
        height = int.from_bytes(data[27:30], "little") + 1
        return (width, height) if width and height else None
    if chunk == b"VP8 " and data[23:26] == b"\x9d\x01\x2a":
        width = int.from_bytes(data[26:28], "little") & 0x3FFF
        height = int.from_bytes(data[28:30], "little") & 0x3FFF
        return (width, height) if width and height else None
    if chunk == b"VP8L" and data[20] == 0x2F:
        bits = int.from_bytes(data[21:25], "little")
        width = (bits & 0x3FFF) + 1
        height = ((bits >> 14) & 0x3FFF) + 1
        return width, height
    return None


_JPEG_SOF_MARKERS = frozenset(
    {
        0xC0, 0xC1, 0xC2, 0xC3,
        0xC5, 0xC6, 0xC7,
        0xC9, 0xCA, 0xCB,
        0xCD, 0xCE, 0xCF,
    }
)


def _jpeg_dimensions(data: bytes | bytearray) -> tuple[int, int] | None:
    if len(data) < 4 or data[:2] != b"\xff\xd8":
        return None
    offset = 2
    while offset + 4 <= len(data):
        if data[offset] != 0xFF:
            offset += 1
            continue
        marker = data[offset + 1]
        if marker == 0xFF:  # fill byte between segments
            offset += 1
            continue
        if marker in (0xD8, 0xD9) or 0xD0 <= marker <= 0xD7:
            offset += 2
            continue
        if marker == 0xDA:  # start of scan: no frame header after this
            return None
        segment_length = int.from_bytes(data[offset + 2 : offset + 4], "big")
        if segment_length < 2:
            return None
        if marker in _JPEG_SOF_MARKERS:
            if offset + 9 > len(data):
                return None
            height = int.from_bytes(data[offset + 5 : offset + 7], "big")
            width = int.from_bytes(data[offset + 7 : offset + 9], "big")
            if width and height:
                return width, height
            return None
        offset += 2 + segment_length
    return None


def _image_label(media_type: str | None) -> str:
    if isinstance(media_type, str) and media_type.lower().startswith("image/"):
        subtype = media_type.split("/", 1)[1].strip().upper()
        if subtype:
            return {"JPG": "JPEG"}.get(subtype, subtype)
    return "IMAGE"


def _format_bytes(byte_count: int) -> str:
    if byte_count < 1024:
        return f"{byte_count} B"
    value = byte_count / 1024
    unit = "KB"
    if value >= 1024:
        value /= 1024
        unit = "MB"
    text = f"{value:.1f}"
    if text.endswith(".0"):
        text = text[:-2]
    return f"{text} {unit}"


# ---------------------------------------------------------------------------
# Normalization
# ---------------------------------------------------------------------------


def normalize_content(
    *,
    item_id: Any,
    updated_seq: Any,
    content: Any,
) -> tuple[Any, int]:
    """Return ``(normalized_content, saved_bytes)``; never mutates ``content``.

    ``saved_bytes`` is 0 exactly when the payload was left unchanged.
    """

    if not slim_enabled():
        return content, 0
    if not isinstance(content, Mapping) or not content:
        return content, 0
    key = _cache_key(item_id, updated_seq)
    try:
        cached_summary = _cache_get(key)
        if cached_summary is not None:
            return _apply_image_summary(content, cached_summary)
        result = content.get("result")
        image_blocks = _collect_image_blocks(result) if result is not None else []
        if image_blocks:
            output = content.get("output")
            if not isinstance(output, str):
                # Fail open: without the serialized field there is nothing to
                # compare aliases against and nothing safe to slim.
                return content, 0
            summary = summarize_images(result)
            if summary is None:
                return content, 0
            normalized, saved = _apply_image_summary(content, summary)
            if saved > 0:
                _cache_put(key, summary)
            return normalized, saved
        return _drop_duplicate_output_aliases(content)
    except Exception as exc:  # noqa: BLE001 - fail open on every unexpected shape
        logger.warning(
            "timeline payload slim failed item_id={} error={}",
            item_id,
            type(exc).__name__,
        )
        return content, 0


def _apply_image_summary(
    content: Mapping[str, Any],
    summary: str,
) -> tuple[Any, int]:
    output = content.get("output")
    if not isinstance(output, str):
        return content, 0
    normalized = dict(content)
    saved = 0
    for alias in ("text", "outputText"):
        value = normalized.get(alias)
        if isinstance(value, str) and value == output:
            saved += len(value.encode("utf-8"))
            del normalized[alias]
    saved += len(output.encode("utf-8")) - len(summary.encode("utf-8"))
    if saved <= 0:
        # Already normalized (the common second call from another endpoint).
        return content, 0
    normalized["output"] = summary
    normalized["outputPreview"] = summary
    normalized["outputLength"] = len(summary)
    return normalized, saved


def _drop_duplicate_output_aliases(content: Mapping[str, Any]) -> tuple[Any, int]:
    output = content.get("output")
    if not isinstance(output, str):
        return content, 0
    normalized = dict(content)
    saved = 0
    for alias in ("text", "outputText"):
        value = normalized.get(alias)
        if isinstance(value, str) and value == output:
            saved += len(value.encode("utf-8"))
            del normalized[alias]
    if saved <= 0:
        return content, 0
    return normalized, saved


def normalize_item_payload(item: Any) -> tuple[Any, int]:
    """Normalize one item mapping, returning ``(item, saved_bytes)``."""

    if not slim_enabled() or not isinstance(item, Mapping):
        return item, 0
    content = item.get("content")
    if not isinstance(content, Mapping) or not content:
        return item, 0
    normalized_content, saved = normalize_content(
        item_id=item.get("id"),
        updated_seq=item.get("updatedSeq"),
        content=content,
    )
    if saved <= 0:
        return item, 0
    normalized_item = dict(item)
    normalized_item["content"] = normalized_content
    return normalized_item, saved


def normalize_item_json(raw_item: str) -> tuple[str, int]:
    """Normalize an already-encoded item, reusing the string when unchanged.

    ``timeline_envelope_message`` splices encoded items straight into the live
    envelope, so this is the hot-path variant.  A cheap substring check keeps
    ordinary rows on the same one-scan path they had before.
    """

    if not slim_enabled() or '"type":"image"' not in raw_item:
        return raw_item, 0
    try:
        item = json.loads(raw_item)
    except (json.JSONDecodeError, ValueError):
        return raw_item, 0
    normalized, saved = normalize_item_payload(item)
    if saved <= 0:
        return raw_item, 0
    return (
        json.dumps(
            normalized,
            ensure_ascii=False,
            sort_keys=True,
            separators=(",", ":"),
        ),
        saved,
    )


def normalize_item_payloads(
    items: Sequence[Any],
) -> tuple[list[Any], SlimStats]:
    """Normalize a batch of raw item mappings (live envelopes, shares)."""

    normalized: list[Any] = []
    stats = SlimStats()
    for item in items:
        new_item, saved_bytes = normalize_item_payload(item)
        normalized.append(new_item)
        stats = stats.add(saved_bytes)
    return normalized, stats


def normalize_timeline_item(item: TimelineItem) -> tuple[TimelineItem, int]:
    """Normalize a validated timeline row for an HTTP response."""

    normalized_content, saved = normalize_content(
        item_id=item.id,
        updated_seq=item.updatedSeq,
        content=item.content,
    )
    if saved <= 0:
        return item, 0
    return item.model_copy(update={"content": normalized_content}), saved


def normalize_timeline_items(
    items: Sequence[TimelineItem],
) -> tuple[list[TimelineItem], SlimStats]:
    normalized: list[TimelineItem] = []
    stats = SlimStats()
    for item in items:
        new_item, saved = normalize_timeline_item(item)
        normalized.append(new_item)
        stats = stats.add(saved)
    return normalized, stats


def log_slim_stats(
    *,
    surface: str,
    session_id: str | None,
    stats: SlimStats,
) -> None:
    if stats.normalized <= 0:
        return
    logger.info(
        "timeline payload slim surface={} session_id={} normalized_items={} "
        "saved_bytes={}",
        surface,
        session_id,
        stats.normalized,
        stats.saved_bytes,
    )
