#!/usr/bin/env bash
# ============================================================================
# Isolated test for the AA v2_42 deploy runbook.
# ============================================================================
#
# This test NEVER touches a real system. It runs the REAL runbook (unmodified)
# with a mock `docker` on PATH that records every invocation and returns canned,
# scenario-controlled answers.
#
# It proves the fail-closed contract:
#   * a compose without the real `server` service aborts;
#   * execute without approval, or without the release image id / evidence,
#     aborts before touching docker;
#   * an absent / mislabeled / v2_42-less release image aborts;
#   * a migration failure aborts before any container start;
#   * readiness never succeeding aborts and prints NO "DONE";
#   * a recreated container NOT on the pinned image id aborts;
#   * a missing/backfilled-backfill gate or a wrong index aborts;
#   * startup maintenance failure aborts;
#   * the happy path prints DONE and the mock log proves it NEVER ran
#     `docker start` and NEVER referenced a `server-next` service.
#
# Usage: bash test_aa_v2_42_deploy_runbook.sh [path-to-runbook.sh]
set -uo pipefail

SCRIPT="${1:-/home/ubuntu/repos/Agents-Anywhere/server/scripts/aa-v2_42-deploy-runbook.sh}"
[ -f "$SCRIPT" ] || { echo "runbook not found: $SCRIPT" >&2; exit 2; }

RELEASE_ID="sha256:1111111111111111111111111111111111111111111111111111111111111111"
OLD_ID="sha256:2222222222222222222222222222222222222222222222222222222222222222"
REVIEWED_COMMIT="34dc8f0449422bff9019be1436a582dff9198fe5"
V2SHA="233bde087b40e72ff59182fd0a233d7a53cef0680b9f2dc6d830f690b804acc2"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin"

PASS=0
FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   - $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL - $1"; }

# ---------------------------------------------------------------------------
# Static checks
# ---------------------------------------------------------------------------
echo "== static checks =="
if bash -n "$SCRIPT"; then ok "bash -n clean"; else bad "bash -n failed"; fi

DUP="/home/ubuntu/aa-test/aa-v2_42-deploy-runbook.sh"
if [ -f "$DUP" ]; then
  if cmp -s "$SCRIPT" "$DUP"; then ok "aa-test copy byte-identical"; else bad "aa-test copy DIFFERS"; fi
fi
# Strip full-line comments before scanning for risky command forms; the header
# intentionally names `docker start` while forbidding it.
CODE="$(grep -vE '^[[:space:]]*#' "$SCRIPT")"
printf '%s\n' "$CODE" | grep -qE '\bdocker[[:space:]]+start\b' \
  && bad "executable 'docker start' fallback present" \
  || ok "no executable 'docker start' fallback"
printf '%s\n' "$CODE" | grep -qE '\bserver-next\b' \
  && bad "'server-next' executable reference present" \
  || ok "no 'server-next' executable reference"
printf '%s\n' "$CODE" | grep -q 'jsonb' && bad "uses ::jsonb cast" || ok "no ::jsonb cast"

# ---------------------------------------------------------------------------
# Mock docker
# ---------------------------------------------------------------------------
cat >"$WORK/bin/docker" <<'MOCK'
#!/usr/bin/env bash
state="${MOCK_STATE_DIR:?}"; log="${MOCK_LOG:?}"
echo "docker $*" >>"$log"
args="$*"; last="${!#}"
flag() { [ -f "$state/$1" ]; }

case "${1:-}" in
  info) exit 0 ;;
  tag)  exit 0 ;;
  ps)   echo mockcontainerid; exit 0 ;;
esac

if [ "${1:-}" = "image" ] && [ "${2:-}" = "inspect" ]; then
  printf '%s' "$args" | grep -q "opencontainers.image.revision" && { echo "${MOCK_REVISION}"; exit 0; }
  flag image_absent && exit 1
  echo "[]"; exit 0
