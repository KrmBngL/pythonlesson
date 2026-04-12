-- pg_query_advisor--1.2--1.3.sql
-- Upgrade: 1.2 → 1.3
-- Yeni: sequence_health, fk_without_index, connection_stats,
--       temp_file_stats, vacuum_progress

-- ==============================================================================
-- 1. SEQUENCE HEALTH
--    Tasman esigine yaklasan sequence'lar: integer overflow → INSERT HATASI.
--    Fark edilmesi cok zordur; production'da beklenmedik an patlayabilir.
-- ==============================================================================

CREATE OR REPLACE FUNCTION query_advisor.sequence_health(
    p_schema        text    DEFAULT NULL,
    p_pct_warn      numeric DEFAULT 75,
    p_pct_critical  numeric DEFAULT 90
)
RETURNS TABLE(
    schema_name      text,
    sequence_name    text,
    data_type        text,
    current_value    bigint,
    min_value        bigint,
    max_value        bigint,
    increment_by     bigint,
    is_cycled        boolean,
    used_pct         numeric,
    remaining_values bigint,
    risk_level       text,
    recommendation   text
)
LANGUAGE sql
STABLE
SECURITY INVOKER
AS $$
    SELECT
        n.nspname::text,
        s.relname::text,
        CASE p.seqtypid
            WHEN 'int2'::regtype THEN 'smallint'
            WHEN 'int4'::regtype THEN 'integer'
            WHEN 'int8'::regtype THEN 'bigint'
            ELSE p.seqtypid::regtype::text
        END,
        p.seqstart + (p.seqlast - p.seqstart)   AS current_value,
        p.seqmin,
        p.seqmax,
        p.seqincrement,
        p.seqcycle,
        -- Kullanilanpct
        round(
            CASE WHEN p.seqmax - p.seqmin > 0
                 THEN (p.seqlast - p.seqmin)::numeric
                      / (p.seqmax - p.seqmin) * 100
                 ELSE 100
            END, 2
        )                                        AS used_pct,
        GREATEST(p.seqmax - p.seqlast, 0)        AS remaining_values,
        CASE
            WHEN p.seqcycle                      THEN 'OK: cycle aktif'
            WHEN (p.seqlast - p.seqmin)::numeric
                 / NULLIF(p.seqmax - p.seqmin, 0) >= p_pct_critical / 100.0
                THEN 'CRITICAL'
            WHEN (p.seqlast - p.seqmin)::numeric
                 / NULLIF(p.seqmax - p.seqmin, 0) >= p_pct_warn / 100.0
                THEN 'WARNING'
            ELSE 'OK'
        END,
        CASE
            WHEN p.seqcycle
                THEN 'Cycle aktif — overflow olmaz ama deger tekrari riski var'
            WHEN p.seqtypid = 'int4'::regtype
                 AND (p.seqlast - p.seqmin)::numeric
                     / NULLIF(p.seqmax - p.seqmin, 0) >= p_pct_warn / 100.0
                THEN 'integer tipini bigint''e yukselt: '
                     || 'ALTER SEQUENCE ' || quote_ident(n.nspname) || '.' || quote_ident(s.relname)
                     || ' AS bigint;'
                     || ' -- Bagli kolonu da degistirin: ALTER TABLE ... ALTER COLUMN id TYPE bigint;'
            WHEN (p.seqlast - p.seqmin)::numeric
                 / NULLIF(p.seqmax - p.seqmin, 0) >= p_pct_warn / 100.0
                THEN 'Bos deger: ' || (p.seqmax - p.seqlast)::text
                     || ' — yakin zamanda: ALTER SEQUENCE ... MAXVALUE <yeni_deger>;'
            ELSE NULL
        END
    FROM pg_class        s
    JOIN pg_namespace    n ON n.oid = s.relnamespace
    JOIN pg_sequence     p ON p.seqrelid = s.oid
    WHERE s.relkind = 'S'
      AND n.nspname NOT IN ('pg_catalog', 'information_schema')
      AND (p_schema IS NULL OR n.nspname = p_schema)
      AND NOT p.seqcycle
          OR (p.seqlast - p.seqmin)::numeric
             / NULLIF(p.seqmax - p.seqmin, 0) >= p_pct_warn / 100.0
    ORDER BY
        (p.seqlast - p.seqmin)::numeric
        / NULLIF(p.seqmax - p.seqmin, 0) DESC NULLS LAST;
