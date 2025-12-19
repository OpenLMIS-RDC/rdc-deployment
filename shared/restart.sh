#!/usr/bin/env bash

set -e

docker compose pull

docker compose down

docker compose up --force-recreate -d
