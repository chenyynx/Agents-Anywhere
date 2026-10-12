from __future__ import annotations

import asyncio
import os
import subprocess

import pytest

from connector.local.common import (
    LIST_MAX_FILES_PER_DIR,
    LIST_MAX_TOTAL_FILES,
)
from connector.local.file_ops import FileOps
from connector.server.local_rpc import LocalRpcHandler


def list_files(root, *, root_param=None):
    params = {"sessionId": "sess_test", "root": str(root_param if root_param is not None else root)}
    return asyncio.run(FileOps().list_files(params))


def _git(root, *args: str) -> None:
    subprocess.run(
        ["git", "-C", str(root), *args],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=True,
    )


def test_git_repository_lists_tracked_and_untracked_but_not_ignored(tmp_path) -> None:
    _git(tmp_path, "init")
    (tmp_path / ".gitignore").write_text("*.log\n")
    (tmp_path / "tracked.txt").write_text("tracked\n")
    (tmp_path / "ignored.log").write_text("ignored\n")
    (tmp_path / "sub").mkdir()
    (tmp_path / "sub" / "nested.md").write_text("# nested\n")
    _git(tmp_path, "add", "tracked.txt", ".gitignore", "sub/nested.md")

    result = list_files(tmp_path)

    files = result["files"]
    assert "tracked.txt" in files
    assert "sub/nested.md" in files
    assert ".gitignore" in files
    # The ignored file is untracked and excluded by .gitignore.
    assert "ignored.log" not in files
    # Nothing from inside .git leaks out.
    assert not any(part == ".git" or part.startswith(".git/") for part in files)
    assert result["truncated"] is False
    assert result["totalFiles"] == len(files)


def test_git_repository_includes_untracked_non_ignored_files(tmp_path) -> None:
    _git(tmp_path, "init")
    (tmp_path / "committed.txt").write_text("committed\n")
    _git(tmp_path, "add", "committed.txt")
    (tmp_path / "fresh.txt").write_text("brand new\n")

    result = list_files(tmp_path)

    assert "committed.txt" in result["files"]
    # `--others` surfaces the untracked, non-ignored file too.
    assert "fresh.txt" in result["files"]


def test_non_git_directory_uses_bounded_bfs(tmp_path) -> None:
    (tmp_path / "a" / "b").mkdir(parents=True)
    (tmp_path / "a" / "b" / "deep.txt").write_text("deep\n")
    (tmp_path / "a" / "top.md").write_text("top\n")
    (tmp_path / "root.txt").write_text("root\n")

    result = list_files(tmp_path)

    assert result["files"] == sorted(["a/b/deep.txt", "a/top.md", "root.txt"])
    assert result["truncated"] is False
    assert result["totalFiles"] == 3


def test_skip_dirs_are_pruned(tmp_path) -> None:
    (tmp_path / "src").mkdir()
    (tmp_path / "src" / "keep.txt").write_text("keep\n")
    (tmp_path / "node_modules").mkdir()
    (tmp_path / "node_modules" / "pkg.js").write_text("pkg\n")
    (tmp_path / ".git").mkdir()
    (tmp_path / ".git" / "config").write_text("[core]\n")

    result = list_files(tmp_path)

    assert result["files"] == ["src/keep.txt"]


@pytest.mark.skipif(os.name == "nt", reason="symlink creation is not reliably available on Windows CI")
def test_symlinks_are_not_followed(tmp_path) -> None:
    outside_dir = tmp_path.parent / "aa-list-outside"
    outside_dir.mkdir(exist_ok=True)
    (outside_dir / "secret.txt").write_text("outside\n")
    (tmp_path / "root.txt").write_text("inside\n")
    (tmp_path / "link.txt").symlink_to(outside_dir / "secret.txt")
    (tmp_path / "linkdir").symlink_to(outside_dir, target_is_directory=True)

    result = list_files(tmp_path)

    files = result["files"]
    assert "root.txt" in files
    assert "link.txt" not in files
    assert not any(f.startswith("linkdir/") for f in files)


def test_per_directory_quota_truncates(tmp_path) -> None:
    crowded = tmp_path / "crowded"
    crowded.mkdir()
    total = LIST_MAX_FILES_PER_DIR + 10
    for index in range(total):
        (crowded / f"f-{index:04d}.txt").touch()

    result = list_files(tmp_path)

    assert result["truncated"] is True
    assert len([f for f in result["files"] if f.startswith("crowded/")]) == LIST_MAX_FILES_PER_DIR


def test_total_file_cap_truncates(tmp_path) -> None:
    # Spread files across many directories so the per-directory quota is not the
    # binding limit; the global cap must trip instead.
    per_dir = LIST_MAX_FILES_PER_DIR - 1
    dirs_needed = (LIST_MAX_TOTAL_FILES // per_dir) + 2
    for d in range(dirs_needed):
        directory = tmp_path / f"d{d:03d}"
        directory.mkdir()
        for i in range(per_dir):
            (directory / f"f{i:03d}.txt").touch()

    result = list_files(tmp_path)

    assert result["truncated"] is True
    assert result["totalFiles"] == LIST_MAX_TOTAL_FILES


def test_empty_directory_returns_empty(tmp_path) -> None:
    result = list_files(tmp_path)

    assert result == {"files": [], "truncated": False, "totalFiles": 0}


def test_missing_root_directory_returns_empty(tmp_path) -> None:
    missing = tmp_path / "does" / "not" / "exist"

    result = list_files(missing)

    assert result == {"files": [], "truncated": False, "totalFiles": 0}


def test_rpc_dispatch_routes_fs_list_files(tmp_path) -> None:
    (tmp_path / "hello.txt").write_text("hi\n")
    local_ops = _StubLocalOps()
    handler = LocalRpcHandler(
        local_ops=local_ops,
        upload_prepared_download=_never,
        start_terminal_relay=_never,
        schedule_background=lambda _awaitable: None,
    )

    assert handler.supports("fs.listFiles")
    result = asyncio.run(
        handler.dispatch("fs.listFiles", {"sessionId": "sess", "root": str(tmp_path)})
    )

    assert result["files"] == ["hello.txt"]
    assert local_ops.calls == ["list_files"]


async def _never(*_args, **_kwargs):
    raise AssertionError("unexpected call")


class _StubLocalOps:
    def __init__(self) -> None:
        self.calls: list[str] = []

    async def list_files(self, params):
        self.calls.append("list_files")
        return await FileOps().list_files(params)


def test_depth_clipped_subtree_marks_truncated(tmp_path) -> None:
    """A subdirectory beyond LIST_MAX_DEPTH is not listed, so `truncated` must
    be true — the client may never treat a depth-clipped list as complete."""
    from connector.local.common import LIST_MAX_DEPTH

    deep = tmp_path
    for i in range(LIST_MAX_DEPTH + 3):
        deep = deep / f"d{i}"
    deep.mkdir(parents=True)
    (deep / "beyond.txt").write_text("x")

    import asyncio
    from connector.local.file_ops import FileOps
    result = asyncio.run(FileOps().list_files({"root": str(tmp_path), "path": ""}))

    assert result["truncated"] is True
    assert "beyond.txt" not in " ".join(result["files"])
