# Claude session process lifecycle

The Connector owns at most one live Claude SDK connection (and its CLI process)
per active AA session. A completed model reply is not the end of that connection:
subsequent user turns reuse it while it remains open. Different AA sessions do
not share a CLI process, even when they use the same project directory. An
inactive historical session is not reopened merely because it exists.

## Reclamation

After a turn completes, an ordinary streaming connection becomes eligible for
reclamation after `idleTimeoutSeconds` (default 600, configurable from 60 to
86400 seconds). A new turn cancels and resets that timer. At expiry, the
Connector checks the same session and connection again under the session lock
before closing it; queued input or an active execution prevents eviction.
Clients without a continuous receive stream retain their one-shot behavior.

Native `task_started` and `task_progress` events mark background work active,
as do the ids in the CLI's `background_tasks_changed` snapshot. Terminal
`task_updated` or `task_notification` events clear it. The connection
is not reclaimed while any observed background task is active, even after the
main reply ends. An unconfirmed task is not assumed complete. Model or
permission changes do not force-close a connection with active background
work; the next turn can use the new selection after that work completes.

Future wakeups are a separate constraint: observed `CronCreate`/`CronList`
jobs keep the process alive regardless of idle timeout, and a successful
empty reconciliation removes that reason to retain it. Failed reconciliation
does not mean an empty job list. Reconciliation waits for native background
work to finish so its maintenance-only tool restrictions do not interrupt that
work. Runtime shutdown and transport failure close
the owned connection; a cleanly interrupted turn can leave it available, while
an input that cannot be individually retracted may require closing it.
After process loss, ordinary turns can resume from the native session ID;
in-flight background work is not automatically replayed. Startup reconnects
only sessions registered with observed scheduled jobs.

## Stuck-turn circuit breaker

A turn that holds the session's execution lock without ever seeing a terminal
result is treated as a defect to be capped, not a state to be waited out. This
is the main defense against a "ghost" turn: user environments write arbitrary
hooks, so the shape that mints a turn nobody is waiting for cannot be
enumerated — but the symptom always looks the same (lock held, no terminal,
nothing published).

A scheduled turn (one the Connector minted from the CLI's own output, with no
user prompt behind it) is given a fixed 30 second budget. When it expires the
Connector publishes a failed terminal and releases the lock, retiring the CLI
process and rebuilding the connection on the next turn — the same retirement
any failed turn performs, because a native prompt cannot be retracted one turn
at a time — **unless observed background work is still active on that
connection**. Live background work (background subagents, background commands)
exists nowhere but that process, and upstream never replays in-flight work
after process loss, so retirement is withheld while the work is alive: the
ghost response is dropped so the reader can route again, the next turn reuses
the same transport, and at most one failed-turn report reaches the client per
connection window (repeat timeouts keep releasing the lock and updating the
session state, but stay off the turn ledger). The failed-turn transport close
follows the same rule. The scheduled job bookkeeping observed on that
connection is handed over to a replacement when a retirement does happen, so
the breaker never silently untracks a session's tasks. The composer stays
usable and the next message is answered normally. Ordinary user turns are never
armed with this budget — a slow model is not a stuck turn.

Frames that are the CLI's own chrome rather than a reply — `SessionStart` hook
narration, non-task system handshakes, compaction bookkeeping, and the
`<command-name>` / `<local-command-caveat>` / `<local-command-stdout>` echoes
the CLI replays after a slash command — are governed rather than answered: at
reader silence they are buffered as preamble instead of minting a turn.
Frames parented to a tool call — activity *inside* a background subagent
leaking into the parent stream — are absorbed the same way: they are work in
progress, not replies, and never mint a turn from silence (the main agent's
own wake-and-report frames carry `parent_tool_use_id=None`). This is noise
reduction only; the breaker above is what guarantees the outcome.

## Agent-set session titles

Every Claude session's system prompt extends Claude Code's own with an
instruction to call the `change_title` tool — an in-process SDK MCP server
(`connector/connector/runtimes/claude/sdk/title_tool.py`) modelled on
HappyCoder's `mcp__happy__change_title` and the Claudio bridge. The tool
handler writes the accepted title back into Claude Code itself through the
SDK's official `rename_session` (a `custom-title` transcript entry; last
write wins, repeated calls are safe), then publishes it immediately over
`session.meta.upsert` (`source: claude.session.agent_title`). The periodic
inventory sync re-reads `custom_title` afterwards — the reader's top title
priority — so the title is durable without any connector-side state. Guards:
empty → duplicate → 8-second throttle; the PreToolUse hook auto-allows the
tool (it is connector bookkeeping and must never surface as a client
approval), and user renames always win (the server rejects connector titles
once a session's `title_source` is `user`). The tool's frames are hidden
from the timeline alongside the Cron*/Task* plumbing tools, so no tool card
reaches clients.

## Pending validation

This lifecycle change has local automated coverage. Verified against the real
CLI: a no-Cron background task completes after its initiating reply, including
background subagents surviving the dispatch reply (incident-wire replay suite
plus a live-CLI harness). Still **pending real validation**: the configured
idle timeout reclaiming the connection, and a scheduled job firing on time
without a new prompt. Also repeat #122 (legacy `ScheduleWakeup`) and #123
(background notification racing a real user message) against the deployed
SDK/CLI; neither issue is closed by the presence of an idle timer. Durable
task ownership across multiple Connector processes and recovery of interrupted
background work are not guaranteed.
