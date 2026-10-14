#!/usr/bin/env bash
# =============================================================================
# Remote part of dev/deploy_to_env.sh: runs ON the reporting host, inside
# $REPORTING_REMOTE_PATH, after the platform checkout has been rsynced there.
#
# Shipped by scp and executed as a file on purpose. It used to be piped into
# `bash -s` over ssh, but `make setup` runs `docker compose exec`, which
# attaches to stdin and swallowed the rest of the script: everything after
# `make setup` (connector refresh, dbt build) silently never ran.
#
# Inputs (environment):
#   KEEP_OR_RESTORE        keep | restore
#   REPORTING_REMOTE_PATH  platform checkout on this host
#   REPORTING_OLD_DOCKER   1 forces the old-Docker workarounds
# =============================================================================
set -euo pipefail
cd "$REPORTING_REMOTE_PATH"

# On 'restore' the stack was already wiped in step 0, before the database was
# replaced, so Debezium starts from nothing and takes a fresh snapshot.

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

# Tables added to SOURCE_PG_TABLE_ALLOWLIST since the last deploy are not
# backfilled by `make setup` (it only re-registers the connector). MODE=auto
# diffs the live connector config against .env and triggers an incremental
# snapshot for the new tables only; it is a no-op when nothing changed.
make connector-refresh

if [ "${KEEP_OR_RESTORE:-keep}" = "restore" ]; then
  # The step-0 reset wiped ClickHouse on restore - rebuild the curated marts now
  # instead of leaving dashboards empty until the hourly Airflow DAG.
  make initial-dbt-build
else
  # Incremental build so models added or changed in the core/extension
  # packages exist before anyone opens the freshly imported dashboards.
  # Rows for newly snapshotted tables may still be arriving; the hourly
  # Airflow DAG fills them in.
  make dbt-build
fi
