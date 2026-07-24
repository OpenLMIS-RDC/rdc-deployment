#!/usr/bin/env bash
#
# Deploys OpenLMIS to the dev server, then deploys the reporting-stack
# (openlmis-reporting platform) onto the SAME Docker host.
#
# Jenkins workspace layout assumed:
#   $WORKSPACE/
#     rdc-deployment/            (this repo, checked out at the workspace root)
#     credentials/               (rdc-configuration, private; subdir)
#     openlmis-reporting/        (reporting-stack platform repo; subdir)
#
# Inputs:
#   KEEP_OR_RESTORE        env var (Jenkins choice param: "keep" | "restore"),
#                          required by restart_or_restore.sh. On "restore" the
#                          database is replaced from a snapshot, so the
#                          reporting stack is reset too.
#   SKIP_REPORTING_STACK=1 skips the reporting-stack part (OLMIS-only redeploy).
#   REPORTING_SSH_KEY      overrides the SSH private key path (e.g. from a
#                          Jenkins credentials binding).
#   REPORTING_OLD_DOCKER=1 forces the old-Docker workarounds (classic-builder
#                          pre-build + seccomp overlay); otherwise they are
#                          applied automatically when the host daemon is < 20.x.
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)

# =============================================================================
# 1. OpenLMIS deploy
# =============================================================================
export DOCKER_TLS_VERIFY="1"
export DOCKER_HOST="tcp://dev.logimev.cd:2376"
export DOCKER_CERT_PATH="${SCRIPT_DIR}/credentials"

"$SCRIPT_DIR/../shared/restart_or_restore.sh" "dev"

# =============================================================================
# 2. Reporting-stack deploy
# =============================================================================
# The reporting-stack compose uses local bind mounts (../scripts, ../airflow/dags,
# etc.), so it can't be deployed by pointing DOCKER_HOST at the remote daemon -
# the daemon would look for those paths on its own filesystem. We instead rsync
# the openlmis-reporting checkout to a fixed path on the host and run
# `make up && make setup` over SSH.

if [ "${SKIP_REPORTING_STACK:-0}" = "1" ]; then
  echo "SKIP_REPORTING_STACK=1 set - skipping reporting-stack deploy."
  exit 0
fi

# All Jenkins SCMs check out UNDER the workspace root:
#   rdc-deployment            -> workspace root (no subdir; this repo)
#   rdc-configuration         -> ./credentials (subdir)
#   soldevelo-reporting-stack -> ./openlmis-reporting (subdir)
# $WORKSPACE is always set by Jenkins. The fallback derives the workspace root
# from this script's location (dev/ -> repo root == workspace root).
WORKSPACE_ROOT="${WORKSPACE:-$(cd "${SCRIPT_DIR}/.." && pwd)}"

REPORTING_REPO_LOCAL="${REPORTING_REPO_LOCAL:-${WORKSPACE_ROOT}/openlmis-reporting}"
REPORTING_REMOTE_HOST="${REPORTING_REMOTE_HOST:-dev.logimev.cd}"
REPORTING_REMOTE_USER="${REPORTING_REMOTE_USER:-ubuntu}"
REPORTING_REMOTE_PATH="${REPORTING_REMOTE_PATH:-/opt/reporting-stack}"

CONFIG_DIR="${WORKSPACE_ROOT}/credentials"
SSH_KEY="${REPORTING_SSH_KEY:-${CONFIG_DIR}/dev_env/id_rsa}"
ENV_REPORTING="${CONFIG_DIR}/dev_env/.env.reporting-stack"
CDC_SQL="${SCRIPT_DIR}/reporting-stack/reporting-stack-cdc.sql"

if [ ! -d "$REPORTING_REPO_LOCAL" ]; then
  echo "ERROR: reporting-stack checkout not found at $REPORTING_REPO_LOCAL" >&2
  echo "Add it as an SCM source in the Jenkins job (subdir openlmis-reporting)." >&2
  exit 1
fi
if [ ! -f "$SSH_KEY" ]; then
  echo "ERROR: SSH key not found at $SSH_KEY" >&2
  echo "Provide it via a Jenkins credentials binding (REPORTING_SSH_KEY)." >&2
  exit 1
