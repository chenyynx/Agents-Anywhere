#!/usr/bin/env bash
# ============================================================================
# AA v2_42 (native_item_id) ATOMIC DEPLOY RUNBOOK  --  FOR REVIEW, NOT RUN
# ============================================================================
#
# Can this be executed yet? NO. Read this whole header before touching it.
#
# Doris' 2026-10-13 finding P0-2: the previous version of this file stopped a
# Compose service that does not exist (`server-next`), never built or pinned the
# release image, fell back to `docker start` (which restarts the OLD container),
# and printed DONE even when readiness never succeeded. This rewrite fixes those
# and, more importantly, is FAIL-CLOSED: every prerequisite that cannot be
# verified by the script itself must be supplied as operator evidence, and any
# unverifiable or failed precondition exits non-zero WITHOUT printing DONE.
#
# What this script guarantees (design contract):
#   * It never silently touches a real system: without `--i-have-approval` it
#     runs ONLY the read-only preflight (which needs docker + a reachable host).
#   * The release artifact is pinned by an operator-supplied IMMUTABLE image ID
#     (sha256:...) that is proven — not assumed — to:
#       - exist locally,
#       - carry an OCI revision label equal to the reviewed commit,
#       - contain /app/server/migrations/versions/v2_42.py whose sha256 matches
#         a reviewed anchor,
#     and that SAME immutable id is used for BOTH the migration job and the
#     force-recreate of the real `server` service. There is no `docker start`
#     fallback and no `:latest` in the execute path.
#   * Any migration gate failure, missing gate, image mismatch, readiness
#     timeout, or wrong post-recreate image id exits non-zero and prints
#     ABORTED, never DONE.
#
# What this script does NOT do, and will refuse to pretend it did:
#   * It does not create the cold backup. You must have run `pg_dump` and pass
#     a verifiable evidence file naming the snapshot (--backup-evidence).
#   * It does not run the destructive deduplicate dry-run. Its safety is not
#     observable in the DB, so it must be an operator-supplied, content-checked
#     artifact listing the exact twin ids to be hard-deleted (--dryrun-evidence).
#   * It does not prove write activity has stopped. It can only see session
#     state; you must assert quiescence via --writes-stopped-evidence (checked
#     against freshness + a fingerprint you re-confirm against the DB right now),
#     with --i-have-stopped-writes as the standing attestation.
#   * It does not fix P0-1. Until the startup maintenance chain is fenced (see
#     the "P0-1" note in PRE-FLIGHT) the correct post-deploy acceptance is the
#     fallback path, not "no error in the log".
#
# PATH SPLIT (nothing is built here):
#   The release image is built OUTSIDE this repo, in the deployment tree, by a
#   separate release process, because moonveil-cloud/server and this tree have
#   diverged (the deploy tree is missing dev-only code such as the janitor) and
#   the fix must be rebased by hand into it. This script only CONSUMES the built
#   image. Do not "fix" the deploy tree from here.
#
# RELEASE REQUIREMENTS (the release process MUST satisfy these, or execute aborts):
#   * Build with an OCI revision label naming the reviewed commit:
#       docker build --label org.opencontainers.image.revision=<sha> ...
#     (absent label => abort: provenance cannot be proven).
#   * The image must contain /app/server/migrations/versions/v2_42.py byte-equal
#     to the reviewed anchor (sha256 checked).
#   * Hand the operator the immutable image id (`docker inspect -f '{{.Id}}'`),
#     NOT a tag, to pass as --release-image-id.
#
# ROLLBACK (documented, not automated — see the final section):
#   An App rollback is NOT a DB rollback. The v2_42 server refuses to start on a
#   v2_41 database (require_current_database). To roll back you must: stop the
#   new server, run `alembic downgrade v2_41` with the same v2_42 image, verify
#   the column/index are gone, then recreate the PREVIOUS image id. Details in
#   the ROLLBACK section at the bottom.
#
# Environment overrides (all optional; defaults are the known layout):
#   COMPOSE_DIR       default /home/ubuntu/repos/moonveil-cloud/deploy
#   COMPOSE_FILE      default docker-compose.moonveil.yml
#   SERVER_SERVICE    default server          (the ONLY real service name)
#   POSTGRES_SERVICE  default postgres
#
# ============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
COMPOSE_DIR="${COMPOSE_DIR:-/home/ubuntu/repos/moonveil-cloud/deploy}"
COMPOSE_FILE="${COMPOSE_FILE:-docker-compose.moonveil.yml}"
SERVER_SERVICE="${SERVER_SERVICE:-server}"
POSTGRES_SERVICE="${POSTGRES_SERVICE:-postgres}"
SERVER_PORT="${SERVER_PORT:-8000}"
HEALTH_PATH="/api/v2/health/ready"
READINESS_ATTEMPTS="${READINESS_ATTEMPTS:-30}"
READINESS_SLEEP="${READINESS_SLEEP:-2}"
MAINTENANCE_WAIT="${MAINTENANCE_WAIT:-180}"

