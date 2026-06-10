-- EXÉCUTER CE SCRIPT UNE SEULE FOIS APRÈS AVOIR CRÉÉ LA PROCÉDURE
-- POUR CHARGER TOUTE L'HISTOIRE PASSÉE DANS LE SCHÉMA ANALYTICS (NIVEAU PRODUIT)

DO $$ 
DECLARE 
    d DATE;
    v_start_date DATE;
BEGIN
    -- Récupérer la date du tout premier mouvement enregistré dans la base
    SELECT MIN(occurreddate)::DATE INTO v_start_date FROM kafka_stock_card_line_items;
    
    -- Sécurité : si la base est vide
    IF v_start_date IS NULL THEN
        RAISE NOTICE 'Aucun mouvement trouvé dans kafka_stock_card_line_items.';
        RETURN;
    END IF;

    -- Optimisation temporaire pour l'insertion massive (Modèle Dense)
    SET LOCAL work_mem = '512MB';
    
    RAISE NOTICE 'Début du backfill à partir du %', v_start_date;

    -- Boucle dynamique sur les dates
    FOR d IN SELECT generate_series(v_start_date, CURRENT_DATE - 1, '1 day')::DATE LOOP
        RAISE NOTICE 'Traitement Mode Dense pour la date : %', d;
        PERFORM analytics.refresh_daily_stock_history(d);
    END LOOP;
END $$;

-- Vérification du résultat
SELECT movement_date, count(*) as nb_products 
FROM analytics.stock_daily_history 
GROUP BY movement_date 
ORDER BY movement_date DESC;


