from __future__ import annotations

import mimetypes
import hashlib
import os
import sys
import time
from pathlib import Path
from typing import Any

from connector.local.common import (
    MAX_DIR_ENTRIES,
    MAX_READ_TEXT_BYTES,
    RESOLVE_MAX_CANDIDATES,
    RESOLVE_MAX_DEPTH,
    RESOLVE_MAX_ENTRIES,
    RESOLVE_MAX_SECONDS,
    RESOLVE_SKIP_DIRS,
    StaleFileError,
    encoding,
    nearest_existing_dir,
    query_components,
    required_string,
    required_text,
    resolve_path,
    score_candidate,
    workspace_root,
)


def _candidate_sort_key(item: tuple[int, str]) -> tuple[int, int, int, str]:
    score, relative = item
    name = relative.rsplit("/", 1)[-1]
    return (-score, len(name), len(relative), relative)


class FileOps:
    def _windows_drive_entries(self) -> list[dict[str, Any]]:
        if sys.platform != "win32":
            return []

        entries: list[dict[str, Any]] = []
        from pathlib import Path

        for code in range(ord("A"), ord("Z") + 1):
            letter = chr(code)
            path = Path(f"{letter}:\\")
            try:
                exists = path.exists()
            except OSError:
                exists = False
            if not exists:
                continue
            entries.append({"name": f"{letter}:", "path": str(path), "type": "directory", "size": None})
        return entries

    async def prepare_download(self, params: dict[str, Any]) -> dict[str, Any]:
        root = workspace_root(params)
        path = resolve_path(root, required_string(params, "path"))
        if not path.is_file():
            raise FileNotFoundError(f"file not found: {path}")
        data = path.read_bytes()
        return {
            "path": str(path),
            "name": path.name,
            "size": len(data),
            "sha256": hashlib.sha256(data).hexdigest(),
            "mediaType": mimetypes.guess_type(path.name)[0] or "application/octet-stream",
        }

    def prepared_download_path(self, params: dict[str, Any]) -> str:
        root = workspace_root(params)
        return str(resolve_path(root, required_string(params, "path")))

    async def write_file(self, params: dict[str, Any]) -> dict[str, Any]:
        root = workspace_root(params)
        path = resolve_path(root, required_string(params, "path"))
        content_encoding = encoding(params)
        content = required_text(params, "content")
        if_match = params.get("ifMatch")
        if not path.parent.is_dir():
            raise FileNotFoundError(f"parent directory not found: {path.parent}")
        if if_match is not None:
            if not isinstance(if_match, str):
                raise ValueError("ifMatch must be a sha256 hex string")
            current_hash = ""
            if path.is_file():
                current_hash = hashlib.sha256(path.read_bytes()).hexdigest()
            elif if_match != "":
                raise StaleFileError(
                    f"file disappeared (expected sha256={if_match})"
                )
            if if_match and current_hash != if_match:
                raise StaleFileError(
                    f"file changed on disk (expected sha256={if_match}, found sha256={current_hash or 'none'})"
                )
        data = content.encode(content_encoding)
        path.write_bytes(data)
        return {
            "path": str(path),
            "encoding": "utf8",
            "bytesWritten": len(data),
            "sha256": hashlib.sha256(data).hexdigest(),
        }

    async def read_text(self, params: dict[str, Any]) -> dict[str, Any]:
        root = workspace_root(params)
        path = resolve_path(root, required_string(params, "path"))
        if not path.is_file():
            raise FileNotFoundError(f"file not found: {path}")
        raw_max = params.get("maxBytes", 1_048_576)
        if not isinstance(raw_max, int):
            raise ValueError("maxBytes must be an integer")
        max_bytes = min(max(raw_max, 1), MAX_READ_TEXT_BYTES)
        full = path.read_bytes()
        clipped = full[:max_bytes]
        truncated = len(full) > max_bytes
        binary = b"\x00" in clipped
        content = "" if binary else clipped.decode("utf-8", errors="replace")
        return {
            "path": str(path),
            "name": path.name,
            "size": len(full),
            "sha256": hashlib.sha256(full).hexdigest(),
            "encoding": "utf8",
            "content": content,
            "truncated": truncated,
            "binary": binary,
        }

    async def read_dir(self, params: dict[str, Any]) -> dict[str, Any]:
        root = workspace_root(params)
        raw_path = params.get("path")
        if sys.platform == "win32" and raw_path == "":
            return {
                "path": "",
                "entries": self._windows_drive_entries(),
                "truncated": False,
                "targetPath": "",
                "targetType": "directory",
            }

        target = root if raw_path is None else resolve_path(root, required_string(params, "path"))
        if target.is_dir():
            target_type = "directory"
        elif target.is_file():
            target_type = "file"
        elif target.exists():
            target_type = "other"
        else:
            target_type = "missing"
        path = nearest_existing_dir(target, fallback=root)

        children = sorted(path.iterdir(), key=lambda item: item.name)
        visible_children = children[:MAX_DIR_ENTRIES]
        if (
            target_type == "file"
            and target.parent == path
            and target not in visible_children
            and visible_children
        ):
            visible_children[-1] = target

        entries: list[dict[str, Any]] = []
        for child in visible_children:
            try:
                stat = child.stat()
            except OSError:
                stat = None
            entries.append(
                {
                    "name": child.name,
                    "path": str(child),
                    "type": "directory" if child.is_dir() else "file" if child.is_file() else "other",
                    "size": stat.st_size if stat is not None and child.is_file() else None,
                }
            )

        return {
            "path": str(path),
            "entries": entries,
            "truncated": len(children) > MAX_DIR_ENTRIES,
            "targetPath": str(target),
            "targetType": target_type,
        }

    def _collect_candidates(
        self, root: Path, raw_path: str
    ) -> list[dict[str, Any]]:
        """Bounded, read-only fuzzy search for `raw_path` inside `root`.

        Returns every match, best first; the caller caps the list to
        `RESOLVE_MAX_CANDIDATES`. Never leaves `root`: symlinks whose resolved
        target escapes the root are skipped, and skipped directories are pruned
        entirely.
        """
        query = query_components(root, raw_path)
        if not query:
            return []
        query_basename = query[-1].lower()
        query_key = "/".join(query)

        matches: list[tuple[int, str]] = []
        entries_seen = 0
        deadline = time.monotonic() + RESOLVE_MAX_SECONDS

        for current_dir, dir_names, file_names in os.walk(root, followlinks=False):
            if deadline <= time.monotonic():
                break
            entries_seen += len(dir_names) + len(file_names)
            if entries_seen > RESOLVE_MAX_ENTRIES:
                break

            current_path = Path(current_dir)
            depth = len(current_path.relative_to(root).parts)
            if depth >= RESOLVE_MAX_DEPTH:
                dir_names[:] = []
            else:
                # Prune hidden/build directories and symlinked dirs that escape root.
                kept_dirs: list[str] = []
                for name in dir_names:
                    if name in RESOLVE_SKIP_DIRS:
                        continue
                    child = current_path / name
                    try:
                        if child.is_symlink() and not child.resolve(strict=False).is_dir():
                            continue
                    except OSError:
                        continue
                    if not self._resolved_within_root(root, child):
                        continue
                    kept_dirs.append(name)
                dir_names[:] = kept_dirs

            for name in file_names:
                child = current_path / name
                if not self._resolved_within_root(root, child):
                    continue
                try:
                    # is_file() re-raises OSError for a permission-denied entry.
                    if not child.is_file():
                        continue
                except OSError:
                    continue
                relative = child.relative_to(root).as_posix()
                if not self._candidate_matches(relative, name, query, query_basename):
                    continue
                score = score_candidate(query_key, relative)
                matches.append((score, relative))

        matches.sort(key=_candidate_sort_key)
        return [self._candidate_payload(root, score, relative) for score, relative in matches]

    @staticmethod
    def _resolved_within_root(root: Path, child: Path) -> bool:
        """True when `child` (after resolving symlinks) stays inside `root`."""
        try:
            resolved = child.resolve(strict=False)
        except OSError:
            return False
        return resolved == root or root in resolved.parents

    @staticmethod
    def _candidate_matches(
        relative: str,
        name: str,
        query: list[str],
        query_basename: str,
    ) -> bool:
        parts = relative.split("/")
        # Suffix match on whole path segments, e.g. "a/b.md" hits "x/a/b.md".
        if len(query) <= len(parts) and parts[-len(query):] == query:
            return True
        # Or an identical basename anywhere.
        return name.lower() == query_basename

    @staticmethod
    def _candidate_payload(root: Path, score: int, relative: str) -> dict[str, Any]:
        return {
            "path": str(root / relative),
            "relative": relative,
            "name": relative.rsplit("/", 1)[-1],
            "score": score,
        }

    async def resolve_path_entry(self, params: dict[str, Any]) -> dict[str, Any]:
        root = workspace_root(params)
        raw_path = required_string(params, "path")

        # resolve_path / is_file() raise OSError (PermissionError outside the
        # ENOENT-class set) and expanduser() raises RuntimeError/ValueError for a
        # path under a chmod-000 directory, `/root/**`, `~unknownuser/**` or a
        # pathological input. A raw path comes from model-authored message text,
        # so a probe must degrade to a miss — never an uncaught exception that
        # the RPC layer turns into a non-contract 502.
        try:
            target = resolve_path(root, raw_path)
            # resolve_path is strict=False, so existence must be checked explicitly.
            if target.is_file() and self._resolved_within_root(root, target):
                return {"status": "exact", "path": str(target)}
        except (OSError, RuntimeError, ValueError):
            pass

        try:
            candidates = self._collect_candidates(root, raw_path)
        except (OSError, RuntimeError, ValueError):
            candidates = []
        if candidates:
            return {"status": "ambiguous", "candidates": candidates[:RESOLVE_MAX_CANDIDATES]}
        return {"status": "missing"}
