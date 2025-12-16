#!/usr/bin/env bash

docker compose down
docker compose pull

echo "Will keep data."

export spring_profiles_active="production"
docker compose up --build --force-recreate -d