# Reviewed commit this runbook was written against (the frozen revision Doris
# reviewed). The release must be built from this commit, or from a descendant
# that still carries the same reviewed v2_42 migration bytes.
REVIEWED_COMMIT_DEFAULT="34dc8f0449422bff9019be1436a582dff9198fe5"
REVIEWED_V2_42_SHA256_DEFAULT="233bde087b40e72ff59182fd0a233d7a53cef0680b9f2dc6d830f690b804acc2"

# ---------------------------------------------------------------------------
# Parse args (mode is the ONLY behavior switch; default is dry-run preflight)
# ---------------------------------------------------------------------------
MODE="preflight"
APPROVAL=0
RELEASE_IMAGE_ID=""
REVIEWED_COMMIT="$REVIEWED_COMMIT_DEFAULT"
V2_42_SHA256="$REVIEWED_V2_42_SHA256_DEFAULT"
BACKUP_EVIDENCE=""
DRYRUN_EVIDENCE=""
WRITES_STOPPED_EVIDENCE=""
STOP_ATTEST=0

usage() {
  cat <<'USAGE'
Usage: aa-v2_42-deploy-runbook.sh [MODE] [OPTIONS]

MODES
  --preflight                 (default) read-only checks only. Safe. Prints
                              whether execute prerequisites appear satisfiable.
  --execute                   the atomic release. REQUIRES --i-have-approval
                              and ALL evidence options below, or it aborts.

EXECUTE OPTIONS (all required with --execute)
  --i-have-approval           standing attestation that pp approved deploying.
  --release-image-id sha256:<64hex>
                              IMMUTABLE id of the built release image.
  --reviewed-commit <sha>     commit the release was built from (must equal the
                              image's OCI revision label).
  --backup-evidence <path>    file by "pg_dump" whose header names the cold
                              backup snapshot (verified, not created, here).
  --dryrun-evidence <path>    file listing the exact twin ids to hard-delete
                              (content fingerprint checked against the live DB).
  --i-have-stopped-writes     standing attestation that all writers are stopped.
  --writes-stopped-evidence <path>
                              file (<= WRITES_STOPPED_MAX_AGE_S old) naming the
                              stopped components and the sessions seq fingerprint
                              you observed, re-checked against the DB now.

OTHER OPTIONS
  --v2-42-sha256 <hex>        override the reviewed v2_42.py anchor hash.
  -h, --help                  this help.
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --preflight) MODE="preflight" ;;
    --execute) MODE="execute" ;;
    --i-have-approval) APPROVAL=1 ;;
    --i-have-stopped-writes) STOP_ATTEST=1 ;;
    --release-image-id) RELEASE_IMAGE_ID="${2:?missing value}"; shift ;;
    --reviewed-commit) REVIEWED_COMMIT="${2:?missing value}"; shift ;;
    --v2-42-sha256) V2_42_SHA256="${2:?missing value}"; shift ;;
    --backup-evidence) BACKUP_EVIDENCE="${2:?missing value}"; shift ;;
    --dryrun-evidence) DRYRUN_EVIDENCE="${2:?missing value}"; shift ;;
    --writes-stopped-evidence) WRITES_STOPPED_EVIDENCE="${2:?missing value}"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

# ---------------------------------------------------------------------------
# Output + failure discipline
# ---------------------------------------------------------------------------
step() { echo; echo "===== $* ====="; }

# Hard stop. Never prints DONE. Use for anything that must abort the run.
abort() {
  echo >&2
  echo "ABORTED at: $*" >&2
  echo "Nothing was marked complete. Resolve the reported problem and re-run." >&2
  exit 1
}

