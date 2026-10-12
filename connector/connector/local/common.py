from __future__ import annotations

import time
from pathlib import Path
from typing import Any, Awaitable, Callable


MAX_DIR_ENTRIES = 500
MAX_OUTPUT_CHARS = 64_000
MAX_READ_TEXT_BYTES = 4 * 1024 * 1024

# Workspace path disambiguation (fs.resolvePath). The traversal is deliberately
# bounded: it is read-only, stays inside the workspace root, and returns as soon
# as a limit is hit rather than risking an unbounded scan.
RESOLVE_SKIP_DIRS = frozenset(
    {
        ".git",
        "node_modules",
        ".venv",
        "venv",
        "__pycache__",
        "dist",
        "build",
        ".build",
        "Pods",
        ".next",
        ".ruff_cache",
        ".pytest_cache",
    }
)
RESOLVE_MAX_DEPTH = 12
RESOLVE_MAX_ENTRIES = 20000
RESOLVE_MAX_SECONDS = 2.0
RESOLVE_MAX_CANDIDATES = 20

# Workspace file listing (fs.listFiles). The client builds an "is this a real
# file?" suffix set from this list, so it must be bounded: a bounded BFS for
# non-git roots and a hard wall-clock budget in all cases. `truncated` reports
# when any limit was hit so the client can refresh instead of trusting a
# partial list.
LIST_MAX_DEPTH = 8
LIST_MAX_FILES_PER_DIR = 50
LIST_MAX_TOTAL_FILES = 5000
LIST_MAX_SECONDS = 3.0
LIST_GIT_TIMEOUT_SECONDS = 3.0

_WORD_BOUNDARY_CHARS = "-_. "

Notify = Callable[[str, dict[str, Any]], Awaitable[None]]


class StaleFileError(Exception):
    """Raised when fs.writeFile's ifMatch check fails."""

    code = "stale"


def workspace_root(params: dict[str, Any]) -> Path:
    raw_root = params.get("root") or params.get("cwd")
    if not isinstance(raw_root, str) or not raw_root.strip():
        raise ValueError("root is required")
    return Path(raw_root).expanduser().resolve(strict=False)


def resolve_path(root: Path, raw_path: str) -> Path:
    path = Path(raw_path).expanduser()
    if not path.is_absolute():
        path = root / path
    return path.resolve(strict=False)


def _is_within_root(root: Path, candidate: Path) -> bool:
    return candidate == root or root in candidate.parents


def _is_separator(char: str) -> bool:
    return char in "/\\"


def query_components(root: Path, raw_path: str) -> list[str]:
    """Relative path segments the workspace lookup should suffix-match against.

    Absolute paths keep only the portion below `root`; a relative path keeps its
    own segments with any `..` escapes and `.` noise removed.
    """
    try:
        resolved = resolve_path(root, raw_path)
    except (OSError, RuntimeError, ValueError):
        # expanduser()/resolve() can raise on a pathological path; fall back to
        # the textual split so a probe degrades to a miss instead of a 502.
        resolved = None
    if resolved is not None and _is_within_root(root, resolved):
        return [part for part in resolved.relative_to(root).parts if part not in ("", ".")]

    replaced = raw_path.replace("\\", "/")
    parts = [part for part in replaced.split("/") if part not in ("", ".", "..")]
    return parts


def score_candidate(query: str, candidate_relpath: str) -> int:
    """Fuzzy relevance of `candidate_relpath` for `query` (VS Code Quick Open style).

    Mirrors the Cmd+P scoring rules: a matched char starts at 1; a run of
    contiguous matches accumulates an increasing bonus; the first pattern
    character, a start-of-path char, a path separator, the word-boundary set
    ``- _ . <space>`` and a camelCase transition all score higher; unmatched
    gaps deduct. Returns -1 when `query` is not a subsequence of the candidate.
    """
    if not query:
        return 0

    score = 0
    pattern_index = 0
    consecutive = 0
    gap = 0
    for target_index, target_char in enumerate(candidate_relpath):
        if pattern_index >= len(query):
            break

        pattern_char = query[pattern_index]
        if target_char.lower() != pattern_char.lower():
            gap += 1
            consecutive = 0
            continue
        # An uppercase target char only matches when the query is uppercase
        # there too, so a lowercase query favours the lowercase spelling.
        if target_char.isupper() and not pattern_char.isupper():
            gap += 1
            consecutive = 0
            continue

        if pattern_index == 0:
            score += 16
        elif consecutive > 0:
            score += 8 + consecutive * 2
        else:
            score += 1
        if gap > 0:
            score -= gap
            gap = 0
        consecutive += 1

        if target_index == 0:
            score += 12
        else:
            prev = candidate_relpath[target_index - 1]
            if _is_separator(prev):
                score += 10
            elif prev in _WORD_BOUNDARY_CHARS:
                score += 6
            if target_char.isupper() and prev.islower():
                score += 6

        pattern_index += 1

    if pattern_index < len(query):
        return -1
    return score


def nearest_existing_dir(path: Path, *, fallback: Path | None = None) -> Path:
    """Return `path` if it is a directory, otherwise the closest existing parent.

    Workspace paths can point at projects that were deleted or moved after a
    session was recorded. Runtime panels should still open somewhere useful
    instead of failing on a stale cwd/path.
    """
    current = path
    while True:
        if current.is_dir():
            return current
        parent = current.parent
        if parent == current:
            break
        current = parent
    if fallback is not None:
        fallback_current = fallback
        while True:
            if fallback_current.is_dir():
                return fallback_current
            parent = fallback_current.parent
            if parent == fallback_current:
                break
            fallback_current = parent
    return Path.cwd()


def required_string(params: dict[str, Any], key: str) -> str:
    value = params.get(key)
    if not isinstance(value, str) or not value:
        raise ValueError(f"{key} is required")
    return value


def required_text(params: dict[str, Any], key: str) -> str:
    value = params.get(key)
    if not isinstance(value, str):
        raise ValueError(f"{key} is required")
    return value


def required_int(params: dict[str, Any], key: str) -> int:
    value = params.get(key)
    if not isinstance(value, int):
        raise ValueError(f"{key} is required")
    return value


def encoding(params: dict[str, Any]) -> str:
    value = params.get("encoding", "utf8")
    if value not in {"utf8", "utf-8"}:
        raise ValueError("only utf8 encoding is supported")
    return "utf-8"


def decode_output(output: bytes) -> tuple[str, bool]:
    text = output.decode("utf-8", errors="replace")
    if len(text) <= MAX_OUTPUT_CHARS:
        return text, False
    return text[:MAX_OUTPUT_CHARS], True


def shell_result(
    cwd: Path,
    command: str,
    exit_code: int | None,
    timed_out: bool,
    start: float,
    stdout: bytes,
    stderr: bytes,
) -> dict[str, Any]:
    stdout_text, stdout_truncated = decode_output(stdout)
    stderr_text, stderr_truncated = decode_output(stderr)
    return {
        "cwd": str(cwd),
        "command": command,
        "exitCode": exit_code,
        "timedOut": timed_out,
        "durationMs": int((time.monotonic() - start) * 1000),
        "stdout": stdout_text,
        "stderr": stderr_text,
        "stdoutTruncated": stdout_truncated,
        "stderrTruncated": stderr_truncated,
    }
