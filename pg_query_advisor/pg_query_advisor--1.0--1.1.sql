-- pg_query_advisor--1.0--1.1.sql
-- Upgrade: 1.0 → 1.1
-- Yeni fonksiyonlar: explain_plan, table_growth_forecast,
--                   partition_candidates, index_recommendations

-- ==============================================================================
-- PRIVATE HELPER: Plan JSON ağacını düzleştir (recursive)
-- ==============================================================================

CREATE OR REPLACE FUNCTION query_advisor._flatten_plan_nodes(node jsonb)
RETURNS SETOF jsonb
LANGUAGE plpgsql
IMMUTABLE
AS $$
BEGIN
    RETURN NEXT node;
    IF (node -> 'Plans') IS NOT NULL
       AND jsonb_array_length(node -> 'Plans') > 0
    THEN
        RETURN QUERY
            SELECT query_advisor._flatten_plan_nodes(child)
            FROM   jsonb_array_elements(node -> 'Plans') AS child;
    END IF;
END;
$$;

-- ==============================================================================
-- 1. EXPLAIN PLAN ANALİZİ
--    Sorgu metnini alır, EXPLAIN çalıştırır, plan düğümlerini analiz eder.
--    p_analyze = true  → EXPLAIN (ANALYZE, BUFFERS) — gerçek çalıştırma
--    p_analyze = false → EXPLAIN only — tahmine dayalı (default, güvenli)
-- ==============================================================================

CREATE OR REPLACE FUNCTION query_advisor.explain_plan(
    p_query   text,
    p_analyze boolean DEFAULT false
)
RETURNS TABLE(
    node_type      text,
    relation_name  text,
    index_name     text,
    total_cost     numeric,
    plan_rows      bigint,
    actual_rows    bigint,
    actual_loops   int,
    finding        text,
    recommendation text
)
LANGUAGE plpgsql
SECURITY INVOKER
AS $$
DECLARE
    v_plan_text  text;
    v_plan       jsonb;
    v_sql        text;
BEGIN
    v_sql := 'EXPLAIN (FORMAT JSON'
             || CASE WHEN p_analyze THEN ', ANALYZE, BUFFERS' ELSE '' END
             || ') ' || p_query;

    BEGIN
        EXECUTE v_sql INTO v_plan_text;
        v_plan := v_plan_text::jsonb;
    EXCEPTION WHEN OTHERS THEN
        RAISE EXCEPTION 'EXPLAIN başarısız: % | Sorgu: %',
                        SQLERRM, left(p_query, 120);
    END;

    RETURN QUERY
    SELECT
        (n ->> 'Node Type')::text,
        (n ->> 'Relation Name')::text,
        (n ->> 'Index Name')::text,
        round((n ->> 'Total Cost')::numeric, 2),
        (n ->> 'Plan Rows')::bigint,
        (n ->> 'Actual Rows')::bigint,
        (n ->> 'Actual Loops')::int,
        -- Finding
        CASE
            WHEN n ->> 'Node Type' = 'Seq Scan'
                 AND (n ->> 'Plan Rows')::bigint > 500
                THEN 'WARN: Seq Scan — '
                     || COALESCE(n ->> 'Relation Name', '?')
                     || ' (' || (n ->> 'Plan Rows') || ' satır)'
            WHEN n ->> 'Node Type' = 'Sort'
                 AND (n ->> 'Sort Method') LIKE '%external%'
                THEN 'WARN: Harici sort (disk kullanıyor) — work_mem yetersiz'
            WHEN n ->> 'Node Type' = 'Nested Loop'
                 AND (n ->> 'Plan Rows')::bigint > 10000
                THEN 'WARN: Nested Loop ile ' || (n ->> 'Plan Rows')
                     || ' satır — Hash Join daha verimli olabilir'
            WHEN n ->> 'Node Type' LIKE '%Index%'
                THEN 'OK: Index kullanıyor — '
                     || COALESCE(n ->> 'Index Name', '?')
            WHEN n ->> 'Node Type' = 'Hash Join'
                THEN 'INFO: Hash Join — join kolonlarında index gereksiz'
            WHEN n ->> 'Node Type' = 'Merge Join'
                THEN 'INFO: Merge Join — join kolonları sıralı'
            ELSE 'INFO: ' || (n ->> 'Node Type')
        END,
        -- Recommendation
        CASE
            WHEN n ->> 'Node Type' = 'Seq Scan'
                 AND (n ->> 'Plan Rows')::bigint > 500
                THEN 'CREATE INDEX CONCURRENTLY ON '
                     || COALESCE(n ->> 'Relation Name', 'tablo')
                     || ' (<filtre_kolonu>);'
            WHEN n ->> 'Node Type' = 'Sort'
                 AND (n ->> 'Sort Method') LIKE '%external%'
                THEN 'SET work_mem = ''256MB'';  -- ya da ORDER BY kolonuna index'
            WHEN n ->> 'Node Type' = 'Nested Loop'
                 AND (n ->> 'Plan Rows')::bigint > 10000
                THEN 'SET enable_nestloop = off;  -- Hash Join ile karsilastirin'
            ELSE NULL
        END
    FROM query_advisor._flatten_plan_nodes(v_plan -> 0 -> 'Plan') AS n
    ORDER BY (n ->> 'Total Cost')::numeric DESC NULLS LAST;
