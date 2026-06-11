# Power BI Integration for OpenLMIS Reporting

This directory contains the configurations required to support Power BI within the OpenLMIS reporting module, including the analytic schema setup, secure communication, and automated data refreshing.

## 1. Analytic Schema Setup (Database)

The Power BI Dashboard utilizes a star schema for optimized reporting.

- **Script:** `prod/reporting/db/docker-entrypoint-initdb.d/templates/OlmisCreateAnalyticSchemaStatements.sql`
- **Automation:** This script is automatically executed during initialization via `prod/reporting/db/docker-entrypoint-initdb.d/reporting-db.sh` targeting the `open_lmis_reporting` database.
- **Security:** The injection method ensures the analytic schema is deployed securely within the reporting instance.

## 2. Power BI Service Proxy & Access

A dedicated service has been added to wrap the Power BI service link and provide a controlled access point.

- **Directory:** `prod/reporting/powerbi/`
- **Infrastructure:** - A new `powerbi-nginx` service is defined in `docker-compose.yml`.
  - The Nginx reverse proxy configuration (`prod/reporting/config/services/nginx/consul-template/openlmis.conf`) has been updated to expose this service securely.
  - Includes the required `dashboard1pbiwrapper.html` entry point.

## 3. Materialized View Refresh (Cron)

To ensure the dashboard displays up-to-date information, the following materialized views are refreshed every 15 minutes:

- `analytics.dim_facility`
- `analytics.dim_product`

**Configuration File:** `prod/reporting/cron/periodic/15min/refresh-mv`

## 4. Analytic Aggregate Schema (Update)

Additional structures have been introduced to support high-performance reporting and pre-aggregated datasets.

- **Script:** `prod/reporting/db/docker-entrypoint-initdb.d/templates/OlmisCreateAnalyticAggregateSchemaStatements.sql`

### Purpose

- Define aggregated fact tables
- Improve query performance for Power BI
- Reduce load on transactional datasets

---

## 5. Daily Analytic Data Initialization (Update)

A new initialization script has been added to prepare baseline analytic data.

- **Script:** `prod/reporting/db/docker-entrypoint-initdb.d/templates/OlmisInitDailyAnalyticDataStatements.sql`

### Purpose

- Populate initial daily datasets
- Ensure historical continuity for reporting
- Prepare the system before enabling aggregation jobs

⚠️ This step is critical. Without it, reporting data may be incomplete or inconsistent.

---

## 6. Daily Stock Aggregation (Cron - New)

A daily aggregation job has been introduced to compute stock metrics and feed reporting tables.

- **Script:** `prod/reporting/cron/periodic/daily/stock-aggregation`

### Purpose

- Aggregate daily stock data (consumption, adjustments, balances)
- Populate fact tables used by Power BI
- Serve as the main data layer for analytics

### Execution

- Runs daily via cron
- Complements the 15-minute materialized view refresh

---

## 7. Updated Reporting Architecture

The reporting system now follows a structured multi-layer approach:

1. **Transactional Data (OpenLMIS)**
2. **Daily Aggregated Data (Cron jobs)**
3. **Analytic Schema (Star model)**
4. **Power BI Dashboards**

### Key Point

- Daily aggregation is now the backbone of reporting
- Materialized views handle dimension freshness
- Power BI reads only optimized datasets

---

## ⚠️ Important Considerations

- Ensure daily aggregation scripts are **idempotent** (no duplicate data)
- Validate data integrity after each run
- Monitor cron execution logs regularly
- Consider indexing large fact tables for performance
