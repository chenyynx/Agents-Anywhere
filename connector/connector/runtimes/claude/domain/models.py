from __future__ import annotations

from collections.abc import Mapping, Sequence
from dataclasses import dataclass
from typing import Any

from connector.runtime_protocol import (
    RuntimeInvalidRequestError,
    RuntimeModelCatalog,
    RuntimeModelItem,
    RuntimeReasoningItem,
)
from connector.runtimes.custom_models import custom_model_items
from connector.server.protocol import protocol_selection_id

# Claude Code's `/model` entry that means "no --model flag".
CLAUDE_DEFAULT_MODEL_ID = "default"

# The context windows a Claude Code model entry can declare. The CLI reports
# no window size; the only signal on the wire is the `[1m]` marker on the
# resolved model id (Claude Code's own naming for the 1M-context variant), so
# a Claude-family entry without it is the standard 200k. A gateway's own
# models are unknown and get no key at all — clients hide their context
# indicator rather than guess.
CLAUDE_EXTENDED_CONTEXT_MARKER = "[1m]"
CLAUDE_EXTENDED_CONTEXT_WINDOW = 1_000_000
CLAUDE_DEFAULT_CONTEXT_WINDOW = 200_000


@dataclass(frozen=True, slots=True)
class ClaudeModelSelection:
    model_id: str
    effort_id: str | None = None

    @property
    def cli_model(self) -> str | None:
        return None if self.model_id == CLAUDE_DEFAULT_MODEL_ID else self.model_id


_CLAUDE_EFFORTS: tuple[dict[str, str], ...] = (
    {
        "id": "low",
        "title": "Low",
        "description": "Quick, straightforward implementation with minimal overhead.",
    },
    {
        "id": "medium",
        "title": "Medium",
        "description": "Balanced approach with standard implementation and testing.",
    },
    {
        "id": "high",
        "title": "High",
        "description": "Comprehensive implementation with deeper reasoning.",
    },
    {
        "id": "xhigh",
        "title": "Extra high",
        "description": "Deeper reasoning than high, just below maximum.",
    },
    {
        "id": "max",
        "title": "Max",
        "description": "Maximum capability with deepest reasoning.",
    },
)


_CLAUDE_MODELS: tuple[dict[str, Any], ...] = (
    {
        "id": "claude-fable-5",
        "title": "Claude Fable 5",
        "description": "Highest-capability generally available Claude model.",
        "family": "fable",
        "generation": "5",
    },
    {
        "id": "claude-opus-5",
        "title": "Claude Opus 5",
        "description": "High-capability Claude model for complex agentic coding.",
        "family": "opus",
        "generation": "5",
    },
    {
        "id": "claude-sonnet-5",
        "title": "Claude Sonnet 5",
        "description": "Balanced Claude model for everyday coding tasks.",
        "family": "sonnet",
        "generation": "5",
    },
    {
        "id": "claude-haiku-4-5-20251001",
        "title": "Claude Haiku 4.5",
        "description": "Fast Claude model for lightweight coding tasks.",
        "family": "haiku",
        "generation": "4.5",
    },
    {
        "id": "claude-opus-4-8",
        "title": "Claude Opus 4.8",
        "description": "Claude Code-supported Opus 4.x model.",
        "family": "opus",
        "generation": "4.8",
        "legacy": True,
    },
    {
        "id": "claude-opus-4-7",
        "title": "Claude Opus 4.7",
        "description": "Claude Code-supported Opus 4.x model.",
        "family": "opus",
        "generation": "4.7",
        "legacy": True,
    },
    {
        "id": "claude-sonnet-4-6",
        "title": "Claude Sonnet 4.6",
        "description": "Claude Code-supported Sonnet 4.x model.",
        "family": "sonnet",
        "generation": "4.6",
        "legacy": True,
    },
    {
        "id": "claude-sonnet-4-5",
        "title": "Claude Sonnet 4.5",
        "description": "Claude Code-supported Sonnet 4.x model.",
        "family": "sonnet",
        "generation": "4.5",
        "legacy": True,
    },
)


def claude_model_catalog(
    revision: int,
    query: str | None = None,
    limit: int = 100,
    custom_models: object | None = None,
    cli_models: Sequence[Mapping[str, Any]] = (),
) -> RuntimeModelCatalog:
    """Build the picker catalog.

    `cli_models` is the list Claude Code reports at initialize; when it is
    available it replaces the static table so new CLI models show up without a
    Connector release. The static table remains the fallback.
    """

    if cli_models:
        models = tuple(_cli_model_item(model) for model in cli_models)
    else:
        models = tuple(_model_item(model) for model in _CLAUDE_MODELS)
    models = (
        *models,
        *custom_model_items(
            "claude",
            custom_models,
            existing_model_ids={model.id for model in models},
        ),
    )
    if query:
        lowered = query.casefold()
        models = tuple(
            model
            for model in models
            if lowered in model.id.casefold() or lowered in model.title.casefold()
        )
    return RuntimeModelCatalog(
        runtime="claude",
        revision=revision,
        models=models[:limit],
    )


