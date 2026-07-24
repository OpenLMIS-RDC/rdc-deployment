# Reporting stack (dev)

CDC-based analytics platform ([soldevelo/reporting-stack](https://github.com/soldevelo/reporting-stack)):
Debezium -> Kafka -> ClickHouse -> dbt (Airflow) -> Superset, co-located on the
environment's Docker host at `/opt/reporting-stack`. Replaces the legacy
NiFi/Superset stack used by uat/prod.

## How it deploys

`deploy_to_env.sh` deploys OpenLMIS first, then the reporting stack:

1. Stages `.env.reporting-stack` (from the private configuration repo) as the
   platform's `.env`.
2. Rsyncs the platform checkout to `<host>:/opt/reporting-stack` and ships
   `reporting-stack-cdc.sql` alongside it (the compose uses local bind mounts,
   so it cannot run through a remote `DOCKER_HOST`).
3. Over SSH: injects the host docker GID for Airflow, `make up`, applies the
   CDC SQL to the source RDS (idempotent, re-applied every deploy), then
   `make package-fetch && make setup`. On `KEEP_OR_RESTORE=restore` the stack
   is `make reset` first and the curated marts are rebuilt with
   `make initial-dbt-build`.

Set `SKIP_REPORTING_STACK=1` for an OpenLMIS-only redeploy.

## One-time prerequisites

1. **RDS replication grant** (the master user is not a superuser on RDS;
   `ALTER ROLE ... WITH REPLICATION` fails there):
   ```sql
   GRANT rds_replication TO drc_user;
   ```
2. **RDS parameter group** must have `rds.logical_replication=1` (needs a
   reboot when first set) and `max_slot_wal_keep_size` as WAL-retention
   protection - without it, a stalled stack's replication slot retains WAL
   until the disk fills. When the cap is exceeded the slot is invalidated
   and Debezium re-snapshots on reconnect.
3. **Jenkins job**: add a third SCM checkout of the platform repo into subdir
   `openlmis-reporting`, and provide the host SSH key via a credentials
   binding exported as `REPORTING_SSH_KEY`.

## Access

- Superset: `https://<env FQDN>:8443` - TLS terminates at the ALB, which
  forwards to Superset's plain-HTTP port; that port is reachable only from
  the ALB's security group.
- Airflow (8080), Kafka UI (9080), ClickHouse (8123) are host-internal; use an
  SSH tunnel: `ssh -L 8080:localhost:8080 -L 9080:localhost:9080 ubuntu@<host>`.

## Verify

On the host in `/opt/reporting-stack`:
```bash
make ps
make verify-services    # Kafka, Connect, Apicurio, Kafka UI, ClickHouse
make verify-cdc         # Debezium connector + CDC topics
make verify-ingestion   # ClickHouse raw landing has data
make verify-dbt
make verify-superset
```

Monitor replication slot lag on the source database:
```sql
SELECT slot_name, active,
  pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS lag_size,
  wal_status
FROM pg_replication_slots;
```

## Keep in sync

The table list must stay identical in:
- `reporting-stack-cdc.sql` (this directory)
- `SOURCE_PG_TABLE_ALLOWLIST` in the private repo's `.env.reporting-stack`
