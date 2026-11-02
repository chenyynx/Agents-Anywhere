# Moonveil production deploy

Moved here from `moonveil-cloud/deploy` on 2026-11-02 so the AA tree is the only
source for the server. The deploy repo keeps nothing that matters for the
server build.

## Files

- `Dockerfile.server` — builds `server/` with the same runtime image the deploy
  repo used; the build context is the repository root.
- `Dockerfile.web` — builds `web-next/`.
- `docker-compose.moonveil.yml` — the production compose (`name: moonveil-cloud`).
- `.env.example` — variable names only, no values.
- `connector-moonveil/` — pairing and run helpers for the isolated connector
  instance (`~/.agents-anywhere-moonveil`).

## Secrets

`.env` is **not** committed. The production copy lives at
`/home/ubuntu/.agents-anywhere-moonveil/deploy.env`; pass it explicitly:

```bash
docker compose --env-file /home/ubuntu/.agents-anywhere-moonveil/deploy.env \
  -f deploy/moonveil/docker-compose.moonveil.yml up -d --no-build server
```

## Build and switch

```bash
docker build -f deploy/moonveil/Dockerfile.server \
  -t moonveil-cloud-server:<tag> .
docker tag moonveil-cloud-server:<tag> moonveil-cloud-server:latest
docker compose --env-file /home/ubuntu/.agents-anywhere-moonveil/deploy.env \
  -f deploy/moonveil/docker-compose.moonveil.yml \
  up -d --no-build --force-recreate server
```

Rollback tags, database backups and the current production image are tracked in
the CC memory note `aa-repo-split-beta-vs-deploy`.

## Migrations

The server's schema gate refuses to start when the database revision is behind.
Run the migration with the new image before recreating the server:

```bash
docker compose --env-file /home/ubuntu/.agents-anywhere-moonveil/deploy.env \
  -f deploy/moonveil/docker-compose.moonveil.yml \
  run --rm --no-deps --entrypoint /opt/venv/bin/python \
  server -m agent_server.infra.db.migrations upgrade
```
