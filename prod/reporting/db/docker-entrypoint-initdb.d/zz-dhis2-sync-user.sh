#!/bin/bash
set -e

# Read-only user for the DHIS2 middleware. Must run after reporting-db.sh
# (needs open_lmis_reporting and the analytics schema), hence the zz- prefix.
if [ -z "$DHIS2_SYNC_POSTGRES_PASSWORD" ]; then
    echo "DHIS2_SYNC_POSTGRES_PASSWORD not set - skipping dhis2_sync user"
    exit 0
fi

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "open_lmis_reporting" \
    -v pw="$DHIS2_SYNC_POSTGRES_PASSWORD" <<-'EOSQL'
    CREATE ROLE dhis2_sync LOGIN PASSWORD :'pw' CONNECTION LIMIT 3;
    ALTER ROLE dhis2_sync SET default_transaction_read_only = on;
    ALTER ROLE dhis2_sync SET statement_timeout = '5min';

    GRANT CONNECT ON DATABASE open_lmis_reporting TO dhis2_sync;
    GRANT USAGE ON SCHEMA public, analytics TO dhis2_sync;
    GRANT SELECT ON ALL TABLES IN SCHEMA public, analytics TO dhis2_sync;
    -- kafka_* tables are created later by the JDBC sink connectors
    ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public, analytics
        GRANT SELECT ON TABLES TO dhis2_sync;
EOSQL