END;
$$;

COMMENT ON FUNCTION query_advisor.explain_plan IS
    'Sorgu planını JSON olarak alır, tüm düğümleri recursive tarar ve '
    'Seq Scan / disk sort / Nested Loop gibi sorunları raporlar. '
    'p_analyze=true ile EXPLAIN ANALYZE çalıştırır (sorguyu gerçek çalıştırır).';

-- ==============================================================================
-- 2. TABLO BÜYÜME TAHMİNİ
--    pg_stat_user_tables.n_tup_ins/del istatistiklerinden günlük net büyüme
--    hesaplayıp 30/90/180/365 gün projeksiyonu yapar.
-- ==============================================================================

CREATE OR REPLACE FUNCTION query_advisor.table_growth_forecast(
    p_schema   text   DEFAULT NULL,
    p_min_rows bigint DEFAULT 10000
)
RETURNS TABLE(
    schema_name        text,
    table_name         text,
    current_size       text,
    current_rows       bigint,
    days_of_stats      numeric,
    daily_inserts      numeric,
    daily_deletes      numeric,
    net_daily_rows     numeric,
    bytes_per_row      numeric,
    est_size_30d       text,
    est_size_90d       text,
    est_size_180d      text,
    est_size_1y        text,
    growth_rate_pct    numeric,
    recommendation     text
)
LANGUAGE sql
STABLE
SECURITY INVOKER
AS $$
    WITH db_stats AS (
        -- İstatistiklerin kaç gündür toplandığı
        SELECT GREATEST(
            extract(epoch FROM (now() - stats_reset)) / 86400.0,
            1.0   -- sıfıra bölmeyi önle
        ) AS days
        FROM pg_stat_database
        WHERE datname = current_database()
    ),
    tbl AS (
        SELECT
            s.schemaname,
            s.relname,
            s.n_live_tup                                    AS cur_rows,
            s.n_tup_ins                                     AS total_ins,
            s.n_tup_del                                     AS total_del,
            pg_total_relation_size(
                quote_ident(s.schemaname) || '.' || quote_ident(s.relname)
            )                                               AS total_bytes,
            d.days
        FROM pg_stat_user_tables s, db_stats d
        WHERE s.n_live_tup >= p_min_rows
          AND (p_schema IS NULL OR s.schemaname = p_schema)
    )
    SELECT
        t.schemaname::text,
        t.relname::text,
        pg_size_pretty(t.total_bytes),
        t.cur_rows,
        round(t.days, 1)                                    AS days_of_stats,
        round(t.total_ins / t.days, 0)                      AS daily_inserts,
        round(t.total_del / t.days, 0)                      AS daily_deletes,
        -- Net günlük satır değişimi
        round((t.total_ins - t.total_del) / t.days, 0)     AS net_daily_rows,
        -- Satır başına byte (ortalama)
        CASE WHEN t.cur_rows > 0
             THEN round(t.total_bytes::numeric / t.cur_rows, 0)
             ELSE 0
        END                                                 AS bytes_per_row,
        -- Projeksiyon: mevcut_bytes + net_satır * gün * bytes_per_row
        pg_size_pretty(GREATEST(0, (
            t.total_bytes +
            ((t.total_ins - t.total_del) / t.days * 30) *
            NULLIF(t.total_bytes::numeric / NULLIF(t.cur_rows,0), 0)
        ))::bigint),
        pg_size_pretty(GREATEST(0, (
            t.total_bytes +
            ((t.total_ins - t.total_del) / t.days * 90) *
            NULLIF(t.total_bytes::numeric / NULLIF(t.cur_rows,0), 0)
        ))::bigint),
        pg_size_pretty(GREATEST(0, (
            t.total_bytes +
            ((t.total_ins - t.total_del) / t.days * 180) *
            NULLIF(t.total_bytes::numeric / NULLIF(t.cur_rows,0), 0)
        ))::bigint),
        pg_size_pretty(GREATEST(0, (
            t.total_bytes +
            ((t.total_ins - t.total_del) / t.days * 365) *
            NULLIF(t.total_bytes::numeric / NULLIF(t.cur_rows,0), 0)
        ))::bigint),
        -- Yıllık büyüme oranı %
        CASE WHEN t.cur_rows > 0 AND t.total_ins > t.total_del
             THEN round(
                 ((t.total_ins - t.total_del) / t.days * 365)
                 / t.cur_rows::numeric * 100, 1)
             ELSE 0
        END,
        -- Öneri
        CASE
            WHEN t.cur_rows > 0
                 AND ((t.total_ins - t.total_del) / t.days * 365)
                     / t.cur_rows::numeric > 2.0
                THEN 'CRITICAL: Tablo 1 yılda 2x büyüyor — hemen partitioning planlayın'
            WHEN t.cur_rows > 0
                 AND ((t.total_ins - t.total_del) / t.days * 365)
                     / t.cur_rows::numeric > 0.5
                THEN 'WARNING: >%50 yıllık büyüme — partitioning stratejisi belirleyin'
            WHEN t.cur_rows > 0
                 AND ((t.total_ins - t.total_del) / t.days * 365)
                     / t.cur_rows::numeric > 0.1
                THEN 'NOTICE: Orta büyüme hızı — autovacuum ayarlarını gözden geçirin'
            WHEN (t.total_ins - t.total_del) <= 0
                THEN 'STABLE / SHRINKING: net satır kaybı veya sabit'
            ELSE 'OK: Düşük büyüme hızı'
        END
    FROM tbl t
    ORDER BY
        (t.total_ins - t.total_del) / t.days DESC;
