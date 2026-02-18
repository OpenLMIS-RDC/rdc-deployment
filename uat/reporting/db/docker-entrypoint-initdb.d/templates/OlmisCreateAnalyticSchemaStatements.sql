-- =========================================
-- COUCHE STAR SCHEMA POUR POWER BI (PostgreSQL)
--  - Dimensions : MATERIALIZED VIEW (petites, OK a rafraichir)
--  - Faits      : VIEW (en evitant un 2e refresh lourd sur gros volumes)
--
-- Dependances sources :
--   - public.stock_status_and_consumption     (MV)
--   - public.adjustments                      (MV)
--   - public.reporting_rate_and_timeliness    (MV)
--   - public.stock_adjustments_view           (MV)
--   - public.view_facility_access             (VIEW)
--   - tables kafka_* (OpenLMIS)
-- =========================================

-- 0) Creation du schema cible
CREATE SCHEMA IF NOT EXISTS analytics;

-- 1) Drop / replace 
DROP VIEW IF EXISTS analytics.fact_stock_status_consumption CASCADE;
DROP VIEW IF EXISTS analytics.fact_adjustments CASCADE;
DROP VIEW IF EXISTS analytics.fact_reporting_rate_timeliness CASCADE;
DROP VIEW IF EXISTS analytics.fact_stock_adjustments CASCADE;
DROP VIEW IF EXISTS analytics.bridge_user_facility_access CASCADE;
DROP VIEW IF EXISTS analytics.dim_program CASCADE;
DROP VIEW IF EXISTS analytics.dim_processing_schedule CASCADE;
DROP VIEW IF EXISTS analytics.dim_processing_period CASCADE;
DROP VIEW IF EXISTS analytics.dim_user CASCADE;

DROP MATERIALIZED VIEW IF EXISTS analytics.dim_facility CASCADE;
DROP MATERIALIZED VIEW IF EXISTS analytics.dim_product CASCADE;

-- =========================================
-- 2) DIMENSIONS (VIEWS et MATERIALIZED VIEWS)
-- =========================================

-- 2.1 Dimension Etablissement (Facility) + hierarchie geographique
CREATE MATERIALIZED VIEW analytics.dim_facility AS
SELECT
    f.id                 AS facility_id,
    f.code               AS facility_code,
    f.name               AS facility_name,
    f.active             AS facility_active_status,
    f.enabled            AS facility_enabled_status,
    f.openlmisaccessible AS openlmis_accessible,
    f.golivedate         AS go_live_date,
    f.godowndate         AS go_down_date,
    dgz.id               AS district_id,
    dgz.code             AS district_code,
    dgz.name             AS district_name,
    rgz.id               AS region_id,
    rgz.code             AS region_code,
    rgz.name             AS region_name,
    cgz.id               AS country_id,
    cgz.code             AS country_code,
    cgz.name             AS country_name,
    ft.id                AS facility_type_id,
    ft.code              AS facility_type_code,
    ft.name              AS facility_type_name,
    fo.id                AS facility_operator_id,
    fo.code              AS facility_operator_code,
    fo.name              AS facility_operator_name
FROM public.kafka_facilities f
LEFT JOIN public.kafka_geographic_zones dgz  ON dgz.id = f.geographiczoneid
LEFT JOIN public.kafka_geographic_zones rgz  ON rgz.id = dgz.parentid
LEFT JOIN public.kafka_geographic_zones cgz  ON cgz.id = rgz.parentid
LEFT JOIN public.kafka_facility_types ft     ON ft.id  = f.typeid
LEFT JOIN public.kafka_facility_operators fo ON fo.id  = f.operatedbyid
WITH DATA;

CREATE UNIQUE INDEX IF NOT EXISTS ux_dim_facility_facility_id
ON analytics.dim_facility (facility_id);

CREATE INDEX IF NOT EXISTS ix_dim_facility_geo
ON analytics.dim_facility (country_id, region_id, district_id);


-- 2.2 Dimension Programme
CREATE OR REPLACE VIEW analytics.dim_program AS
SELECT
    p.id    AS program_id,
    p.code  AS program_code,
    p.name  AS program_name,
    p.active AS program_active_status,
    p.shownonfullsupplytab AS shown_on_full_supply_tab,
    p.skipauthorization    AS skip_authorization
FROM public.kafka_programs p;


