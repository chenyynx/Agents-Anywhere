from __future__ import annotations

import asyncio
import os

import pytest

from connector.local.common import score_candidate
from connector.local.file_ops import FileOps
from connector.server.local_rpc import LocalRpcHandler


def resolve(root, path: str):
    return asyncio.run(FileOps().resolve_path_entry({"root": str(root), "path": path}))


def _tree(tmp_path):
    (tmp_path / "src" / "docs").mkdir(parents=True)
    (tmp_path / "src" / "main.ts").write_text("export const x = 1\n")
    (tmp_path / "src" / "docs" / "readme.md").write_text("# src docs\n")
    (tmp_path / "other").mkdir()
    (tmp_path / "other" / "readme.md").write_text("# other docs\n")
    (tmp_path / "a").mkdir()
    (tmp_path / "a" / "b.md").write_text("exact segment match\n")
    (tmp_path / "x" / "a").mkdir(parents=True)
    (tmp_path / "x" / "a" / "b.md").write_text("suffix segment match\n")
    return tmp_path


def test_absolute_existing_file_is_exact(tmp_path) -> None:
    _tree(tmp_path)
    target = tmp_path / "src" / "main.ts"

    result = resolve(tmp_path, str(target))

    assert result == {"status": "exact", "path": str(target.resolve())}


def test_relative_existing_file_is_exact(tmp_path) -> None:
    _tree(tmp_path)
    target = (tmp_path / "src" / "main.ts").resolve()

    result = resolve(tmp_path, "src/main.ts")

    assert result == {"status": "exact", "path": str(target)}


def test_bare_filename_in_subdirectory_is_ambiguous_with_relative(tmp_path) -> None:
    _tree(tmp_path)

    result = resolve(tmp_path, "main.ts")

    assert result["status"] == "ambiguous"
    candidates = result["candidates"]
    assert any(candidate["relative"] == "src/main.ts" for candidate in candidates)
    match = next(candidate for candidate in candidates if candidate["relative"] == "src/main.ts")
    assert match["name"] == "main.ts"
    assert match["path"] == str((tmp_path / "src" / "main.ts").resolve())
    assert isinstance(match["score"], int)


def test_same_name_in_two_subdirectories_returns_both(tmp_path) -> None:
    _tree(tmp_path)

    result = resolve(tmp_path, "readme.md")

    assert result["status"] == "ambiguous"
    relatives = {candidate["relative"] for candidate in result["candidates"]}
    assert {"src/docs/readme.md", "other/readme.md"} <= relatives


def test_nonexistent_file_is_missing(tmp_path) -> None:
    _tree(tmp_path)

    assert resolve(tmp_path, "does/not/exist.txt") == {"status": "missing"}


def test_parent_escape_does_not_leak_outside_files(tmp_path) -> None:
    _tree(tmp_path)
    outside = tmp_path.parent / "aa-resolve-secret.md"
    outside.write_text("outside the workspace root\n")

    result = resolve(tmp_path, "../aa-resolve-secret.md")

    assert result["status"] == "missing"


@pytest.mark.skipif(os.name == "nt", reason="symlink creation is not reliably available on Windows CI")
def test_symlink_to_outside_root_is_not_returned(tmp_path) -> None:
    _tree(tmp_path)
    outside = tmp_path.parent / "aa-resolve-link-target.txt"
    outside.write_text("outside the workspace root\n")
    (tmp_path / "linked.txt").symlink_to(outside)

    # The link exists inside the tree but resolves outside the root, so it must
    # neither be returned as an exact hit nor as a candidate.
    assert resolve(tmp_path, "linked.txt") == {"status": "missing"}


def test_skipped_and_hidden_directories_are_pruned(tmp_path) -> None:
    _tree(tmp_path)
    (tmp_path / "node_modules").mkdir()
    (tmp_path / "node_modules" / "hidden_unique.md").write_text("skip me\n")
    (tmp_path / "node_modules" / "readme.md").write_text("skip me too\n")
    (tmp_path / ".git").mkdir()
    (tmp_path / ".git" / "readme.md").write_text("skip me as well\n")

    assert resolve(tmp_path, "hidden_unique.md") == {"status": "missing"}

    result = resolve(tmp_path, "readme.md")
    relatives = {candidate["relative"] for candidate in result["candidates"]}
    assert "node_modules/readme.md" not in relatives
    assert ".git/readme.md" not in relatives


