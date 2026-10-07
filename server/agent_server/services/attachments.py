from __future__ import annotations

import base64
import hashlib
import secrets
from typing import Any

from agent_server.infra.files import FileStorage
from agent_server.core.models import UploadedAttachment
from agent_server.core.auth import create_signed_token
from agent_server.core.api_namespace import api_v2_path
from agent_server.core.utc import utc_now


LOCAL_FILE_TOKEN_KIND = "local_file"
LOCAL_FILE_TOKEN_EXPIRES_IN = 300
FILE_OPEN_EXPIRES_IN = 300
# Upper bound for the optional image dimensions in attachment metadata.
MAX_ATTACHMENT_DIMENSION = 65535


class AttachmentService:
    def __init__(self, store: Any, files: FileStorage) -> None:
        self._store = store
        self._files = files

    async def save_user_upload(
        self,
        *,
        session_id: str,
        user_id: str,
        name: str,
        data: bytes,
        media_type: str | None = None,
        width: int | None = None,
        height: int | None = None,
    ) -> dict[str, Any]:
        async with self._store.attachment_write_fence(session_id, user_id=user_id):
            return await self._persist_file_blob(
                session_id=session_id,
                data=data,
                name=name,
                media_type=media_type,
                origin="user",
                width=width,
                height=height,
            )

    async def read_user_file(
        self,
        *,
        session_id: str,
        file_id: str,
        user_id: str,
    ) -> dict[str, Any]:
        await self._store.get_session(session_id, user_id=user_id)
        self._validate_file_id(file_id)
        data, metadata = await self._files.read(session_id, file_id)
        self._validate_blob_integrity(data, metadata)
        return {
            **metadata,
            "contentBase64": base64.b64encode(data).decode("ascii"),
        }

    async def read_local_signed_file(
        self,
        *,
        session_id: str,
        file_id: str,
    ) -> tuple[bytes, dict[str, Any]]:
        self._validate_file_id(file_id)
        data, metadata = await self._files.read(session_id, file_id)
        self._validate_blob_integrity(data, metadata)
        return data, metadata

    async def read_shared_file(
        self,
        *,
        session_id: str,
        file_id: str,
    ) -> tuple[bytes, dict[str, Any]]:
        self._validate_file_id(file_id)
        data, metadata = await self._files.read(session_id, file_id)
        self._validate_blob_integrity(data, metadata)
        return data, metadata

    async def user_file_metadata(
        self,
        *,
        session_id: str,
        file_id: str,
        user_id: str,
    ) -> dict[str, Any]:
        await self._store.get_session(session_id, user_id=user_id)
        self._validate_file_id(file_id)
        return await self._files.metadata(session_id, file_id)

    async def user_file_open_url(
        self,
        *,
        session_id: str,
        file_id: str,
        user_id: str,
    ) -> str:
        await self.user_file_metadata(
            session_id=session_id,
            file_id=file_id,
            user_id=user_id,
        )
        return await self.signed_file_open_url(session_id=session_id, file_id=file_id)

    async def signed_file_open_url(
        self,
        *,
        session_id: str,
        file_id: str,
    ) -> str:
        self._validate_file_id(file_id)
        native = await self._files.open_url(
            session_id,
            file_id,
            expires_in=FILE_OPEN_EXPIRES_IN,
        )
        if native is not None:
            return native.url
        token = create_signed_token(
            LOCAL_FILE_TOKEN_KIND,
            {"sessionId": session_id, "fileId": file_id},
            LOCAL_FILE_TOKEN_EXPIRES_IN,
        )
        return f"{api_v2_path(f'/sessions/local/{session_id}/{file_id}')}?token={token}"

    async def read_connector_attachment(
        self,
        *,
        session_id: str,
        file_id: str,
        connector_id: str,
    ) -> tuple[bytes, dict[str, Any]]:
        self._validate_file_id(file_id)
        if not await self._store.session_owned_by_connector(session_id, connector_id):
            raise KeyError(session_id)
        data, metadata = await self._files.read(session_id, file_id)
        self._validate_blob_integrity(data, metadata)
        return data, metadata

    async def delete_file(self, *, session_id: str, file_id: str) -> None:
        self._validate_file_id(file_id)
        await self._files.delete(session_id, file_id)

    async def uploaded_attachment_view(
        self,
        *,
        session_id: str,
        saved: dict[str, Any],
        fallback_media_type: str,
    ) -> UploadedAttachment:
        return UploadedAttachment(
            fileId=saved["fileId"],
            sessionId=session_id,
            name=saved["name"],
            size=saved["size"],
            sha256=saved["sha256"],
            mediaType=saved.get("mediaType") or fallback_media_type,
            createdAt=saved["createdAt"],
            downloadUrl=api_v2_path(f"/sessions/{session_id}/attachments/{saved['fileId']}"),
            openUrl=api_v2_path(f"/sessions/{session_id}/attachments/{saved['fileId']}/open"),
            width=valid_dimension(saved.get("width")),
            height=valid_dimension(saved.get("height")),
        )

    async def _persist_file_blob(
        self,
        *,
        session_id: str,
        data: bytes,
        name: str | None,
        source_path: str | None = None,
        media_type: str | None = None,
        origin: str,
        width: int | None = None,
        height: int | None = None,
    ) -> dict[str, Any]:
        file_id = f"file_{secrets.token_urlsafe(12)}"
        created_at = utc_now()
        metadata: dict[str, Any] = {
            "fileId": file_id,
            "sessionId": session_id,
            "path": source_path or "",
            "name": name or file_id,
            "size": len(data),
            "sha256": hashlib.sha256(data).hexdigest(),
            "mediaType": media_type or "",
            "origin": origin,
            "createdAt": created_at,
        }
        # Only valid dimensions reach the sidecar; anything else falls back to
        # clients deriving the display size themselves.
        if valid_dimension(width) is not None:
            metadata["width"] = width
        if valid_dimension(height) is not None:
            metadata["height"] = height
        await self._files.write(session_id, file_id, data, metadata)
        return metadata

    @staticmethod
    def _validate_file_id(file_id: str) -> None:
        if "/" in file_id or "\\" in file_id or not file_id.startswith("file_"):
            raise KeyError(file_id)

    @staticmethod
    def _validate_blob_integrity(data: bytes, metadata: dict[str, Any]) -> None:
        actual_sha256 = hashlib.sha256(data).hexdigest()
        if actual_sha256 != metadata.get("sha256") or len(data) != metadata.get("size"):
            raise ValueError("stored file metadata does not match content")


def valid_dimension(value: Any) -> int | None:
    """Return the value when it is a usable pixel dimension, else None.

    Shared by the write path (only valid dimensions reach the sidecar) and the
    read path (metadata written by an older server simply has no key).
    """

    if (
        isinstance(value, int)
        and not isinstance(value, bool)
        and 1 <= value <= MAX_ATTACHMENT_DIMENSION
    ):
        return value
    return None


class AttachmentMaterializer:
    """Runtime input helper for future driver-specific attachment handoff."""

    @staticmethod
    def path_hint(metadata: dict[str, Any], path: str) -> str:
        name = metadata.get("name") or metadata.get("fileId") or "attachment"
        media_type = metadata.get("mediaType") or "application/octet-stream"
        size = metadata.get("size") or 0
        return f"[Attached file: {name} ({media_type}, {size} bytes) at {path}]"