fi
if [ "${1:-}" = "run" ]; then
  printf '%s' "$args" | grep -q "sha256sum" && { flag v2_absent && exit 1; echo "${MOCK_V2SHA}  ${last}"; exit 0; }
  exit 0
fi
if [ "${1:-}" = "inspect" ]; then echo "${MOCK_RUNNING_IMAGE}"; exit 0; fi

if [ "${1:-}" = "compose" ]; then
  shift
  while [ "${1:-}" = "-f" ]; do shift 2; done
  sub="${1:-}"; shift || true
  case "$sub" in
    config) printf '%s\n' ${MOCK_SERVICES:-postgres redis server web}; exit 0 ;;
    ps)   echo mockcontainerid; exit 0 ;;
    exec)
      if printf '%s' "$args" | grep -q "psql"; then
        case "$last" in
          *"version_num FROM alembic_version"*)
            if flag force_v41; then echo v2_41
            elif flag migrated; then echo v2_42
            else echo "${MOCK_VERSION_BEFORE:-v2_41}"; fi ;;
          *"count(*) FROM timeline_items;"*) echo "${MOCK_ROWS:-73477}" ;;
          *"pg_stat_activity"*) : ;;
          *"md5(string_agg"*) echo "${MOCK_FINGERPRINT:-ABC123}" ;;
          *"NOT i.indisvalid"*) echo 0 ;;
          *"session_active_runs"*) echo "${MOCK_ACTIVE_RUNS:-0}" ;;
          *"COALESCE(max(seq),0) FROM sessions"*) echo "${MOCK_SEQ:-100}" ;;
          *"column_name='native_item_id'"*) echo "${MOCK_COLUMN:-1}" ;;
          *"i.indisvalid::int"*) echo "${MOCK_INDVALID:-1}" ;;
          *"i.indisunique::int"*) echo "${MOCK_INDUNIQUE:-0}" ;;
          *"relname='idx_timeline_items_session_native_item'"*) echo "${MOCK_INDCOUNT:-1}" ;;
          *"payload_json LIKE"*) echo "${MOCK_PROJECTABLE_NULL:-0}" ;;
          *"WHERE native_item_id IS NULL;"*) echo "${MOCK_NULL_TOTAL:-0}" ;;
          *"session_id='"*) flag dryrun_missing && echo 0 || echo 1 ;;
          *"HAVING count(DISTINCT id)"*) echo 0 ;;
          *) echo "" ;;
        esac
        exit 0
      fi
      if printf '%s' "$args" | grep -q "/opt/venv/bin/python"; then
        flag not_ready && { echo '{"status":"not_ready"}'; exit 0; }
        echo '{"status":"ready","checks":{},"schemaVersion":"2.42"}'; exit 0
      fi
      exit 0 ;;
    stop) exit 0 ;;
    run)
      if printf '%s' "$args" | grep -q "migrations upgrade"; then
        flag migrate_fail && { echo "migration blew up"; exit 17; }
        : >"$state/migrated"; echo "database schema is now 2.42 (v2_42)"; exit 0
      fi
      exit 0 ;;
    up)   exit 0 ;;
    logs) cat "$state/logs" 2>/dev/null || true; exit 0 ;;
  esac
fi
exit 0
MOCK
chmod +x "$WORK/bin/docker"

# ---------------------------------------------------------------------------
# Case harness. A case is a directory; the runbook always runs with the mock
# docker first on PATH. Fault flags are files in the case dir.
# ---------------------------------------------------------------------------
mkcase() {
  local name="$1"
  CASE="$WORK/c$name"
  rm -rf "$CASE"; mkdir -p "$CASE"
  printf 'services: {}\n' >"$WORK/c$name.compose.yml"
  printf 'INFO timeline startup maintenance refilled=0 deduplicated=8 repaired=57\n' >"$CASE/logs"
  { echo "-- PostgreSQL database dump"; echo "SELECT 1;"; } >"$CASE/backup.dump"
  { echo "sess_a|twin_1"; echo "sess_a|twin_2"; } >"$CASE/dryrun.txt"
  echo "stopped=writer,connector seq_fingerprint=ABC123" >"$CASE/stopped.txt"
}