def test_closer_match_ranks_first_and_scores_descend(tmp_path) -> None:
    _tree(tmp_path)

    # "b.md" is not at the root (so not exact), but matches two nested files.
    result = resolve(tmp_path, "b.md")

    assert result["status"] == "ambiguous"
    relatives = [candidate["relative"] for candidate in result["candidates"]]
    # The shallower path is the closer match and must rank first.
    assert relatives[0] == "a/b.md"
    assert "x/a/b.md" in relatives
    scores = [candidate["score"] for candidate in result["candidates"]]
    assert scores == sorted(scores, reverse=True)


def test_suffix_segment_match_hits_nested_path(tmp_path) -> None:
    (tmp_path / "deep" / "nested" / "thing").mkdir(parents=True)
    target = tmp_path / "deep" / "nested" / "thing" / "report.md"
    target.write_text("nested report\n")

    # The query is a whole-segment suffix of the real path but not itself a
    # root-relative path, so it must resolve to the ambiguous candidate.
    result = resolve(tmp_path, "nested/thing/report.md")

    assert result["status"] == "ambiguous"
    candidate = result["candidates"][0]
    assert candidate["relative"] == "deep/nested/thing/report.md"
    assert candidate["path"] == str(target.resolve())


def test_score_candidate_rewards_contiguity_and_boundaries() -> None:
    # Not a subsequence -> rejected.
    assert score_candidate("zzz", "src/main.ts") == -1
    # Contiguous run outranks the same characters scattered across gaps.
    contiguous = score_candidate("readme", "docs/readme.md")
    scattered = score_candidate("readme", "r-e-a-d-m-e.md")
    assert contiguous > scattered
    # A match right after a separator is rewarded over one buried mid-word.
    boundary = score_candidate("main", "src/main.ts")
    buried = score_candidate("main", "domain/main.ts".replace("/", ""))
    assert boundary > buried


def test_rpc_dispatch_routes_fs_resolve_path(tmp_path) -> None:
    _tree(tmp_path)
    local_ops = _StubLocalOps()
    handler = LocalRpcHandler(
        local_ops=local_ops,
        upload_prepared_download=_never,
        start_terminal_relay=_never,
        schedule_background=lambda _awaitable: None,
    )

    assert handler.supports("fs.resolvePath")
    result = asyncio.run(
        handler.dispatch("fs.resolvePath", {"root": str(tmp_path), "path": "src/main.ts"})
    )

    assert result["status"] == "exact"
    assert local_ops.calls == ["resolve_path_entry"]


async def _never(*_args, **_kwargs):
    raise AssertionError("unexpected call")


class _StubLocalOps:
    def __init__(self) -> None:
        self.calls: list[str] = []

    async def resolve_path_entry(self, params):
        self.calls.append("resolve_path_entry")
        return await FileOps().resolve_path_entry(params)


# --- Red-team regressions: a raw path comes from model-authored message text,
# so a probe must degrade to a miss, never an uncaught exception (which the RPC
# layer would surface as a non-contract 502). ---

def test_home_dir_expansion_is_missing_not_an_exception(tmp_path) -> None:
    # `~` may fall outside the root; the probe must not raise.
    result = resolve(tmp_path, "~/.bashrc")

    assert result["status"] in {"missing", "ambiguous"}


def test_unknown_user_home_expansion_does_not_raise(tmp_path) -> None:
    # expanduser() raises RuntimeError for `~unknownuser`; it must be swallowed.
    result = resolve(tmp_path, "~nosuchuser_zzz/file.txt")

    assert result == {"status": "missing"}


def test_absolute_outside_root_permission_path_does_not_raise(tmp_path) -> None:
    # An absolute path outside the root, into a directory we cannot read.
    result = resolve(tmp_path, "/root/.bashrc")

    assert result == {"status": "missing"}


def test_pathological_long_path_does_not_raise(tmp_path) -> None:
    result = resolve(tmp_path, "a/" * 20_000 + "x.txt")

    assert result["status"] in {"missing", "ambiguous"}


@pytest.mark.skipif(os.name == "nt", reason="POSIX permission bits")
def test_unreadable_dir_inside_root_does_not_raise(tmp_path) -> None:
    _tree(tmp_path)
    locked = tmp_path / "locked"
    locked.mkdir()
    (locked / "hidden.txt").write_text("secret\n")
    os.chmod(locked, 0o000)
    try:
        if os.geteuid() == 0:
            pytest.skip("root bypasses permission bits")
        result = resolve(tmp_path, "locked/hidden.txt")
        assert result == {"status": "missing"}
        # The scan must also survive the unreadable directory without raising.
        result = resolve(tmp_path, "hidden.txt")
        assert result["status"] in {"missing", "ambiguous", "exact"}
    finally:
        os.chmod(locked, 0o700)
