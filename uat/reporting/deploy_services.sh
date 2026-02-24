#!/usr/bin/env bash

export DOCKER_TLS_VERIFY="1"
export DOCKER_HOST="tcp://uat-reporting.logimev.cd:2376"
export DOCKER_CERT_PATH="${PWD}/credentials"

# docker volume create pgdata

docker compose down -v --remove-orphans

export DOCKER_CLIENT_TIMEOUT=1200
export COMPOSE_HTTP_TIMEOUT=1200

DOCKER_BUILDKIT=0 docker compose build --no-cache
docker compose up -d
