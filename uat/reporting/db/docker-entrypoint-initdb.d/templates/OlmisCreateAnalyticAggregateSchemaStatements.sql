-- ==============================================================================
-- 0. PRÉPARATION DU SCHÉMA
-- ==============================================================================
CREATE SCHEMA IF NOT EXISTS analytics;

-- ==============================================================================
-- 1. CRÉATION DES TABLES PHYSIQUES (FACT TABLE DU DATA WAREHOUSE)
-- ==============================================================================

DROP TABLE IF EXISTS analytics.stock_daily_history CASCADE;
DROP TABLE IF EXISTS analytics.audit_daily_batch CASCADE;
DROP FUNCTION IF EXISTS analytics.refresh_daily_stock_history CASCADE;

CREATE TABLE analytics.stock_daily_history (
    movement_date DATE NOT NULL,
    facility_id UUID NOT NULL,
    program_id UUID NOT NULL,
    product_id UUID NOT NULL,
    
    -- Mesures du modèle en étoile
    opening_balance NUMERIC(15,2) DEFAULT 0,
    receipts NUMERIC(15,2) DEFAULT 0,
    consumptions NUMERIC(15,2) DEFAULT 0,
    losses NUMERIC(15,2) DEFAULT 0,
    net_transfers NUMERIC(15,2) DEFAULT 0,
    net_adjustments NUMERIC(15,2) DEFAULT 0,
    net_variation NUMERIC(15,2) DEFAULT 0,
    stock_on_hand NUMERIC(15,2) DEFAULT 0,  -- Solde final J (Clôture)
    stockout_days INTEGER DEFAULT 0,           -- 1 si rupture le jour J, sinon 0
    
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT uk_fact_stock_daily UNIQUE (movement_date, facility_id, program_id, product_id)
);

-- Indexation optimisée pour Power BI (Filtrage temporel)
CREATE INDEX IF NOT EXISTS idx_fact_stock_main ON analytics.stock_daily_history(movement_date, facility_id, product_id);

-- Indexation optimisée pour l'Extraction du Solde Précédent (Performance du Modèle Dense)
CREATE INDEX IF NOT EXISTS idx_fact_stock_balance ON analytics.stock_daily_history(facility_id, program_id, product_id, movement_date DESC);


-- Table d'Audit pour la surveillance du Batch
CREATE TABLE IF NOT EXISTS analytics.audit_daily_batch (
    id SERIAL PRIMARY KEY,
    execution_start TIMESTAMP NOT NULL,
    execution_end TIMESTAMP,
    target_date DATE NOT NULL,
    status VARCHAR(50) NOT NULL,
    rows_processed INT DEFAULT 0,
    error_message TEXT
);

-- ==============================================================================
-- 2. PROCÉDURE STOCKÉE DE CHARGEMENT OPTIMISÉE
-- ==============================================================================

CREATE OR REPLACE FUNCTION analytics.refresh_daily_stock_history(p_target_date DATE DEFAULT CURRENT_DATE - 1)
RETURNS integer 
LANGUAGE plpgsql AS $$
DECLARE
    v_audit_id INT;
    v_rows_inserted INT := 0;
    v_error_text TEXT;
