-- pg_query_advisor--1.4--1.5.sql
-- Upgrade: 1.4 → 1.5
-- Yeni: wait_event_summary, index_bloat_estimate,
--       table_privileges_audit, table_access_methods

-- ==============================================================================
-- 1. WAIT EVENT SUMMARY
--    pg_stat_activity.wait_event dagilimi: sistemin nerede bekledigini gosterir.
--    Lock, LWLock, IO veya CPU bound mi? Tum darbogazlarin ozeti.
-- ==============================================================================

CREATE OR REPLACE FUNCTION query_advisor.wait_event_summary()
RETURNS TABLE(
    wait_event_type  text,
    wait_event       text,
    session_count    bigint,
    pct_of_total     numeric,
    risk_level       text,
    explanation      text,
    sample_query     text
)
LANGUAGE sql
STABLE
SECURITY INVOKER
AS $$
    WITH all_sessions AS (
        SELECT count(*) AS total
        FROM pg_stat_activity
        WHERE backend_type = 'client backend'
    )
    SELECT
        COALESCE(a.wait_event_type, 'CPU/Running')::text,
        COALESCE(a.wait_event,      '(bekleme yok — aktif calisiyor)')::text,
        count(*)::bigint                                              AS session_count,
        round(count(*)::numeric
              / NULLIF((SELECT total FROM all_sessions), 0) * 100, 1) AS pct_of_total,
        CASE
            WHEN a.wait_event_type = 'Lock'
                THEN 'CRITICAL'
            WHEN a.wait_event_type IN ('LWLock', 'IO')
                THEN 'WARNING'
            WHEN a.wait_event_type = 'Client'
                THEN 'NOTICE'
            ELSE 'OK'
        END                                                           AS risk_level,
        CASE
            WHEN a.wait_event_type = 'Lock'
                THEN 'Agir lock bekleme — query_advisor.lock_waits() ile bloklayan sorguyu bulun'
            WHEN a.wait_event_type = 'LWLock' AND a.wait_event LIKE '%Buffer%'
                THEN 'Buffer lock: yuksek yazma baskisi veya shared_buffers yetersiz'
            WHEN a.wait_event_type = 'LWLock' AND a.wait_event LIKE '%WAL%'
                THEN 'WAL lock: wal_buffers artirin veya synchronous_commit gozden gecirin'
            WHEN a.wait_event_type = 'LWLock'
                THEN 'Dahili kilit: yuksek concurrent islem veya checkpoint baskisi'
            WHEN a.wait_event_type = 'IO' AND a.wait_event = 'DataFileRead'
                THEN 'Disk okuma beklemesi: shared_buffers yetersiz veya soguk cache — cache_hit() inceleyin'
            WHEN a.wait_event_type = 'IO' AND a.wait_event = 'WALWrite'
                THEN 'WAL yazma gecikme: wal_buffers artirin veya depolama I/O kontrol edin'
            WHEN a.wait_event_type = 'IO' AND a.wait_event = 'DataFileWrite'
                THEN 'Disk yazma beklemesi: checkpoint baskisi — checkpoint_completion_target=0.9 deneyin'
            WHEN a.wait_event_type = 'IO'
                THEN 'Genel I/O bekleme: depolama IOPS kapasitesini kontrol edin'
            WHEN a.wait_event_type = 'Client'
                THEN 'Client bekleme: uygulama sonucu okumakta gecikiyor (network veya uygulama tarafli)'
            WHEN a.wait_event_type IS NULL
                THEN 'Aktif sorgu calisiyor — bekleme yok'
            ELSE a.wait_event_type || ' / ' || COALESCE(a.wait_event, '')
        END                                                           AS explanation,
        -- Her wait_event icin ornek bir sorgu (ilk 100 karakter)
        (   SELECT left(a2.query, 100)
            FROM   pg_stat_activity a2
            WHERE  a2.wait_event_type IS NOT DISTINCT FROM a.wait_event_type
              AND  a2.wait_event      IS NOT DISTINCT FROM a.wait_event
              AND  a2.query IS NOT NULL
              AND  a2.backend_type = 'client backend'
            LIMIT  1
        )::text                                                       AS sample_query
    FROM pg_stat_activity a
    WHERE a.backend_type = 'client backend'
    GROUP BY a.wait_event_type, a.wait_event
    ORDER BY
        CASE a.wait_event_type
            WHEN 'Lock'   THEN 0
            WHEN 'LWLock' THEN 1
            WHEN 'IO'     THEN 2
            WHEN 'Client' THEN 3
            ELSE               4
        END,
        count(*) DESC;
