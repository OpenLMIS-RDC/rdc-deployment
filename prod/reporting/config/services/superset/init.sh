#!/bin/bash

set -e

: ${SUPERSET_ADMIN_USERNAME:?"Need to set SUPERSET_ADMIN_USERNAME"}
: ${SUPERSET_ADMIN_PASSWORD:?"Need to set SUPERSET_ADMIN_PASSWORD"}
: ${SUPERSET_VERSION:?"Need to set SUPERSET_VERSION"}
: ${APP_DIR:?"Need to set APP_DIR"}

CONFIG_DIR="/etc/superset"

# wait for postgres
until PGPASSWORD=$POSTGRES_PASSWORD psql -h "db" -p "5432" -U "$POSTGRES_USER" -d "open_lmis_reporting" -c '\q'; do
  >&2 echo "Postgres is unavailable - sleeping"
  sleep 5
done

>&2 echo "Postgres is up"

# App initialization
# Run the Flask CLI from outside the `superset` package dir; otherwise, when the
# image's WORKDIR is the package dir, FLASK_APP=superset resolves to the bogus
# module "superset.superset" and `flask fab` fails.
cd /
flask fab create-admin --username ${SUPERSET_ADMIN_USERNAME} --firstname Admin --lastname Admin --email noreply --password ${SUPERSET_ADMIN_PASSWORD} &&

superset db upgrade &&
superset import_datasources -p $CONFIG_DIR/datasources/database.yaml &&
superset import_dashboards -u ${SUPERSET_ADMIN_USERNAME} -p $CONFIG_DIR/dashboards/openlmis_rdc_dashboards_v2.zip &&
superset init &&

gunicorn $GUNICORN_CMD_ARGS "superset.app:create_app()"
