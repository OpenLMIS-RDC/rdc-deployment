#!/usr/bin/env bash

docker compose down

echo "Will keep data."

export spring_profiles_active="production"
docker compose up --build --force-recreate -d