# run [args...] -- runs the runbook into $CASE; sets RC, OUT, DLOG
run() {
  : >"$CASE/docker.log"
  env PATH="$WORK/bin:$PATH" \
      MOCK_STATE_DIR="$CASE" MOCK_LOG="$CASE/docker.log" \
      COMPOSE_DIR="$WORK" COMPOSE_FILE="$(basename "$CASE").compose.yml" \
      WRITES_STOPPED_MAX_AGE_S=3600 RELEASE_INSTALLED=1 \
      MOCK_REVISION="${MOCK_REVISION:-$REVIEWED_COMMIT}" \
      MOCK_V2SHA="${MOCK_V2SHA:-$V2SHA}" \
      MOCK_RUNNING_IMAGE="${MOCK_RUNNING_IMAGE:-$RELEASE_ID}" \
      MOCK_SERVICES="${MOCK_SERVICES:-postgres redis server web}" \
      MOCK_ACTIVE_RUNS="${MOCK_ACTIVE_RUNS:-0}" \
      MOCK_COLUMN="${MOCK_COLUMN:-1}" MOCK_INDVALID="${MOCK_INDVALID:-1}" \
      MOCK_INDUNIQUE="${MOCK_INDUNIQUE:-0}" MOCK_INDCOUNT="${MOCK_INDCOUNT:-1}" \
      MOCK_PROJECTABLE_NULL="${MOCK_PROJECTABLE_NULL:-0}" MOCK_NULL_TOTAL="${MOCK_NULL_TOTAL:-0}" \
      MAINTENANCE_WAIT="${MAINTENANCE_WAIT:-3}" \
      READINESS_ATTEMPTS="${READINESS_ATTEMPTS:-2}" READINESS_SLEEP=0 \
      bash "$SCRIPT" "$@" >"$CASE/out.txt" 2>&1
  RC=$?
  OUT="$(cat "$CASE/out.txt")"
  DLOG="$(cat "$CASE/docker.log")"
}

# Execute arg bundle used by most cases.
std_exec() {
  printf '%s\0' --execute --i-have-approval \
    --release-image-id "$RELEASE_ID" --reviewed-commit "$REVIEWED_COMMIT" \
    --backup-evidence "$CASE/backup.dump" \
    --dryrun-evidence "$CASE/dryrun.txt" \
    --i-have-stopped-writes \
    --writes-stopped-evidence "$CASE/stopped.txt"
}
run_std() { mapfile -d '' -t A < <(std_exec); run "${A[@]}"; }

# Reset overridable MOCK_* between cases.
reset_env() {
  unset MOCK_REVISION MOCK_V2SHA MOCK_RUNNING_IMAGE MOCK_SERVICES
  unset MOCK_ACTIVE_RUNS MOCK_COLUMN MOCK_INDVALID MOCK_INDUNIQUE MOCK_INDCOUNT
  unset MOCK_PROJECTABLE_NULL MOCK_NULL_TOTAL MAINTENANCE_WAIT READINESS_ATTEMPTS
}

# ---------------------------------------------------------------------------
# Cases
# ---------------------------------------------------------------------------
echo "== case 1: compose without 'server' aborts preflight =="
mkcase svc
export MOCK_SERVICES="postgres redis web"; run --preflight; unset MOCK_SERVICES
if [ "$RC" -ne 0 ] && echo "$OUT" | grep -q "not found"; then ok "missing 'server' service aborts"
else bad "missing 'server' service should abort (rc=$RC)"; fi

