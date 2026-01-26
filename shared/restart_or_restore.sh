#!/usr/bin/env bash
set -e

BASE_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." &> /dev/null && pwd)

if [ -z "$BASE_DIR" ]; then
  echo "Error: Could not determine BASE_DIR"
  exit 1
fi

if [ "$KEEP_OR_RESTORE" == "restore" ]; then
  echo "Restoring database from the latest snapshot..."

  cd "$BASE_DIR/shared/restore"
  docker compose down -v
  docker compose run --rm rds-restore

  echo "Pulling latest images and starting services..."
else
  echo "Restarting services"
fi

cd "$BASE_DIR/uat"
docker compose pull
docker compose up --force-recreate -d
