package com.agentsanywhere.app.feature.sessiondetail

import com.agentsanywhere.app.R
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * The retired-process disclosure must reach the user as copy, not as the
 * Connector's English wire message — and the codes this build has never
 * heard of must keep reading as something a person can act on.
 */
class RuntimeErrorCopyTest {
    @Test
    fun theRetirementCodeHasCopy() {
        assertEquals(R.string.session_claude_process_retired, runtimeErrorCopyRes("claude_process_retired"))
    }

    /** The old timeout code is a DIFFERENT incident (no close happened), and
     * its wording is still correct. Mapping it here would silently rewrite a
     * sentence that was never the defect. */
    @Test
    fun theTimeoutCodeKeepsTheConnectorsOwnWording() {
        assertNull(runtimeErrorCopyRes("claude_scheduled_turn_timeout"))
    }

    /** The contract with every future code: keep today's behaviour. An
     * unknown code reaches the user as the Connector's own message, never as
     * an empty string and never as a serialized payload. */
    @Test
    fun anUnknownCodeHasNoCopy() {
        assertNull(runtimeErrorCopyRes("code_from_a_newer_connector"))
        assertNull(runtimeErrorCopyRes(null))
    }

    @Test
    fun theCodeIsReadOffTheErrorPayload() {
        val payload = mapOf<String, Any?>(
            "code" to "claude_process_retired",
            "message" to "The Claude process was terminated after failing to respond.",
            "params" to mapOf("stuckSeconds" to 600),
        )
        assertEquals("claude_process_retired", payload.runtimeErrorCode())
        assertNotNull(runtimeErrorCopyRes(payload.runtimeErrorCode()))
    }

    /** A payload with no code, or a code that is not a string, must not crash
     * the lookup — it is the same unknown-code path. */
    @Test
    fun aMissingOrNonStringCodeIsJustAnUnknownCode() {
        assertNull(mapOf<String, Any?>("message" to "boom").runtimeErrorCode())
        assertNull(mapOf<String, Any?>("code" to 42).runtimeErrorCode())
        assertNull((null as Map<String, Any?>?).runtimeErrorCode())
        assertNull(runtimeErrorCopyRes(mapOf<String, Any?>("code" to 42).runtimeErrorCode()))
    }
}