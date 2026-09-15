# Moonveil connector instance (isolated)

Second, independent AA connector that talks to **our** cloud
(`https://moonveil.pipicore.cn`) instead of the official one.

| | official | this instance |
|---|---|---|
| pm2 app | `aa-connector` | `moonveil-connector` |
| data dir | `~/.agents-anywhere` | `~/.agents-anywhere-moonveil` (`AGENT_CONNECTOR_DATA_DIR`) |
| config | `~/.agents-anywhere/connector.json` | `~/.agents-anywhere-moonveil/connector.json` (`--config`) |
| backend | `web.agents-anywhere.com` | `moonveil.pipicore.cn` |

The RuntimeLease file is derived from the config path (`cli.py:192`), so the two
instances cannot clobber each other's lease/state. Neither `ccpocket-bridge` nor
`aa-connector` is touched; no `pm2 restart all` anywhere.

## Bring it up (pp runs the pairing step; tokens never leave your hands)

    ~/moonveil-connector/pair.sh                      # prints a 6-digit code
    # type that code into the console (connectors -> pair), then:
    pm2 start ~/moonveil-connector/ecosystem.json
    pm2 logs moonveil-connector --lines 20

## Roll back

    pm2 delete moonveil-connector
    rm -rf ~/.agents-anywhere-moonveil        # only this instance's state
