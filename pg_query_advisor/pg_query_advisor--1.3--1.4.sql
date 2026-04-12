-- pg_query_advisor--1.3--1.4.sql
-- Upgrade: 1.3 → 1.4
-- Yeni: tablespace_usage, toast_analysis, deadlock_stats, buffercache_top

-- ==============================================================================
-- 1. TABLESPACE USAGE
--    Hangi tablespace ne kadar disk kullaniyor, icerisinde kac nesne var,
--    bos veya cok buyuk tablespace varsa uyariyor.
-- ==============================================================================

CREATE OR REPLACE FUNCTION query_advisor.tablespace_usage()
RETURNS TABLE(
    tablespace_name  text,
    location         text,
    total_size       text,
    total_size_bytes bigint,
    object_count     bigint,
    table_count      bigint,
    index_count      bigint,
    risk_level       text,
    recommendation   text
)
LANGUAGE sql
STABLE
SECURITY INVOKER
AS $$
    WITH ts_data AS (
        SELECT
            t.oid,
            t.spcname,
            pg_tablespace_location(t.oid)                        AS location,
            CASE WHEN t.spcname != 'pg_global'
                 THEN pg_tablespace_size(t.oid)
                 ELSE 0::bigint
            END                                                  AS ts_size,
            count(c.oid)                                         AS obj_count,
            count(c.oid) FILTER (WHERE c.relkind = 'r')         AS tbl_count,
            count(c.oid) FILTER (WHERE c.relkind = 'i')         AS idx_count
        FROM pg_tablespace t
        LEFT JOIN pg_class c ON c.reltablespace = t.oid
        GROUP BY t.oid, t.spcname
    )
    SELECT
        spcname::text,
        COALESCE(NULLIF(location, ''), '(PGDATA/base — pg_default)')::text,
        pg_size_pretty(ts_size),
        ts_size,
        obj_count,
        tbl_count,
        idx_count,
        CASE
            WHEN ts_size > 100::bigint * 1024 * 1024 * 1024 THEN 'WARNING'
            WHEN obj_count = 0
                 AND spcname NOT IN ('pg_default', 'pg_global') THEN 'NOTICE'
            ELSE 'OK'
        END,
        CASE
            WHEN ts_size > 100::bigint * 1024 * 1024 * 1024
                THEN 'Tablespace > 100 GB — disk dolulugunu izleyin: df -h ' || COALESCE(NULLIF(location,''), '/var/lib/pgsql')
            WHEN obj_count = 0
                 AND spcname NOT IN ('pg_default', 'pg_global')
                THEN 'Bos tablespace — kullanilmiyorsa: DROP TABLESPACE ' || spcname
            ELSE 'OK'
        END
    FROM ts_data
    ORDER BY ts_size DESC;
$$;

COMMENT ON FUNCTION query_advisor.tablespace_usage IS
    'Tum tablespace''lerin disk kullanimi, nesne sayisi ve risk durumunu gosterir. '
    'Bos tablespace''ler ve 100 GB uzerindekiler icin oneri uretir.';

-- ==============================================================================
-- 2. TOAST ANALYSIS
--    TEXT, JSONB, BYTEA, XML gibi genis sütunlar TOAST tablosuna tasma yaptıginda
--    bu tablo gizlice sisebilir. Asil tabloyu VACUUM yapinca TOAST temizlenmez,
--    VACUUM FULL gerekir ya da alan geri alinmaz.
-- ==============================================================================

