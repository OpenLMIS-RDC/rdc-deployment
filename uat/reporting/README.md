# Power BI Integration for OpenLMIS Reporting

This directory contains the configurations required to support Power BI within the OpenLMIS reporting module, including the analytic schema setup, secure communication, and automated data refreshing.

## 1. Analytic Schema Setup (Database)
The Power BI Dashboard utilizes a star schema for optimized reporting.
- **Script:** `uat/reporting/db/docker-entrypoint-initdb.d/templates/OlmisCreateAnalyticSchemaStatements.sql`
- **Automation:** This script is automatically executed during initialization via `uat/reporting/db/docker-entrypoint-initdb.d/reporting-db.sh` targeting the `open_lmis_reporting` database.
- **Security:** The injection method ensures the analytic schema is deployed securely within the reporting instance.

## 2. Power BI Service Proxy & Access
A dedicated service has been added to wrap the Power BI service link and provide a controlled access point.
- **Directory:** `uat/reporting/powerbi/`
- **Infrastructure:** - A new `powerbi-nginx` service is defined in `docker-compose.yml`.
    - The Nginx reverse proxy configuration (`uat/reporting/config/services/nginx/consul-template/openlmis.conf`) has been updated to expose this service securely.
    - Includes the required `dashboard1pbiwrapper.html` entry point.

## 3. Materialized View Refresh (Cron)
To ensure the dashboard displays up-to-date information, the following materialized views are refreshed every 15 minutes:
- `analytics.dim_facility`
- `analytics.dim_product`

**Configuration File:** `uat/reporting/cron/periodic/15min/refresh-mv`