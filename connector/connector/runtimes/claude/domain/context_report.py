"""The Claude CLI's own `/context` self-report, and what one session read.

The running engine is the only authority on the context window it enforces: it
must know the size to auto-compact at all, so its answer is true for any setup
— native Claude, a gateway, a custom model — where a model-name guess is not
(a gateway that serves `deepseek-v4.1-flash` under Claude Code's `default`
entry used to be read as a 200k Claude model). `client.query("/context")`
returns the CLI's native markdown report in-process (verified 2026-10-08:
zero API calls, ~65–300 ms, no prompt echo); `parse_context_report` reads the
two lines this feature needs out of it, and `ClaudeContextProbe` is the
per-session cache of that answer.

The parser never guesses: every piece parses on its own, and a line the
report does not carry (or does not parse) yields None for that piece.

The same principle is future work on the other runtime that can answer the
question: codex's SDK already reports `modelContextWindow` on its
`thread/tokenUsage/updated` event (currently dropped by its frame whitelist),
so its calibration will read that channel instead of a slash command. This
module is deliberately Claude-shaped.
"""

from __future__ import annotations

import re
from dataclasses import dataclass

# The native command that makes the CLI report its own context usage. Dispatched
# through the session's SDK prompt, exactly like `/compact`.
CLAUDE_CONTEXT_PROMPT = "/context"

# The report's own opening, used to recognize a leaked probe frame as the CLI's
# local-command output rather than conversation. The verified render starts
# `## Context Usage`; the model/tokens pair is the fallback for a render that
# drops the heading.
CONTEXT_REPORT_HEADING = "## Context Usage"

# Spacing is tolerated inside the markers but never ACROSS a line break, so an
# empty model line cannot swallow the next line's first token as its value.
_MODEL_PATTERN = re.compile(
    r"\*\*[ \t]*Model[ \t]*:?[ \t]*\*\*[ \t]*:?[ \t]*(\S+)",
    re.IGNORECASE,
)
_TOKENS_PATTERN = re.compile(
    r"\*\*[ \t]*Tokens[ \t]*:?[ \t]*\*\*[ \t]*:?[ \t]*"
    r"(\d+(?:\.\d+)?)[ \t]*([kKmM]?)[ \t]*/[ \t]*"
    r"(\d+(?:\.\d+)?)[ \t]*([kKmM]?)",
    re.IGNORECASE,
)
_SUFFIX_MULTIPLIERS = {"": 1, "k": 1_000, "m": 1_000_000}

# How far into a message the model/tokens pair may sit for the heading-less
# report shape to still count as chrome. The measured reports put it at the
# very top; the bound keeps the predicate from ever scanning a long answer.
_CHROME_SCAN_LIMIT = 2048


def parse_context_report(text: str | None) -> tuple[str | None, int | None, int | None]:
    """Read `(model, window, used)` out of one `/context` report.

    The verified report carries both lines:

        **Model:** deepseek-v4.1-flash
        **Tokens:** 12.2k / 1m (1%)

    `used` and `window` accept the `k`/`m` suffixes the CLI renders counts
    with (`15.6k` → 15600, `1m` → 1000000) and tolerates spacing variants
    around the markers, the slash and the percentage. A missing or
    unparseable piece is None — never a fallback derived from the others.
    """

    if not isinstance(text, str) or not text:
        return (None, None, None)
    model_match = _MODEL_PATTERN.search(text)
    model = model_match.group(1) if model_match is not None else None
    used: int | None = None
    window: int | None = None
    tokens_match = _TOKENS_PATTERN.search(text)
    if tokens_match is not None:
        used = _scaled_tokens(tokens_match.group(1), tokens_match.group(2))
        window = _scaled_tokens(tokens_match.group(3), tokens_match.group(4))
    return (model, window, used)


def is_context_report_text(text: str | None) -> bool:
    """Whether a message is the CLI's own `/context` report.

    A probe whose frames outlive the probe (a timeout, a drop) must never be
    read as conversation: the assistant frame is the CLI's local-command
    output, and minting a turn from it would publish the report as a phantom
    answer. `messages.is_synthetic_control_message` consumes this predicate
    alongside the other local-command chrome, so the reader's mint gate and
    the turn's content gate agree on it.
    """

    if not text:
        return False
    normalized = text.lstrip()
    if normalized[: len(CONTEXT_REPORT_HEADING)].casefold() == (
        CONTEXT_REPORT_HEADING.casefold()
    ):
        return True
    if _MODEL_PATTERN.match(normalized) is None:
        return False
    return _TOKENS_PATTERN.search(normalized[:_CHROME_SCAN_LIMIT]) is not None


def _scaled_tokens(value: str, suffix: str) -> int:
    return round(float(value) * _SUFFIX_MULTIPLIERS.get(suffix.casefold(), 1))


@dataclass(slots=True)
class ClaudeContextProbe:
    """One session's last engine self-report, and its probe attempt ledger.

    `selection` is the model selection the report was measured for: the window
    belongs to whatever the engine ran at probe time, so a selection change
    starts a fresh generation — the report fields clear and the attempt budget
    resets. A generation ends when a window is read (`covers`), or when the
    attempt limit is spent; failures are retried with an exponential backoff
    and can never outlive that budget, because a probe is an optimization and
    must never cost the session anything.
    """

    selection: str | None = None
    model: str | None = None
    window: int | None = None
    used: int | None = None
    attempts: int = 0
    last_attempt_at: float | None = None

    def covers(self, selection: str | None) -> bool:
        """Whether a successful report for this model selection is cached."""

        return self.selection == selection and self.window is not None

    def attempt_allowed(
        self,
        selection: str | None,
        *,
        now: float,
        limit: int,
        backoff_seconds: float,
    ) -> bool:
        """Whether a probe may run now: unseen selection, budget left, not backing off."""

        if self.covers(selection):
            return False
        if self.selection != selection:
            return True
        if self.attempts >= limit:
            return False
        if self.last_attempt_at is None:
            return True
        delay = backoff_seconds * (2 ** max(0, self.attempts - 1))
        return now - self.last_attempt_at >= delay

    def begin_attempt(self, selection: str | None, *, now: float) -> None:
        """Open (or restart) the generation this attempt belongs to."""

        if self.selection != selection:
            self.selection = selection
            self.model = None
            self.window = None
            self.used = None
            self.attempts = 0
            self.last_attempt_at = None
        self.attempts += 1
        self.last_attempt_at = now

    def record(self, model: str | None, window: int | None, used: int | None) -> None:
        """Store what one report parsed to (any piece may be None)."""

        self.model = model
        self.window = window
        self.used = used
