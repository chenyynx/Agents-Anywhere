from __future__ import annotations


class RuntimeProtocolError(RuntimeError):
    code = "runtime_protocol_error"
    retryable = False


class RuntimeUnsupportedError(RuntimeProtocolError):
    code = "runtime_unsupported"

    def __init__(self, method: str) -> None:
        super().__init__(f"runtime does not support {method}")
        self.method = method


class RuntimeInvalidRequestError(RuntimeProtocolError):
    code = "runtime_invalid_request"

    def __init__(self, message: str, *, status: str | None = None) -> None:
        super().__init__(message)
        # Same channel as RuntimeUnavailableError: an instance the supervisor
        # has never registered is a different truth from one that is merely
        # starting, and the Server must be able to tell them apart.
        self.status = status


class RuntimeConflictError(RuntimeProtocolError):
    code = "runtime_conflict"


class RuntimeUnavailableError(RuntimeProtocolError):
    code = "runtime_unavailable"
    retryable = True

    def __init__(self, message: str, *, status: str | None = None) -> None:
        super().__init__(message)
        # The lifecycle state the instance was actually in. Carried as a
        # structured field so the Server can speak the truth instead of
        # re-reading this sentence: `starting` and `stopped` share this code
        # and are not the same event to a user.
        self.status = status


class RuntimeUpstreamError(RuntimeProtocolError):
    code = "runtime_upstream_error"
