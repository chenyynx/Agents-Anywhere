from __future__ import annotations

import pytest

from connector.runtime_protocol import MAX_CONFIG_REVISION
from connector.runtimes.catalog_revisions import (
    CATALOG_CONFIG_REVISION_FACTOR,
    CatalogPushState,
    catalog_content_signature,
    catalog_push_revision,
    catalog_push_state_from_mapping,
    catalog_push_state_payload,
    runtime_catalog_revision,
)


def test_millisecond_config_revision_produces_js_safe_catalog_revision() -> None:
    revision = runtime_catalog_revision(1_786_665_600_123, 999)

    assert revision == 1_786_665_600_123_999
    assert revision <= MAX_CONFIG_REVISION


def test_largest_composable_catalog_revision_reaches_js_safe_boundary() -> None:
    config_revision, static_revision = divmod(
        MAX_CONFIG_REVISION,
        CATALOG_CONFIG_REVISION_FACTOR,
    )

    assert (
        runtime_catalog_revision(config_revision, static_revision)
        == MAX_CONFIG_REVISION
    )


@pytest.mark.parametrize(
    ("config_revision", "static_revision"),
    [
        (
            MAX_CONFIG_REVISION // CATALOG_CONFIG_REVISION_FACTOR,
            MAX_CONFIG_REVISION % CATALOG_CONFIG_REVISION_FACTOR + 1,
        ),
        (MAX_CONFIG_REVISION // CATALOG_CONFIG_REVISION_FACTOR + 1, 0),
        (MAX_CONFIG_REVISION, 999),
    ],
)
def test_catalog_revision_rejects_unrepresentable_combinations(
    config_revision: int,
    static_revision: int,
) -> None:
    with pytest.raises(ValueError, match="combined catalog revision"):
        runtime_catalog_revision(config_revision, static_revision)


@pytest.mark.parametrize(
    ("config_revision", "static_revision", "error_type"),
    [
        (True, 1, TypeError),
        (-1, 1, ValueError),
        (MAX_CONFIG_REVISION + 1, 1, ValueError),
        (1, True, TypeError),
        (1, -1, ValueError),
        (1, 1000, ValueError),
    ],
)
def test_catalog_revision_rejects_invalid_components(
    config_revision: object,
    static_revision: object,
    error_type: type[Exception],
) -> None:
    with pytest.raises(error_type):
        runtime_catalog_revision(  # type: ignore[arg-type]
            config_revision,
            static_revision,
        )


def test_catalog_content_signature_ignores_revision_and_key_order() -> None:
    content = {"runtime": "claude", "models": [{"id": "alpha"}]}

    baseline = catalog_content_signature({**content, "revision": 10})

    assert catalog_content_signature({**content, "revision": 11}) == baseline
    assert (
        catalog_content_signature(
            {"models": [{"id": "alpha"}], "revision": 10, "runtime": "claude"}
        )
        == baseline
    )


def test_catalog_content_signature_tracks_content_changes() -> None:
    first = catalog_content_signature(
        {"runtime": "claude", "models": [{"id": "alpha"}], "revision": 10}
    )
    second = catalog_content_signature(
        {"runtime": "claude", "models": [{"id": "beta"}], "revision": 10}
    )
    extended = catalog_content_signature(
        {
            "runtime": "claude",
            "models": [{"id": "alpha"}, {"id": "zcode/GLM-5.3"}],
            "revision": 10,
        }
    )

    assert first != second
    assert first != extended


def test_catalog_push_revision_first_push_clears_a_frozen_base() -> None:
    # No recorded state: one step above the derived revision, so a drifted
    # catalog is accepted even though the derived revision did not move.
    assert catalog_push_revision(1004, None) == 1005


def test_catalog_push_revision_advances_above_the_last_push() -> None:
    state = CatalogPushState(content_signature="sig", revision=1005)

    assert catalog_push_revision(1004, state) == 1006
    # A moved config revision is used when it already leads the last push.
    assert catalog_push_revision(2004, state) == 2004
    # A regressed config revision must never pull the stream backwards: the
    # Server would drop (or worse, conflict with) the lower revision.
    assert catalog_push_revision(504, state) == 1006


def test_catalog_push_revision_clamps_at_the_safe_integer_boundary() -> None:
    assert catalog_push_revision(MAX_CONFIG_REVISION, None) == MAX_CONFIG_REVISION
    state = CatalogPushState(
        content_signature="sig",
        revision=MAX_CONFIG_REVISION,
    )

    assert catalog_push_revision(MAX_CONFIG_REVISION, state) == MAX_CONFIG_REVISION


@pytest.mark.parametrize(
    ("base_revision", "state", "error_type"),
    [
        (True, None, TypeError),
        (-1, None, ValueError),
        (MAX_CONFIG_REVISION + 1, None, ValueError),
        (1, CatalogPushState(content_signature="sig", revision=True), TypeError),
        (1, CatalogPushState(content_signature="sig", revision=-1), ValueError),
    ],
)
def test_catalog_push_revision_rejects_invalid_inputs(
    base_revision: object,
    state: object,
    error_type: type[Exception],
) -> None:
    with pytest.raises(error_type):
        catalog_push_revision(  # type: ignore[arg-type]
            base_revision,
            state,
        )


def test_catalog_push_state_round_trips() -> None:
    state = CatalogPushState(content_signature="abc123", revision=1005)

    assert catalog_push_state_from_mapping(catalog_push_state_payload(state)) == state


@pytest.mark.parametrize(
    "value",
    [
        None,
        {},
        {"version": 2, "contentSignature": "abc", "revision": 1},
        {"version": 1, "contentSignature": "", "revision": 1},
        {"version": 1, "contentSignature": "abc", "revision": True},
        {"version": 1, "contentSignature": "abc", "revision": -1},
        {"version": 1, "contentSignature": "abc"},
        {"version": 1, "revision": 1},
    ],
)
def test_catalog_push_state_rejects_malformed_values(value: object) -> None:
    assert catalog_push_state_from_mapping(value) is None  # type: ignore[arg-type]
