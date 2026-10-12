from __future__ import annotations

import mimetypes
import hashlib
import os
import subprocess
import sys
import time
from collections import deque
from pathlib import Path
from typing import Any

from connector.local.common import (
    LIST_GIT_TIMEOUT_SECONDS,
    LIST_MAX_DEPTH,
    LIST_MAX_FILES_PER_DIR,
    LIST_MAX_SECONDS,
    LIST_MAX_TOTAL_FILES,
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


def _list_git_files(root: Path) -> tuple[list[str], bool] | None:
    """POSIX-relative file paths git considers part of `root`.

    Follows ccpocket: `ls-files -z --cached --others --exclude-standard` lists
    tracked files plus untracked non-ignored files, one NUL-terminated entry per
    file (directories are never listed). Returns None when `root` is not a git
    repository (no `.git` entry, so git is never even invoked off-repo) or git is
    unusable, so the caller can fall back to a bounded BFS.
    """
    # `.git` is a directory in a normal repo and a file in a worktree/submodule;
    # either way the entry's presence is the cheap "is this a repo root?" gate.
    if not os.path.exists(os.path.join(str(root), ".git")):
        return None
    try:
        completed = subprocess.run(
            [
                "git",
                "-C",
                str(root),
                "ls-files",
                "-z",
                "--cached",
                "--others",
                "--exclude-standard",
            ],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=LIST_GIT_TIMEOUT_SECONDS,
            check=False,
        )
    except (OSError, subprocess.SubprocessError):
        # git missing, or it hung past the timeout: fall back to the BFS so we
        # still return a (possibly truncated) list instead of failing.
        return None
    if completed.returncode != 0:
        return None

    files: list[str] = []
    for raw in completed.stdout.split(b"\x00"):
        if not raw:
            continue
        text = raw.decode("utf-8", errors="replace").replace("\\", "/")
        entry = text.strip("/")
        if not entry or entry in (".", ".."):
            continue
        if entry.startswith("../"):
            # Defensive: ls-files should never emit an escape, but a corrupt
            # index must not let a path leak outside the root.
            continue
        files.append(entry)
    return files, False


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

    def _list_files_bfs(self, root: Path) -> dict[str, Any]:
        """Bounded breadth-first listing of files under `root`.

        BFS (never DFS) so one deep subtree cannot exhaust the global budget.
        Symlinked directories are not followed, out-of-root entries are skipped,
        and any limit (depth / per-dir / total / wall clock) marks the result
        truncated. Read-only; returns POSIX paths relative to `root`.
        """
        files: list[str] = []
        truncated = False
        deadline = time.monotonic() + LIST_MAX_SECONDS

        root_resolved = root.resolve(strict=False)
        queue: deque[tuple[Path, int]] = deque([(root, 0)])
        while queue:
            if time.monotonic() > deadline:
                truncated = True
                break
            directory, depth = queue.popleft()
            try:
                with os.scandir(directory) as it:
                    entries = sorted(it, key=lambda item: item.name)
            except OSError:
                # Unreadable directory (permissions, race) is skipped, not fatal.
                continue

            dir_children: list[tuple[Path, int]] = []
            file_count = 0
            for entry in entries:
                try:
                    is_dir = entry.is_dir(follow_symlinks=False)
                except OSError:
                    is_dir = False
                if is_dir:
                    if entry.name in RESOLVE_SKIP_DIRS:
                        continue
                    if entry.is_symlink():
                        # Never follow a symlinked directory.
                        continue
                    if depth < LIST_MAX_DEPTH:
                        dir_children.append((Path(entry.path), depth + 1))
                    else:
                        # A subdirectory beyond the depth cap: its files are not
                        # listed, so the result is incomplete — mark it so the
                        # client never treats a depth-clipped list as complete.
                        truncated = True

                try:
                    is_file = entry.is_file(follow_symlinks=False)
                except OSError:
                    is_file = False
                if not is_file:
                    continue
                if file_count >= LIST_MAX_FILES_PER_DIR:
                    truncated = True
                    break
                if not self._resolved_within_root(root_resolved, Path(entry.path)):
                    continue
                files.append(Path(entry.path).relative_to(root).as_posix())
                file_count += 1
                if len(files) >= LIST_MAX_TOTAL_FILES:
                    truncated = True
                    break

            if len(files) >= LIST_MAX_TOTAL_FILES:
                break
            queue.extend(dir_children)

        shuffled = sorted(set(files))
        return {"files": shuffled, "truncated": truncated, "totalFiles": len(shuffled)}

    async def list_files(self, params: dict[str, Any]) -> dict[str, Any]:
        """List files under the workspace root as POSIX paths relative to it.

        Git repositories use `git ls-files` (honours .gitignore, does not walk
        ignored trees); anything else falls back to a bounded BFS. When git
        output exceeds the total cap the relative list is truncated and sorted.
        """
        root = workspace_root(params).resolve()
        if not root.is_dir():
            return {"files": [], "truncated": False, "totalFiles": 0}

        git_result = _list_git_files(root)
        if git_result is not None:
            files, truncated = git_result
            files.sort()
            if len(files) > LIST_MAX_TOTAL_FILES:
                files = files[:LIST_MAX_TOTAL_FILES]
                truncated = True
            return {
                "files": files,
                "truncated": truncated,
                "totalFiles": len(files),
            }

        return self._list_files_bfs(root)

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
