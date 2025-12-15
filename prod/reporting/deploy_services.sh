#!/usr/bin/env bash

export DOCKER_TLS_VERIFY="1"
export DOCKER_HOST="reporting.logimev.cd:2376"
export DOCKER_CERT_PATH="${PWD}/credentials"

docker volume create pgdata

docker compose down -v --remove-orphans
docker compose build --no-cache
docker compose up -d