BEGIN
    INSERT INTO analytics.audit_daily_batch(execution_start, target_date, status) 
    VALUES (clock_timestamp(), p_target_date, 'RUNNING') RETURNING id INTO v_audit_id;

    -- ÉTAPE 1 : Définir le périmètre cible (tous les produits gérés par tous les établissements)
    WITH base_perimeter AS (
        SELECT DISTINCT 
            facilityid AS facility_id,
            programid AS program_id,
            orderableid AS product_id
        FROM kafka_stock_cards
    ),
    -- ÉTAPE 2 : Agréger les mouvements réels de la journée cible
    daily_movements AS (
        SELECT 
            sc.facilityid AS facility_id,
            sc.programid AS program_id,
            sc.orderableid AS product_id,
            
            -- 1. Variation nette absolue du jour
            SUM(CASE WHEN r.reasontype = 'CREDIT' THEN li.quantity WHEN r.reasontype = 'DEBIT' THEN -li.quantity ELSE 0 END) AS variation_nette,
            -- 2. Réceptions
            SUM(CASE WHEN r.name IN ('Receipts') THEN li.quantity ELSE 0 END) AS receptions,
            -- 3. Consommations
            SUM(CASE WHEN r.name IN ('Consumed', 'Consommation') THEN li.quantity ELSE 0 END) AS consommations,
            -- 4. Pertes 
            SUM(CASE WHEN r.reasontype = 'DEBIT' AND r.reasoncategory = 'ADJUSTMENT' AND r.name IN ('Peremption', 'Avarie', 'Vol ou Disparition') THEN li.quantity ELSE 0 END) AS pertes,
            -- 5. Transferts Net 
            SUM(CASE WHEN r.name IN ('Transfer In', 'Transfert Entrant', 'Retour de Service', 'Transfert Sortant', 'Retour au Fournisseur', 'Donation Sortante', 'Donation Recue') THEN (CASE WHEN r.reasontype = 'CREDIT' THEN li.quantity ELSE -li.quantity END) ELSE 0 END) AS transferts_net,
            -- 6. Ajustements Net 
            SUM(CASE WHEN r.name NOT IN ('Correction (+)', 'Correction (-)', 'Ajustement Inventaire (+)', 'Ajustement Inventaire (-)', 'Beginning Balance Excess', 'Beginning Balance Insufficiency', 'Unpacked From Kit', 'Unpack Kit') THEN (CASE WHEN r.reasontype = 'CREDIT' THEN li.quantity ELSE -li.quantity END) ELSE 0 END) AS ajustements_net
            
        FROM kafka_stock_card_line_items li
        JOIN kafka_stock_card_line_item_reasons r ON li.reasonid = r.id
        JOIN kafka_stock_cards sc ON li.stockcardid = sc.id
        WHERE li.occurreddate >= p_target_date AND li.occurreddate < p_target_date + INTERVAL '1 day'
        GROUP BY sc.facilityid, sc.programid, sc.orderableid
    ),
    -- ÉTAPE 3 : Trouver le dernier solde connu (pas uniquement la veille, mais le dernier enregistrement existant)
    last_known_balances AS (
        SELECT DISTINCT ON (facility_id, program_id, product_id) 
            facility_id, program_id, product_id,
            stock_on_hand AS previous_balance
        FROM analytics.stock_daily_history
        WHERE movement_date < p_target_date
        ORDER BY facility_id, program_id, product_id, movement_date DESC
    )

    -- INSERTION / MISE A JOUR : Combiner tout (Périmètre + Soldes passés + Mouvements du jour)
    INSERT INTO analytics.stock_daily_history (
        movement_date, facility_id, program_id, product_id,
        opening_balance, receipts, consumptions, losses, net_transfers, 
        net_adjustments, net_variation, stock_on_hand, stockout_days
    )
    SELECT 
        p_target_date AS movement_date, 
        bp.facility_id, 
        bp.program_id, 
        bp.product_id,
        
        -- Récupération du solde d'ouverture (0 si c'est la toute première fois)
        COALESCE(lkb.previous_balance, 0) AS opening_balance,
        
        -- Flux de la journée (0 s'il n'y a pas eu de mouvement)
        COALESCE(dm.receptions, 0) AS receipts, 
        COALESCE(dm.consommations, 0) AS consumptions, 
        COALESCE(dm.pertes, 0) AS losses, 
        COALESCE(dm.transferts_net, 0) AS net_transfers,
        COALESCE(dm.ajustements_net, 0) AS net_adjustments, 
        COALESCE(dm.variation_nette, 0) AS net_variation,
        
        -- Solde Final = Ouverture + Variation Mouvements
        (COALESCE(lkb.previous_balance, 0) + COALESCE(dm.variation_nette, 0)) AS stock_on_hand,
        
        -- Indicateur de ruptures (1 s'il est à 0 ou négatif)
        (CASE WHEN (COALESCE(lkb.previous_balance, 0) + COALESCE(dm.variation_nette, 0)) <= 0 THEN 1 ELSE 0 END) AS stockout_days
        
    FROM base_perimeter bp
    -- LEFT JOIN très importants : on force la création de la ligne même sans mouvements/historique
    LEFT JOIN daily_movements dm 
        ON bp.facility_id = dm.facility_id 
        AND bp.program_id = dm.program_id 
        AND bp.product_id = dm.product_id
    LEFT JOIN last_known_balances lkb 
        ON bp.facility_id = lkb.facility_id 
        AND bp.program_id = lkb.program_id 
        AND bp.product_id = lkb.product_id
        
    ON CONFLICT (movement_date, facility_id, program_id, product_id) DO UPDATE SET 
        opening_balance = EXCLUDED.opening_balance,
        receipts = EXCLUDED.receipts,
        consumptions = EXCLUDED.consumptions,
        losses = EXCLUDED.losses,
        net_transfers = EXCLUDED.net_transfers,
        net_adjustments = EXCLUDED.net_adjustments,
        net_variation = EXCLUDED.net_variation,
        stock_on_hand = EXCLUDED.stock_on_hand,
        stockout_days = EXCLUDED.stockout_days,
        updated_at = CURRENT_TIMESTAMP;

    GET DIAGNOSTICS v_rows_inserted = ROW_COUNT;
    UPDATE analytics.audit_daily_batch SET execution_end = clock_timestamp(), status = 'SUCCESS', rows_processed = v_rows_inserted WHERE id = v_audit_id;
    RETURN v_rows_inserted;

EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_error_text = MESSAGE_TEXT;
    UPDATE analytics.audit_daily_batch SET execution_end = clock_timestamp(), status = 'ERROR', error_message = v_error_text WHERE id = v_audit_id;
    RAISE WARNING 'Erreur sur analytics : %', v_error_text;
    RETURN 0;
END;
$$;


-- ==============================================================================
-- VUES OPTIMISÉES POUR POWER BI (LOGISTIQUE DE SANTÉ / OPENLMIS)
-- ==============================================================================

DROP VIEW IF EXISTS analytics.fact_expired_risk_snapshot;
DROP VIEW IF EXISTS analytics.fact_stock_monthly;
DROP VIEW IF EXISTS analytics.fact_stock_daily;
DROP VIEW IF EXISTS analytics.dim_date;

-- 0. TABLE DE DIMENSION TEMPORELLE (CALENDRIER CENTRAL)
-- Génère automatiquement tous les jours de 2024 à 2027
CREATE OR REPLACE VIEW analytics.dim_date AS
SELECT 
    d::date AS date_id,
    EXTRACT(YEAR FROM d)::INT AS reporting_year,
    EXTRACT(MONTH FROM d)::INT AS reporting_month,
    EXTRACT(DAY FROM d)::INT AS reporting_day,
    CASE EXTRACT(MONTH FROM d)
        WHEN 1 THEN 'Janvier'
        WHEN 2 THEN 'Février'
        WHEN 3 THEN 'Mars'
        WHEN 4 THEN 'Avril'
        WHEN 5 THEN 'Mai'
        WHEN 6 THEN 'Juin'
        WHEN 7 THEN 'Juillet'
        WHEN 8 THEN 'Août'
        WHEN 9 THEN 'Septembre'
        WHEN 10 THEN 'Octobre'
        WHEN 11 THEN 'Novembre'
        WHEN 12 THEN 'Décembre'
    END AS reporting_month_name,
    EXTRACT(QUARTER FROM d)::INT AS reporting_quarter,
    'T' || EXTRACT(QUARTER FROM d)::TEXT AS reporting_quarter_name,
    TO_CHAR(d, 'YYYY-MM') AS year_month
FROM generate_series(
    '2024-01-01'::date, 
    (CURRENT_DATE + INTERVAL '2 years')::date, 
    '1 day'::interval
) d;
-- Réduit l'historique à 2 ans pour préserver les performances de Power BI
CREATE OR REPLACE VIEW analytics.fact_stock_daily AS
SELECT 
    movement_date,
    facility_id,
    program_id,
    product_id,
    opening_balance,
    receipts,
    consumptions,
    losses,
    net_transfers,
    net_adjustments,
    net_variation,
    stock_on_hand,
    stockout_days
FROM analytics.stock_daily_history
WHERE movement_date >= (CURRENT_DATE - INTERVAL '2 years');

-- 2. VUE MENSUELLE (AGRÉGATION STANDARD SUPPLY CHAIN)
-- Agrège le modèle dense par mois et pré-calcule les métriques logistiques clés
CREATE OR REPLACE VIEW analytics.fact_stock_monthly AS
WITH monthly_aggregated AS (
    SELECT 
        date_trunc('month', movement_date)::date AS month_date,
        facility_id,
        program_id,
        product_id,
        SUM(receipts) AS receipts,
        SUM(consumptions) AS consumptions,
        SUM(losses) AS losses,
        SUM(net_transfers) AS net_transfers,
        SUM(net_adjustments) AS net_adjustments,
        ROUND(AVG(stock_on_hand), 2) AS average_stock,
        SUM(stockout_days) AS stockout_days,
        COUNT(movement_date) AS active_days -- Nombre exact de jours analysés dans le mois
    FROM analytics.stock_daily_history
    WHERE movement_date >= (CURRENT_DATE - INTERVAL '2 years')
    GROUP BY 
        date_trunc('month', movement_date)::date,
        facility_id,
        program_id,
        product_id
),
monthly_closing AS (
    -- Logistique : Il est crucial d'avoir le vrai "Stock de Clôture" (SOH) du mois
    -- On isole ici la dernière valeur connue du mois pour chaque produit
    SELECT DISTINCT ON (date_trunc('month', movement_date)::date, facility_id, program_id, product_id)
        date_trunc('month', movement_date)::date AS month_date,
        facility_id,
        program_id,
        product_id,
        stock_on_hand AS closing_balance
    FROM analytics.stock_daily_history
    WHERE movement_date >= (CURRENT_DATE - INTERVAL '2 years')
    ORDER BY date_trunc('month', movement_date)::date, facility_id, program_id, product_id, movement_date DESC
),
monthly_opening AS (
    -- Logistique : Récupérer le "Stock Initial" du premier jour du mois
    SELECT DISTINCT ON (date_trunc('month', movement_date)::date, facility_id, program_id, product_id)
        date_trunc('month', movement_date)::date AS month_date,
        facility_id,
        program_id,
        product_id,
        opening_balance
    FROM analytics.stock_daily_history
    WHERE movement_date >= (CURRENT_DATE - INTERVAL '2 years')
    ORDER BY date_trunc('month', movement_date)::date, facility_id, program_id, product_id, movement_date ASC
),
monthly_base AS (
    SELECT 
        a.month_date,
        a.facility_id,
        a.program_id,
        a.product_id,
        a.receipts,
        a.consumptions,
        a.losses,
        a.net_transfers,
        a.net_adjustments,
        
        -- MÉTRIQUES LOGISTIQUES CLÉS (Standards OpenLMIS / USAID) :
        o.opening_balance,              -- Stock au 1er du mois
        a.average_stock,                  
        c.closing_balance,              -- Stock on Hand (SOH) à la fin du mois
        a.stockout_days,          -- Jours sans stock utilisable
        a.active_days,                  -- Période de couverture réelle du produit
        
        -- Pré-calcul de la Consommation Ajustée (si le produit a connu des ruptures)
        CASE 
            WHEN a.active_days > a.stockout_days AND a.active_days > 0 THEN 
                ROUND((a.consumptions / (a.active_days - a.stockout_days)) * a.active_days, 2)
            ELSE 0 
        END AS adjusted_consumption
        
    FROM monthly_aggregated a
    JOIN monthly_closing c 
        ON a.month_date = c.month_date 
        AND a.facility_id = c.facility_id 
        AND a.program_id = c.program_id 
        AND a.product_id = c.product_id
    JOIN monthly_opening o
        ON a.month_date = o.month_date 
        AND a.facility_id = o.facility_id 
        AND a.program_id = o.program_id 
        AND a.product_id = o.product_id
)
SELECT 
    *,
    
    -- AMC (Consommation Moyenne Mensuelle sur les 3 derniers mois STRICTEMENT précédents)
    ROUND(AVG(adjusted_consumption) OVER (
        PARTITION BY facility_id, program_id, product_id 
        ORDER BY month_date 
        ROWS BETWEEN 3 PRECEDING AND 1 PRECEDING
    ), 2) AS amc_3m,
    
    -- MSD (Mois de Stock Disponible) basé sur le stock de clôture et l'AMC
    -- Si l'AMC est 0, on gère la division par zéro
    CASE 
        WHEN AVG(adjusted_consumption) OVER (
            PARTITION BY facility_id, program_id, product_id 
            ORDER BY month_date 
            ROWS BETWEEN 3 PRECEDING AND 1 PRECEDING
        ) > 0 THEN 
            ROUND(closing_balance / AVG(adjusted_consumption) OVER (
                PARTITION BY facility_id, program_id, product_id 
                ORDER BY month_date 
                ROWS BETWEEN 3 PRECEDING AND 1 PRECEDING
            ), 2)
        WHEN closing_balance > 0 THEN NULL -- Stock dormant (Stock disponible, mais aucune consommation)
        ELSE 0 
    END AS msd_3m,
    month_date AS movement_date
FROM monthly_base;

-- 3. VUE DES RISQUES DE PÉREMPTION (LOTS & LIFETIME)
-- Identifie les lots avec une durée de vie résiduelle critique (<= 9 mois)
CREATE OR REPLACE VIEW analytics.fact_expired_risk_snapshot AS
WITH current_lot_balance AS (
    SELECT 
        sc.facilityid AS facility_id,
        sc.programid AS program_id,
        sc.orderableid AS product_id,
        sc.lotid AS lot_id,
        SUM(li.quantity) AS stock_on_hand
    FROM kafka_stock_card_line_items li
    JOIN kafka_stock_cards sc ON li.stockcardid = sc.id
    GROUP BY sc.facilityid, sc.programid, sc.orderableid, sc.lotid
    HAVING SUM(li.quantity) > 0
)
SELECT 
    sb.facility_id,
    sb.program_id,
    sb.product_id,
    sb.lot_id,
    l.lotcode AS lot_code,
    l.expirationdate AS expiration_date,
    sb.stock_on_hand,
    (l.expirationdate - CURRENT_DATE) AS lifetime_days,
    CASE
        WHEN (l.expirationdate - CURRENT_DATE) < 0 THEN 'Périmé'
        WHEN (l.expirationdate - CURRENT_DATE) <= 90 THEN 'Moins de 3 mois'
        WHEN (l.expirationdate - CURRENT_DATE) <= 180 THEN '3 à 6 mois'
        WHEN (l.expirationdate - CURRENT_DATE) <= 270 THEN '6 à 9 mois'
        ELSE 'Sain (Plus de 9 mois)'
    END AS expiration_category
FROM current_lot_balance sb
JOIN kafka_lots l ON sb.lot_id = l.id
WHERE (l.expirationdate - CURRENT_DATE) <= 270;

-- View: public.vw_stock_adjustments

-- DROP VIEW public.vw_stock_adjustments;

CREATE OR REPLACE VIEW public.vw_stock_adjustments
 AS
 SELECT li.id AS line_item_id,
    df.facility_name AS structure,
    dp.product_code AS code_produit,
    dp.product_name AS nom_produit,
    kl.lotcode AS numero_lot,
    dp.product_description AS unite_de_dispensation,
        CASE
            WHEN r.reasontype = 'CREDIT'::text THEN li.quantity
            ELSE - li.quantity
        END AS quantite_ajustee,
    r.name AS raison_ajustement,
    TRIM(BOTH FROM (COALESCE(du.first_name, ''::text) || ' '::text) || COALESCE(du.last_name, ''::text)) AS utilisateur_ayant_ajuste,
    du.username AS login_utilisateur,
        CASE
            WHEN r.reasontype = 'CREDIT'::text THEN 'Positif'::text
            ELSE 'Négatif'::text
        END AS sens_ajustement,
    r.reasontype,
    li.quantity AS quantite_absolue,
    li.occurreddate AS date_ajustement,
    dpr.program_name AS programme,
    df.geographic_level AS niveau_organisationnel,
    df.geographic_zone_name AS zone_geographique,
    df.district_name AS district,
    df.region_name AS region,
    df.facility_type_name AS type_de_structure,
    EXTRACT(year FROM li.occurreddate)::integer AS annee,
    EXTRACT(month FROM li.occurreddate)::integer AS mois,
    to_char(li.occurreddate::timestamp with time zone, 'YYYY-MM'::text) AS annee_mois
   FROM kafka_stock_card_line_items li
     JOIN kafka_stock_card_line_item_reasons r ON r.id = li.reasonid
     JOIN kafka_stock_cards sc ON sc.id = li.stockcardid
     LEFT JOIN analytics.dim_product dp ON dp.orderable_id = sc.orderableid
     LEFT JOIN kafka_lots kl ON kl.id = sc.lotid
     LEFT JOIN analytics.dim_facility df ON df.facility_id = sc.facilityid
     LEFT JOIN analytics.dim_program dpr ON dpr.program_id = sc.programid
     LEFT JOIN analytics.dim_user du ON du.user_id = li.userid
  WHERE r.reasoncategory = 'ADJUSTMENT'::text AND (r.name <> ALL (ARRAY['Consommation'::text, 'Consumed'::text, 'Receipts'::text, 'Beginning Balance Excess'::text, 'Beginning Balance Insufficiency'::text]));

ALTER TABLE public.vw_stock_adjustments
    OWNER TO postgres;



-- View: public.vw_expiry_risk

-- DROP VIEW public.vw_expiry_risk;

CREATE OR REPLACE VIEW public.vw_expiry_risk
 AS
 WITH price AS (
         SELECT DISTINCT ON (po.orderableid) po.orderableid,
            po.priceperpack
           FROM kafka_program_orderables po
          ORDER BY po.orderableid, po.active DESC, po.orderableversionnumber DESC
        ), packsize AS (
         SELECT DISTINCT ON (o.id) o.id AS orderableid,
            o.netcontent
           FROM kafka_orderables o
          ORDER BY o.id, o.versionnumber DESC
        )
 SELECT fe.facility_id,
    fe.product_id,
    fe.lot_id,
    df.facility_name AS structure,
    dp.product_code AS code_produit,
    dp.product_name AS nom_produit,
    fe.lot_code AS numero_lot,
    fe.expiration_date AS date_expiration,
    dp.product_description AS unite_du_produit,
    fe.stock_on_hand,
    fe.lifetime_days AS jours_avant_expiration,
    fe.expiration_category AS categorie_expiration,
        CASE
            WHEN fe.lifetime_days < 0 THEN fe.stock_on_hand
            ELSE 0::bigint
        END AS qte_deja_expiree,
        CASE
            WHEN fe.lifetime_days >= 0 AND fe.lifetime_days <= 30 THEN fe.stock_on_hand
            ELSE 0::bigint
        END AS qte_expirant_30j,
        CASE
            WHEN fe.lifetime_days >= 0 AND fe.lifetime_days <= 60 THEN fe.stock_on_hand
            ELSE 0::bigint
        END AS qte_expirant_60j,
        CASE
            WHEN fe.lifetime_days >= 0 AND fe.lifetime_days <= 90 THEN fe.stock_on_hand
            ELSE 0::bigint
        END AS qte_expirant_90j,
    round(
        CASE
            WHEN fe.lifetime_days >= 0 AND fe.lifetime_days <= 30 THEN fe.stock_on_hand
            ELSE 0::bigint
        END::numeric * pr.priceperpack / NULLIF(ps.netcontent, 0)::numeric, 2) AS valeur_usd_30j,
    pr.priceperpack,
    ps.netcontent,
    dpr.program_name AS programme,
    df.geographic_level AS niveau_organisationnel,
    df.geographic_zone_name AS zone_geographique,
    df.district_name AS district,
    df.region_name AS region,
    df.facility_type_name AS type_de_structure,
    EXTRACT(year FROM fe.expiration_date)::integer AS annee,
    EXTRACT(month FROM fe.expiration_date)::integer AS mois,
    to_char(fe.expiration_date::timestamp with time zone, 'YYYY-MM'::text) AS annee_mois
   FROM analytics.fact_expired_risk_snapshot fe
     LEFT JOIN analytics.dim_product dp ON dp.orderable_id = fe.product_id
     LEFT JOIN analytics.dim_facility df ON df.facility_id = fe.facility_id
     LEFT JOIN analytics.dim_program dpr ON dpr.program_id = fe.program_id
     LEFT JOIN price pr ON pr.orderableid = fe.product_id
     LEFT JOIN packsize ps ON ps.orderableid = fe.product_id
  WHERE fe.lifetime_days <= 90;

ALTER TABLE public.vw_expiry_risk
    OWNER TO postgres;



-- View: public.vw_order_flow_product

-- DROP VIEW public.vw_order_flow_product;

CREATE OR REPLACE VIEW public.vw_order_flow_product
 AS
 WITH rli AS (
         SELECT kafka_requisition_line_items.requisitionid,
            kafka_requisition_line_items.orderableid,
            sum(kafka_requisition_line_items.requestedquantity) AS qte_demandee,
            sum(kafka_requisition_line_items.approvedquantity) AS qte_approuvee
           FROM kafka_requisition_line_items
          GROUP BY kafka_requisition_line_items.requisitionid, kafka_requisition_line_items.orderableid
        ), pod_prod AS (
         SELECT s.orderid,
            pol.orderableid,
            sum(pol.quantityaccepted) AS qte_acceptee,
            sum(pol.quantityrejected) AS qte_rejetee,
            count(DISTINCT pol.lotid) AS nb_lots
           FROM kafka_proof_of_delivery_line_items pol
             JOIN kafka_proofs_of_delivery pod ON pod.id = pol.proofofdeliveryid
             JOIN kafka_shipments s ON s.id = pod.shipmentid
          GROUP BY s.orderid, pol.orderableid
        ), ord AS (
         SELECT o.id AS order_id,
            o.externalid AS ext,
            o.ordercode,
            o.status AS order_status,
            o.facilityid,
            o.programid,
            o.processingperiodid,
            o.emergency,
            min(o.createddate::timestamp with time zone) AS date_commande,
            min(s.shippeddate::timestamp with time zone) AS date_expedition,
            max(pod.receiveddate) AS date_reception
           FROM kafka_orders o
             LEFT JOIN kafka_shipments s ON s.orderid = o.id
             LEFT JOIN kafka_proofs_of_delivery pod ON pod.shipmentid = s.id
          GROUP BY o.id, o.externalid, o.ordercode, o.status, o.facilityid, o.programid, o.processingperiodid, o.emergency
        )
 SELECT ord.ext::uuid AS requisition_id,
    ord.order_id,
    ord.ordercode AS numero_commande,
    dpp.processing_period_name AS periode,
    ord.order_status,
        CASE ord.order_status
            WHEN 'ORDERED'::text THEN 'Commandée'::text
            WHEN 'FULFILLING'::text THEN 'En préparation'::text
            WHEN 'SHIPPED'::text THEN 'Expédiée'::text
            WHEN 'RECEIVED'::text THEN 'Reçue'::text
            WHEN 'TRANSFER_FAILED'::text THEN 'Échec de transfert'::text
            ELSE ord.order_status
        END AS statut_commande,
    oli.orderableid::uuid AS orderable_id,
    dp.product_code AS code_produit,
    dp.product_name AS nom_du_produit,
    dp.product_description AS unite_du_produit,
    rli.qte_demandee,
    rli.qte_approuvee,
    oli.orderedquantity AS qte_commandee,
    COALESCE(pp.qte_acceptee, 0::bigint) + COALESCE(pp.qte_rejetee, 0::bigint) AS qte_livree,
    pp.qte_acceptee,
    pp.qte_rejetee,
    pp.nb_lots,
        CASE
            WHEN oli.orderedquantity > 0 THEN LEAST(round(100.0 * (COALESCE(pp.qte_acceptee, 0::bigint) + COALESCE(pp.qte_rejetee, 0::bigint))::numeric / oli.orderedquantity::numeric, 1), 100.0)
            ELSE NULL::numeric
        END AS taux_satisfaction_pct,
        CASE
            WHEN oli.orderedquantity > 0 THEN LEAST(round(100.0 * COALESCE(pp.qte_acceptee, 0::bigint)::numeric / oli.orderedquantity::numeric, 1), 100.0)
            ELSE NULL::numeric
        END AS taux_reception_pct,
        CASE
            WHEN (COALESCE(pp.qte_acceptee, 0::bigint) + COALESCE(pp.qte_rejetee, 0::bigint)) > 0 THEN round(100.0 * COALESCE(pp.qte_rejetee, 0::bigint)::numeric / (COALESCE(pp.qte_acceptee, 0::bigint) + COALESCE(pp.qte_rejetee, 0::bigint))::numeric, 1)
            ELSE NULL::numeric
        END AS taux_rejet_pct,
    COALESCE(pp.qte_acceptee, 0::bigint) > oli.orderedquantity AS incoherence_qte,
    ord.date_commande,
    ord.date_expedition,
    ord.date_reception,
    df.geographic_level AS niveau_organisationnel,
    df.geographic_zone_name AS zone_geographique,
    df.facility_type_name AS type_de_structure,
    df.facility_name AS structure,
    dpr.program_name AS programme,
    dpp.period_year AS annee,
    dpp.period_month AS mois,
    ord.emergency AS urgence
   FROM kafka_order_line_items oli
     JOIN ord ON ord.order_id = oli.orderid
     LEFT JOIN rli ON rli.requisitionid = ord.ext::uuid AND rli.orderableid = oli.orderableid::uuid
     LEFT JOIN pod_prod pp ON pp.orderid = oli.orderid AND pp.orderableid = oli.orderableid
     LEFT JOIN analytics.dim_product dp ON dp.orderable_id = oli.orderableid::uuid
     LEFT JOIN analytics.dim_facility df ON df.facility_id = ord.facilityid::uuid
     LEFT JOIN analytics.dim_program dpr ON dpr.program_id = ord.programid::uuid
     LEFT JOIN analytics.dim_processing_period dpp ON dpp.processing_period_id = ord.processingperiodid::uuid;

ALTER TABLE public.vw_order_flow_product
    OWNER TO postgres;



-- View: public.vw_requisition_order_flow

-- DROP VIEW public.vw_requisition_order_flow;

CREATE OR REPLACE VIEW public.vw_requisition_order_flow
 AS
 WITH req_dates AS (
         SELECT kafka_status_changes.requisitionid,
            min(kafka_status_changes.createddate::timestamp with time zone) FILTER (WHERE kafka_status_changes.status::text = 'INITIATED'::text) AS date_initiated,
            min(kafka_status_changes.createddate::timestamp with time zone) FILTER (WHERE kafka_status_changes.status::text = 'RELEASED'::text) AS date_released
           FROM kafka_status_changes
          GROUP BY kafka_status_changes.requisitionid
        ), req_qty AS (
         SELECT kafka_requisition_line_items.requisitionid,
            sum(kafka_requisition_line_items.requestedquantity) AS qte_demandee,
            sum(kafka_requisition_line_items.approvedquantity) AS qte_approuvee
           FROM kafka_requisition_line_items
          GROUP BY kafka_requisition_line_items.requisitionid
        ), ord_qty AS (
         SELECT kafka_order_line_items.orderid,
            sum(kafka_order_line_items.orderedquantity) AS qte_commandee
           FROM kafka_order_line_items
          GROUP BY kafka_order_line_items.orderid
        ), pod_qty AS (
         SELECT s.orderid,
            sum(pol.quantityaccepted) AS qte_acceptee,
            sum(pol.quantityrejected) AS qte_rejetee
           FROM kafka_proof_of_delivery_line_items pol
             JOIN kafka_proofs_of_delivery pod ON pod.id = pol.proofofdeliveryid
             JOIN kafka_shipments s ON s.id = pod.shipmentid
          GROUP BY s.orderid
        ), prod_units AS (
         SELECT oli.orderid,
            string_agg(DISTINCT dp.product_description::text, ', '::text ORDER BY (dp.product_description::text)) AS unites_produits,
            count(DISTINCT oli.orderableid) AS nb_articles
           FROM kafka_order_line_items oli
             JOIN analytics.dim_product dp ON dp.orderable_id = oli.orderableid::uuid
          GROUP BY oli.orderid
        ), order_info AS (
         SELECT o.id AS order_id,
            o.externalid AS ext,
            o.ordercode,
            o.status AS order_status,
            min(o.createddate::timestamp with time zone) AS date_commande,
            min(s.shippeddate::timestamp with time zone) AS date_expedition,
            max(pod.receiveddate) AS date_reception
           FROM kafka_orders o
             LEFT JOIN kafka_shipments s ON s.orderid = o.id
             LEFT JOIN kafka_proofs_of_delivery pod ON pod.shipmentid = s.id
          GROUP BY o.id, o.externalid, o.ordercode, o.status
        )
 SELECT r.id AS requisition_id,
    oi.order_id,
    oi.ordercode AS numero_commande,
    dpp.processing_period_name AS periode,
    pu.unites_produits,
    pu.nb_articles,
        CASE r.status
            WHEN 'INITIATED'::text THEN 'Initiée'::character varying
            WHEN 'SUBMITTED'::text THEN 'Soumise'::character varying
            WHEN 'AUTHORIZED'::text THEN 'Autorisée'::character varying
            WHEN 'IN_APPROVAL'::text THEN 'En cours d''approbation'::character varying
            WHEN 'APPROVED'::text THEN 'Approuvée'::character varying
            WHEN 'RELEASED'::text THEN 'Libérée (convertie en commande)'::character varying
            WHEN 'RELEASED_WITHOUT_ORDER'::text THEN 'Libérée sans commande'::character varying
            WHEN 'REJECTED'::text THEN 'Rejetée'::character varying
            WHEN 'SKIPPED'::text THEN 'Ignorée'::character varying
            ELSE r.status
        END AS statut_requisition,
    oi.order_status,
        CASE oi.order_status
            WHEN 'ORDERED'::text THEN 'Commandée'::text
            WHEN 'FULFILLING'::text THEN 'En préparation'::text
            WHEN 'SHIPPED'::text THEN 'Expédiée'::text
            WHEN 'RECEIVED'::text THEN 'Reçue'::text
            WHEN 'TRANSFER_FAILED'::text THEN 'Échec de transfert'::text
            ELSE oi.order_status
        END AS statut_commande,
        CASE
            WHEN oi.date_reception IS NOT NULL OR oi.order_status = 'RECEIVED'::text THEN '6. Reçue'::text
            WHEN oi.order_status = 'SHIPPED'::text THEN '5. Expédiée'::text
            WHEN oi.order_status = 'FULFILLING'::text THEN '4. En préparation'::text
            WHEN oi.order_status = 'ORDERED'::text THEN '3. Commandée'::text
            WHEN oi.order_status = 'TRANSFER_FAILED'::text THEN 'X. Échec de transfert'::text
            WHEN r.status::text = 'RELEASED'::text THEN '2. Libérée'::text
            ELSE '1. En cours (réquisition)'::text
        END AS etape_flux,
    rq.qte_demandee,
    rq.qte_approuvee,
    oq.qte_commandee,
    COALESCE(pq.qte_acceptee, 0::bigint) + COALESCE(pq.qte_rejetee, 0::bigint) AS qte_livree,
    pq.qte_acceptee,
    pq.qte_rejetee,
        CASE
            WHEN oq.qte_commandee > 0::numeric THEN LEAST(round(100.0 * (COALESCE(pq.qte_acceptee, 0::bigint) + COALESCE(pq.qte_rejetee, 0::bigint))::numeric / oq.qte_commandee, 1), 100.0)
            ELSE NULL::numeric
        END AS taux_satisfaction_pct,
        CASE
            WHEN oq.qte_commandee > 0::numeric THEN LEAST(round(100.0 * COALESCE(pq.qte_acceptee, 0::bigint)::numeric / oq.qte_commandee, 1), 100.0)
            ELSE NULL::numeric
        END AS taux_reception_pct,
        CASE
            WHEN (COALESCE(pq.qte_acceptee, 0::bigint) + COALESCE(pq.qte_rejetee, 0::bigint)) > 0 THEN round(100.0 * COALESCE(pq.qte_rejetee, 0::bigint)::numeric / (COALESCE(pq.qte_acceptee, 0::bigint) + COALESCE(pq.qte_rejetee, 0::bigint))::numeric, 1)
            ELSE NULL::numeric
        END AS taux_rejet_pct,
    COALESCE(pq.qte_acceptee, 0::bigint)::numeric > oq.qte_commandee AS incoherence_qte,
    rd.date_initiated,
    rd.date_released,
    oi.date_commande,
    oi.date_expedition,
    oi.date_reception,
    GREATEST(oi.date_reception - rd.date_initiated::date, 0) AS delai_total_demande_a_reception_j,
    GREATEST(oi.date_reception - oi.date_commande::date, 0) AS delai_commande_a_reception_j,
    df.geographic_level AS niveau_organisationnel,
    df.geographic_zone_name AS zone_geographique,
    df.facility_type_name AS type_de_structure,
    df.facility_name AS structure,
    dpr.program_name AS programme,
    dpp.period_year AS annee,
    dpp.period_month AS mois,
    r.emergency AS urgence
   FROM kafka_requisitions r
     LEFT JOIN req_dates rd ON rd.requisitionid = r.id
     LEFT JOIN req_qty rq ON rq.requisitionid = r.id
     LEFT JOIN order_info oi ON oi.ext = r.id
     LEFT JOIN ord_qty oq ON oq.orderid = oi.order_id
     LEFT JOIN pod_qty pq ON pq.orderid = oi.order_id
     LEFT JOIN prod_units pu ON pu.orderid = oi.order_id
     LEFT JOIN analytics.dim_facility df ON df.facility_id = r.facilityid
     LEFT JOIN analytics.dim_program dpr ON dpr.program_id = r.programid
     LEFT JOIN analytics.dim_processing_period dpp ON dpp.processing_period_id = r.processingperiodid;

ALTER TABLE public.vw_requisition_order_flow
    OWNER TO postgres;




-- View: public.vw_stock_msd

-- DROP VIEW public.vw_stock_msd;

CREATE OR REPLACE VIEW public.vw_stock_msd
 AS
 WITH bornes AS (
         SELECT max(kafka_stock_card_line_items.occurreddate) AS d_max
           FROM kafka_stock_card_line_items
        ), conso AS (
         SELECT sc.facilityid AS facility_id,
            sc.orderableid AS product_id,
            sc.programid AS program_id,
            sum(li.quantity)::numeric / 3.0 AS cmm
           FROM kafka_stock_card_line_items li
             JOIN kafka_stock_card_line_item_reasons r ON r.id = li.reasonid
             JOIN kafka_stock_cards sc ON sc.id = li.stockcardid
             CROSS JOIN bornes b
          WHERE (r.name = ANY (ARRAY['Consommation'::text, 'Consumed'::text, 'Sortie de stock'::text]))
            AND li.occurreddate > (b.d_max - '3 mons'::interval)
            AND li.occurreddate <= b.d_max
          GROUP BY sc.facilityid, sc.orderableid, sc.programid
        ), sdu AS (
         SELECT DISTINCT ON (fact_stock_daily.facility_id, fact_stock_daily.product_id) fact_stock_daily.facility_id,
            fact_stock_daily.product_id,
            fact_stock_daily.program_id,
            fact_stock_daily.stock_on_hand,
            fact_stock_daily.movement_date
           FROM analytics.fact_stock_daily
          ORDER BY fact_stock_daily.facility_id, fact_stock_daily.product_id, fact_stock_daily.movement_date DESC
        )
 SELECT s.facility_id,
    s.product_id,
    s.program_id,
    s.movement_date AS date_rapport,
    EXTRACT(year FROM s.movement_date)::integer AS annee,
    EXTRACT(month FROM s.movement_date)::integer AS mois_num,
    to_char(s.movement_date::timestamp with time zone, 'TMMonth'::text) AS mois,
    fac.geographic_level AS niveau_organisation,
    fac.geographic_zone_name AS unite_organisation,
    fac.district_name AS district,
    fac.region_name AS region,
    fac.facility_type_name AS type_structure,
    fac.facility_name AS structure,
    p.program_name AS programme,
    o.product_name AS produit,
    o.product_code AS code_produit,
    s.stock_on_hand AS quantites_en_fin_de_periode,
    round(c.cmm, 2) AS cmm,
        CASE
            WHEN s.stock_on_hand <= 0::numeric THEN 0::numeric
            WHEN COALESCE(c.cmm, 0::numeric) = 0::numeric THEN NULL::numeric
            ELSE LEAST(round(s.stock_on_hand / c.cmm, 2), 24::numeric)
        END AS msd,
        CASE
            WHEN s.stock_on_hand <= 0::numeric THEN 'Rupture'::text
            WHEN COALESCE(c.cmm, 0::numeric) = 0::numeric THEN 'Stock dormant'::text
            WHEN (s.stock_on_hand / c.cmm) <= 4::numeric THEN 'Potentielle rupture'::text
            WHEN (s.stock_on_hand / c.cmm) <= 7::numeric THEN 'Sous-stock'::text
            WHEN (s.stock_on_hand / c.cmm) <= 15::numeric THEN 'Satisfaisant'::text
            ELSE 'Surstock'::text
        END AS etat_stock
   FROM sdu s
     LEFT JOIN conso c ON c.facility_id = s.facility_id AND c.product_id = s.product_id AND c.program_id = s.program_id
     LEFT JOIN analytics.dim_facility fac ON fac.facility_id = s.facility_id
     LEFT JOIN analytics.dim_product o ON o.orderable_id = s.product_id
     LEFT JOIN analytics.dim_program p ON p.program_id = s.program_id;

ALTER TABLE public.vw_stock_msd
    OWNER TO postgres;



-- View: public.vw_rupture_structures

-- DROP VIEW public.vw_rupture_structures;

CREATE OR REPLACE VIEW public.vw_rupture_structures
 AS
 WITH prod_prog AS (
         SELECT DISTINCT kafka_program_orderables.orderableid AS product_id,
            kafka_program_orderables.programid AS program_id
           FROM kafka_program_orderables
          WHERE kafka_program_orderables.active
        ), prog_fac AS (
         SELECT DISTINCT kafka_supported_programs.programid AS program_id,
            kafka_supported_programs.facilityid AS facility_id
           FROM kafka_supported_programs
          WHERE kafka_supported_programs.active
        ), soh AS (
         SELECT DISTINCT ON (fact_stock_daily.facility_id, fact_stock_daily.product_id) fact_stock_daily.facility_id,
            fact_stock_daily.product_id,
            fact_stock_daily.stock_on_hand
           FROM analytics.fact_stock_daily
          ORDER BY fact_stock_daily.facility_id, fact_stock_daily.product_id, fact_stock_daily.movement_date DESC
        ), base AS (
         SELECT pp.product_id,
            pp.program_id,
            pf.facility_id
           FROM prod_prog pp
             JOIN prog_fac pf ON pf.program_id = pp.program_id
        )
 SELECT b.product_id,
    b.facility_id,
    b.program_id,
    o.product_code AS code_produit,
    o.product_name AS produit,
    p.program_name AS programme,
    fac.facility_name AS structure,
    fac.geographic_level AS niveau_organisation,
    fac.geographic_zone_name AS unite_organisation,
    fac.district_name AS district,
    fac.region_name AS region,
    fac.facility_type_name AS type_structure,
    s.stock_on_hand,
    1 AS structure_existante,
        CASE
            WHEN COALESCE(s.stock_on_hand, 0::numeric) <= 0::numeric THEN 1
            ELSE 0
        END AS en_rupture,
        CASE
            WHEN s.facility_id IS NULL THEN 1
            ELSE 0
        END AS sans_donnee,
        CASE
            WHEN s.stock_on_hand <= 0::numeric THEN 1
            ELSE 0
        END AS stockout_confirme
   FROM base b
     LEFT JOIN soh s ON s.facility_id = b.facility_id AND s.product_id = b.product_id
     LEFT JOIN analytics.dim_facility fac ON fac.facility_id = b.facility_id
     LEFT JOIN analytics.dim_product o ON o.orderable_id = b.product_id
     LEFT JOIN analytics.dim_program p ON p.program_id = b.program_id;

ALTER TABLE public.vw_rupture_structures
    OWNER TO postgres;



-- View: public.vw_taux_perte

-- DROP VIEW public.vw_taux_perte;

CREATE OR REPLACE VIEW public.vw_taux_perte
 AS
 WITH mv AS (
         SELECT sc.facilityid AS facility_id,
            sc.orderableid AS product_id,
            sc.programid AS program_id,
            date_trunc('month'::text, li.occurreddate::timestamp with time zone)::date AS mois,
            li.quantity,
            r.reasontype,
            r.name AS reason
           FROM kafka_stock_card_line_items li
             JOIN kafka_stock_card_line_item_reasons r ON r.id = li.reasonid
             JOIN kafka_stock_cards sc ON sc.id = li.stockcardid
        ), agg AS (
         SELECT mv.facility_id,
            mv.product_id,
            mv.program_id,
            mv.mois,
            sum(mv.quantity) FILTER (WHERE mv.reasontype = 'CREDIT'::text) AS entrees,
            sum(mv.quantity) FILTER (WHERE mv.reasontype = 'DEBIT'::text) AS sorties_totales,
            sum(mv.quantity) FILTER (WHERE (mv.reason = ANY (ARRAY['Peremption'::text, 'Avarie'::text, 'Vol ou Disparition'::text]))) AS pertes,
            sum(mv.quantity) FILTER (WHERE mv.reason = 'Peremption'::text) AS pertes_peremption,
            sum(mv.quantity) FILTER (WHERE mv.reason = 'Avarie'::text) AS pertes_avarie,
            sum(mv.quantity) FILTER (WHERE mv.reason = 'Vol ou Disparition'::text) AS pertes_vol
           FROM mv
          GROUP BY mv.facility_id, mv.product_id, mv.program_id, mv.mois
        ), opening AS (
         SELECT DISTINCT ON (stock_daily_history.facility_id, stock_daily_history.product_id, stock_daily_history.program_id, (date_trunc('month'::text, stock_daily_history.movement_date::timestamp with time zone))) stock_daily_history.facility_id,
            stock_daily_history.product_id,
            stock_daily_history.program_id,
            date_trunc('month'::text, stock_daily_history.movement_date::timestamp with time zone)::date AS mois,
            stock_daily_history.opening_balance AS stock_debut
           FROM analytics.stock_daily_history
          ORDER BY stock_daily_history.facility_id, stock_daily_history.product_id, stock_daily_history.program_id, (date_trunc('month'::text, stock_daily_history.movement_date::timestamp with time zone)), stock_daily_history.movement_date
        )
 SELECT a.mois AS date_rapport,
    EXTRACT(year FROM a.mois)::integer AS annee,
    to_char(a.mois::timestamp with time zone, 'TMMonth'::text) AS mois,
    fac.province_name AS province,
    fac.health_zone_name AS zone_de_sante,
    fac.health_area_name AS aire_de_sante,
    fac.facility_name AS etablissement_de_sante,
    fac.facility_type_name AS type_structure,
    p.program_name AS programme,
    o.product_code AS code,
    o.product_name AS produit,
    op.stock_debut,
    COALESCE(a.entrees, 0::bigint) AS quantite_entrees,
    COALESCE(a.sorties_totales, 0::bigint) AS quantite_sorties,
    COALESCE(a.pertes, 0::bigint) AS quantite_perdue,
    COALESCE(a.pertes_peremption, 0::bigint) AS pertes_peremption,
    COALESCE(a.pertes_avarie, 0::bigint) AS pertes_avarie,
    COALESCE(a.pertes_vol, 0::bigint) AS pertes_vol,
    op.stock_debut + COALESCE(a.entrees, 0::bigint)::numeric AS stock_total_disponible,
    COALESCE(a.pertes, 0::bigint)::numeric / NULLIF(a.entrees, 0)::numeric AS taux_perte_sur_entrees,
    COALESCE(a.pertes, 0::bigint)::numeric / NULLIF(a.sorties_totales, 0)::numeric AS taux_perte_sur_sorties,
    COALESCE(a.pertes, 0::bigint)::numeric / NULLIF(op.stock_debut + COALESCE(a.entrees, 0::bigint)::numeric, 0::numeric) AS taux_perte_sur_disponible,
    round(100.0 * COALESCE(a.pertes, 0::bigint)::numeric / NULLIF(a.sorties_totales, 0)::numeric, 1) AS taux_perte_pct,
    to_char(a.mois::timestamp with time zone, 'YYYY-MM'::text) AS annee_mois
   FROM agg a
     LEFT JOIN opening op ON op.facility_id = a.facility_id AND op.product_id = a.product_id AND op.program_id = a.program_id AND op.mois = a.mois
     LEFT JOIN analytics.dim_facility fac ON fac.facility_id = a.facility_id
     LEFT JOIN analytics.dim_program p ON p.program_id = a.program_id
     LEFT JOIN analytics.dim_product o ON o.orderable_id = a.product_id;

ALTER TABLE public.vw_taux_perte
    OWNER TO postgres;
