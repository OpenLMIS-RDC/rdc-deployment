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
# 0. Reporting-stack settings, and stopping it before a database restore
# =============================================================================
REPORTING_ENABLED=1
if [ "${SKIP_REPORTING_STACK:-0}" = "1" ]; then
  echo "SKIP_REPORTING_STACK=1 set - the reporting-stack deploy will be skipped."
  REPORTING_ENABLED=0
fi

if [ "$REPORTING_ENABLED" = "1" ]; then
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

  # A restore replaces the source database. The running Debezium connector
  # would reconnect to the new database before the CDC bootstrap SQL runs,
  # find no publication, and create one FOR ALL TABLES itself (its default
  # publication.autocreate.mode). Such a publication cannot be narrowed and
  # blocks DELETEs on tables without a primary key, so OpenLMIS Flyway
  # migrations start failing. Wipe the stack (connector config, offsets,
  # ClickHouse) BEFORE the restore; it is brought back up in step 2. A failed
  # reset must stop the deploy, not be ignored.
  if [ "${KEEP_OR_RESTORE:-keep}" = "restore" ]; then
    echo "KEEP_OR_RESTORE=restore - stopping the reporting stack and wiping its volumes before the database restore."
    ssh $SSH_OPTS "$SSH_TARGET" "if [ -f '$REPORTING_REMOTE_PATH/.env' ]; then cd '$REPORTING_REMOTE_PATH' && make reset; else echo 'No reporting stack deployed yet at $REPORTING_REMOTE_PATH - nothing to reset.'; fi"
  fi
fi

# =============================================================================
# 1. OpenLMIS deploy
# =============================================================================
export DOCKER_TLS_VERIFY="1"
export DOCKER_HOST="tcp://dev.logimev.cd:2376"
export DOCKER_CERT_PATH="${SCRIPT_DIR}/credentials"

"$SCRIPT_DIR/../shared/restart_or_restore.sh" "dev"

if [ "$REPORTING_ENABLED" != "1" ]; then
  exit 0
fi

# =============================================================================
# 2. Reporting-stack deploy
# =============================================================================
# The reporting-stack compose uses local bind mounts (../scripts, ../airflow/dags,
# etc.), so it can't be deployed by pointing DOCKER_HOST at the remote daemon -
# the daemon would look for those paths on its own filesystem. We instead rsync
# the openlmis-reporting checkout to a fixed path on the host and run
# `make up && make setup` over SSH.


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

REMOTE_SCRIPT="${SCRIPT_DIR}/reporting-stack/deploy-remote.sh"
scp $SSH_OPTS "$REMOTE_SCRIPT" "${SSH_TARGET}:${REPORTING_REMOTE_PATH}/.deploy/deploy-remote.sh"

echo "Running the remote deploy (make up, CDC objects, make setup, connector refresh, dbt build)..."
# Executed as a file, with stdin closed: see the header of deploy-remote.sh.
ssh $SSH_OPTS "$SSH_TARGET" "KEEP_OR_RESTORE='${KEEP_OR_RESTORE:-keep}' REPORTING_REMOTE_PATH='$REPORTING_REMOTE_PATH' REPORTING_OLD_DOCKER='${REPORTING_OLD_DOCKER:-0}' bash '$REPORTING_REMOTE_PATH/.deploy/deploy-remote.sh' < /dev/null"

echo "=== Done ==="