$$;

COMMENT ON FUNCTION query_advisor.table_growth_forecast IS
    'pg_stat_user_tables insert/delete istatistiklerinden günlük net büyüme '
    'hesaplar ve 30/90/180/365 günlük boyut projeksiyonu üretir.';

-- ==============================================================================
-- 3. PARTİTİONİNG ADAYI ANALİZİ
--    Büyük tablolarda timestamp → RANGE, integer/uuid → HASH partitioning önerir.
--    Hazır CREATE TABLE ... PARTITION BY DDL üretir.
-- ==============================================================================

CREATE OR REPLACE FUNCTION query_advisor.partition_candidates(
    p_schema      text    DEFAULT NULL,
    p_min_size_mb numeric DEFAULT 100
)
RETURNS TABLE(
    schema_name        text,
    table_name         text,
    table_size         text,
    row_count          bigint,
    partition_strategy text,
    partition_key      text,
    key_type           text,
    sample_ddl         text,
    recommendation     text
)
LANGUAGE sql
STABLE
SECURITY INVOKER
AS $$
    WITH large_tables AS (
        SELECT
            n.nspname  AS schema_name,
            c.relname  AS table_name,
            c.oid,
            pg_total_relation_size(c.oid)        AS total_bytes,
            greatest(c.reltuples::bigint, 0)     AS row_count
        FROM pg_class     c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE c.relkind = 'r'
          AND NOT c.relispartition
          AND n.nspname NOT IN ('pg_catalog','information_schema','pg_toast')
          AND pg_total_relation_size(c.oid) >= p_min_size_mb * 1024 * 1024
          AND (p_schema IS NULL OR n.nspname = p_schema)
    ),
    -- En iyi timestamp kolonu (created_at, olusturma, ts, date gibi isimler önce)
    ts_cols AS (
        SELECT DISTINCT ON (lt.oid)
            lt.oid,
            a.attname AS col_name,
            t.typname AS col_type
        FROM large_tables lt
        JOIN pg_attribute a ON a.attrelid = lt.oid AND a.attnum > 0 AND NOT a.attisdropped
        JOIN pg_type      t ON t.oid = a.atttypid
        WHERE t.typname IN ('timestamp','timestamptz','date')
        ORDER BY lt.oid,
            -- Yaygın isimler önce
            CASE WHEN lower(a.attname) IN ('created_at','olusturma','ts','event_time',
                                           'transaction_time','log_time','dt','tarih')
                 THEN 0 ELSE 1 END,
            a.attnum
    ),
    -- En iyi integer/uuid kolon (id, user_id, tenant_id gibi)
    int_cols AS (
        SELECT DISTINCT ON (lt.oid)
            lt.oid,
            a.attname AS col_name,
            t.typname AS col_type
        FROM large_tables lt
        JOIN pg_attribute a ON a.attrelid = lt.oid AND a.attnum > 0 AND NOT a.attisdropped
        JOIN pg_type      t ON t.oid = a.atttypid
        WHERE t.typname IN ('int2','int4','int8','uuid')
        ORDER BY lt.oid,
            CASE WHEN lower(a.attname) IN ('id','user_id','tenant_id','account_id',
                                           'customer_id','partition_key')
                 THEN 0 ELSE 1 END,
            a.attnum
    )
    SELECT
        lt.schema_name::text,
        lt.table_name::text,
        pg_size_pretty(lt.total_bytes),
        lt.row_count,
        CASE
            WHEN tc.col_name IS NOT NULL THEN 'RANGE'
            WHEN ic.col_name IS NOT NULL THEN 'HASH'
            ELSE 'MANUEL ANALİZ GEREKİYOR'
        END                                                        AS partition_strategy,
        COALESCE(tc.col_name, ic.col_name, '?')::text             AS partition_key,
        COALESCE(tc.col_type, ic.col_type, '?')::text             AS key_type,
        -- Hazır DDL
        CASE
            WHEN tc.col_name IS NOT NULL THEN
                '-- Adım 1: Yeni partitioned tablo' || chr(10)
                || 'CREATE TABLE ' || quote_ident(lt.schema_name) || '.'
                || quote_ident(lt.table_name || '_p')             || chr(10)
                || '  (LIKE ' || quote_ident(lt.schema_name) || '.'
                || quote_ident(lt.table_name) || ' INCLUDING ALL)'|| chr(10)
                || 'PARTITION BY RANGE (' || quote_ident(tc.col_name) || ');'
                || chr(10) || chr(10)
                || '-- Adım 2: Örnek yıllık partition' || chr(10)
                || 'CREATE TABLE ' || quote_ident(lt.schema_name) || '.'
                || quote_ident(lt.table_name || '_2024')          || chr(10)
                || '  PARTITION OF ' || quote_ident(lt.schema_name) || '.'
                || quote_ident(lt.table_name || '_p')             || chr(10)
                || '  FOR VALUES FROM (''2024-01-01'') TO (''2025-01-01'');'
                || chr(10) || chr(10)
                || '-- Adım 3: Veriyi taşı (kesintisiz)' || chr(10)
                || '-- INSERT INTO ... SELECT * FROM ' || lt.table_name || ';'
                || chr(10)
                || '-- ALTER TABLE ' || lt.table_name
                || ' RENAME TO ' || lt.table_name || '_old;'
            WHEN ic.col_name IS NOT NULL THEN
                '-- Adım 1: Yeni partitioned tablo (8 partition)' || chr(10)
                || 'CREATE TABLE ' || quote_ident(lt.schema_name) || '.'
                || quote_ident(lt.table_name || '_p')             || chr(10)
                || '  (LIKE ' || quote_ident(lt.schema_name) || '.'
                || quote_ident(lt.table_name) || ' INCLUDING ALL)'|| chr(10)
                || 'PARTITION BY HASH (' || quote_ident(ic.col_name) || ');'
                || chr(10) || chr(10)
                || '-- Adım 2: 8 partition oluştur (0..7)' || chr(10)
                || 'CREATE TABLE ' || quote_ident(lt.schema_name) || '.'
                || quote_ident(lt.table_name || '_p0')            || chr(10)
                || '  PARTITION OF ' || quote_ident(lt.schema_name) || '.'
                || quote_ident(lt.table_name || '_p')             || chr(10)
                || '  FOR VALUES WITH (MODULUS 8, REMAINDER 0);'  || chr(10)
                || '-- ... REMAINDER 1..7 için tekrarlayın'
            ELSE
                'Manuel analiz gerekiyor — tablo yapısını inceleyin: '
                || chr(10)
                || '\d ' || lt.schema_name || '.' || lt.table_name
        END                                                        AS sample_ddl,
        CASE
            WHEN lt.row_count  > 500000000 THEN 'CRITICAL: >500M satır — acil partitioning'
            WHEN lt.row_count  > 100000000 THEN 'HIGH: >100M satır — partitioning şiddetle önerilir'
            WHEN lt.row_count  > 10000000  THEN 'MEDIUM: >10M satır — partitioning planlayın'
            WHEN lt.total_bytes > 10 * 1024^3 THEN 'HIGH: >10 GB tablo — boyut bazlı partitioning'
            ELSE                                   'LOW: büyüme trendine göre değerlendirin'
        END                                                        AS recommendation
    FROM large_tables lt
    LEFT JOIN ts_cols  tc ON tc.oid = lt.oid
    LEFT JOIN int_cols ic ON ic.oid = lt.oid
    ORDER BY lt.total_bytes DESC;