$$;

COMMENT ON FUNCTION query_advisor.wait_event_summary IS
    'pg_stat_activity.wait_event dagilimini ozetler. '
    'Lock, LWLock, IO veya CPU-bound mi sorusuna cevap verir. '
    'CRITICAL: Lock bekleme, WARNING: LWLock/IO, NOTICE: Client bekleme.';

-- ==============================================================================
-- 2. INDEX BLOAT ESTIMATE
--    pgstattuple gerektirmeden index bloat tahmini.
--    Dead tuple orani + fill factor + zaman bazli yaklasim.
--    %50 dead tuple → indexteki kayitlarin da yaklasik %50si gereksiz.
-- ==============================================================================

CREATE OR REPLACE FUNCTION query_advisor.index_bloat_estimate(
    p_schema        text    DEFAULT NULL,
    p_min_bloat_pct numeric DEFAULT 20,
    p_min_size_mb   numeric DEFAULT 1
)
RETURNS TABLE(
    schema_name       text,
    table_name        text,
    index_name        text,
    index_type        text,
    index_size        text,
    index_size_bytes  bigint,
    fill_factor       int,
    table_dead_pct    numeric,
    bloat_ratio_pct   numeric,
    estimated_waste   text,
    days_since_vacuum int,
    risk_level        text,
    recommendation    text
)
LANGUAGE sql
STABLE
SECURITY INVOKER
AS $$
    WITH index_data AS (
        SELECT
            n.nspname                                                   AS schema_name,
            tc.relname                                                  AS table_name,
            ic.relname                                                  AS index_name,
            am.amname                                                   AS index_type,
            pg_relation_size(ix.indexrelid)                             AS idx_size,
            -- Fill factor: reloptions'dan al, yoksa btree=90 / hash=75 varsayim
            COALESCE(
                (SELECT option_value::int
                 FROM   pg_options_to_table(ic.reloptions)
                 WHERE  option_name = 'fillfactor'),
                CASE am.amname WHEN 'btree' THEN 90
                               WHEN 'hash'  THEN 75
                               ELSE 70 END
            )                                                           AS fill_factor,
            -- Tablo dead tuple orani (index bloat proxy)
            round(
                st.n_dead_tup::numeric
                / NULLIF(st.n_live_tup + st.n_dead_tup, 0) * 100, 1
            )                                                           AS dead_pct,
            -- Son vacuum'dan gecen gun
            EXTRACT(DAY FROM now() - COALESCE(st.last_vacuum, st.last_autovacuum))::int
                                                                        AS days_since_vac,
            ix.indexrelid,
            ix.indisvalid,
            ix.indisunique,
            ix.indisprimary
        FROM pg_index           ix
        JOIN pg_class           ic ON ic.oid = ix.indexrelid
        JOIN pg_class           tc ON tc.oid = ix.indrelid
        JOIN pg_namespace        n ON  n.oid = tc.relnamespace
        JOIN pg_am              am ON am.oid = ic.relam
        JOIN pg_stat_user_tables st ON st.relid = ix.indrelid
        WHERE ix.indisvalid
          AND n.nspname NOT IN ('pg_catalog', 'information_schema')
          AND (p_schema IS NULL OR n.nspname = p_schema)
          AND pg_relation_size(ix.indexrelid) >= p_min_size_mb * 1024 * 1024
    )
    SELECT
        schema_name::text,
        table_name::text,
        index_name::text,
        index_type::text,
        pg_size_pretty(idx_size),
        idx_size,
        fill_factor,
        COALESCE(dead_pct, 0),
        -- Bloat tahmini: dead tuple orani + fill factor bosluklari
        -- Formul: dead_pct + (100-fill_factor) * 0.3  (fill overhead payi)
        LEAST(
            COALESCE(dead_pct, 0)
            + (100 - fill_factor) * 0.3,
            90.0
        )                                                               AS bloat_ratio_pct,
        pg_size_pretty(
            (idx_size * LEAST(
                COALESCE(dead_pct, 0)
                + (100 - fill_factor) * 0.3,
                90.0
            ) / 100.0)::bigint
        )                                                               AS estimated_waste,
        days_since_vac,
        CASE
            WHEN COALESCE(dead_pct, 0) >= 50        THEN 'CRITICAL'
            WHEN COALESCE(dead_pct, 0) >= p_min_bloat_pct THEN 'WARNING'
            ELSE 'NOTICE'
        END,
        CASE
            WHEN COALESCE(dead_pct, 0) >= 50
                THEN 'Agir index bloat (dead_tup=%' || dead_pct::text || ') — '
                     || 'REINDEX CONCURRENTLY ' || quote_ident(index_name) || ';'
            WHEN COALESCE(dead_pct, 0) >= p_min_bloat_pct
                THEN 'Index bloat tahmini (dead_tup=%' || dead_pct::text || ') — '
                     || 'VACUUM ANALYZE ' || quote_ident(schema_name) || '.' || quote_ident(table_name)
                     || '; ardından REINDEX CONCURRENTLY ' || quote_ident(index_name)
            ELSE 'VACUUM ANALYZE ' || quote_ident(schema_name) || '.' || quote_ident(table_name)
                 || ' ile dead tuple temizlenebilir'
        END
    FROM index_data
    WHERE COALESCE(dead_pct, 0)
          + (100 - fill_factor) * 0.3 >= p_min_bloat_pct
    ORDER BY
        (COALESCE(dead_pct, 0) + (100 - fill_factor) * 0.3) DESC,
        idx_size DESC;
