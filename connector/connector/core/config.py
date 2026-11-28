from __future__ import annotations

import json
import os
from dataclasses import dataclass, replace
from pathlib import Path
from typing import Any

from connector.paths import connector_data_dir


@dataclass(slots=True)
class ConnectorConfig:
    server_url: str
    connector_id: str
    connector_token: str
    heartbeat_seconds: float = 20
    reconnect_seconds: float = 3
    sync_existing_on_connect: bool = True
    sync_interval_seconds: float = 30
    state_path: str | None = None
    phone_bridge_enabled: bool = False
    phone_bridge_listen_host: str = "127.0.0.1"
    phone_bridge_listen_port: int = 18200
    phone_bridge_device_id: str | None = None
    phone_bridge_target_port: int = 8200

    @classmethod
    def default_path(cls) -> Path:
        configured = os.environ.get("AGENT_CONNECTOR_CONFIG")
        return (
            Path(configured).expanduser()
            if configured
            else connector_data_dir() / "connector.json"
        )

    @classmethod
    def from_env(cls) -> ConnectorConfig:
        missing = [
            name
            for name in (
                "AGENT_SERVER_URL",
                "AGENT_CONNECTOR_ID",
                "AGENT_CONNECTOR_TOKEN",
            )
            if not os.environ.get(name)
        ]
        if missing:
            raise RuntimeError(f"missing required environment variables: {', '.join(missing)}")
        return cls(
            server_url=os.environ["AGENT_SERVER_URL"].rstrip("/"),
            connector_id=os.environ["AGENT_CONNECTOR_ID"],
            connector_token=os.environ["AGENT_CONNECTOR_TOKEN"],
            heartbeat_seconds=float(os.environ.get("AGENT_CONNECTOR_HEARTBEAT_SECONDS", "20")),
            reconnect_seconds=float(os.environ.get("AGENT_CONNECTOR_RECONNECT_SECONDS", "3")),
            sync_existing_on_connect=_bool_env(
                "AGENT_CONNECTOR_SYNC_EXISTING",
                True,
            ),
            sync_interval_seconds=float(os.environ.get("AGENT_CONNECTOR_SYNC_INTERVAL_SECONDS", "30")),
            state_path=os.environ.get("AGENT_CONNECTOR_STATE_FILE"),
            phone_bridge_enabled=_bool_env(
                "AGENT_CONNECTOR_PHONE_BRIDGE_ENABLED",
                False,
            ),
            phone_bridge_listen_host=os.environ.get(
                "AGENT_CONNECTOR_PHONE_BRIDGE_HOST", "127.0.0.1"
            ),
            phone_bridge_listen_port=int(
                os.environ.get("AGENT_CONNECTOR_PHONE_BRIDGE_PORT", "18200")
            ),
            phone_bridge_device_id=os.environ.get("AGENT_CONNECTOR_PHONE_BRIDGE_DEVICE"),
            phone_bridge_target_port=int(
                os.environ.get("AGENT_CONNECTOR_PHONE_BRIDGE_TARGET_PORT", "8200")
            ),
        )

    @classmethod
    def load(cls, path: str | Path | None = None) -> ConnectorConfig:
        config_path = Path(path) if path is not None else cls.default_path()
        data = json.loads(config_path.read_text(encoding="utf-8-sig"))
        return apply_phone_bridge_env(cls.from_mapping(data))

    @classmethod
    def from_mapping(cls, data: dict[str, Any]) -> ConnectorConfig:
        return cls(
            server_url=str(data["serverUrl"]).rstrip("/"),
            connector_id=str(data["connectorId"]),
            connector_token=str(data["connectorToken"]),
            heartbeat_seconds=float(data.get("heartbeatSeconds", 20)),
            reconnect_seconds=float(data.get("reconnectSeconds", 3)),
            sync_existing_on_connect=bool(data.get("syncExistingOnConnect", True)),
            sync_interval_seconds=float(data.get("syncIntervalSeconds", 30)),
            state_path=(
                data.get("statePath")
                if isinstance(data.get("statePath"), str)
                else None
            ),
            phone_bridge_enabled=bool(data.get("phoneBridgeEnabled", False)),
            phone_bridge_listen_host=str(
                data.get("phoneBridgeListenHost", "127.0.0.1")
            ),
            phone_bridge_listen_port=int(data.get("phoneBridgeListenPort", 18200)),
            phone_bridge_device_id=(
                data.get("phoneBridgeDeviceId")
                if isinstance(data.get("phoneBridgeDeviceId"), str)
                else None
            ),
            phone_bridge_target_port=int(data.get("phoneBridgeTargetPort", 8200)),
        )

    def save(self, path: str | Path | None = None) -> Path:
        config_path = Path(path) if path is not None else self.default_path()
        config_path.parent.mkdir(parents=True, exist_ok=True)
        config_path.write_text(
            json.dumps(
                {
                    "serverUrl": self.server_url,
                    "connectorId": self.connector_id,
                    "connectorToken": self.connector_token,
                    "heartbeatSeconds": self.heartbeat_seconds,
                    "reconnectSeconds": self.reconnect_seconds,
                    "syncExistingOnConnect": self.sync_existing_on_connect,
                    "syncIntervalSeconds": self.sync_interval_seconds,
                    "statePath": self.state_path,
                    "phoneBridgeEnabled": self.phone_bridge_enabled,
                    "phoneBridgeListenHost": self.phone_bridge_listen_host,
                    "phoneBridgeListenPort": self.phone_bridge_listen_port,
                    "phoneBridgeDeviceId": self.phone_bridge_device_id,
                    "phoneBridgeTargetPort": self.phone_bridge_target_port,
                },
                ensure_ascii=False,
                indent=2,
            )
            + "\n",
            encoding="utf-8",
        )
        config_path.chmod(0o600)
        return config_path


def _bool_env(name: str, default: bool) -> bool:
    value = os.environ.get(name)
    if value is None:
        return default
    return value.strip().lower() in {"1", "true", "yes", "on"}


def apply_phone_bridge_env(config: ConnectorConfig) -> ConnectorConfig:
    """Overlay the Phone Bridge env vars on a config built from args/file.

    ``from_env`` only runs when every credential is an env var; the CLI also
    accepts flags and a JSON file, so the phone fields need this separate pass.
    Unset variables keep the file/flag value.
    """

    def _int(name: str, current: int) -> int:
        raw = os.environ.get(name)
        if raw is None or not raw.strip():
            return current
        try:
            return int(raw)
        except ValueError:
            return current

    return replace(
        config,
        phone_bridge_enabled=_bool_env(
            "AGENT_CONNECTOR_PHONE_BRIDGE_ENABLED", config.phone_bridge_enabled
        ),
        phone_bridge_listen_host=os.environ.get(
            "AGENT_CONNECTOR_PHONE_BRIDGE_HOST", config.phone_bridge_listen_host
        ),
        phone_bridge_listen_port=_int(
            "AGENT_CONNECTOR_PHONE_BRIDGE_PORT", config.phone_bridge_listen_port
        ),
        phone_bridge_device_id=os.environ.get(
            "AGENT_CONNECTOR_PHONE_BRIDGE_DEVICE", config.phone_bridge_device_id
        ),
        phone_bridge_target_port=_int(
            "AGENT_CONNECTOR_PHONE_BRIDGE_TARGET_PORT",
            config.phone_bridge_target_port,
        ),
    )