$$;

COMMENT ON FUNCTION query_advisor.partition_candidates IS
    'Büyük tabloları analiz eder; timestamp kolonlar için RANGE, '
    'integer/uuid kolonlar için HASH partitioning önerir. '
    'Hazır CREATE TABLE ... PARTITION BY DDL üretir.';

-- ==============================================================================
-- 4. INDEX ÖNERİ MOTORU
--    pg_stat_statements'taki yavaş/sık sorguları tarar, yüksek seq scan
--    olan tablolara değen sorguları bulur, WHERE koşullarından kolon
--    adayları çıkarır ve CREATE INDEX taslağı önerir.
--    NOT: Regex tabanlı analiz — alias/subquery içeren sorgularda
--         manuel doğrulama önerilir.
-- ==============================================================================

CREATE OR REPLACE FUNCTION query_advisor.index_recommendations(
    p_schema    text   DEFAULT NULL,
    p_min_calls bigint DEFAULT 10
)
RETURNS TABLE(
    schema_table        text,
    seq_scan_count      bigint,
    live_rows           bigint,
    candidate_columns   text,
    matching_queries    bigint,
    total_exec_time_ms  numeric,
    sample_query        text,
    existing_indexes    text,
    suggested_ddl       text,
    recommendation      text
)
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
AS $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_extension WHERE extname = 'pg_stat_statements'
    ) THEN
        RAISE NOTICE
            'pg_stat_statements gereklidir. '
            'shared_preload_libraries içine ekleyip CREATE EXTENSION çalıştırın.';
        RETURN;
    END IF;

    RETURN QUERY EXECUTE $dyn$
    WITH
    -- Yüksek seq scan olan tablolar
    seq_tbls AS (
        SELECT
            s.schemaname,
            s.relname,
            s.seq_scan,
            s.n_live_tup
        FROM pg_stat_user_tables s
        WHERE s.seq_scan > 50
          AND s.n_live_tup > 1000
          AND COALESCE(s.idx_scan, 0) < s.seq_scan
          AND ($1 IS NULL OR s.schemaname = $1)
    ),
    -- O tablolara dokunan sorgular
    matched_q AS (
        SELECT
            st.schemaname,
            st.relname,
            st.seq_scan,
            st.n_live_tup,
            pss.query,
            pss.calls,
            pss.total_exec_time
        FROM seq_tbls st
        JOIN pg_stat_statements pss
          ON  pss.query ~* ('\m' || st.relname || '\M')
          AND pss.calls    >= $2
          AND pss.query    ~* '\m(?:WHERE|AND|OR)\M'
    ),
    -- WHERE koşullarından kolon adayları çıkar
    candidates AS (
        SELECT
            schemaname,
            relname,
            seq_scan,
            n_live_tup,
            query,
            calls,
            total_exec_time,
            array_agg(DISTINCT lower(m[1])) FILTER (
                WHERE m[1] !~* '^(select|from|where|and|or|not|null|true|false|'
                               'in|like|ilike|is|join|on|as|by|order|group|having|'
                               'limit|offset|case|when|then|else|end|exists|'
                               'between|all|any|some|distinct|union|except|'
                               'intersect|returning|into|set|update|delete|insert)$'
                  AND m[1] !~ '^\$'
            ) AS cols
        FROM matched_q,
             LATERAL regexp_matches(
                 query,
                 '(?:WHERE|AND|OR)\s+(?:\w+\.)?(\w+)\s*'
                 '(?:[=<>!]{1,2}|~~\*?|!~~\*?|\mLIKE\M|\mILIKE\M'
                 '|\mIS\M|\mIN\M|\mBETWEEN\M)',
                 'gi'
             ) AS m
        GROUP BY schemaname, relname, seq_scan, n_live_tup,
                 query, calls, total_exec_time
    ),
    -- Mevcut indexler
    existing AS (
        SELECT
            s.schemaname,
            s.relname,
            string_agg(
                s.indexrelname || '('
                || array_to_string(
                       ARRAY(
                           SELECT a.attname
                           FROM   pg_attribute a
                           WHERE  a.attrelid = s.indexrelid
                             AND  a.attnum   > 0
                           ORDER  BY a.attnum
                       ),
                       ','
                   )
                || ')',
                ' | '
            ) AS idx_list
        FROM pg_stat_user_indexes s
        GROUP BY s.schemaname, s.relname
    )
    SELECT
        (c.schemaname || '.' || c.relname)::text,
        c.seq_scan,
        c.n_live_tup,
        array_to_string(c.cols, ', ')::text,
        count(*)::bigint,
        round(sum(c.total_exec_time)::numeric, 0),
        left(max(c.query), 250)::text,
        COALESCE(e.idx_list, 'index yok')::text,
        -- Önerilen DDL
        CASE
            WHEN c.cols IS NOT NULL AND array_length(c.cols, 1) >= 2 THEN
                'CREATE INDEX CONCURRENTLY idx_'
                || c.relname || '_' || array_to_string(c.cols[1:2], '_')
                || chr(10)
                || '  ON ' || quote_ident(c.schemaname) || '.'
                || quote_ident(c.relname)
                || ' (' || array_to_string(c.cols[1:2], ', ') || ');'
                || chr(10)
                || '-- Tek kolon alternatifi:'
                || chr(10)
                || 'CREATE INDEX CONCURRENTLY idx_'
                || c.relname || '_' || c.cols[1]
                || ' ON ' || quote_ident(c.schemaname) || '.'
                || quote_ident(c.relname)
                || ' (' || c.cols[1] || ');'
            WHEN c.cols IS NOT NULL AND array_length(c.cols, 1) = 1 THEN
                'CREATE INDEX CONCURRENTLY idx_'
                || c.relname || '_' || c.cols[1]
                || chr(10)
                || '  ON ' || quote_ident(c.schemaname) || '.'
                || quote_ident(c.relname)
                || ' (' || c.cols[1] || ');'
            ELSE
                'Kolon tespit edilemedi — EXPLAIN ANALYZE ile sorguyu manuel inceleyin'
        END,
        CASE
            WHEN c.seq_scan > 10000 THEN 'HIGH: çok yüksek seq scan — acil index ekleyin'
            WHEN c.seq_scan > 1000  THEN 'MEDIUM: yüksek seq scan — index değerlendirin'
            ELSE                         'LOW: düşük seq scan — izleyin'
        END
    FROM candidates c
    LEFT JOIN existing e ON e.schemaname = c.schemaname AND e.relname = c.relname
    GROUP BY c.schemaname, c.relname, c.seq_scan, c.n_live_tup,
             c.cols, e.idx_list
    ORDER BY c.seq_scan DESC
    $dyn$ USING p_schema, p_min_calls;
END;
$$;

COMMENT ON FUNCTION query_advisor.index_recommendations IS
    'pg_stat_statements ile yüksek seq scan tablolarını çapraz tarar. '
    'WHERE koşullarından regex ile kolon adayları çıkarır ve '
    'CREATE INDEX CONCURRENTLY taslakları önerir. '
    'Alias veya subquery içeren sorgularda manuel doğrulama önerilir.';
