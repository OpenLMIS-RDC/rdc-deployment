#!/usr/bin/env bash
set -e

BASE_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." &> /dev/null && pwd)
TARGET_ENV="${1:-}"

if [ -z "$BASE_DIR" ]; then
  echo "Error: Could not determine BASE_DIR"
  exit 1
fi

if [[ -z "$TARGET_ENV" ]]; then
  echo "Error: Could not determine TARGET_ENV. [uat|prod]"
  exit 1
fi

ENV_PATH="$BASE_DIR/$TARGET_ENV"

if [ "$KEEP_OR_RESTORE" == "restore" ]; then
  echo "Restoring database from the latest snapshot..."

  cd "$BASE_DIR/shared/restore"
  docker compose down -v
  docker compose pull
  docker compose run --rm rds-restore

  echo "Database restoration complete."
else
  echo "Skipping database restore (Restarting services only)."
fi

echo "Navigating to: $ENV_PATH"
cd "$ENV_PATH"

echo "Cleaning up existing containers and volumes for $TARGET_ENV..."
docker compose down -v

echo "Pulling latest images..."
docker compose pull

echo "Starting services..."
docker compose up --build --force-recreate -d

echo "Successfully deployed to $TARGET_ENV."
