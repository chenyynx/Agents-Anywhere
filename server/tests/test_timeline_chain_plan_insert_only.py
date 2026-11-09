"""The chain plan inserts new rows, renumbering the smallest local block.

2026-11-10 (sess_S6J6UvA73cio-w): a local live-store resend appended three
message groups at the tail, and the following full-chain rebuild renumbered
431 batch-external rows without repairing the three groups. The plan now:

- inserts a new run into free integers between its stored batch neighbours;
  nothing stored moves on this path;
- when the interval is full, renumbers the **smallest block** of stored rows
  around the insertion point, in their existing order, until the run fits.
  Only block rows change number; everything else keeps its exact ``orderSeq``;
- appends a run that has no later batch anchor; when the batch names no stored
  anchor at all, it reports ``tail_anchored``.

The block grows to the session end only when the session is dense (order
1..N), where no integer gap exists — the 2026-11-09 fresh-session backfill.
"""

from __future__ import annotations

from agent_server.core.timeline import (
    chain_reorder_plan,
    chain_reorder_plan_with_diagnostics,
)


def test_an_existing_only_batch_plans_nothing() -> None:
    diagnostics = chain_reorder_plan_with_diagnostics(
        stored_order=[("b", 1), ("platform", 2), ("a", 3)],
        batch_ids=["a", "b"],
    )

    assert diagnostics.plan == {}
    assert diagnostics.renumbered_stored == 0


def test_new_row_is_inserted_between_its_stored_batch_neighbours() -> None:
    """The 2026-11-10 shape: m3 was missed, m2/m4 are stored anchors."""

    assert chain_reorder_plan(
        stored_order=[("m1", 1), ("m2", 2), ("m4", 4), ("m5", 5)],
        batch_ids=["m1", "m2", "m3", "m4", "m5"],
    ) == {"m3": 3}


def test_front_run_uses_free_positive_slots_below_the_anchor() -> None:
    """Backfilled rows before the first stored row keep their chain order.

    The 2026-11-09 incident: a stuck turn's rows arrived after newer rows.
    A free slot below the anchor inserts them without moving anything.
    """

    assert chain_reorder_plan(
        stored_order=[("new1", 10), ("new2", 11)],
        batch_ids=["old1", "old2", "new1", "new2"],
    ) == {"old1": 8, "old2": 9}


def test_front_run_without_a_positive_slot_renumbers_the_front_block() -> None:
    """A fresh session numbered from 1 has no gap before its first row.

    The plan shifts the stored front rows up and inserts the run at 1..2 —
    the 2026-11-09 order is restored instead of appending the old turn.
    """

    diagnostics = chain_reorder_plan_with_diagnostics(
        stored_order=[("new1", 1), ("new2", 2)],
        batch_ids=["old1", "old2", "new1", "new2"],
    )
    assert diagnostics.plan == {"old1": 1, "old2": 2, "new1": 3, "new2": 4}
    assert diagnostics.renumbered_stored == 2
    assert diagnostics.tail_anchored == ()


def test_a_full_interval_renumbers_the_smallest_block() -> None:
    stored = [("a", 1), ("p", 2), ("b", 3)]
    diagnostics = chain_reorder_plan_with_diagnostics(
        stored_order=stored,
        batch_ids=["a", "n", "b"],
    )

    # The only integer between a (1) and b (3) is taken by p; the block
    # (p, b) shifts up and n takes 3.
    assert diagnostics.plan == {"n": 3, "b": 4}
    assert diagnostics.renumbered_stored == 1


def test_new_row_without_any_stored_anchor_is_appended_and_reported() -> None:
    """A batch that names no anchor cannot know where the row belongs."""

    diagnostics = chain_reorder_plan_with_diagnostics(
        stored_order=[("m1", 1), ("m2", 2)],
        batch_ids=["m3"],
    )

    assert diagnostics.plan == {"m3": 3}
    assert diagnostics.tail_anchored == ("m3",)


def test_a_tail_run_appends_after_the_stored_rows() -> None:
    """A new row with a previous anchor but no later one is the newest row."""

    diagnostics = chain_reorder_plan_with_diagnostics(
        stored_order=[("u1", 5), ("x", 6), ("u2", 7)],
        batch_ids=["n0", "x", "n1"],
    )

    # n0 must sit below x, but 6 is taken; the smallest block (x, u2) shifts
    # up one and n0 takes 6. n1 has no later anchor and lands after the block.
    assert diagnostics.plan == {"n0": 6, "x": 7, "u2": 8, "n1": 9}
    assert diagnostics.renumbered_stored == 2
    assert diagnostics.tail_anchored == ()


def test_skewed_stored_neighbours_append_instead_of_renumbering() -> None:
    """A stored row in the wrong place must not make the batch rewrite rows.

    ``b`` is stored after ``a`` while the chain says ``b`` is earlier. Placing
    the run between them would move ``a`` or ``b`` — rows the batch did not ask
    to move — so every new row is appended and reported instead.
    """

    diagnostics = chain_reorder_plan_with_diagnostics(
        stored_order=[("a", 10), ("b", 20), ("c", 25), ("d", 30)],
        batch_ids=["b", "x1", "x2", "x3", "x4", "x5", "a"],
    )

    assert diagnostics.plan == {
        "x1": 31,
        "x2": 32,
        "x3": 33,
        "x4": 34,
        "x5": 35,
    }
    assert diagnostics.renumbered_stored == 0
    assert diagnostics.skewed_anchors == ("x1", "x2", "x3", "x4", "x5")


def test_a_skewed_pair_does_not_raise() -> None:
    """Regression: the append branch used an insertion floor it never set."""

    diagnostics = chain_reorder_plan_with_diagnostics(
        stored_order=[("a", 10), ("b", 20)],
        batch_ids=["b", "x", "a"],
    )

    assert diagnostics.plan == {"x": 21}
    assert diagnostics.skewed_anchors == ("x",)


def test_healthy_order_is_a_strict_no_op() -> None:
    assert (
        chain_reorder_plan(
            stored_order=[("a", 1), ("b", 2), ("c", 3)],
            batch_ids=["a", "b", "c"],
        )
        is None
    )


def test_plan_is_idempotent_when_applied() -> None:
    stored = [("a", 1), ("b", 2), ("d", 4)]
    plan = chain_reorder_plan(stored_order=stored, batch_ids=["a", "b", "c", "d"])
    assert plan == {"c": 3}

    applied = sorted(
        [(item_id, plan.get(item_id, number)) for item_id, number in stored]
        + [("c", plan["c"])],
        key=lambda entry: (entry[1], entry[0]),
    )
    assert [item_id for item_id, _ in applied] == ["a", "b", "c", "d"]
    assert (
        chain_reorder_plan(
            stored_order=applied,
            batch_ids=["a", "b", "c", "d"],
        )
        is None
    )