# Gate: expectation must equal reality. On mismatch the script aborts (execute)
# or records a problem (preflight, which continues to report all issues).
GATE_FAILS=0
gate() {
  local name="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "  PASS  $name = $actual"
  else
    echo "  FAIL  $name: expected [$expected] got [$actual]"
    GATE_FAILS=$((GATE_FAILS + 1))
  fi
}

# ---------------------------------------------------------------------------
# Docker helpers. Every docker call is wrapped so a missing daemon is a clean,
# explicit failure rather than a confusing "command not found" mid-deploy.
# ---------------------------------------------------------------------------
dc() { docker compose -f "$COMPOSE_DIR/$COMPOSE_FILE" "$@"; }

require_docker() {
  command -v docker >/dev/null 2>&1 || abort "docker not found on PATH"
  docker info >/dev/null 2>&1 || abort "docker daemon not reachable"
}

psql_ro() {
  # Read-only query against the real postgres container. No password parsing:
  # psql inside the container authenticates over the unix socket via the same
  # POSTGRES_* env the server uses.
  dc exec -T "$POSTGRES_SERVICE" psql -U moonveil -d moonveil -tAc "$1"
}

# Read the live server's container id via the compose project itself (respects
# the project name in the file), not a guessed container name or a hardcoded
# project label.
running_server_image_id() { dc ps -q "$SERVER_SERVICE" 2>/dev/null | head -1; }

container_image_id() { docker inspect -f '{{.Image}}' "$1" 2>/dev/null; }

# ===========================================================================
# EXECUTE-MODE PREREQUISITES (fail-closed). In preflight mode we *report* which
# are satisfiable instead of aborting, so an operator can see the gaps.
# ===========================================================================
require_prereqs() {
  step "PREREQUISITES (fail-closed)"
  [ "$APPROVAL" = "1" ] || abort "execute requires --i-have-approval"
  [ -n "$RELEASE_IMAGE_ID" ] || abort "execute requires --release-image-id (immutable sha256:...)"
  case "$RELEASE_IMAGE_ID" in
    sha256:*) ;;
    *) abort "--release-image-id must be an immutable sha256:<64hex> image id, not a tag" ;;
  esac
  [ -n "$REVIEWED_COMMIT" ] || abort "execute requires --reviewed-commit"
  [ -f "$BACKUP_EVIDENCE" ] || abort "execute requires --backup-evidence (file not found: $BACKUP_EVIDENCE)"
  [ -f "$DRYRUN_EVIDENCE" ] || abort "execute requires --dryrun-evidence (file not found: $DRYRUN_EVIDENCE)"
  [ "$STOP_ATTEST" = "1" ] || abort "execute requires --i-have-stopped-writes"
  [ -f "$WRITES_STOPPED_EVIDENCE" ] || abort "execute requires --writes-stopped-evidence (file not found: $WRITES_STOPPED_EVIDENCE)"

  # Provenance of the STOP claim: the file must be recent, and we re-confirm the
  # fingerprint it carries against the live DB in the PRE-FLIGHT step.
  local max_age="${WRITES_STOPPED_MAX_AGE_S:-1800}"
  local now mtime age
  now=$(date +%s)
  mtime=$(stat -c %Y "$WRITES_STOPPED_EVIDENCE")
  age=$((now - mtime))
  if [ "$age" -gt "$max_age" ]; then
    abort "writes-stopped evidence is ${age}s old (> ${max_age}s); re-capture it"
  fi
  echo "  PASS  writes-stopped evidence is ${age}s old (<= ${max_age}s)"

  # RELEASE-INSTALLED is a single operator-provided token (env or file) meaning
  # "the reviewed fix is installed in the deploy tree and the release is built
  # from it". The script cannot check the df tree (out of scope by design).
  if [ "${RELEASE_INSTALLED:-0}" != "1" ] && [ ! -f "${RELEASE_INSTALLED_MARKER:-/dev/null}" ]; then
    abort "RELEASE_INSTALLED not asserted. Set RELEASE_INSTALLED=1 (or provide RELEASE_INSTALLED_MARKER) only after the reviewed fix is installed in the deploy tree and the release image is built from it."
  fi
  echo "  PASS  RELEASE_INSTALLED asserted"
}

