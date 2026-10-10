"""R1-zombie Z2 attacks — assembly surface D-A (enrich-only) + D-B (window_origin).

Baseline e1809da4. Read-only: no product code is modified.
Findings are mirrored into Z2-FINDINGS.md as they are confirmed.
"""

from __future__ import annotations

import asyncio
from pathlib import Path
from typing import Any

from test_zombie_card_z2 import (
    EXTERNAL_SESSION_ID,
    SESSION_ID,
    T_LATER,
    _FakeSdk,
    _layout,
    _raw_dispatch_row,
    _raw_notice_row,
    _raw_receipt_row,
    _raw_user_row,
    _runtime_with,
    _sdk_dispatch,
    _sdk_receipt,
    _sdk_user,
    _syncer,
    _window_rows,
    _write_rows,
)

from connector.runtimes.claude.history.syncer import _history_session
from connector.runtimes.claude.sessions.reader import _raw_history_notices
from connector.runtimes.claude.sessions.subagent_oracle import scan_raw_transcript

# ===========================================================================
# D-A — the enrich's ordering_time branch is dead in the production shape
# ===========================================================================


def test_Z2_DA_production_entry_orders_at_adoption_now_not_transcript_time(
    tmp_path: Path, monkeypatch: Any
) -> None:
    """ATTACK: a store entry created the production way already carries an
    ordering_time of "now" (``ensure`` defaults it), so the enrich's
    ``ordering_time=None if stored.ordering_time else ...`` never fires — the
    settled history session keeps sorting at adoption time, the very page-1
    pull-up the D-A comment and ``cache.py`` docstring claim to prevent.

    This is the exact shape the D-A comment names: a session that reached the
    store through ``record_timeline_item``'s bare ``ensure(session_id)``.
    """

    config, project, raw = _layout(tmp_path)
    monkeypatch.setenv("CLAUDE_CONFIG_DIR", str(config))
    _write_rows(raw, [_raw_dispatch_row(), _raw_receipt_row()])

    host, runtime = _runtime_with(_runtime_oracle())
    store = runtime._session_store
    # Production shape: the bare ensure of record_timeline_item fills neither
    # cwd, external id, nor a transcript-derived ordering_time.
    bare = store.ensure(session_id=SESSION_ID)
    assert bare.cwd is None and bare.external_session_id is None
    # The default the attack is about: it is NOT None.
    assert bare.ordering_time is not None, "ensure no longer defaults ordering_time"

    before = bare.ordering_time

    sdk = _FakeSdk([_sdk_dispatch(), _sdk_receipt()], raw, project)
    syncer = _syncer(
        host=host, sdk=sdk, session_store=store, oracle=runtime.subagent_oracle
    )
    prepared = asyncio.run(
        syncer.prepare_session_timeline_sync(SESSION_ID, EXTERNAL_SESSION_ID)
    )
    assert prepared is not None

    stored = store.get(SESSION_ID)
    # cwd/external ARE enriched (D-A's main goal holds)...
    assert stored.cwd
    assert stored.external_session_id == EXTERNAL_SESSION_ID
    # ...but the ordering_time is untouched: still the adoption "now", not the
    # transcript's own last_modified. The session sorts to the top of page 1.
    assert stored.ordering_time == before


def test_Z2_DA_the_transcript_ordering_time_never_reaches_a_bare_entry(
    tmp_path: Path, monkeypatch: Any
) -> None:
    """ATTACK, isolated: the value the enrich *would* supply differs from the
    stored one, proving the branch is skipped rather than agreeing by luck."""

    config, project, raw = _layout(tmp_path)
    monkeypatch.setenv("CLAUDE_CONFIG_DIR", str(config))
    _write_rows(raw, [_raw_dispatch_row(), _raw_receipt_row()])

    host, runtime = _runtime_with(_runtime_oracle())
    store = runtime._session_store
    store.ensure(session_id=SESSION_ID)
    stored = store.get(SESSION_ID)

    sdk = _FakeSdk([_sdk_dispatch(), _sdk_receipt()], raw, project)
    syncer = _syncer(
        host=host, sdk=sdk, session_store=store, oracle=runtime.subagent_oracle
    )
    prepared = asyncio.run(
        syncer.prepare_session_timeline_sync(SESSION_ID, EXTERNAL_SESSION_ID)
    )
    assert prepared is not None

    # What the history read believes the ordering time is.
    history_ordering = _history_times(sdk, raw)
    assert history_ordering is not None
    # The stored value is unchanged and differs from it.
    assert stored.ordering_time != history_ordering