-- 2.3 Dimension Produit (Orderable)
CREATE MATERIALIZED VIEW analytics.dim_product AS
WITH latest_orderables AS (
    SELECT DISTINCT ON (o.id)
        o.id,
        o.code,
        o.fullproductname,
        o.description,
        o.versionnumber,
        o.lastupdated,
        o.roundtozero,
        o.dispensableid
    FROM public.kafka_orderables o
    ORDER BY o.id, o.versionnumber DESC
),
trade_items AS (
    SELECT DISTINCT ON (oi.orderableid)
        oi.orderableid,
        oi.value AS trade_item_id
    FROM public.kafka_orderable_identifiers oi
    WHERE oi.key::text = 'tradeItem'
    ORDER BY oi.orderableid
)
SELECT
    o.id              AS orderable_id,
    o.code            AS product_code,
    o.fullproductname AS product_name,
    o.description     AS product_description,
    o.versionnumber   AS product_version,
    o.lastupdated     AS product_last_updated,
    o.roundtozero     AS round_to_zero,
    o.dispensableid   AS dispensable_id,
    ti.trade_item_id  AS trade_item_id
FROM latest_orderables o
LEFT JOIN trade_items ti ON ti.orderableid = o.id
WITH DATA;

CREATE UNIQUE INDEX IF NOT EXISTS ux_dim_product_orderable_id
ON analytics.dim_product (orderable_id);

CREATE INDEX IF NOT EXISTS ix_dim_product_product_code
ON analytics.dim_product (product_code);


-- 2.4 Dimension Processing Schedule
CREATE OR REPLACE VIEW analytics.dim_processing_schedule AS
SELECT
    ps.id           AS processing_schedule_id,
    ps.code         AS processing_schedule_code,
    ps.name         AS processing_schedule_name,
    ps.modifieddate AS schedule_modified_date
FROM public.kafka_processing_schedules ps;


-- 2.5 Dimension Processing Period
CREATE OR REPLACE VIEW analytics.dim_processing_period AS
SELECT
    pp.id                   AS processing_period_id,
    pp.name                 AS processing_period_name,
    pp.processingscheduleid AS processing_schedule_id,
    ps.code                 AS processing_schedule_code,
    ps.name                 AS processing_schedule_name,
    pp.startdate            AS processing_period_startdate,
    pp.enddate              AS processing_period_enddate,
    EXTRACT(YEAR  FROM pp.startdate)::int AS period_year,
    EXTRACT(MONTH FROM pp.startdate)::int AS period_month,
    to_char(pp.startdate, 'YYYY-MM')      AS period_yyyy_mm
FROM public.kafka_processing_periods pp
LEFT JOIN public.kafka_processing_schedules ps ON ps.id = pp.processingscheduleid;


-- 2.6 Dimension Utilisateur
CREATE OR REPLACE VIEW analytics.dim_user AS
SELECT
    u.id             AS user_id,
    u.username       AS username,
    u.firstname      AS first_name,
    u.lastname       AS last_name,
    u.email          AS email,
    u.jobtitle       AS job_title,
    u.phonenumber    AS phone_number,
    u.timezone       AS timezone,
    u.homefacilityid AS home_facility_id,
    u.verified       AS verified,
    u.active         AS active
FROM public.kafka_users u;

-- =========================================
-- 3) FAITS (VIEWS) - Power BI Import + Incremental friendly
-- =========================================
-- Regle : on garde les IDs (keys), les dates (pour incremental) et les mesures.