echo "== case 2: execute without approval aborts, no DONE =="
mkcase noapprove
run --execute \
  --release-image-id "$RELEASE_ID" --reviewed-commit "$REVIEWED_COMMIT" \
  --backup-evidence "$CASE/backup.dump" --dryrun-evidence "$CASE/dryrun.txt" \
  --i-have-stopped-writes --writes-stopped-evidence "$CASE/stopped.txt"
if [ "$RC" -ne 0 ] && echo "$OUT" | grep -q "requires --i-have-approval"; then ok "missing approval aborts"
else bad "missing approval should abort (rc=$RC)"; fi
echo "$OUT" | grep -q "^DONE" && bad "printed DONE without approval" || ok "no DONE without approval"
echo "$DLOG" | grep -qE 'compose' && bad "touched docker before checking approval" || ok "no docker calls before approval gate"

echo "== case 3: execute without release image id aborts =="
mkcase noimg
run --execute --i-have-approval \
  --reviewed-commit "$REVIEWED_COMMIT" \
  --backup-evidence "$CASE/backup.dump" --dryrun-evidence "$CASE/dryrun.txt" \
  --i-have-stopped-writes --writes-stopped-evidence "$CASE/stopped.txt"
if [ "$RC" -ne 0 ] && echo "$OUT" | grep -q "requires --release-image-id"; then ok "missing image id aborts"
else bad "missing image id should abort (rc=$RC)"; fi

echo "== case 4: execute without backup evidence aborts =="
mkcase nobkp
run --execute --i-have-approval \
  --release-image-id "$RELEASE_ID" --reviewed-commit "$REVIEWED_COMMIT" \
  --dryrun-evidence "$CASE/dryrun.txt" \
  --i-have-stopped-writes --writes-stopped-evidence "$CASE/stopped.txt"
if [ "$RC" -ne 0 ] && echo "$OUT" | grep -q "requires --backup-evidence"; then ok "missing backup evidence aborts"
else bad "missing backup evidence should abort (rc=$RC)"; fi

echo "== case 5: absent release image aborts =="
mkcase absent
: >"$CASE/image_absent"; run_std
if [ "$RC" -ne 0 ] && echo "$OUT" | grep -qi "not present locally"; then ok "absent image aborts"
else bad "absent image should abort (rc=$RC)"; fi

echo "== case 6: image revision mismatch aborts =="
mkcase revbad
MOCK_REVISION="deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" run_std
if [ "$RC" -ne 0 ] && echo "$OUT" | grep -q "image revision == reviewed commit" && echo "$OUT" | grep -q "FAIL"; then ok "revision mismatch aborts"
else bad "revision mismatch should abort (rc=$RC)"; fi

echo "== case 7: image missing v2_42 (wrong hash) aborts =="
mkcase v2bad
MOCK_V2SHA="0000000000000000000000000000000000000000000000000000000000000000" run_std
if [ "$RC" -ne 0 ] && echo "$OUT" | grep -q "image v2_42.py sha256" && echo "$OUT" | grep -q "FAIL"; then ok "wrong v2_42 hash aborts"
else bad "wrong v2_42 hash should abort (rc=$RC)"; fi

echo "== case 8: image missing v2_42 file aborts =="
mkcase v2missing
: >"$CASE/v2_absent"; run_std
if [ "$RC" -ne 0 ] && echo "$OUT" | grep -qi "no /app/server/migrations/versions/v2_42.py"; then ok "missing v2_42 file aborts"
else bad "missing v2_42 file should abort (rc=$RC)"; fi

echo "== case 9: active writers abort before stop =="
mkcase active
MOCK_ACTIVE_RUNS="3" run_std
if [ "$RC" -ne 0 ] && echo "$OUT" | grep -q "session_active_runs is not empty"; then ok "active runs abort"
else bad "active runs should abort (rc=$RC)"; fi
echo "$DLOG" | grep -qE 'compose .* stop ' && bad "stopped service despite active writers" || ok "did not stop service with active writers"

