from __future__ import annotations

from collections.abc import Awaitable, Callable, Mapping
from dataclasses import dataclass
from enum import StrEnum

from connector.logging import logger
from connector.runtime_protocol import (
    RuntimeInvalidRequestError,
    RuntimeOperationResult,
    RuntimeSessionStateCache,
)
from connector.runtimes.claude.catalogs.reader import ClaudeCatalogReader
from connector.runtimes.claude.domain.selections import effective_claude_selections
from connector.runtimes.claude.domain.session import ClaudeSession
from connector.runtimes.claude.notifications.projector import (
    ClaudeNotificationProjector,
)
from connector.runtimes.claude.sessions.cache import ClaudeSessionStore


class SelectionApplyResult(StrEnum):
    """The outcome of trying to apply a selection change to a live transport.

    Three facts, never two (`model-switch-in-process-tasks.md` §3.1, real-CLI
    probe 2026-10-15). The old boolean conflated a transient refusal with a
    capability failure, which would rebuild the process — killing the very
    background work this change exists to protect — for a failure that clears
    on a later attempt.

    * ``APPLIED``: the live transport now carries the target selections.
    * ``DEFERRED``: the SDK seam exists and was called, but the CLI refused —
      a TRANSIENT, retryable answer (its 1-token model-validation probe stalled
      against the API). The session stays on the old selection; the runner
      records the pending target and retries at the next event, bounded.
    * ``UNAVAILABLE``: the change cannot be applied in place at all — no live
      transport, no SDK seam, an effort change, or the ``bypassPermissions``
      exception. The caller keeps today's rebuild semantics.

    Every outcome keeps the caller's message flowing: none of them waits.
    """

    APPLIED = "applied"
    DEFERRED = "deferred"
    UNAVAILABLE = "unavailable"


# In-process selection application
# (model-switch-in-process-tasks.md §3.1). A live transport can take a model /
# permission change on the same CLI process (the SDK's `set_model` /
# `set_permission_mode` control requests), so a selection change no longer has
# to rebuild the process. This callback is the narrow seam the controller uses
# to reach the connection table, which it does not own: the runner supplies the
# implementation (`ClaudeTurnRunner.apply_selection_to_live`).
ApplyLiveSelections = Callable[
    [ClaudeSession, Mapping[str, str | None]],
    Awaitable[SelectionApplyResult],
]


@dataclass(slots=True)
class ClaudeSelectionController:
    session_states: RuntimeSessionStateCache
    session_store: ClaudeSessionStore
    catalogs: ClaudeCatalogReader
    notifications: ClaudeNotificationProjector
    #: Optional so a controller wired without a connection table keeps the
    #: pre-in-process behaviour (today's idle rebuild); the live runtime wires
    #: the runner's implementation here.
    apply_to_live: ApplyLiveSelections | None = None

    async def update_session_selections(
        self,
        session_id: str,
        external_session_id: str | None,
        selections: Mapping[str, str | None],
    ) -> RuntimeOperationResult:
        session = self.session_store.ensure(
            session_id=session_id,
            external_session_id=external_session_id,
        )
        try:
            session.selections = await self.effective_selections(
                session_id,
                selections,
            )
        except RuntimeInvalidRequestError as exc:
            return RuntimeOperationResult(
                ok=False,
                code="claude_invalid_selection",
                message=str(exc),
            )
        # Prefer applying the change to the live transport in place, so the
        # next turn runs on the new model / permissions with no process
        # rebuild and no message held. A non-APPLIED result is not an error:
        # the controller's idle refresh (and, for live background work, the
        # deferred landing) is the fallback, and the runner has already
        # published any disclosure for the "not yet in effect" case.
        apply_result = SelectionApplyResult.UNAVAILABLE
        if self.apply_to_live is not None:
            try:
                apply_result = await self.apply_to_live(session, session.selections)
            except Exception:  # noqa: BLE001
                # Applying a selection must never fail the request: the
                # controller's rebuild path still lands the change, and the
                # failure is observable in the log.
                logger.exception(
                    "Claude in-process selection apply failed session_id={}",
                    session_id,
                )
                apply_result = SelectionApplyResult.UNAVAILABLE
        state = self.session_states.get(session_id)
        await self.notifications.session_state.session_state_update(
            session,
            state.status if state is not None else "idle",
            selections=session.selections,
            metadata={
                "source": "claude.selections.update",
                # Honest runtime state: whether the live transport already
                # carries the new selection. False means the change has not
                # taken effect yet (a rebuild is pending, or a transient
                # refusal is being retried); the runner adds its own disclosure
                # for the "not yet in effect" case.
                "selectionInProcess": (
                    apply_result is SelectionApplyResult.APPLIED
                ),
            },
        )
        return RuntimeOperationResult(
            ok=True,
            result={
                "sessionId": session_id,
                "externalSessionId": session.external_session_id,
                "selections": session.selections,
            },
        )

    async def effective_selections(
        self,
        session_id: str,
        selections: Mapping[str, str | None] | None,
    ) -> dict[str, str | None]:
        state = self.session_states.get(session_id)
        current = state.selections if state is not None else {}
        await self.catalogs.resolve_model_selection(
            {**current, **dict(selections or {})}.get("model")
        )
        return effective_claude_selections(
            current,
            selections,
            custom_models=self.catalogs.custom_models,
            cli_models=self.catalogs.cli_models,
        )