$$;

COMMENT ON FUNCTION query_advisor.sequence_health IS
    'Tasman esigine yaklasan sequence''lari tespit eder. '
    'Integer overflow olunca INSERT islemi hata verir, uygulama cokebilir. '
    'p_pct_warn (default 75) ve p_pct_critical (default 90) ile esik ayarlanir.';

-- ==============================================================================
-- 2. FK WITHOUT INDEX
--    Parent tabloda DELETE/UPDATE yapilinca child tabloda full scan olur.
--    En sikca kacirilan performans sorunlarindan biri.
-- ==============================================================================

CREATE OR REPLACE FUNCTION query_advisor.fk_without_index(
    p_schema text DEFAULT NULL
)
RETURNS TABLE(
    schema_name        text,
    table_name         text,
    constraint_name    text,
    fk_columns         text,
    referenced_table   text,
    referenced_columns text,
    table_size         text,
    seq_scans          bigint,
    create_index_sql   text,
    recommendation     text
)
LANGUAGE sql
STABLE
SECURITY INVOKER
AS $$
    WITH fk_info AS (
        SELECT
            n.nspname                                            AS schema_name,
            c.relname                                            AS table_name,
            con.conname                                          AS constraint_name,
            -- FK kolonlari
            (   SELECT string_agg(a.attname, ', ' ORDER BY x.ord)
                FROM   unnest(con.conkey) WITH ORDINALITY AS x(num, ord)
                JOIN   pg_attribute a ON a.attrelid = c.oid AND a.attnum = x.num
            )                                                    AS fk_columns,
            -- FK kolonlari dizi olarak (index esleme icin)
            con.conkey                                           AS fk_attkeys,
            -- Referans alinan tablo
            rn.nspname || '.' || rc.relname                     AS referenced_table,
            (   SELECT string_agg(a.attname, ', ' ORDER BY x.ord)
                FROM   unnest(con.confkey) WITH ORDINALITY AS x(num, ord)
                JOIN   pg_attribute a ON a.attrelid = rc.oid AND a.attnum = x.num
            )                                                    AS referenced_columns,
            c.oid                                                AS table_oid,
            n.nspname                                            AS schema
        FROM pg_constraint  con
        JOIN pg_class        c  ON c.oid  = con.conrelid
        JOIN pg_namespace    n  ON n.oid  = c.relnamespace
        JOIN pg_class        rc ON rc.oid = con.confrelid
        JOIN pg_namespace    rn ON rn.oid = rc.relnamespace
        WHERE con.contype = 'f'
          AND n.nspname NOT IN ('pg_catalog', 'information_schema')
          AND (p_schema IS NULL OR n.nspname = p_schema)
    )
    SELECT
        fi.schema_name::text,
        fi.table_name::text,
        fi.constraint_name::text,
        fi.fk_columns::text,
        fi.referenced_table::text,
        fi.referenced_columns::text,
        pg_size_pretty(pg_total_relation_size(fi.table_oid)),
        COALESCE(pst.seq_scan, 0),
        'CREATE INDEX CONCURRENTLY idx_'
            || fi.table_name || '_' || replace(fi.fk_columns, ', ', '_')
            || ' ON ' || quote_ident(fi.schema_name) || '.' || quote_ident(fi.table_name)
            || ' (' || fi.fk_columns || ');'                    AS create_index_sql,
        'FK index eksik — parent silme/guncellemede full scan olur. '
            || 'seq_scan=' || COALESCE(pst.seq_scan, 0)::text   AS recommendation
    FROM fk_info fi
    LEFT JOIN pg_stat_user_tables pst
           ON pst.schemaname = fi.schema_name
          AND pst.relname    = fi.table_name
    WHERE NOT EXISTS (
        -- Ayni kolonlari leading key olarak iceren herhangi bir index
        SELECT 1
        FROM   pg_index     ix
        JOIN   pg_attribute ia
               ON ia.attrelid = ix.indrelid
              AND ia.attnum   = ix.indkey[0]        -- ilk kolon eslessin
        WHERE  ix.indrelid = fi.table_oid
          AND  ia.attnum   = fi.fk_attkeys[1]       -- FK'nin ilk kolonu
    )
    ORDER BY COALESCE(pst.seq_scan, 0) DESC, pg_total_relation_size(fi.table_oid) DESC;
