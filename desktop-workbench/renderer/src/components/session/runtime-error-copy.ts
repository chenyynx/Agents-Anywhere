/**
 * Runtime error codes whose Connector `message` names the wrong cause.
 *
 * A `message` on the wire is written once, in English, by the Connector, and
 * passing it through verbatim is the right default — most runtime errors are
 * diagnostic and the raw sentence is the useful one. It is the wrong default
 * for the codes below, where the English sentence says the model was slow
 * while the truth is that the CLI process was terminated and every task
 * running inside it ended. A user told the false cause rescues nothing and
 * retries nothing, so the false cause is the defect, not the wording.
 *
 * Lookup is by CODE and never by message text: the Connector owns the code's
 * stability, whereas matching prose breaks silently the first time that prose
 * is edited.
 *
 * Unknown codes return null so the caller keeps today's behaviour — the
 * generic error surface. That fallback is the contract with every code this
 * table has not been taught yet, and `runtime-error-copy.test.mjs` pins it.
 */
const RUNTIME_ERROR_COPY_KEYS: Record<string, string> = {
  claude_process_retired: 'claudeProcessRetired',
}

/** The message key this build would use for `code`, or null when it has none. */
export function runtimeErrorCopyKey(code: string | null | undefined): string | null {
  if (typeof code !== 'string' || !code) return null
  return RUNTIME_ERROR_COPY_KEYS[code] ?? null
}