-- 3.1 Fait principal : Stock status & consumption
-- Source : public.stock_status_and_consumption
CREATE OR REPLACE VIEW analytics.fact_stock_status_consumption AS
SELECT
    -- Keys
    ssc.requisition_line_item_id,
    ssc.id                       AS requisition_id,
    ssc.facility_id,
    ssc.program_id,
    ssc.orderable_id,
    ssc.processing_period_id,
    ssc.processing_schedule_id,
    ssc.supplying_facility       AS supplying_facility_id,
    ssc.supervisory_node         AS supervisory_node_id,
    -- Temps (critique pour Incremental Refresh Power BI)
    ssc.req_created_date,
    ssc.processing_period_startdate,
    ssc.processing_period_enddate,
    ssc.modified_date            AS etl_updated_at,
    -- Mesures
    ssc.beginning_balance,
    ssc.stock_on_hand,
    ssc.consumption,
    ssc.adjusted_consumption,
    ssc.average_consumption,
    ssc.amc,
    ssc.closing_balance,
    ssc.total_received_quantity,
    ssc.total_consumed_quantity,
    ssc.total_losses_and_adjustments,
    ssc.total_stockout_days,
    ssc.max_periods_of_stock,
    ssc.calculated_order_quantity,
    ssc.requested_quantity,
    ssc.approved_quantity,
    ssc.order_quantity,
    ssc.packs_to_ship,
    ssc.price_per_pack,
    ssc.total_cost,
    ssc.combined_stockout,
    ssc.due_days,
    ssc.late_days,
    -- Flags / faibles cardinalites
    ssc.req_status,
    ssc.stock_status,
    ssc.emergency_status,
    ssc.facility_status,
    ssc.facilty_active_status,
    ssc.program_active_status
FROM public.stock_status_and_consumption ssc;

-- 3.2 Fait : Adjustments
-- Source reelle : public.adjustments join requisition pour recuperer facility/program/period IDs
CREATE OR REPLACE VIEW analytics.fact_adjustments AS
SELECT
    -- Keys
    a.adjustment_lines_id,
    a.requisition_line_item_id,
    a.requisition_id,
    r.facilityid         AS facility_id,
    r.programid          AS program_id,
    r.processingperiodid AS processing_period_id,
    r.supervisorynodeid  AS supervisory_node_id,
    r.supplyingfacilityid AS supplying_facility_id,
    a.orderable_id,
    -- Temps
    a.created_date,
    a.modified_date      AS etl_updated_at,
    a.status_history_created_date,
    -- Mesures
    a.quantity,
    a.total_losses_and_adjustments,
    -- Flags / attributs utiles
    a.status,
    a.stock_adjustment_reason,
    -- RLS / tracabilite
    a.author_id
    -- ,a.username
FROM public.adjustments a
LEFT JOIN public.kafka_requisitions r ON r.id = a.requisition_id;


-- 3.3 Fait : Reporting rate & timeliness
-- Source reelle : public.reporting_rate_and_timeliness
CREATE OR REPLACE VIEW analytics.fact_reporting_rate_timeliness AS
SELECT
    -- Cle composite (pseudo PK cote BI)
    (
      rrt.facility_id::text || '|' ||
      rrt.program_id::text  || '|' ||
      rrt.processing_period_id::text || '|' ||
      rrt.req_id::text || '|' ||
      COALESCE(rrt.status_change_date::text,'')
    ) AS reporting_key,
    -- Keys
    rrt.req_id,
    rrt.facility_id,
    rrt.program_id,
    rrt.processing_period_id,
    rrt.supervisory_node_id,
    -- Temps (incremental Power BI)
    rrt.processing_period_startdate,
    rrt.processing_period_enddate,
    rrt.status_change_date,
    rrt.created_date,
    rrt.modified_date       AS etl_updated_at,
    -- Mesure / classification
    rrt.reporting_timeliness,
    -- Flags
    rrt.emergency_status,
    rrt.facility_active_status,
    rrt.program_active_status,
    rrt.supported_program_active
FROM public.reporting_rate_and_timeliness rrt;


-- 3.4 Fait : Stock adjustments (mouvements stock)
-- Source reelle : public.stock_adjustments_view
CREATE OR REPLACE VIEW analytics.fact_stock_adjustments AS
SELECT
    -- Keys
    s.id            AS stock_adjustment_id,
    s.facility_id,
    s.program_id,
    dp.orderable_id,
    s.product_code,
    -- Temps
    s.occurreddate   AS occurred_date,
    s.occurreddate::timestamp AS etl_updated_at,
    -- Mesure
    s.quantity,
    -- Attributs
    s.reason_name,
    s.reasoncategory
FROM public.stock_adjustments_view s
LEFT JOIN analytics.dim_product dp
       ON dp.product_code = s.product_code;


-- 3.5 Bridge : acces utilisateur (RLS helper)
-- Source reelle : public.view_facility_access
CREATE OR REPLACE VIEW analytics.bridge_user_facility_access AS
SELECT
    v.username,
    v.facilityid        AS facility_id,
    v.programid         AS program_id,
    v.supervisory_node_id,
    v.rightname
FROM public.view_facility_access v;