echo "== case 10: migration failure aborts before any start =="
mkcase migfail
: >"$CASE/migrate_fail"; run_std
if [ "$RC" -ne 0 ] && echo "$OUT" | grep -q "migration exited"; then ok "migration failure aborts"
else bad "migration failure should abort (rc=$RC)"; fi
echo "$DLOG" | grep -qE 'compose .* up ' && bad "started containers despite migration failure" || ok "no compose up after migration failure"
echo "$OUT" | grep -q "^DONE" && bad "printed DONE after migration failure" || ok "no DONE after migration failure"

echo "== case 11: migration succeeds but alembic_version gate fails aborts =="
mkcase vgate
: >"$CASE/force_v41"   # mock keeps reporting v2_41 even after the migrate step
run_std
if [ "$RC" -ne 0 ] && echo "$OUT" | grep -q "FAIL  alembic_version"; then ok "version gate mismatch aborts"
else bad "version gate mismatch should abort (rc=$RC)"; fi
echo "$DLOG" | grep -qE 'compose .* up ' && bad "started despite version gate failure" || ok "no start despite version gate failure"

echo "== case 12: non-unique index gate (unique index present) aborts =="
mkcase idxuniq
MOCK_INDUNIQUE="1" run_std
if [ "$RC" -ne 0 ] && echo "$OUT" | grep -q "index non-unique"; then ok "unique index aborts"
else bad "unique index should abort (rc=$RC)"; fi
echo "$OUT" | grep -q "^DONE" && bad "printed DONE with unique index" || ok "no DONE with unique index"

echo "== case 13: invalid index gate aborts =="
mkcase idxinv
MOCK_INDVALID="0" run_std
if [ "$RC" -ne 0 ] && echo "$OUT" | grep -q "index valid"; then ok "invalid index aborts"
else bad "invalid index should abort (rc=$RC)"; fi

echo "== case 14: projectable-NULL backfill gate aborts =="
mkcase nullgate
MOCK_PROJECTABLE_NULL="42" run_std
if [ "$RC" -ne 0 ] && echo "$OUT" | grep -q "projectable rows backfilled"; then ok "unbackfilled projectable rows abort"
else bad "unbackfilled projectable rows should abort (rc=$RC)"; fi
echo "$DLOG" | grep -qE 'compose .* up ' && bad "started despite backfill gate failure" || ok "no start despite backfill gate failure"

echo "== case 15: platform-NULL rows alone do NOT abort (correct gate) =="
mkcase platformnull
MOCK_PROJECTABLE_NULL="0" MOCK_NULL_TOTAL="75" run_std
if [ "$RC" -eq 0 ] && echo "$OUT" | grep -q "^DONE"; then ok "platform NULL rows tolerated (gate is projectable-only)"
else bad "platform NULL rows should be tolerated (rc=$RC): $(echo "$OUT" | tail -3)"; fi

echo "== case 16: recreated container on the OLD image aborts =="
mkcase wrongimg
MOCK_RUNNING_IMAGE="$OLD_ID" run_std
if [ "$RC" -ne 0 ] && echo "$OUT" | grep -q "running container image == release image id"; then ok "old-image container aborts"
else bad "old-image container should abort (rc=$RC)"; fi
echo "$OUT" | grep -q "^DONE" && bad "printed DONE on wrong image" || ok "no DONE on wrong image"

echo "== case 17: readiness timeout aborts, no DONE, no docker start =="
mkcase notready
: >"$CASE/not_ready"; run_std
if [ "$RC" -ne 0 ] && echo "$OUT" | grep -q "readiness never returned"; then ok "readiness timeout aborts"
else bad "readiness timeout should abort (rc=$RC)"; fi
echo "$OUT" | grep -q "^DONE" && bad "printed DONE on readiness failure" || ok "no DONE on readiness failure"
echo "$DLOG" | grep -qE '\bdocker start\b' && bad "used docker start" || ok "never used docker start"

