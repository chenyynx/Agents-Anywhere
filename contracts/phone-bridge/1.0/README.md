# Phone Bridge 1.0 Contract

Phone Bridge carries raw TCP bytes between an AA Connector and a paired iPhone
running iCTRL, through the AA Server. The Server never decrypts iCTRL's
application envelope: it forwards the encrypted JSON-RPC body as opaque bytes.

```text
Connector local listener (127.0.0.1:18200)
  → Server PhoneBridgeBroker
  → AA iOS App PhoneBridgeClient
  → iCTRL runner (127.0.0.1:8200)
```

## Versioning

`phone-bridge/1.0` is independent of the application version. Additive fields
are allowed; unknown fields must be ignored by all three ends. Removing or
renaming a field requires `2.0`.

## Endpoints

| Method | Path | Auth | Purpose |
|---|---|---|---|
| `POST` | `/api/v2/connectors/{connectorId}/phone/bridges` | Connector Bearer access token | Create a bridge to one online phone; `deviceId` may be omitted when exactly one phone is online |
| `GET` | `/api/v2/phone/devices` | User Bearer access token | List the user's online phones |
| `GET` | `/api/v2/connectors/{connectorId}/phone/devices` | Connector Bearer access token | Same list for the connector's owner |
| `WS` | `/api/v2/phone/ws?ticket=...` | `ws-ticket` with `scope.phone=true` | Phone side |
| `WS` | `/api/v2/connectors/{connectorId}/phone/{bridgeId}/relay?token=...` | `Authorization: Bearer <connector access token>` + signed bridge relay token | Connector side |

The phone ticket is a single-use `ws-ticket`. The relay token is a signed,
short-lived token bound to `bridgeId`, `connectorId`, and `userId`. The
connector access token travels in the `Authorization` header so it never appears
in the request line or server logs; only the 60 s relay token stays in the query.

## Limits

- Allowed target ports: `[8200]` only.
- Max frame: 1 MiB (decoded `data` bytes).
- Idle bridge timeout: 300 s.
- Bridge token lifetime: 60 s (must attach before expiry).
- Max concurrent bridges per device: 4.
- Max concurrent bridges per user: 8.

## Frames

All frames are JSON text frames. `data` is base64 of the raw TCP bytes.

### Server → phone

```json
{"type":"open","bridgeId":"pb_...","port":8200,"connectorName":"MacBook-Pro"}
{"type":"data","bridgeId":"pb_...","seq":1,"data":"..."}
{"type":"close","bridgeId":"pb_...","reason":"eof|timeout|error|revoked"}
{"type":"ping"}
```

### Server → phone (after hello)

```json
{"type":"registered","deviceId":"..."}
```

### Phone → server

```json
{"type":"hello","deviceId":"...","name":"iPhone","appVersion":"1.0","bridgeVersion":"1"}
{"type":"ready","bridgeId":"pb_...","port":8200}
{"type":"data","bridgeId":"pb_...","seq":1,"data":"..."}
{"type":"error","bridgeId":"pb_...","code":"port_refused","message":"..."}
{"type":"close","bridgeId":"pb_...","reason":"eof|error"}
{"type":"pong"}
```

### Connector → server

The connector relay socket is per bridge, so `bridgeId` is implicit and omitted.

```json
{"type":"data","seq":1,"data":"..."}
{"type":"close","reason":"eof|error"}
{"type":"ping"}
```

### Server → connector

```json
{"type":"ready","bridgeId":"pb_...","port":8200}
{"type":"data","seq":1,"data":"..."}
{"type":"close","reason":"eof|timeout|error|revoked"}
{"type":"error","code":"...","message":"..."}
{"type":"pong"}
```

## State machine

```text
create → phone open → phone ready → connector attached → relaying
                                              │
                                              ├─ phone close → close
                                              ├─ connector close → close
                                              └─ idle timeout → close
```

- The bridge is created before the connector relay attaches, so the phone can
  dial iCTRL early. Frames from the phone before the connector attaches are
  dropped (the iCTRL handshake starts with a client request).
- A phone reconnect invalidates all of its bridges with `reason="revoked"`.
- v1 has no device-revocation endpoint; turning off Phone Control on the phone
  closes its socket, and the Server invalidates all of that device's bridges.
  A persisted revoke/`revoked_at` list is planned for v1.1.

## Fixtures

`fixtures/valid/` contains accepted examples; `fixtures/invalid/` contains
rejected examples. `frames.schema.json` exposes direction-specific `$defs`;
`http.schema.json` exposes payload `$defs`. Connector tests validate every
fixture against its matching definition.
