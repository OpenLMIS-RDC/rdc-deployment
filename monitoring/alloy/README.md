# Grafana Alloy agent (OpenLMIS RDC)

One Alloy agent per Docker host. It collects host, container and app
metrics, container logs, the nginx log files and (optionally) PostgreSQL
metrics, and pushes them to the central
[soldevelo-monitoring](https://github.com/SolDevelo/soldevelo-monitoring)
stack at `olmis-monitoring.soldevelo.com`. It runs as its own compose project
(`soldevelo-monitoring-agents`), so app deploys do not touch it.

## Hosts

| Host | `ENVIRONMENT` | `TARGET_NAME` | Config in rdc-configuration | Deploy |
|---|---|---|---|---|
| dev.logimev.cd (app + reporting stack) | `dev` | `rdc-dev` | `dev_env/` | `deploy_alloy.sh dev` |
| uat.logimev.cd | `uat` | `rdc-uat` | `uat_env/` | `deploy_alloy.sh uat` |
| uat-reporting.logimev.cd | `uat` | `rdc-uat-reporting` | `uat_env/reporting/` | `deploy_alloy.sh uat reporting` |
| www.logimev.cd | `prod` | `rdc-prod` | `prod_env/` | `deploy_alloy.sh prod` |
| reporting.logimev.cd | `prod` | `rdc-prod-reporting` | `prod_env/reporting/` | `deploy_alloy.sh prod reporting` |

## Files

| File | What |
|---|---|
| `config.alloy` | The package agent config, **vendored** at the tag in `PACKAGE_VERSION`. Never edit it here. |
| `openlmis.alloy` | OpenLMIS additions: nginx access/error logs from the `nginx-log` volume. |
| `sync-from-package.sh` | Re-copies `config.alloy` for `PACKAGE_VERSION`; `--check` reports drift. |
| `deploy_alloy.sh` | Builds the image on the host's Docker daemon and starts the agent. |
| `.env.example` | The variables. Real values: `alloy.env` per host in `rdc-configuration` (see Hosts). |

Upgrade: bump `PACKAGE_VERSION`, run `./sync-from-package.sh`, read the diff and
the package CHANGELOG, commit, deploy.

## Deploy

Manual Jenkins job `OpenLMIS-RDC-monitoring-alloy-deploy-to-<env>[-reporting]`.
It checks out this repo and `rdc-configuration` (into `credentials/`) and runs
`monitoring/alloy/deploy_alloy.sh <env> [reporting]` from the workspace root.
The host's Docker engine must be 20.10 or newer.

## Scraping apps

The agent scrapes containers labelled `monitoring.scrape: "true"`, at
`monitoring.port` + `monitoring.path`, named by `monitoring.service` (see
`uat/docker-compose.yml`). Labels apply on the next app deploy. They are set
on dev and uat only: prod runs service versions from before
`/actuator/prometheus`; label it when it is upgraded to OpenLMIS 3.20.
`hapifhir` is not scraped.

## PostgreSQL

`postgres-exporter` runs only with `COMPOSE_PROFILES=postgres` and
`PG_EXPORTER_DSN` in `alloy.env` (app hosts), as a read-only role:

```sql
CREATE ROLE olmis_monitoring LOGIN PASSWORD '...';
GRANT pg_monitor TO olmis_monitoring;
```

A dev/UAT restore replaces the RDS instance from the prod snapshot, where the
role has the prod password (or does not exist); `shared/restore/after_restore.sh`
re-creates it with the env's password when `MONITORING_DB_PASSWORD` is set in
`.env-restore`.

## Notes

- `network_mode: host`, not the app network, so app deploys never find a
  foreign container on `<env>_default`.
- `COMPOSE_PROJECT_NAME` must stay `soldevelo-monitoring-agents`: `config.alloy`
  drops the agent's own logs by that project name.
- Labels: `app=openlmis`, `deployment=rdc`, `environment=dev|uat|prod`.
- Alerts: `#notifications-rdc-prod` and `#notifications-rdc-uat`; dev is muted
  (routing lives in openlmis-monitoring-overlay).