CREATE OR REPLACE FUNCTION query_advisor.toast_analysis(
    p_schema       text    DEFAULT NULL,
    p_min_toast_mb numeric DEFAULT 1
)
RETURNS TABLE(
    schema_name      text,
    table_name       text,
    heap_size        text,
    toast_size       text,
    total_size       text,
    toast_pct        numeric,
    live_tuples      bigint,
    toast_table      text,
    has_wide_cols    boolean,
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
        pg_size_pretty(pg_relation_size(c.oid)),
        pg_size_pretty(pg_relation_size(t.oid)),
        pg_size_pretty(pg_total_relation_size(c.oid)),
        round(
            pg_relation_size(t.oid)::numeric
            / NULLIF(pg_total_relation_size(c.oid), 0) * 100, 1
        )                                                       AS toast_pct,
        COALESCE(s.n_live_tup, 0),
        t.relname::text,
        -- Genis tip kolonu var mi? (text, jsonb, bytea, xml, varchar, hstore, tsvector)
        EXISTS(
            SELECT 1 FROM pg_attribute a
            WHERE a.attrelid = c.oid
              AND a.atttypid IN (
                  'text'::regtype,   'jsonb'::regtype,
                  'json'::regtype,   'bytea'::regtype,
                  'xml'::regtype,    'varchar'::regtype,
                  'tsvector'::regtype
              )
              AND a.attnum > 0 AND NOT a.attisdropped
        )                                                       AS has_wide_cols,
        CASE
            WHEN pg_relation_size(t.oid)::numeric
                 / NULLIF(pg_total_relation_size(c.oid), 0) >= 0.5
                THEN 'WARNING'
            WHEN pg_relation_size(t.oid) >= 1::bigint * 1024 * 1024 * 1024
                THEN 'NOTICE'
            ELSE 'OK'
        END,
        CASE
            WHEN pg_relation_size(t.oid)::numeric
                 / NULLIF(pg_total_relation_size(c.oid), 0) >= 0.5
                THEN 'TOAST boyutu tablonun %' ||
                     round(pg_relation_size(t.oid)::numeric
                           / NULLIF(pg_total_relation_size(c.oid),0) * 100, 0)::text
                     || ''''
                     || ' — VACUUM FULL ile geri alabilirsiniz (tablo kilitlenir!)'
                     || ' veya pg_repack kullanin'
            WHEN pg_relation_size(t.oid) >= 1::bigint * 1024 * 1024 * 1024
                THEN 'TOAST > 1 GB — VACUUM ANALYZE ' || n.nspname || '.' || c.relname
            ELSE 'TOAST boyutu normal'
        END
    FROM pg_class       c
    JOIN pg_namespace   n ON n.oid = c.relnamespace
    JOIN pg_class       t ON t.oid = c.reltoastrelid
    LEFT JOIN pg_stat_user_tables s
           ON s.schemaname = n.nspname AND s.relname = c.relname
    WHERE c.relkind = 'r'
      AND c.reltoastrelid <> 0
      AND pg_relation_size(t.oid) >= p_min_toast_mb * 1024 * 1024
      AND n.nspname NOT IN ('pg_catalog', 'information_schema')
      AND (p_schema IS NULL OR n.nspname = p_schema)
    ORDER BY pg_relation_size(t.oid) DESC;
$$;

COMMENT ON FUNCTION query_advisor.toast_analysis IS
    'TEXT/JSONB/BYTEA gibi genis sütunlarin TOAST tablosundaki boyutunu analiz eder. '
    'TOAST boyutu tablonun %50''sini gecerse uyari uretir; VACUUM FULL veya pg_repack onerir. '
    'p_min_toast_mb: minimum TOAST boyutu filtresi (varsayilan 1 MB).';

-- ==============================================================================
-- 3. DEADLOCK STATS
--    pg_stat_database.deadlocks ile veritabani basina kumulatif deadlock sayisi.
--    Ayrica mevcut lock bekleme zinciri ozeti.
-- ==============================================================================

CREATE OR REPLACE FUNCTION query_advisor.deadlock_stats()
RETURNS TABLE(
    database_name      text,
    deadlocks_total    bigint,
    conflicts_total    bigint,
    blk_read_time_ms   numeric,
    blk_write_time_ms  numeric,
    stats_reset        timestamptz,
    current_lock_waits bigint,
    risk_level         text,
    recommendation     text
)
LANGUAGE sql
STABLE
SECURITY INVOKER
AS $$
    WITH lock_waits AS (
        SELECT count(*) AS cnt
        FROM pg_locks l
        WHERE NOT l.granted
    )
    SELECT
        d.datname::text,
        d.deadlocks,
        d.conflicts,
        round(d.blk_read_time::numeric,  1),
        round(d.blk_write_time::numeric, 1),
        d.stats_reset,
        lw.cnt,
        CASE
            WHEN d.deadlocks > 100   THEN 'CRITICAL'
            WHEN d.deadlocks > 10    THEN 'WARNING'
            WHEN d.deadlocks > 0     THEN 'NOTICE'
            WHEN lw.cnt > 0          THEN 'NOTICE'
            ELSE 'OK'
        END,
        CASE
            WHEN d.deadlocks > 100
                THEN 'Cok yuksek deadlock! Transaction sirasini standartlastirin. '
                     || 'SELECT FOR UPDATE islemlerini hep ayni sirada yapin. '
                     || 'pg_log dosyasinda DETAIL: Process ... waits for ... satirlarini arayin.'
            WHEN d.deadlocks > 10
                THEN 'Tekrarlayan deadlock — lock_waits() ile bloklayan sorgulari tespit edin. '
                     || 'deadlock_timeout parametresini gozden gecirin.'
            WHEN d.deadlocks > 0
                THEN 'Az sayida deadlock (' || d.deadlocks || ') — '
                     || 'istatistik baslangici: ' || to_char(d.stats_reset, 'DD.MM.YYYY')
            WHEN lw.cnt > 0
                THEN lw.cnt::text || ' lock bekleniyor — query_advisor.lock_waits() ile inceleyin'
            ELSE 'Deadlock yok, lock bekleme yok'
        END
    FROM pg_stat_database d,
         lock_waits lw
    WHERE d.datname NOT IN ('template0', 'template1')
    ORDER BY d.deadlocks DESC, d.datname;
$$;

COMMENT ON FUNCTION query_advisor.deadlock_stats IS
    'Veritabani basina kumulatif deadlock ve conflict sayilarini gosterir (pg_stat_database). '
    'Mevcut lock bekleyen transaction sayisini da ekler. '
    'CRITICAL: >100 deadlock, WARNING: >10 deadlock.';

-- ==============================================================================
-- 4. BUFFER CACHE TOP
--    Buffer cache''de en cok yer kaplayan nesneler.
--    pg_buffercache extension varsa gercek zamanli doluluk gosterir;
--    yoksa pg_statio_user_tables ile kumulatif hit istatistigi kullanir.
-- ==============================================================================

CREATE OR REPLACE FUNCTION query_advisor.buffercache_top(
    p_top_n  int  DEFAULT 20,
    p_schema text DEFAULT NULL
)
RETURNS TABLE(
    schema_name        text,
    object_name        text,
    object_type        text,
    buffers_used       bigint,
    buffer_size        text,
    pct_of_cache       numeric,
    dirty_buffers      bigint,
    object_size        text,
    cache_coverage_pct numeric,
    source             text,
    recommendation     text
)
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
AS $$
DECLARE
    v_has_bc  boolean;
    v_blksz   bigint;
    v_total   bigint;
BEGIN
    SELECT EXISTS(
        SELECT 1 FROM pg_extension WHERE extname = 'pg_buffercache'
    ) INTO v_has_bc;

    v_blksz := current_setting('block_size')::bigint;

    IF v_has_bc THEN
        -- Gercek zamanli buffer dolulugu
        SELECT count(*) INTO v_total FROM pg_buffercache;

        RETURN QUERY
        SELECT
            n.nspname::text,
            c.relname::text,
            CASE c.relkind
                WHEN 'r' THEN 'TABLE'
                WHEN 'i' THEN 'INDEX'
                WHEN 't' THEN 'TOAST'
                ELSE c.relkind::text
            END::text,
            count(*)::bigint                                  AS buffers_used,
            pg_size_pretty(count(*) * v_blksz)               AS buffer_size,
            round(count(*)::numeric / NULLIF(v_total, 0) * 100, 2)
                                                              AS pct_of_cache,
            count(*) FILTER (WHERE b.isdirty)::bigint        AS dirty_buffers,
            pg_size_pretty(pg_total_relation_size(c.oid))    AS object_size,
            round(
                count(*) * v_blksz::numeric
                / NULLIF(pg_total_relation_size(c.oid), 0) * 100, 1
            )                                                 AS cache_coverage_pct,
            'pg_buffercache (gercek zamanli)'::text          AS source,
            CASE
                WHEN round(
                    count(*) * v_blksz::numeric
                    / NULLIF(pg_total_relation_size(c.oid), 0) * 100, 1
                ) > 90
                    THEN 'Tablo neredeyse tamamen cache''de — sorgu performansi iyi olmali'
                WHEN round(
                    count(*) * v_blksz::numeric
                    / NULLIF(pg_total_relation_size(c.oid), 0) * 100, 1
                ) < 10
                    THEN 'Tablonun yalnizca %' ||
                         round(count(*) * v_blksz::numeric
                               / NULLIF(pg_total_relation_size(c.oid), 0) * 100, 1)::text
                         || ''''
                         || ' cache''de — yuksek disk I/O beklenir; shared_buffers artirmayi deneyin'
                ELSE 'Kismi cache — normal'
            END::text
        FROM pg_buffercache b
        JOIN pg_class     c ON c.relfilenode = b.relfilenode
                            AND b.reldatabase IN (
                                0,
                                (SELECT oid FROM pg_database
                                 WHERE datname = current_database())
                            )
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE b.relfilenode IS NOT NULL
          AND c.relkind IN ('r', 'i', 't')
          AND n.nspname NOT IN ('pg_catalog', 'information_schema')
          AND (p_schema IS NULL OR n.nspname = p_schema)
        GROUP BY n.nspname, c.relname, c.relkind, c.oid
        ORDER BY count(*) DESC
        LIMIT p_top_n;

    ELSE
        -- Fallback: pg_statio ile kumulatif hit sayisina gore siralama
        RETURN QUERY
        SELECT
            s.schemaname::text,
            s.relname::text,
            'TABLE'::text,
            COALESCE(s.heap_blks_hit, 0)                              AS buffers_used,
            pg_size_pretty(COALESCE(s.heap_blks_hit, 0) * v_blksz)   AS buffer_size,
            NULL::numeric                                              AS pct_of_cache,
            NULL::bigint                                               AS dirty_buffers,
            pg_size_pretty(pg_total_relation_size(
                quote_ident(s.schemaname) || '.' || quote_ident(s.relname)
            ))                                                         AS object_size,
            round(
                COALESCE(s.heap_blks_hit, 0)::numeric
                / NULLIF(COALESCE(s.heap_blks_hit,0)
                         + COALESCE(s.heap_blks_read,0), 0) * 100, 1
            )                                                          AS cache_coverage_pct,
            'pg_statio (kumulatif — pg_buffercache kurulu degil)'::text AS source,
            'Gercek zamanli buffer analizi icin: CREATE EXTENSION pg_buffercache; '
            || 'Simdilik kumulatif heap_blks_hit gosteriliyor.'::text  AS recommendation
        FROM pg_statio_user_tables s
        WHERE (p_schema IS NULL OR s.schemaname = p_schema)
          AND COALESCE(s.heap_blks_hit, 0) + COALESCE(s.heap_blks_read, 0) > 0
        ORDER BY COALESCE(s.heap_blks_hit, 0) DESC
        LIMIT p_top_n;
    END IF;
END;
$$;

COMMENT ON FUNCTION query_advisor.buffercache_top IS
    'Buffer cache''de en cok yer kaplayan nesneleri gosterir. '
    'pg_buffercache extension kuruluysa gercek zamanli blok dolulugu gosterir; '
    'kurulu degilse pg_statio_user_tables ile kumulatif hit istatistigi kullanir. '
    'cache_coverage_pct: tablonun kac yuzdesi su an buffer cache''de oldugunu gosterir.';
