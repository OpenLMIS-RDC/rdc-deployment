#!/usr/bin/env bash
# Deploy the Alloy agent to a Docker host over TLS, like <env>/deploy_to_env.sh.
# Run from the Jenkins workspace root with rdc-configuration checked out in
# credentials/; reads alloy.env (identity, ingest token, DOCKER_HOST) and the
# Docker client certs (credentials/) from <env>_env/, or from
# <env>_env/reporting/ for the separate reporting host (uat, prod).
# Usage: monitoring/alloy/deploy_alloy.sh <dev|uat|prod> [reporting]
set -euo pipefail

ENV_NAME="${1:?usage: $0 <dev|uat|prod> [reporting]}"
HOST_ROLE="${2:-}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="${CONFIG_DIR:-$(pwd)/credentials}/${ENV_NAME}_env"
case "${HOST_ROLE}" in
  "") ;;
  reporting) CONFIG_DIR="${CONFIG_DIR}/reporting" ;;
  *) echo "unknown host role '${HOST_ROLE}' (expected: reporting)" >&2; exit 1 ;;
esac

cp "${CONFIG_DIR}/alloy.env" "${HERE}/.env"
trap 'rm -f "${HERE}/.env"' EXIT
set -a; . "${HERE}/.env"; set +a

export DOCKER_TLS_VERIFY=1
export DOCKER_CERT_PATH="${CONFIG_DIR}/credentials"

cd "${HERE}"
# Classic builder: BuildKit on older daemons drops the base image's
# ENTRYPOINT from FROM+COPY images.
DOCKER_BUILDKIT=0 docker build --build-arg "ALLOY_VERSION=${ALLOY_VERSION}" \
  -t "soldevelo-monitoring-alloy:${ALLOY_VERSION}" .
docker compose up -d
docker compose ps