$$;

COMMENT ON FUNCTION query_advisor.fk_without_index IS
    'Parent tabloda DELETE/UPDATE yapilinca child tabloda full table scan olmasina '
    'yol acan eksik FK index''lerini tespit eder. '
    'create_index_sql sutunu calistirmaya hazir CREATE INDEX CONCURRENTLY icermektedir.';

-- ==============================================================================
-- 3. CONNECTION STATS
--    Baglanti havuzunun anlık durumu: kim ne yapiyor, ne kadar boslukta bekliyor,
--    max_connections doluluk orani, uygulama bazli dagilim.
-- ==============================================================================

CREATE OR REPLACE FUNCTION query_advisor.connection_stats()
RETURNS TABLE(
    category         text,
    metric           text,
    value            text,
    pct_of_max       numeric,
    risk_level       text,
    detail           text
)
LANGUAGE sql
STABLE
SECURITY INVOKER
AS $$
    WITH totals AS (
        SELECT
            current_setting('max_connections')::int  AS max_conn,
            count(*)                                  AS total_conn,
            count(*) FILTER (WHERE state = 'active') AS active_conn,
            count(*) FILTER (WHERE state = 'idle')   AS idle_conn,
            count(*) FILTER (
                WHERE state IN ('idle in transaction',
                                'idle in transaction (aborted)')
            )                                         AS idle_txn,
            count(*) FILTER (WHERE wait_event IS NOT NULL
                               AND state = 'active')  AS waiting_conn,
            count(*) FILTER (WHERE backend_type = 'background worker')
                                                      AS bg_workers
        FROM pg_stat_activity
        WHERE backend_type NOT IN ('autovacuum launcher', 'walwriter',
                                   'background writer', 'checkpointer',
                                   'logical replication launcher')
    ),
    by_app AS (
        SELECT
            COALESCE(NULLIF(application_name,''), '(adsiz)') AS app,
            count(*)                                           AS cnt,
            count(*) FILTER (WHERE state = 'active')          AS active
        FROM pg_stat_activity
        WHERE backend_type = 'client backend'
        GROUP BY 1
        ORDER BY cnt DESC
        LIMIT 5
    )
    -- 1. Genel Ozet
    SELECT
        'GENEL' AS category,
        'Toplam baglanti'  AS metric,
        t.total_conn::text AS value,
        round(t.total_conn::numeric / t.max_conn * 100, 1),
        CASE
            WHEN t.total_conn::numeric / t.max_conn >= 0.9 THEN 'CRITICAL'
            WHEN t.total_conn::numeric / t.max_conn >= 0.7 THEN 'WARNING'
            ELSE 'OK'
        END,
        'max_connections = ' || t.max_conn
    FROM totals t

    UNION ALL SELECT 'GENEL', 'Aktif sorgu',   t.active_conn::text,
        round(t.active_conn::numeric / t.max_conn * 100, 1),
        CASE WHEN t.active_conn > t.max_conn * 0.5 THEN 'WARNING' ELSE 'OK' END,
        'Su an sorgu calistiran backend sayisi'
    FROM totals t

    UNION ALL SELECT 'GENEL', 'Idle baglanti', t.idle_conn::text,
        round(t.idle_conn::numeric / t.max_conn * 100, 1),
        CASE WHEN t.idle_conn > 50 THEN 'WARNING' ELSE 'OK' END,
        'Sorgu beklemeyen, bos duran bağlantilar — PgBouncer onerilir'
    FROM totals t

    UNION ALL SELECT 'GENEL', 'Idle in transaction', t.idle_txn::text,
        round(t.idle_txn::numeric / NULLIF(t.total_conn,0) * 100, 1),
        CASE WHEN t.idle_txn > 0 THEN 'WARNING' ELSE 'OK' END,
        'Acik kalmis transaction — autovacuum engeli, lock biriktirici'
    FROM totals t

    UNION ALL SELECT 'GENEL', 'Lock bekleyen', t.waiting_conn::text,
        NULL,
        CASE WHEN t.waiting_conn > 0 THEN 'WARNING' ELSE 'OK' END,
        'wait_event != NULL olan aktif sessionlar'
    FROM totals t

    -- 2. Uygulama bazli dagilim (top 5)
    UNION ALL
    SELECT
        'UYGULAMA',
        a.app,
        a.cnt::text,
        round(a.cnt::numeric / (SELECT max_conn FROM totals) * 100, 1),
        CASE WHEN a.cnt::numeric / (SELECT max_conn FROM totals) > 0.3
             THEN 'WARNING' ELSE 'OK' END,
        'Aktif: ' || a.active::text || ' / Toplam: ' || a.cnt::text
    FROM by_app a

    -- 3. Kullanici bazli (en cok baglanan 5 kullanici)
    UNION ALL
    SELECT
        'KULLANICI',
        usename::text,
        count(*)::text,
        round(count(*)::numeric / (SELECT max_conn FROM totals) * 100, 1),
        CASE WHEN count(*)::numeric / (SELECT max_conn FROM totals) > 0.3
             THEN 'WARNING' ELSE 'OK' END,
        'Aktif: ' || count(*) FILTER (WHERE state='active')::text
    FROM pg_stat_activity
    WHERE backend_type = 'client backend'
    GROUP BY usename
    ORDER BY count(*) DESC
    LIMIT 5;
