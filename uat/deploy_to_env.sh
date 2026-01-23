#!/usr/bin/env sh

export DOCKER_TLS_VERIFY="1"
export DOCKER_HOST="uat.logimev.cd:2376"
export DOCKER_CERT_PATH="${PWD}/credentials"

../shared/restart.sh $1
