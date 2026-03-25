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