$$;

COMMENT ON FUNCTION query_advisor.index_bloat_estimate IS
    'pgstattuple olmadan index bloat tahmini yapar. '
    'Tablo dead tuple orani ve index fill factor kombinasyonu kullanilir. '
    'Oneri: REINDEX CONCURRENTLY ile canli sistemde yeniden olusturulabilir. '
    'p_min_bloat_pct: sonuc filtresi (varsayilan %20), p_min_size_mb: min boyut.';

-- ==============================================================================
-- 3. TABLE PRIVILEGES AUDIT
--    Asiri yetkili roller, PUBLIC erisimi olan tablolar, superuser hesaplari.
--    Guvenlik denetimi: en az yetki prensibi (principle of least privilege).
-- ==============================================================================

CREATE OR REPLACE FUNCTION query_advisor.table_privileges_audit(
    p_schema text DEFAULT NULL
)
RETURNS TABLE(
    audit_type       text,
    role_name        text,
    object_schema    text,
    object_name      text,
    privileges       text,
    risk_level       text,
    recommendation   text
)
LANGUAGE sql
STABLE
SECURITY INVOKER
AS $$
    -- 1. PUBLIC erisimi olan tablolar (herkes okuyabilir/yazabilir)
    SELECT
        'PUBLIC TABLE ACCESS'::text                     AS audit_type,
        'PUBLIC'::text                                  AS role_name,
        g.table_schema::text,
        g.table_name::text,
        string_agg(g.privilege_type, ', '
                   ORDER BY g.privilege_type)           AS privileges,
        CASE
            WHEN 'INSERT' = ANY(array_agg(g.privilege_type))
              OR 'UPDATE' = ANY(array_agg(g.privilege_type))
              OR 'DELETE' = ANY(array_agg(g.privilege_type))
                THEN 'CRITICAL'
            WHEN 'SELECT' = ANY(array_agg(g.privilege_type))
                THEN 'WARNING'
            ELSE 'NOTICE'
        END,
        CASE
            WHEN 'INSERT' = ANY(array_agg(g.privilege_type))
              OR 'UPDATE' = ANY(array_agg(g.privilege_type))
              OR 'DELETE' = ANY(array_agg(g.privilege_type))
                THEN 'PUBLIC yazma yetkisi tehlikeli — REVOKE INSERT,UPDATE,DELETE ON '
                     || g.table_schema || '.' || g.table_name || ' FROM PUBLIC;'
            ELSE 'PUBLIC okuma yetkisi: hassas veri icin REVOKE SELECT ON '
                 || g.table_schema || '.' || g.table_name || ' FROM PUBLIC;'
        END
    FROM information_schema.role_table_grants g
    WHERE g.grantee = 'PUBLIC'
      AND g.table_schema NOT IN ('pg_catalog', 'information_schema')
      AND (p_schema IS NULL OR g.table_schema = p_schema)
    GROUP BY g.table_schema, g.table_name

    UNION ALL

    -- 2. Superuser hesaplari (postgres disinda)
    SELECT
        'SUPERUSER ROLE'::text,
        r.rolname::text,
        NULL::text,
        NULL::text,
        'SUPERUSER'::text,
        'CRITICAL'::text,
        'Superuser yetkisi en aza indirilmeli. '
        || 'Gerekli degilse: ALTER ROLE ' || r.rolname || ' NOSUPERUSER;'
    FROM pg_roles r
    WHERE r.rolsuper = true
      AND r.rolname <> 'postgres'
      AND NOT r.rolname LIKE 'pg_%'

    UNION ALL

    -- 3. CREATEROLE yetkisi olan roller (diger rolleri degistirebilir)
    SELECT
        'CREATEROLE PRIVILEGE'::text,
        r.rolname::text,
        NULL::text,
        NULL::text,
        'CREATEROLE'::text,
        'WARNING'::text,
        'CREATEROLE ile diger rollerin yetkileri degistirilebilir. '
        || 'Gerekli degilse: ALTER ROLE ' || r.rolname || ' NOCREATEROLE;'
    FROM pg_roles r
    WHERE r.rolcreaterole = true
      AND r.rolname <> 'postgres'
      AND NOT r.rolname LIKE 'pg_%'
      AND NOT r.rolsuper   -- superuser'lar zaten yukarida gozuktu

    UNION ALL

    -- 4. CREATEDB yetkisi olan roller
    SELECT
        'CREATEDB PRIVILEGE'::text,
        r.rolname::text,
        NULL::text,
        NULL::text,
        'CREATEDB'::text,
        'NOTICE'::text,
        'Gerekli degilse: ALTER ROLE ' || r.rolname || ' NOCREATEDB;'
    FROM pg_roles r
    WHERE r.rolcreatedb = true
      AND r.rolname <> 'postgres'
      AND NOT r.rolname LIKE 'pg_%'
      AND NOT r.rolsuper

    UNION ALL

    -- 5. Sifresi olmayan (veya sifresiz giris) roller
    SELECT
        'NO PASSWORD'::text,
        r.rolname::text,
        NULL::text,
        NULL::text,
        'LOGIN without password'::text,
        'WARNING'::text,
        'Sifresiz giris: ALTER ROLE ' || r.rolname
        || ' PASSWORD ''guclu_sifre'';'
        || '  -- pg_hba.conf da kontrol edilmeli'
    FROM pg_roles r
    WHERE r.rolcanlogin = true
      AND r.rolpassword IS NULL
      AND r.rolname <> 'postgres'
      AND NOT r.rolname LIKE 'pg_%'

    ORDER BY
        CASE risk_level
            WHEN 'CRITICAL' THEN 0
            WHEN 'WARNING'  THEN 1
            WHEN 'NOTICE'   THEN 2
            ELSE                 3
        END,
        audit_type, role_name;
