"""Per-task stop declaration for Claude CLI connections (2026-10-05).

The CLI's own initialize schema (2.1.284/285/288, field
``perTaskStopAffordance``): "Declares that this consumer renders a per-task
stop control wired to the ``stop_task`` control request, so the user can stop
an individual background task. When declared, an interrupt on an open-input
(interactive stream-json) session spares running background agents/workflows
(Stop only aborts the turn). ... ABSENCE also fails closed: the interrupt
kills background tasks, since the user would otherwise have no way to stop a
runaway one."

AA renders exactly such a control (the SubAgent panel's per-task stop), so the
affordance is declared. Consumers without one keep the old all-stop semantics:
see ``ClaudeTurnActionHandler.interrupt_session(preserve_background=False)``,
which kills the tasks a sparing interrupt left alive.

Why a patched send: the SDK (0.2.161) has no option for arbitrary initialize
fields, and the initialize request is built inside ``Query``. The request is
therefore amended in the one place it goes out. The patch is narrow (only dict
requests whose subtype is ``initialize``), installed once per process, shared
by every connection, and fail-soft: an SDK that no longer exposes the seam
leaves the pre-declaration behavior in place instead of failing a connection.
Kill-switch: the runtime config value ``perTaskStopAffordance`` (default on),
effective per connection at build time — the install's return value is
recorded on the connection (``DECLARED_ATTR``) and every stop-path decision
reads that connection fact, not the process-level switch.
"""

from __future__ import annotations

import asyncio
import inspect
from collections.abc import Iterable
from typing import Any

from connector.logging import logger

DECLARE_FIELD = "perTaskStopAffordance"
_PATCH_MARKER = "_aa_declares_per_task_stop"
#: Set on every client whose connection was built with the declaration in
#: force. The connection copies it (``ClaudeConnection.per_task_stop_declared``)
#: so the stop path reads the connection's own fact: the process-level
#: ``_declared`` switch is only the startup-time install decision, and another
#: runtime instance (different config, runtime flip) must not re-decide this
#: connection's semantics (red team F-A/F-C, 2026-10-06).
DECLARED_ATTR = "_aa_per_task_stop_declared"

# A per-task stop is a control request the CLI answers promptly; bounding it
# keeps a silent CLI from holding the stop path it belongs to.
STOP_TASK_TIMEOUT_SECONDS = 5.0

_declared = False


def is_declared() -> bool:
    """Whether new CLI connections declare the per-task stop affordance."""

    return _declared


def install_per_task_stop_declaration(sdk: Any, *, declare: bool = True) -> bool:
    """Amend every ``initialize`` control request with the declaration.

    Returns whether the declaration is in force. False (fail-soft) when the
    SDK seam is absent: the old CLI behavior — an interrupt kills background
    work — is left exactly as it was.
    """

    global _declared

    query_cls = _query_class(sdk)
    sender = getattr(query_cls, "_send_control_request", None) if query_cls else None
    if not callable(sender):
        logger.warning(
            "Claude per-task stop declaration unavailable: initialize send not found"
        )
        _declared = False
        return False
    if not getattr(sender, _PATCH_MARKER, False):
        original = sender

        async def declaring_send_control_request(
            self: Any,
            request: Any,
            *args: Any,
            **kwargs: Any,
        ) -> Any:
            # Only the initialize request is touched, and only while the
            # kill-switch is on: every other control request (interrupt,
            # stop_task, set_permission_mode, …) passes through verbatim.
            if (
                _declared
                and isinstance(request, dict)
                and request.get("subtype") == "initialize"
            ):
                request = {**request, DECLARE_FIELD: True}
            return await original(self, request, *args, **kwargs)

        setattr(declaring_send_control_request, _PATCH_MARKER, True)
        query_cls._send_control_request = declaring_send_control_request
    _declared = declare
    return declare


def sdk_supports_stop_task(sdk: Any) -> bool:
    """Whether this SDK offers the per-task stop control at all.

    The capability bit's ``supported`` fact: an SDK whose client class has no
    ``stop_task`` cannot stop an individual background task, whatever the CLI
    underneath would accept. Checked on the class (the control is a method on
    ``ClaudeSDKClient``), never by version number.
    """

    client_cls = getattr(sdk, "ClaudeSDKClient", None)
    return callable(getattr(client_cls, "stop_task", None))


def mark_declared_client(client: Any, declared: bool) -> None:
    """Record the connection-level declaration fact on its client.

    Fail-soft: a client that forbids attributes keeps the safe default
    (undeclared = the CLI owns the all-stop), which is the pre-declaration
    semantics rather than a missing stop.
    """

    try:
        setattr(client, DECLARED_ATTR, bool(declared))
    except Exception:  # noqa: BLE001 - fail-soft by contract
        pass


def client_declares_per_task_stop(client: Any) -> bool:
    """Whether this client's connection was built with the declaration."""

    return bool(getattr(client, DECLARED_ATTR, False))


def _query_class(sdk: Any) -> Any:
    internal = getattr(sdk, "_internal", None)
    query_module = getattr(internal, "query", None) if internal is not None else None
    if query_module is None:
        try:
            import claude_agent_sdk._internal.query as query_module
        except Exception:  # noqa: BLE001 - fail-soft by contract
            return None
    return getattr(query_module, "Query", None)


async def stop_background_tasks(
    client: Any,
    task_ids: Iterable[str],
    *,
    timeout: float = STOP_TASK_TIMEOUT_SECONDS,
) -> tuple[str, ...]:
    """Stop each named background task through the SDK's per-task control.

    This is the explicit half of the default interrupt flavor: the declared
    CLI interrupt spares running background work, so a consumer without a
    per-task control has the tasks stopped here instead.

    Returns exactly the ids the stop was accepted for (the snapshot ∩ the
    successful stops). That set is what the connector may report as killed —
    reporting the whole snapshot would fold survivors into killed cards, a
    lie that also sticks: an Agent card marked interrupted does not heal.
    """

    stop_task = getattr(client, "stop_task", None)
    if not callable(stop_task):
        return ()

    async def stop_one(task_id: str) -> str:
        result = stop_task(task_id)
        if inspect.isawaitable(result):
            await asyncio.wait_for(result, timeout=timeout)
        return task_id

    results = await asyncio.gather(
        *(stop_one(task_id) for task_id in task_ids),
        return_exceptions=True,
    )
    return tuple(
        result for result in results if not isinstance(result, BaseException)
    )