$$;

COMMENT ON FUNCTION query_advisor.connection_stats IS
    'Baglanti havuzunun anlik durumunu gosterir: toplam/aktif/idle/idle-in-transaction '
    'sayilari, max_connections doluluk orani, uygulama ve kullanici bazli dagilim. '
    'max_connections dolulugunda CRITICAL uyarisi verir.';

-- ==============================================================================
-- 4. TEMP FILE STATS
--    work_mem yetersizligini gostergeler: disk''e sort/hash spill.
--    Suradan goruntulenir: pg_stat_database + pg_stat_statements
-- ==============================================================================

CREATE OR REPLACE FUNCTION query_advisor.temp_file_stats(
    p_top_n int DEFAULT 10
)
RETURNS TABLE(
    category             text,
    database_name        text,
    total_temp_files     bigint,
    total_temp_size      text,
    work_mem_current     text,
    sort_mem_multiplier  numeric,
    risk_level           text,
    recommendation       text
)
LANGUAGE sql
STABLE
SECURITY INVOKER
AS $$
    -- Veritabani seviyesinde temp file ozeti (pg_stat_database)
    SELECT
        'DATABASE'                                   AS category,
        datname::text,
        temp_files,
        pg_size_pretty(temp_bytes),
        current_setting('work_mem'),
        -- Kac work_mem birimlik temp gozuyor?
        CASE WHEN pg_size_bytes(current_setting('work_mem')) > 0
             THEN round(temp_bytes::numeric
                        / pg_size_bytes(current_setting('work_mem'))::numeric, 1)
             ELSE NULL
        END,
        CASE
            WHEN temp_files > 10000 THEN 'CRITICAL'
            WHEN temp_files > 1000  THEN 'WARNING'
            WHEN temp_files > 0     THEN 'NOTICE'
            ELSE 'OK'
        END,
        CASE
            WHEN temp_files > 1000
                THEN 'work_mem artirin veya sorgu planini optimize edin. '
                     || 'Su an: ' || current_setting('work_mem')
                     || ' — Onerilen: en az '
                     || pg_size_pretty(
                            LEAST(
                                pg_size_bytes(current_setting('work_mem')) * 4,
                                256 * 1024 * 1024
                            )::bigint
                        )
            WHEN temp_files > 0
                THEN 'Bazi sorgular disk''e spill etti. '
                     || 'EXPLAIN ANALYZE ile sort/hash node''larini inceleyin.'
            ELSE 'Temp file yok — work_mem yeterli gorunuyor'
        END
    FROM pg_stat_database
    WHERE datname NOT IN ('template0', 'template1')
      AND temp_files > 0
    ORDER BY temp_files DESC
    LIMIT p_top_n
    ;