$$;

COMMENT ON FUNCTION query_advisor.table_privileges_audit IS
    'Guvenlik denetimi: PUBLIC erisimi olan tablolar, superuser roller, '
    'CREATEROLE/CREATEDB yetkileri ve sifresiz giris yapabilen roller. '
    'En az yetki (least privilege) ilkesine aykirilik tespiti.';

-- ==============================================================================
-- 4. TABLE ACCESS METHODS
--    Her tablonun hangi access method ile depolandigini gosterir.
--    PG17+ ile birlikte heap disinda columnar, zheap vb. alternatifler geldi.
--    Standart disinda bir AM kullaniliyorsa dikkat cekici bilgi verir.
-- ==============================================================================

CREATE OR REPLACE FUNCTION query_advisor.table_access_methods(
    p_schema text DEFAULT NULL
)
RETURNS TABLE(
    schema_name      text,
    table_name       text,
    access_method    text,
    table_size       text,
    live_tuples      bigint,
    is_partitioned   boolean,
    is_standard      boolean,
    toast_size       text,
    fillfactor       int,
    risk_level       text,
    recommendation   text
)
LANGUAGE sql
STABLE
SECURITY INVOKER
AS $$
    SELECT
        n.nspname::text,
        c.relname::text,
        am.amname::text,
        pg_size_pretty(pg_total_relation_size(c.oid)),
        COALESCE(s.n_live_tup, 0),
        c.relkind = 'p'                                             AS is_partitioned,
        am.amname = 'heap'                                          AS is_standard,
        -- TOAST boyutu
        CASE WHEN c.reltoastrelid <> 0
             THEN pg_size_pretty(pg_relation_size(c.reltoastrelid))
             ELSE 'yok'
        END,
        -- Fill factor
        COALESCE(
            (SELECT option_value::int
             FROM   pg_options_to_table(c.reloptions)
             WHERE  option_name = 'fillfactor'),
            CASE c.relkind WHEN 'r' THEN 100 ELSE NULL END
        ),
        CASE
            WHEN am.amname NOT IN ('heap')
                THEN 'NOTICE'
            WHEN (SELECT option_value::int
                  FROM   pg_options_to_table(c.reloptions)
                  WHERE  option_name = 'fillfactor') < 80
                THEN 'NOTICE'
            ELSE 'OK'
        END,
        CASE
            WHEN am.amname NOT IN ('heap')
                THEN 'Standart olmayan AM: ' || am.amname
                     || ' — extension''a bagli; kaldirilirsa tablo erisimi bozulur'
            WHEN (SELECT option_value::int
                  FROM   pg_options_to_table(c.reloptions)
                  WHERE  option_name = 'fillfactor') < 80
                THEN 'Dusuk fillfactor (' ||
                     (SELECT option_value FROM pg_options_to_table(c.reloptions)
                      WHERE option_name = 'fillfactor') ||
                     ') — UPDATE yogun tablolarda kasitli olabilir (HOT guncelleme icin)'
            ELSE 'Standart heap — normal'
        END
    FROM pg_class         c
    JOIN pg_namespace     n  ON n.oid  = c.relnamespace
    JOIN pg_am            am ON am.oid = c.relam
    LEFT JOIN pg_stat_user_tables s
           ON s.schemaname = n.nspname AND s.relname = c.relname
    WHERE c.relkind IN ('r', 'p')   -- normal tablo ve partitioned tablo
      AND n.nspname NOT IN ('pg_catalog', 'information_schema', 'pg_toast')
      AND (p_schema IS NULL OR n.nspname = p_schema)
    ORDER BY
        CASE am.amname WHEN 'heap' THEN 1 ELSE 0 END,  -- heap olmayanlar once
        pg_total_relation_size(c.oid) DESC;
$$;

COMMENT ON FUNCTION query_advisor.table_access_methods IS
    'Her tablonun depolama access method bilgisini gosterir (heap, columnar vb). '
    'Standart olmayan access method kullaniliyorsa NOTICE uretir; '
    'extension kaldirilirsa tablo erisimi bozulabilir. '
    'Dusuk fillfactor (HOT guncelleme) tespit eder.';