fi
if [ ! -f "$ENV_REPORTING" ]; then
  echo "ERROR: .env.reporting-stack not found at $ENV_REPORTING" >&2
  exit 1
fi
if [ ! -f "$CDC_SQL" ]; then
  echo "ERROR: CDC bootstrap SQL not found at $CDC_SQL" >&2
  exit 1
fi

# SSH refuses to use keys with loose permissions; rsync inherits that.
chmod 600 "$SSH_KEY"

SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
SSH_TARGET="${REPORTING_REMOTE_USER}@${REPORTING_REMOTE_HOST}"

echo "=== Reporting-stack deploy ==="
echo "Target: ${SSH_TARGET}:${REPORTING_REMOTE_PATH}"
echo "Mode:   ${KEEP_OR_RESTORE:-keep}"

# Stage .env on the Jenkins side so it gets rsync'd in.
cp "$ENV_REPORTING" "$REPORTING_REPO_LOCAL/.env"

# Ensure remote path exists and is owned by the deploy user.
ssh $SSH_OPTS "$SSH_TARGET" "sudo mkdir -p '$REPORTING_REMOTE_PATH' && sudo chown -R '$REPORTING_REMOTE_USER':'$REPORTING_REMOTE_USER' '$REPORTING_REMOTE_PATH'"

echo "Syncing repo..."
rsync -az --delete \
  -e "ssh $SSH_OPTS" \
  --exclude='.git/' \
  --exclude='.bootstrap/' \
  --exclude='.packages/' \
  --exclude='.dbt/' \
  --exclude='.deploy/' \
  "$REPORTING_REPO_LOCAL/" \
  "${SSH_TARGET}:${REPORTING_REMOTE_PATH}/"

# Ship the CDC bootstrap SQL alongside the repo (outside the rsync'd tree).
ssh $SSH_OPTS "$SSH_TARGET" "mkdir -p '$REPORTING_REMOTE_PATH/.deploy'"
scp $SSH_OPTS "$CDC_SQL" "${SSH_TARGET}:${REPORTING_REMOTE_PATH}/.deploy/reporting-stack-cdc.sql"

echo "Running make up && make setup on remote host..."
ssh $SSH_OPTS "$SSH_TARGET" "KEEP_OR_RESTORE='${KEEP_OR_RESTORE:-keep}' REPORTING_REMOTE_PATH='$REPORTING_REMOTE_PATH' REPORTING_OLD_DOCKER='${REPORTING_OLD_DOCKER:-0}' bash -s" <<'REMOTE'
set -euo pipefail
cd "$REPORTING_REMOTE_PATH"

# On 'restore', the database was replaced from a snapshot - CDC offsets are
# stale, so reset the reporting-stack volumes and let Debezium re-snapshot.
if [ "${KEEP_OR_RESTORE:-keep}" = "restore" ]; then
  echo "KEEP_OR_RESTORE=restore - resetting reporting-stack volumes for fresh snapshot."
  make reset || true
fi

# --- dbt-directory perms + AIRFLOW_DOCKER_GID alignment ---------------------
# The Airflow scheduler runs as uid 50000 with group_add: ["$AIRFLOW_DOCKER_GID"]
# so it can talk to /var/run/docker.sock. The same supplementary group is what
# lets it write into the dbt directory. The GID is auto-detected so the deploy
# survives host rebuilds without hand-editing the configuration repo.
DOCKER_GID=$(stat -c '%g' /var/run/docker.sock)
echo "Host docker.sock gid: $DOCKER_GID - applying to .env and dbt/ perms."

if grep -q '^AIRFLOW_DOCKER_GID=' .env; then
  sed -i "s|^AIRFLOW_DOCKER_GID=.*|AIRFLOW_DOCKER_GID=$DOCKER_GID|" .env
else
  echo "AIRFLOW_DOCKER_GID=$DOCKER_GID" >> .env
fi

chgrp -R "$DOCKER_GID" dbt
chmod -R g+rwX dbt