def model_selection_from_selection_id(
    selection_id: str | None,
    custom_models: object | None = None,
    cli_models: Sequence[Mapping[str, Any]] = (),
) -> ClaudeModelSelection | None:
    if selection_id is None:
        return None
    for model in _selection_candidates(custom_models, cli_models):
        if model.selection_id == selection_id:
            return ClaudeModelSelection(model_id=model.id)
        for effort in model.reasoning_items:
            if effort.selection_id == selection_id:
                return ClaudeModelSelection(model_id=model.id, effort_id=effort.id)
    raise RuntimeInvalidRequestError("unknown Claude model selection")


def _selection_candidates(
    custom_models: object | None,
    cli_models: Sequence[Mapping[str, Any]],
) -> tuple[RuntimeModelItem, ...]:
    # Sessions keep the selection ids they were created with, so static
    # entries stay resolvable even while the picker shows the CLI list.
    candidates = list(
        claude_model_catalog(
            revision=0,
            custom_models=custom_models,
            cli_models=cli_models,
        ).models
    )
    # A CLI entry can reuse a static model id while reporting fewer efforts.
    # Keep its saved static selections resolvable without adding those efforts
    # to the picker, which continues to show the CLI's reported capabilities.
    candidates.extend(_model_item(model) for model in _CLAUDE_MODELS)
    return tuple(candidates)


def _cli_model_item(item: Mapping[str, Any]) -> RuntimeModelItem:
    model_id = str(item["value"])
    display_name = item.get("displayName")
    description = item.get("description")
    metadata: dict[str, Any] = {"source": "claude-code.initialize"}
    resolved_model = item.get("resolvedModel")
    if isinstance(resolved_model, str) and resolved_model:
        metadata["resolvedModel"] = resolved_model
    for key in ("supportsFastMode", "supportsAutoMode", "supportsAdaptiveThinking"):
        if isinstance(item.get(key), bool):
            metadata[key] = item[key]
    window = claude_context_window(
        resolved_model if isinstance(resolved_model, str) else None,
        model_id,
    )
    if window is not None:
        metadata["contextWindow"] = window
    return RuntimeModelItem(
        id=model_id,
        title=display_name
        if isinstance(display_name, str) and display_name
        else model_id,
        selection_id=protocol_selection_id(
            "claude",
            "model",
            {"model_id": model_id},
        ),
        description=description if isinstance(description, str) else None,
        reasoning_items=_reasoning_items(model_id, _cli_effort_ids(item)),
        metadata=metadata,
    )


def _cli_effort_ids(item: Mapping[str, Any]) -> tuple[str, ...]:
    if item.get("supportsEffort") is not True:
        return ()
    levels = item.get("supportedEffortLevels")
    if not isinstance(levels, list):
        return ()
    return tuple(level for level in levels if isinstance(level, str) and level)


def _model_item(item: dict[str, Any]) -> RuntimeModelItem:
    model_id = str(item["id"])
    metadata = {
        "source": "claude-code.static-models",
        "family": item.get("family"),
        "generation": item.get("generation"),
    }
    if item.get("legacy") is True:
        metadata["legacy"] = True
    window = claude_context_window(model_id)
    if window is not None:
        metadata["contextWindow"] = window
    return RuntimeModelItem(
        id=model_id,
        title=str(item["title"]),
        selection_id=protocol_selection_id(
            "claude",
            "model",
            {"model_id": model_id},
        ),
        description=str(item["description"]),
        reasoning_items=_reasoning_items(model_id),
        metadata=metadata,
    )


def claude_context_window(*candidates: str | None) -> int | None:
    """The context window a Claude Code model entry declares, if known.

    Derived from the entry's raw CLI fields — `resolvedModel` first, `value`
    as the fallback. `[1m]` in any candidate means the 1M-context variant; a
    `claude*` id otherwise is the standard window. Anything else (a gateway's
    own models) returns None so the key is omitted from the catalog metadata
    and the clients hide their context indicator instead of guessing.
    """

    for candidate in candidates:
        if candidate and CLAUDE_EXTENDED_CONTEXT_MARKER in candidate:
            return CLAUDE_EXTENDED_CONTEXT_WINDOW
    if any(candidate and candidate.startswith("claude") for candidate in candidates):
        return CLAUDE_DEFAULT_CONTEXT_WINDOW
    return None


def _reasoning_items(
    model_id: str,
    effort_ids: Sequence[str] | None = None,
) -> tuple[RuntimeReasoningItem, ...]:
    known = {effort["id"]: effort for effort in _CLAUDE_EFFORTS}
    ids = tuple(known) if effort_ids is None else tuple(effort_ids)
    return tuple(
        RuntimeReasoningItem(
            id=effort_id,
            title=known[effort_id]["title"] if effort_id in known else effort_id,
            selection_id=protocol_selection_id(
                "claude",
                "model",
                {"model_id": model_id, "effort_id": effort_id},
            ),
            description=known[effort_id]["description"] if effort_id in known else None,
            metadata={"source": "claude-agent-sdk.effort"},
        )
        for effort_id in ids
    )