def test_Z2_DA_control_enrich_still_fills_cwd_and_external(
    tmp_path: Path, monkeypatch: Any
) -> None:
    """CONTROL: the D-A main goal — the sweep can now reach a never-live
    session — holds, so the ordering_time gap is a dead sub-feature, not a
    broken fix."""

    config, project, raw = _layout(tmp_path)
    monkeypatch.setenv("CLAUDE_CONFIG_DIR", str(config))
    _write_rows(raw, [_raw_dispatch_row(), _raw_receipt_row()])

    host, runtime = _runtime_with(_runtime_oracle())
    store = runtime._session_store
    store.ensure(session_id=SESSION_ID)
    assert store.get(SESSION_ID).cwd is None

    sdk = _FakeSdk([_sdk_dispatch(), _sdk_receipt()], raw, project)
    syncer = _syncer(
        host=host, sdk=sdk, session_store=store, oracle=runtime.subagent_oracle
    )
    asyncio.run(syncer.prepare_session_timeline_sync(SESSION_ID, EXTERNAL_SESSION_ID))

    stored = store.get(SESSION_ID, EXTERNAL_SESSION_ID)
    assert stored is not None and stored.cwd and stored.external_session_id


def test_Z2_DA_control_a_pristine_live_session_is_not_outvoted(
    tmp_path: Path, monkeypatch: Any
) -> None:
    """CONTROL (G1): a live-authored cwd is never overwritten."""

    config, project, raw = _layout(tmp_path)
    monkeypatch.setenv("CLAUDE_CONFIG_DIR", str(config))
    _write_rows(raw, [_raw_dispatch_row(), _raw_receipt_row()])

    host, runtime = _runtime_with(_runtime_oracle())
    store = runtime._session_store
    store.ensure(
        session_id=SESSION_ID,
        external_session_id=EXTERNAL_SESSION_ID,
        cwd="/live/authoritative",
    )
    sdk = _FakeSdk([_sdk_dispatch(), _sdk_receipt()], raw, project)
    syncer = _syncer(
        host=host, sdk=sdk, session_store=store, oracle=runtime.subagent_oracle
    )
    asyncio.run(syncer.prepare_session_timeline_sync(SESSION_ID, EXTERNAL_SESSION_ID))
    assert store.get(SESSION_ID).cwd == "/live/authoritative"


# ===========================================================================
# D-B — window_origin_uuid admission boundaries
# ===========================================================================


def test_Z2_DB_control_a_notice_after_the_origin_is_admitted() -> None:
    """CONTROL: the s7 shape — the notice follows the cursor row — lands."""

    scan = scan_raw_transcript(_window_rows())
    window = (_sdk_user("w1", "later message"),)
    placed = _raw_history_notices(window, scan, window_origin_uuid="d2")
    assert len(placed) == 1
    assert placed[0][0] == -1


def test_Z2_DB_control_a_notice_before_the_origin_is_dropped() -> None:
    """CONTROL: an out-of-window notice older than the cursor never re-fires."""

    scan = scan_raw_transcript(_window_rows())
    window = (_sdk_user("w1", "later message"),)
    assert _raw_history_notices(window, scan, window_origin_uuid="w1") == ()


def test_Z2_DB_control_without_an_origin_the_old_gate_holds() -> None:
    """CONTROL: no origin (rebase / first sync) is byte-identical to before."""

    scan = scan_raw_transcript(_window_rows())
    window = (_sdk_user("w1", "later message"),)
    assert _raw_history_notices(window, scan) == ()