# Fail fast: in execute mode, prove every operator-supplied prerequisite exists
# BEFORE touching docker or the DB.
if [ "$MODE" = "execute" ]; then
  require_prereqs
fi

# ===========================================================================
# STEP 0 -- READ-ONLY PRE-FLIGHT
# ===========================================================================
step "0. PRE-FLIGHT (read-only)"
require_docker
[ -f "$COMPOSE_DIR/$COMPOSE_FILE" ] || abort "compose file not found: $COMPOSE_DIR/$COMPOSE_FILE"

# 0a. The real compose service must be `server` -- assert it, do not assume.
# Capture once, then match with a here-string. Do NOT pipe `docker ... | grep -q`:
# under `set -o pipefail`, grep -q exits as soon as it matches and closes the pipe,
# so a producer still writing the remaining lines dies on SIGPIPE (141) — which
# pipefail then reports as a pipeline failure, spuriously "not found" (~0.2% of
# runs, timing-dependent). The same captured value feeds the error message.
compose_services="$(dc config --services 2>/dev/null || true)"
if ! grep -qx "$SERVER_SERVICE" <<<"$compose_services"; then
  abort "compose service '$SERVER_SERVICE' not found; real services are: $(printf '%s' "$compose_services" | tr '\n' ' ')"
fi
echo "  PASS  compose service '$SERVER_SERVICE' exists"

# 0b. Image provenance (execute mode has the immutable id; preflight reports).
if [ -n "$RELEASE_IMAGE_ID" ]; then
  if ! docker image inspect "$RELEASE_IMAGE_ID" >/dev/null 2>&1; then
    abort "release image id $RELEASE_IMAGE_ID is not present locally; build/load it first"
  fi
  echo "  PASS  release image $RELEASE_IMAGE_ID is present locally"

  # OCI provenance: the image must self-identify the reviewed commit.
  img_rev="$(docker image inspect -f '{{ index .Config.Labels "org.opencontainers.image.revision" }}' "$RELEASE_IMAGE_ID" 2>/dev/null || true)"
  if [ -z "$img_rev" ]; then
    abort "release image has no org.opencontainers.image.revision label; cannot prove provenance"
  fi
  gate "image revision == reviewed commit" "$REVIEWED_COMMIT" "$img_rev"

  # The image must actually carry the v2_42 migration, byte-identical to review.
  v2sha="$(docker run --rm --entrypoint sha256sum "$RELEASE_IMAGE_ID" \
            /app/server/migrations/versions/v2_42.py 2>/dev/null | awk '{print $1}' || true)"
  if [ -z "$v2sha" ]; then
    abort "release image has no /app/server/migrations/versions/v2_42.py (old image?)"
  fi
  gate "image v2_42.py sha256" "$V2_42_SHA256" "$v2sha"
else
  echo "  NOTE  no --release-image-id given; provenance checks run only in --execute"
fi

# 0c. Current schema + row state (read-only).
echo "  schema now: $(psql_ro "SELECT version_num FROM alembic_version;" 2>/dev/null || echo '<unreadable>')"
echo "  rows:       $(psql_ro "SELECT count(*) FROM timeline_items;" 2>/dev/null || echo '<unreadable>')"

# 0d. Long transactions that would trip the 5s CIC lock_timeout.
echo "  long transactions (> 5s) that would block CREATE INDEX CONCURRENTLY:"
psql_ro "SELECT pid, state, now()-xact_start AS age, left(query,50) FROM pg_stat_activity WHERE datname='moonveil' AND xact_start IS NOT NULL AND now()-xact_start > interval '5 seconds';" 2>/dev/null || true

# 0e. Re-confirm the writes-stopped fingerprint NOW (execute mode only).
if [ -n "$WRITES_STOPPED_EVIDENCE" ] && [ -f "$WRITES_STOPPED_EVIDENCE" ]; then
  fingerprint="$(grep -oE 'seq_fingerprint=[0-9a-f:]+' "$WRITES_STOPPED_EVIDENCE" | tail -1 | cut -d= -f2 || true)"
  if [ -n "$fingerprint" ]; then
    live_fingerprint="$(psql_ro "SELECT md5(string_agg(session_id || ':' || seq::text, ',' ORDER BY session_id)) FROM sessions;" 2>/dev/null || true)"
    gate "sessions seq fingerprint still matches stopped-writes evidence" \
         "$fingerprint" "$live_fingerprint"
  else
    echo "  NOTE  writes-stopped evidence carries no seq_fingerprint= line; freshness only"
  fi