$$;

COMMENT ON FUNCTION query_advisor.temp_file_stats IS
    'pg_stat_database uzerinden veritabani bazinda temp file kullanimini gosterir. '
    'Yuksek temp_files degeri work_mem yetersizligini isaret eder. '
    'EXPLAIN ANALYZE ile sort/hash node''larindaki disk spill tespit edilebilir.';

-- ==============================================================================
-- 5. VACUUM PROGRESS
--    Halihazirda calisan VACUUM / ANALYZE islemlerinin ilerlemesi.
--    Buyuk tablolarda saatler surebilir; bu fonksiyon ilerlemeyi gosterir.
-- ==============================================================================

CREATE OR REPLACE FUNCTION query_advisor.vacuum_progress()
RETURNS TABLE(
    pid                  int,
    operation            text,
    schema_name          text,
    table_name           text,
    phase                text,
    heap_blks_total      bigint,
    heap_blks_scanned    bigint,
    heap_blks_vacuumed   bigint,
    progress_pct         numeric,
    index_vacuum_count   bigint,
    dead_tuples_found    bigint,
    dead_tuples_removed  bigint,
    duration_seconds     numeric,
    is_autovacuum        boolean,
    recommendation       text
)
LANGUAGE sql
STABLE
SECURITY INVOKER
AS $$
    SELECT
        v.pid,
        CASE WHEN a.query ILIKE 'autovacuum:%' THEN 'AUTOVACUUM'
             WHEN a.query ILIKE '%analyze%'    THEN 'ANALYZE'
             ELSE 'VACUUM'
        END                                                         AS operation,
        v.relid::regclass::text                                     AS full_name,
        n.nspname::text,
        c.relname::text,
        v.phase::text,
        v.heap_blks_total,
        v.heap_blks_scanned,
        v.heap_blks_vacuumed,
        CASE WHEN v.heap_blks_total > 0
             THEN round(v.heap_blks_vacuumed::numeric
                        / v.heap_blks_total * 100, 1)
             ELSE 0
        END                                                         AS progress_pct,
        v.index_vacuum_count,
        v.num_dead_tuples,
        v.num_dead_tuples                                           AS dead_removed,  -- approx at this phase
        round(EXTRACT(EPOCH FROM (now() - a.xact_start))::numeric, 0),
        a.query ILIKE 'autovacuum:%'                                AS is_autovacuum,
        CASE
            WHEN v.heap_blks_total > 0
                 AND v.heap_blks_vacuumed::numeric
                     / v.heap_blks_total < 0.1
                 AND EXTRACT(EPOCH FROM (now() - a.xact_start)) > 3600
                THEN 'UYARI: 1 saatten uzun suredir calisiyor, ilerleme <%10 — blokaj var mi?'
            WHEN a.query ILIKE 'autovacuum:%'
                THEN 'Autovacuum calisiyor — normalse mudahale etmeyin'
            ELSE 'Manuel VACUUM calisiyor'
        END
    FROM pg_stat_progress_vacuum v
    JOIN pg_class       c ON c.oid = v.relid
    JOIN pg_namespace   n ON n.oid = c.relnamespace
    JOIN pg_stat_activity a ON a.pid = v.pid
    ORDER BY EXTRACT(EPOCH FROM (now() - a.xact_start)) DESC;
$$;

COMMENT ON FUNCTION query_advisor.vacuum_progress IS
    'Halihazirda calisan VACUUM ve AUTOVACUUM islemlerinin ilerleme durumunu gosterir. '
    'pg_stat_progress_vacuum kullanir. Buyuk tablolarda saatler surebilen '
    'vacuum''larda yuzde ilerleme ve sure takibi saglar.';