def test_Z2_DB_a_duplicate_uuid_keeps_the_earlier_line_for_the_gate() -> None:
    """ATTACK (P2/记档): `uuid_line_index` keeps the FIRST line a uuid appears
    on. A rewritten/resumed file that repeats the origin row yields a SMALLER
    origin line, so a notice between the two copies can be admitted or dropped
    by which copy is the origin — the gate reads the earliest, which is the
    conservative (more drops) direction for a notice after the first copy."""

    from connector.runtimes.claude.sessions.subagent_oracle import (
        scan_raw_transcript as scan,
    )

    # The same receipt uuid appears twice; a notice sits between them.
    rows = (
        _raw_dispatch_row(),
        _raw_receipt_row(),  # d2 at line 1
        _raw_notice_row(),  # notice at line 2 (anchor d2)
        _raw_receipt_row(),  # d2 again at line 3
        _raw_user_row("w1", "later", T_LATER),
    )
    scan_result = scan(rows)
    assert scan_result.uuid_line_index["d2"] == 1, "first-line rule changed"
    # Origin is d2 (line 1); the notice is at line 2 -> admitted.
    window = (_sdk_user("w1", "later"),)
    placed = _raw_history_notices(window, scan_result, window_origin_uuid="d2")
    assert len(placed) == 1


def test_Z2_DB_an_origin_absent_from_the_index_declines_the_notice() -> None:
    """CONTROL: an origin uuid the raw scan never saw (a rewritten file that
    dropped the row) yields no origin line -> nothing is admitted, matching
    the no-origin gate. Safe (a drop, not a false fire)."""

    scan = scan_raw_transcript(_window_rows())
    window = (_sdk_user("w1", "later message"),)
    assert (
        _raw_history_notices(window, scan, window_origin_uuid="uuid-not-in-file")
        == ()
    )


# --------------------------------------------------------------------------
# helpers
# --------------------------------------------------------------------------


def _runtime_oracle() -> Any:
    from test_zombie_card_z2 import _history_oracle

    return _history_oracle()


def _history_times(sdk: Any, raw: Path) -> str | None:
    """The transcript ordering time the history read would supply."""

    info = sdk.get_session_info(SESSION_ID)
    session = _history_session(SESSION_ID, EXTERNAL_SESSION_ID, info)
    return session.ordering_time


def test_Z2_DA_the_enrich_cannot_create_the_entry_it_targets(
    tmp_path: Path, monkeypatch: Any
) -> None:
    """FIXED (Z2-P1, b5df776a): the attack used to land — the enrich explicitly
    did NOT create an entry, so a never-live history-only session got its first
    entry bare (cwd/external None) via ``record_timeline_item`` after the read,
    and the enrich never healed it. The history sync now ADOPTS an entry before
    publishing, for any session that carries an Agent card, so the read's store
    view is no longer unchanged and the first entry is born with the meta the
    sweep's oracle probe needs."""

    config, project, raw = _layout(tmp_path)
    monkeypatch.setenv("CLAUDE_CONFIG_DIR", str(config))
    _write_rows(raw, [_raw_dispatch_row(), _raw_receipt_row()])

    host, runtime = _runtime_with(_runtime_oracle())
    store = runtime._session_store
    sdk = _FakeSdk([_sdk_dispatch(), _sdk_receipt()], raw, project)
    syncer = _syncer(
        host=host, sdk=sdk, session_store=store, oracle=runtime.subagent_oracle
    )

    assert store.get(SESSION_ID) is None
    first = asyncio.run(
        syncer.prepare_session_timeline_sync(SESSION_ID, EXTERNAL_SESSION_ID)
    )
    assert first is not None and first.snapshot is not None
    # The snapshot carries an Agent card, so the entry is adopted at read time,
    # with cwd and the external id — the attack's "entry born bare after
    # publish" no longer happens.
    adopted = store.get(SESSION_ID, EXTERNAL_SESSION_ID)
    assert adopted is not None, (
        "the history sync published a card-bearing session it never gave the store"
    )
    assert adopted.cwd is not None
    assert adopted.external_session_id == EXTERNAL_SESSION_ID