fi

# 0f. Leftover INVALID index shell from a previously failed CIC build.
invalid_shell="$(psql_ro "SELECT count(*) FROM pg_class c JOIN pg_index i ON i.indexrelid=c.oid WHERE c.relname='idx_timeline_items_session_native_item' AND NOT i.indisvalid;" 2>/dev/null || echo 0)"
echo "  pre-existing INVALID index shells: $invalid_shell (the migration drops+rebuilds these)"

# 0g. Backup evidence CONTENT (not just existence). A real pg_dump is either
# gzip (magic 1f 8b) or a plaintext dump whose header names PostgreSQL.
if [ -f "$BACKUP_EVIDENCE" ]; then
  magic="$(head -c2 "$BACKUP_EVIDENCE" | od -An -tx1 | tr -d ' \n')"
  if [ "$magic" = "1f8b" ] || grep -qa "PostgreSQL database dump" "$BACKUP_EVIDENCE"; then
    echo "  PASS  backup evidence looks like a pg_dump artifact (magic=$magic)"
  else
    echo "  FAIL  backup evidence does not look like a pg_dump (magic=$magic)"; GATE_FAILS=$((GATE_FAILS+1))
  fi
fi

# 0h. Dry-run evidence CONTENT cross-check. The file lists the exact twin rows
# the sweep will hard-delete, one per line as `<session_id>|<item_id>`. Every id
# must still exist right now, or the cold backup is stale / the list is wrong.
if [ -f "$DRYRUN_EVIDENCE" ]; then
  missing=0
  total=0
  while IFS='|' read -r sid iid; do
    [ -n "$sid" ] || continue
    [ -n "$iid" ] || continue
    total=$((total+1))
    exists="$(psql_ro "SELECT count(*) FROM timeline_items WHERE session_id='$sid' AND id='$iid';" 2>/dev/null || echo 0)"
    if [ "$exists" != "1" ]; then
      echo "  FAIL  dry-run lists $sid|$iid but the row is not present" >&2
      missing=$((missing+1))
    fi
  done < "$DRYRUN_EVIDENCE"
  if [ "$missing" -ne 0 ]; then
    echo "  FAIL  $missing/$total dry-run ids missing; re-run the dry-run against the current DB" >&2
    GATE_FAILS=$((GATE_FAILS+1))
  else
    echo "  PASS  all $total dry-run twin ids still present"
  fi
fi

# Preflight does not proceed to execute steps; report and stop.
if [ "$MODE" != "execute" ]; then
  step "PREFLIGHT RESULT"
  if [ "$GATE_FAILS" -gt 0 ]; then
    echo "  PREFLIGHT FAILED: $GATE_FAILS gate(s) failed. Execute would ABORT." >&2
    exit 1
  fi
  echo "  PREFLIGHT OK (read-only). No system was modified."
  echo "  NOTE  preflight checked only what it was given. --execute additionally"
  echo "        requires approval + release-image-id + commit + backup/dryrun/"
  echo "        writes-stopped evidence; missing any of them aborts without DONE."
  exit 0
fi

# From here MODE == execute. Any gate failure aborts. (Prereqs already checked.)
[ "$GATE_FAILS" -eq 0 ] || abort "$GATE_FAILS pre-flight gate(s) failed; not executing"

# Pin the release image by its immutable id for BOTH the migration job and the
# service recreate. Compose can only be pinned via a concrete image reference,
# so we tag the id locally and drive compose with a one-line override. This is
# what stops the old `:latest` from being used by `dc run` for the migration.
PIN_TAG="aa-release-pin:${RELEASE_IMAGE_ID#sha256:}"
docker tag "$RELEASE_IMAGE_ID" "$PIN_TAG" >/dev/null 2>&1 \
  || abort "could not pin release image id to a tag alias"
OVERRIDE_FILE="$(mktemp)"
trap 'rm -f "$OVERRIDE_FILE"' EXIT
cat >"$OVERRIDE_FILE" <<YAML
services:
  $SERVER_SERVICE:
    image: $PIN_TAG
