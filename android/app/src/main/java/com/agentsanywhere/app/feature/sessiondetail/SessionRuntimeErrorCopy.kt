package com.agentsanywhere.app.feature.sessiondetail

import androidx.annotation.StringRes
import com.agentsanywhere.app.R

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
 * Unknown codes return null so the caller keeps today's behaviour. That
 * fallback is the contract with every code this table has not been taught
 * yet, and `RuntimeErrorCopyTest` pins it — an unknown code must reach the
 * user as the Connector's own message, never as an empty string and never as
 * a serialized payload.
 */
internal fun runtimeErrorCopyRes(code: String?): Int? = when (code) {
    "claude_process_retired" -> R.string.session_claude_process_retired
    else -> null
}

/** The code on a runtime error payload, or null when there is none. */
internal fun Map<String, Any?>?.runtimeErrorCode(): String? = this?.get("code") as? String