def test_Z2_DA_control_a_pre_existing_bare_entry_is_enriched(
    tmp_path: Path, monkeypatch: Any
) -> None:
    """CONTROL (the shape the Z2 test uses, and the e2e's): an entry that
    already existed before the history read IS enriched — but note it exists
    only because something wrote a timeline item for the session earlier."""

    config, project, raw = _layout(tmp_path)
    monkeypatch.setenv("CLAUDE_CONFIG_DIR", str(config))
    _write_rows(raw, [_raw_dispatch_row(), _raw_receipt_row()])

    host, runtime = _runtime_with(_runtime_oracle())
    store = runtime._session_store
    store.ensure(session_id=SESSION_ID)  # the pre-existing bare entry
    sdk = _FakeSdk([_sdk_dispatch(), _sdk_receipt()], raw, project)
    syncer = _syncer(
        host=host, sdk=sdk, session_store=store, oracle=runtime.subagent_oracle
    )
    asyncio.run(syncer.prepare_session_timeline_sync(SESSION_ID, EXTERNAL_SESSION_ID))
    stored = store.get(SESSION_ID, EXTERNAL_SESSION_ID)
    assert stored.cwd and stored.external_session_id


def test_Z2_DA_the_sweep_is_blind_to_a_bare_entry_the_enrich_never_reached(
    tmp_path: Path, monkeypatch: Any
) -> None:
    """FIXED (Z2-P1, b5df776a): the attack used to land — a never-live
    session's first publish birthed a BARE entry (cwd None) via
    ``record_timeline_item``, and the sweep published nothing because the
    oracle's probe cannot resolve a transcript without cwd. The history sync
    now adopts the entry (cwd + external) before publishing, so the entry the
    sweep iterates is never bare and the same card closes."""

    from test_zombie_card_z2 import (
        FILE_STALE_SECONDS,
        _history_oracle,
        _published_card,
        _subagent_file,
    )

    config, project, raw = _layout(tmp_path)
    monkeypatch.setenv("CLAUDE_CONFIG_DIR", str(config))
    _subagent_file(config, project, age_seconds=FILE_STALE_SECONDS)
    _write_rows(raw, [_raw_dispatch_row(), _raw_receipt_row()])

    host, runtime = _runtime_with(_history_oracle())
    store = runtime._session_store
    sdk = _FakeSdk([_sdk_dispatch(), _sdk_receipt()], raw, project)
    syncer = _syncer(
        host=host, sdk=sdk, session_store=store, oracle=runtime.subagent_oracle
    )
    first = asyncio.run(
        syncer.prepare_session_timeline_sync(SESSION_ID, EXTERNAL_SESSION_ID)
    )
    assert first is not None and first.snapshot is not None
    # The publish lands on the adopted entry (never bare).
    for item in first.snapshot.items:
        store.record_timeline_item(item)
    stored = store.get(SESSION_ID, EXTERNAL_SESSION_ID)
    assert stored is not None and stored.cwd is not None

    card = _published_card()
    stored.timeline_items[card.id] = card
    runner = runtime._turns.runner
    published = asyncio.run(runner.sweep_agent_cards_by_evidence(stored))
    assert published == 1, (
        "the sweep is still blind to a history-only session's stale card"
    )


def test_Z2_DA_control_the_sweep_closes_on_an_enriched_entry(
    tmp_path: Path, monkeypatch: Any
) -> None:
    """CONTROL: the same card closes once the entry carries cwd/external — the
    state the enrich produces only when the entry pre-existed the read."""

    from test_zombie_card_z2 import (
        FILE_STALE_SECONDS,
        _history_oracle,
        _published_card,
        _subagent_file,
    )

    config, project, raw = _layout(tmp_path)
    monkeypatch.setenv("CLAUDE_CONFIG_DIR", str(config))
    _subagent_file(config, project, age_seconds=FILE_STALE_SECONDS)
    _write_rows(raw, [_raw_dispatch_row(), _raw_receipt_row()])

    host, runtime = _runtime_with(_history_oracle())
    store = runtime._session_store
    store.ensure(session_id=SESSION_ID)  # pre-existing bare entry
    sdk = _FakeSdk([_sdk_dispatch(), _sdk_receipt()], raw, project)
    syncer = _syncer(
        host=host, sdk=sdk, session_store=store, oracle=runtime.subagent_oracle
    )
    asyncio.run(syncer.prepare_session_timeline_sync(SESSION_ID, EXTERNAL_SESSION_ID))
    stored = store.get(SESSION_ID, EXTERNAL_SESSION_ID)
    assert stored.cwd


    card = _published_card()
    stored.timeline_items[card.id] = card
    runner = runtime._turns.runner
    published = asyncio.run(runner.sweep_agent_cards_by_evidence(stored))
    assert published == 1