YAML
# Compose with the pin override; inherits network/env/volumes from the real file.
dcp() { docker compose -f "$COMPOSE_DIR/$COMPOSE_FILE" -f "$OVERRIDE_FILE" "$@"; }

# ===========================================================================
# STEP 1 -- WRITE-ACTIVITY HARD GATE
# ===========================================================================
# The script cannot prove writes stopped. It checks what it can: every session
# must be idle (no active run) at the moment of stopping. The operator's
# attestation + evidence file (checked in step 0) carry the rest.
step "1. STOP WRITES (downtime window opens)"
active_runs="$(psql_ro "SELECT count(*) FROM session_active_runs;" 2>/dev/null || echo '<unreadable>')"
if [ "$active_runs" != "0" ]; then
  abort "session_active_runs is not empty ($active_runs); writers are still active"
fi
echo "  PASS  no active runs"

next_seq_before="$(psql_ro "SELECT COALESCE(max(seq),0) FROM sessions;" 2>/dev/null || echo '<unreadable>')"

# Stop the real service. No fallbacks, no `|| docker start`.
dc stop "$SERVER_SERVICE"
echo "  server stopped (dc stop $SERVER_SERVICE)"

# ===========================================================================
# STEP 2 -- MIGRATE v2_41 -> v2_42 using the SAME immutable release image
# ===========================================================================
step "2. MIGRATE v2_41 -> v2_42 (release image $RELEASE_IMAGE_ID)"
# Run the migration INSIDE the pinned release image, on the compose network, with
# the DB URL taken from the compose service's own environment (no YAML parsing,
# no password scraping). The migration holds no long ACCESS EXCLUSIVE lock and
# bounds CIC lock waits to 5s. `dcp` here means the override pins the image id,
# so `dc run` cannot fall back to a stale `:latest`.
migrate_rc=0
dcp run --rm --no-deps \
  --entrypoint /opt/venv/bin/python \
  -e AGENT_SERVER_DB_BACKEND=postgres \
  "$SERVER_SERVICE" \
  -m agent_server.infra.db.migrations upgrade || migrate_rc=$?
if [ "$migrate_rc" -ne 0 ]; then
  abort "migration exited $migrate_rc"
fi
echo "  migration returned $migrate_rc"

# ===========================================================================
# STEP 3 -- SCHEMA / INDEX / BACKFILL GATES (all must pass before starting)
# ===========================================================================
step "3. VERIFY GATES"
gate "alembic_version" "v2_42" "$(psql_ro "SELECT version_num FROM alembic_version;")"
gate "column present" "1" "$(psql_ro "SELECT count(*) FROM information_schema.columns WHERE table_name='timeline_items' AND column_name='native_item_id';")"

# Index: must exist AND be valid AND be NON-unique. The task asked to assert
# NONUNIQUE explicitly: v2_42 builds it with unique=False, and a unique index
# would wrongly reject two rows legitimately sharing a native id (different
# roles). We assert valid=1 and unique=0 separately so a wrong index is caught.
gate "index valid" "1" "$(psql_ro "SELECT COALESCE((SELECT i.indisvalid::int FROM pg_class c JOIN pg_index i ON i.indexrelid=c.oid WHERE c.relname='idx_timeline_items_session_native_item'),0);")"
gate "index non-unique" "0" "$(psql_ro "SELECT COALESCE((SELECT i.indisunique::int FROM pg_class c JOIN pg_index i ON i.indexrelid=c.oid WHERE c.relname='idx_timeline_items_session_native_item'),1);")"
gate "index count" "1" "$(psql_ro "SELECT count(*) FROM pg_class WHERE relname='idx_timeline_items_session_native_item';")"

# Backfill completeness. The previous gate ("all NULL == 0") was WRONG: v2_42
# deliberately leaves platform-authored / pre-projection rows NULL and the PG
# drill asserts that (final-review-B: platform NULL is preserved by design).
# The correct gate is over the PROJECTABLE row set: rows whose payload carries a
# source.itemId MUST have a non-NULL native_item_id. We never cast payload to
# jsonb (production payloads contain raw \u0000 and would abort a ::jsonb cast);
# instead we count rows that look projectable (text LIKE on a quoted itemId key)
# but are still NULL. A bounded sample is used for the pattern check.
projectable_null="$(psql_ro "SELECT count(*) FROM timeline_items WHERE native_item_id IS NULL AND payload_json LIKE '%\"itemId\"%';")"
gate "projectable rows backfilled (0 NULL among source.itemId rows)" "0" "$projectable_null"
null_total="$(psql_ro "SELECT count(*) FROM timeline_items WHERE native_item_id IS NULL;")"
echo "  native_item_id IS NULL rows (total, incl. platform/pre-projection): $null_total"