# --- Old-Docker workaround (only when the host daemon is < 20.x) -------------
# BuildKit on 19.03-era daemons strips inherited Cmd/Entrypoint from FROM+COPY
# images, and old libseccomp rejects clone3; the classic-builder pre-build and
# the seccomp overlay cover both. Skipped on modern daemons.
DOCKER_SERVER_VERSION=$(docker version --format '{{.Server.Version}}')
DOCKER_SERVER_MAJOR=${DOCKER_SERVER_VERSION%%.*}
if [ "${REPORTING_OLD_DOCKER:-0}" = "1" ] || [ "$DOCKER_SERVER_MAJOR" -lt 20 ]; then
  echo "Docker $DOCKER_SERVER_VERSION - pre-building custom images with the classic builder..."
  for spec in kafka-connect:connect airflow:airflow superset:superset; do
    name="${spec%%:*}"; ctx="${spec##*:}"
    DOCKER_BUILDKIT=0 docker build -t "soldevelo-reporting-stack/${name}:latest" "$ctx"
  done
  export COMPOSE_OVERLAY=compose/docker-compose.seccomp-unconfined.yml
  if ! grep -q '^DBT_DOCKER_SECCOMP=' .env; then
    echo "DBT_DOCKER_SECCOMP=unconfined" >> .env
  fi
else
  echo "Docker $DOCKER_SERVER_VERSION - no old-Docker workarounds needed."
fi

make up

# --- CDC objects on the source RDS -------------------------------------------
# The idempotent CDC bootstrap SQL is re-applied on EVERY deploy: a restore
# build replaces the database from a snapshot, which drops these objects.
# The snapshot restore completes before this script runs, so table existence
# is sufficient (no Flyway churn to wait out).
get_env() { grep "^$1=" .env | head -n1 | cut -d= -f2-; }
SOURCE_PG_HOST=$(get_env SOURCE_PG_HOST)
SOURCE_PG_PORT=$(get_env SOURCE_PG_PORT)
SOURCE_PG_DB=$(get_env SOURCE_PG_DB)
SOURCE_PG_USER=$(get_env SOURCE_PG_USER)
SOURCE_PG_PASSWORD=$(get_env SOURCE_PG_PASSWORD)
SOURCE_PG_SSLMODE=$(get_env SOURCE_PG_SSLMODE)
ALLOWLIST=$(get_env SOURCE_PG_TABLE_ALLOWLIST)

# No -i: it would drain the stdin that feeds this script (bash -s).
psql_rds() {
  docker run --rm -v "$REPORTING_REMOTE_PATH/.deploy:/sql:ro" -e PGPASSWORD="$SOURCE_PG_PASSWORD" postgres:14-alpine \
    psql "host=$SOURCE_PG_HOST port=${SOURCE_PG_PORT:-5432} dbname=$SOURCE_PG_DB user=$SOURCE_PG_USER sslmode=${SOURCE_PG_SSLMODE:-require}" \
    -v ON_ERROR_STOP=1 "$@"
}

EXPECTED=$(echo "$ALLOWLIST" | tr ',' '\n' | grep -c .)
IN_LIST=$(echo "$ALLOWLIST" | tr ',' '\n' | sed "s/\([^.]*\)\.\(.*\)/('\1','\2')/" | paste -sd, -)

echo "Waiting for the $EXPECTED allowlisted source tables to exist..."
DEADLINE=$(( $(date +%s) + 1800 ))
while :; do
  COUNT=$(psql_rds -tA -c "SELECT count(*) FROM information_schema.tables WHERE (table_schema, table_name) IN ($IN_LIST);" || echo 0)
  if [ "$COUNT" = "$EXPECTED" ]; then
    echo "All $EXPECTED source tables present - applying CDC objects..."
    psql_rds -f /sql/reporting-stack-cdc.sql
    break
  fi
  echo "  $COUNT/$EXPECTED tables present - retrying in 30s..."
  sleep 30
  if [ "$(date +%s)" -ge "$DEADLINE" ]; then
    echo "ERROR: timed out waiting for the source tables ($COUNT/$EXPECTED)." >&2
    exit 1
  fi
done

# Git-mode packages: clone core (+ extensions if configured) to .packages/ so
# the connector and Superset importers (run by `make setup`) pick them up.
make package-fetch
make setup

# 'make reset' wiped ClickHouse on restore - rebuild the curated marts now
# instead of leaving dashboards empty until the hourly Airflow DAG.
if [ "${KEEP_OR_RESTORE:-keep}" = "restore" ]; then
  make initial-dbt-build
fi
REMOTE

echo "=== Done ==="