echo "== case 18: startup maintenance failure aborts =="
mkcase maintfail
printf 'ERROR timeline startup maintenance failed\n' >"$CASE/logs"; run_std
if [ "$RC" -ne 0 ] && echo "$OUT" | grep -q "startup maintenance"; then ok "maintenance failure aborts"
else bad "maintenance failure should abort (rc=$RC)"; fi
echo "$OUT" | grep -q "^DONE" && bad "printed DONE on maintenance failure" || ok "no DONE on maintenance failure"

echo "== case 19: dry-run evidence listing a missing id aborts =="
mkcase dryrun_bad
: >"$CASE/dryrun_missing"   # mock reports every listed id as absent
run_std
if [ "$RC" -ne 0 ] && echo "$OUT" | grep -qi "dry-run"; then ok "dry-run evidence with missing ids aborts"
else bad "dry-run evidence with missing ids should abort (rc=$RC)"; fi
echo "$DLOG" | grep -qE 'compose .* up ' && bad "started despite bad dry-run evidence" || ok "no start despite bad dry-run evidence"

echo "== case 20: happy path prints DONE, never docker start =="
mkcase happy
run_std
if [ "$RC" -eq 0 ] && echo "$OUT" | grep -q "^DONE. v2_42 is deployed"; then ok "happy path prints DONE and exits 0"
else bad "happy path should print DONE and exit 0 (rc=$RC): $(echo "$OUT" | tail -4)"; fi
echo "$DLOG" | grep -qE '\bdocker start\b' && bad "happy path used docker start" || ok "happy path never used docker start"
echo "$DLOG" | grep -qE 'server-next' && bad "happy path referenced server-next" || ok "happy path never referenced server-next"
echo "$DLOG" | grep -qE 'migrations upgrade' && ok "happy path ran the migration inside a compose run" || bad "happy path did not run the migration"
echo "$DLOG" | grep -qE 'up -d --no-build --pull never --force-recreate' && ok "happy path force-recreated without build" || bad "happy path did not force-recreate"

echo "== case 21: P0-1 'incomplete' maintenance log aborts =="
mkcase maintincomplete
printf "WARNING timeline startup maintenance incomplete failed_passes=['deduplicate_message_identities'] results={}\n" >"$CASE/logs"
run_std
if [ "$RC" -ne 0 ] && echo "$OUT" | grep -q "incomplete"; then ok "'incomplete' maintenance aborts"
else bad "'incomplete' maintenance should abort (rc=$RC)"; fi
echo "$OUT" | grep -q "^DONE" && bad "printed DONE on incomplete maintenance" || ok "no DONE on incomplete maintenance"

echo "== case 22: P0-1 'applied results=' success log is accepted =="
mkcase maintapplied
printf "INFO timeline startup maintenance applied results={'backfill_native_item_ids': 2, 'deduplicate_message_identities': 8, 'repair_intra_message_order': 57}\n" >"$CASE/logs"
run_std
if [ "$RC" -eq 0 ] && echo "$OUT" | grep -q "^DONE"; then ok "post-P0-1 'applied results=' accepted"
else bad "post-P0-1 success log should be accepted (rc=$RC): $(echo "$OUT" | tail -3)"; fi

# Raw evidence for the report.
if [ -n "${EVIDENCE_DIR:-}" ] && [ -d "${EVIDENCE_DIR}" ]; then
  cp "$WORK/chappy/docker.log" "$EVIDENCE_DIR/happy-docker-log.txt" 2>/dev/null || true
  cp "$WORK/chappy/out.txt"    "$EVIDENCE_DIR/happy-out.txt" 2>/dev/null || true
  cp "$WORK/cmigfail/docker.log" "$EVIDENCE_DIR/migfail-docker-log.txt" 2>/dev/null || true
  cp "$WORK/cnotready/out.txt" "$EVIDENCE_DIR/notready-out.txt" 2>/dev/null || true
fi

echo
echo "== RESULT: $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