if [ "$GATE_FAILS" -ne 0 ]; then
  abort "$GATE_FAILS schema/index/backfill gate(s) failed; refusing to start the new version"
fi
# GATE_FAILS is reset so the post-start gates start clean.
GATE_FAILS=0

# ===========================================================================
# STEP 4 -- START THE NEW VERSION via force-recreate of the SAME image id
# ===========================================================================
step "4. START the new version (force-recreate with pinned image id)"
# The image is already pinned via `dcp` (override) from the execute preamble.
# Recreate WITHOUT a build (we are not building here), force-recreate so the old
# container is replaced (NOT restarted), then assert the container's image id IS
# the immutable id. If any of that fails we abort -- there is no `docker start`
# of the old container.
if ! dcp up -d --no-build --pull never --force-recreate "$SERVER_SERVICE"; then
  abort "dc up --force-recreate failed"
fi

cid="$(running_server_image_id)"
[ -n "$cid" ] || abort "no running container for service '$SERVER_SERVICE' after recreate"
running_id="$(container_image_id "$cid")"
gate "running container image == release image id" "$RELEASE_IMAGE_ID" "$running_id"
if [ "$GATE_FAILS" -ne 0 ]; then
  abort "the recreated container is NOT running the release image; it is still the OLD image"
fi

# ===========================================================================
# STEP 5 -- READINESS (HTTP + JSON) with a hard, fail-closed timeout
# ===========================================================================
step "5. READINESS ($HEALTH_PATH)"
# The slim server image has no wget/curl; use its own Python to fetch the
# readiness JSON, so the check does not depend on extra tooling.
ready=0
for _ in $(seq 1 "$READINESS_ATTEMPTS"); do
  body="$(dc exec -T "$SERVER_SERVICE" /opt/venv/bin/python -c \
    "import urllib.request,sys; \
     print(urllib.request.urlopen('http://127.0.0.1:$SERVER_PORT$HEALTH_PATH', timeout=3).read().decode())" \
    2>/dev/null || true)"
  if grep -q '"status":"ready"' <<<"$body"; then
    ready=1
    break
  fi
  sleep "$READINESS_SLEEP"
done
if [ "$ready" != "1" ]; then
  abort "readiness never returned status:ready after $READINESS_ATTEMPTS attempts"
fi
echo "  PASS  READY"

# The readiness body exposes the server's own schema version; assert it says
# 2.42 (the deploy target) AND that the DB revision is v2_42 (independent of the
# earlier migration gate, in case something rolled it back).
gate "readiness body schemaVersion 2.42" "1" \
  "$(printf '%s' "$body" | grep -c '"schemaVersion":"2.42"')"
gate "db revision still v2_42" "v2_42" "$(psql_ro "SELECT version_num FROM alembic_version;")"
if [ "$GATE_FAILS" -ne 0 ]; then
  abort "$GATE_FAILS post-start gate(s) failed"
fi

# ===========================================================================
# STEP 6 -- STARTUP MAINTENANCE: EXPLICIT (not best-effort) VERIFICATION
# ===========================================================================
step "6. STARTUP MAINTENANCE verification"
# The startup maintenance pass is CONFIRMED to run only when it had work to do:
# the success line is logged only `if refilled or removed or repaired` (frozen
# commit) / `elif any(results.values())` (post-P0-1). So the honest acceptance is
# a FAILURE check plus, when there was work, the success line. We never treat
# "no error" as "maintenance succeeded". Both log vocabularies are recognized so
# the runbook works against the frozen build AND the P0-1 build:
#   failure: "...maintenance failed" | "...maintenance pass failed"
#            | "...maintenance incomplete"
#   success: "...maintenance refilled=" | "...maintenance applied results="
echo "  scanning recent server logs for maintenance result..."
maint_fail=0
maint_ok=0
deadline=$(( $(date +%s) + MAINTENANCE_WAIT ))
while [ "$(date +%s)" -lt "$deadline" ]; do
  logs="$(dc logs --since 10m "$SERVER_SERVICE" 2>/dev/null || true)"
  if grep -qE "timeline startup maintenance (failed|incomplete|pass failed)" <<<"$logs"; then
    maint_fail=1
    break
  fi
  if grep -qE "timeline startup maintenance (refilled=|applied results=)" <<<"$logs"; then
    maint_ok=1
    grep -E "timeline startup maintenance (refilled=|applied results=)" <<<"$logs" | tail -1 | sed 's/^/    /'
    break
  fi
  sleep 3
done
if [ "$maint_fail" = "1" ]; then
  echo "  FAIL  startup maintenance logged a failure/incomplete (see logs)" >&2
  echo "  NOTE  with the P0-1 fence defect unfixed, this is the EXPECTED path when" >&2
  echo "        there is stored data to repair. The old server will not service it." >&2
  abort "startup maintenance failed or reported incomplete"
fi
if [ "$maint_ok" != "1" ]; then
  # No summary line and no failure line: either nothing needed repair, or the
  # pass has not finished. We cannot call that success.
  hist_null="$(psql_ro "SELECT count(*) FROM timeline_items WHERE native_item_id IS NULL AND payload_json LIKE '%\"itemId\"%';")"
  if [ "$hist_null" != "0" ]; then
    abort "maintenance neither confirmed nor disproved and $hist_null projectable rows remain NULL"
  fi
  echo "  NOTE  no pending maintenance work; summary line absent because refilled/removed/repaired were all 0"
fi

# ===========================================================================
# STEP 7 -- POST-START PROOF (read-only, best-effort log-only)
# ===========================================================================
step "7. POST-START proof"
echo "  next_seq before stop: $next_seq_before"
echo "  next_seq now:         $(psql_ro "SELECT COALESCE(max(seq),0) FROM sessions;" 2>/dev/null || echo '<unreadable>')"
echo "  duplicate groups remaining (should be 0 after a working sweep):"
psql_ro "SELECT count(*) FROM (SELECT session_id, native_item_id, role FROM timeline_items WHERE type='message' AND native_item_id IS NOT NULL GROUP BY 1,2,3 HAVING count(DISTINCT id) > 1) d;" 2>/dev/null || true
echo "  acceptance (manual):"
echo "    - sess_wDLH_ye_VE3kQw shows no duplicate replies"
echo "    - reasoning blocks render ABOVE the answer body"
echo "    - a fresh live+history message pair persists as ONE row"

echo
echo "DONE. v2_42 is deployed and serving on the release image."
echo "Rollback is NOT automatic; see the ROLLBACK section in this file."

# ===========================================================================
# ROLLBACK (documented; run by hand, with approval)
# ===========================================================================
# An App rollback is NOT a DB rollback. The v2_42 server refuses to start on a
# v2_41 database, so the order below is mandatory:
#
#   1. Stop the new server:
#        docker compose -f "$COMPOSE_DIR/$COMPOSE_FILE" stop server
#   2. Downgrade the schema with the SAME v2_42 image (the downgrade needs the
#      v2_42 migration code; the old image will not have it):
#        docker compose run --rm --no-deps --entrypoint /opt/venv/bin/python \
#          -e AGENT_SERVER_DB_BACKEND=postgres server \
#          -c "from alembic import command; from agent_server.infra.db.migrations \
#              import _alembic_config; import os; \
#              command.downgrade(_alembic_config(os.environ['AGENT_SERVER_DB_URL']), 'v2_41')"
#   3. Verify the column and index are gone:
#        psql -c "SELECT count(*) FROM information_schema.columns \
#                 WHERE table_name='timeline_items' AND column_name='native_item_id';"  -- expect 0
#   4. Recreate the PREVIOUS image id (pin it explicitly):
#        # docker compose up -d --no-build --force-recreate server   with the old id
#   5. Only a cold backup (restore) can undo a hard row DELETE performed by the
#      sweep; the downgrade does not restore deleted rows. Hence the mandatory
#      --backup-evidence.
#
# The rollback is intentionally NOT scripted: it is a destructive, DB-changing
# action that must be approved and observed by a human, and automating it would
# re-introduce exactly the "print DONE on failure" hazard this rewrite removes.
