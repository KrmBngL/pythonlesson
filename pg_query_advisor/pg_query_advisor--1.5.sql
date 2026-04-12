-- pg_query_advisor--1.5.sql
-- PostgreSQL Query Advisor Extension v1.5
-- Compatible with PostgreSQL 17 / 18 — RHEL 8 / RHEL 9


\echo Use "CREATE EXTENSION pg_query_advisor" to load this file. \quit

-- ==============================================================================
-- SCHEMA
-- ==============================================================================

CREATE SCHEMA IF NOT EXISTS query_advisor;

-- ==============================================================================
-- 1. TABLE HEALTH
--    Dead tuple ratio, last vacuum/analyze timestamps, health status
-- ==============================================================================

CREATE OR REPLACE FUNCTION query_advisor.table_health(
    p_schema         text    DEFAULT NULL,
    p_min_dead_tup   bigint  DEFAULT 0
)
RETURNS TABLE(
    schema_name        text,
    table_name         text,
    live_tuples        bigint,
    dead_tuples        bigint,
    dead_ratio_pct     numeric,
    table_size         text,
    last_vacuum        timestamptz,
    last_autovacuum    timestamptz,
    last_analyze       timestamptz,
    last_autoanalyze   timestamptz,
    vacuum_count       bigint,
    autovacuum_count   bigint,
    health_status      text
)
LANGUAGE sql
STABLE
SECURITY INVOKER
AS $$
    SELECT
        s.schemaname::text,
        s.relname::text,
        s.n_live_tup,
        s.n_dead_tup,
        CASE WHEN (s.n_live_tup + s.n_dead_tup) > 0
             THEN round(s.n_dead_tup::numeric /
                        (s.n_live_tup + s.n_dead_tup)::numeric * 100, 2)
             ELSE 0
        END                                                                  AS dead_ratio_pct,
        pg_size_pretty(
            pg_total_relation_size(
                quote_ident(s.schemaname) || '.' || quote_ident(s.relname)
            )
        )                                                                    AS table_size,
        s.last_vacuum,
        s.last_autovacuum,
        s.last_analyze,
        s.last_autoanalyze,
        s.vacuum_count,
        s.autovacuum_count,
        CASE
            WHEN (s.n_live_tup + s.n_dead_tup) > 0 AND
                 s.n_dead_tup::numeric / (s.n_live_tup + s.n_dead_tup)::numeric > 0.20
                THEN 'CRITICAL: dead tuple ratio >20% — run VACUUM ANALYZE immediately'
            WHEN (s.n_live_tup + s.n_dead_tup) > 0 AND
                 s.n_dead_tup::numeric / (s.n_live_tup + s.n_dead_tup)::numeric > 0.10
                THEN 'WARNING: dead tuple ratio >10% — schedule VACUUM ANALYZE'
            WHEN s.last_autovacuum IS NULL AND s.last_vacuum IS NULL
                 AND s.n_live_tup > 1000
                THEN 'WARNING: table has never been vacuumed'
            WHEN s.last_autoanalyze IS NULL AND s.last_analyze IS NULL
                 AND s.n_live_tup > 1000
                THEN 'WARNING: table has never been analyzed'
            WHEN s.last_autovacuum < now() - interval '7 days'
                 AND s.n_dead_tup > 10000
                THEN 'NOTICE: no autovacuum in 7 days with significant dead tuples'
            ELSE 'OK'
        END                                                                  AS health_status
    FROM pg_stat_user_tables s
    WHERE (p_schema IS NULL OR s.schemaname = p_schema)
      AND s.n_dead_tup >= p_min_dead_tup
    ORDER BY s.n_dead_tup DESC, s.n_live_tup DESC;
$$;

COMMENT ON FUNCTION query_advisor.table_health IS
    'Dead tuple ratio, vacuum/analyze timestamps and health status for user tables.';

-- ==============================================================================
-- 2. INDEX USAGE
--    Scans, tuples read/fetched, size per index
-- ==============================================================================

CREATE OR REPLACE FUNCTION query_advisor.index_usage(
    p_schema text DEFAULT NULL
)
RETURNS TABLE(
    schema_name     text,
    table_name      text,
    index_name      text,
    index_scans     bigint,
    tuples_read     bigint,
    tuples_fetched  bigint,
    index_size      text,
    usage_status    text
)
LANGUAGE sql
STABLE
SECURITY INVOKER
AS $$
    SELECT
        i.schemaname::text,
        i.relname::text,
        i.indexrelname::text,
        i.idx_scan,
        i.idx_tup_read,
        i.idx_tup_fetch,
        pg_size_pretty(pg_relation_size(i.indexrelid)),
        CASE
            WHEN i.idx_scan = 0   THEN 'UNUSED — consider DROP INDEX CONCURRENTLY'
            WHEN i.idx_scan < 50  THEN 'RARELY USED — monitor'
            WHEN i.idx_scan < 500 THEN 'LOW USAGE'
            ELSE                       'ACTIVE'
        END
    FROM pg_stat_user_indexes i
    WHERE (p_schema IS NULL OR i.schemaname = p_schema)
    ORDER BY i.idx_scan ASC,
             pg_relation_size(i.indexrelid) DESC;
$$;

COMMENT ON FUNCTION query_advisor.index_usage IS
    'Index scan counts, tuples read/fetched and usage classification.';

-- ==============================================================================
-- 3. MISSING INDEXES
--    Tables with sequential scans >> index scans
-- ==============================================================================

CREATE OR REPLACE FUNCTION query_advisor.missing_indexes(
    p_schema        text   DEFAULT NULL,
    p_min_seq_scan  bigint DEFAULT 100,
    p_min_rows      bigint DEFAULT 1000
)
RETURNS TABLE(
    schema_name       text,
    table_name        text,
    seq_scan_count    bigint,
    seq_tuples_read   bigint,
    index_scan_count  bigint,
    live_tuples       bigint,
    table_size        text,
    priority          text,
    recommendation    text
)
LANGUAGE sql
STABLE
SECURITY INVOKER
AS $$
    SELECT
        s.schemaname::text,
        s.relname::text,
        s.seq_scan,
        s.seq_tup_read,
        COALESCE(s.idx_scan, 0),
        s.n_live_tup,
        pg_size_pretty(
            pg_total_relation_size(
                quote_ident(s.schemaname) || '.' || quote_ident(s.relname)
            )
        ),
        CASE
            WHEN COALESCE(s.idx_scan, 0) = 0 AND s.seq_scan > 10000
                THEN '1-HIGH'
            WHEN s.seq_scan > COALESCE(s.idx_scan, 0) * 10
                THEN '2-MEDIUM'
            ELSE '3-LOW'
        END,
        CASE
            WHEN COALESCE(s.idx_scan, 0) = 0
                THEN 'No index scans at all — identify filter columns and add index'
            WHEN s.seq_scan > COALESCE(s.idx_scan, 0) * 10
                THEN 'Seq scans >> index scans — consider composite/partial index on WHERE columns'
            ELSE
                'More seq scans than index scans — review query predicates'
        END
    FROM pg_stat_user_tables s
    WHERE s.seq_scan >= p_min_seq_scan
      AND s.n_live_tup >= p_min_rows
      AND (p_schema IS NULL OR s.schemaname = p_schema)
    ORDER BY s.seq_scan DESC;
$$;

COMMENT ON FUNCTION query_advisor.missing_indexes IS
    'Tables where sequential scans dominate, suggesting missing indexes.';

-- ==============================================================================
-- 4. UNUSED INDEXES
--    Never-used or rarely-used indexes that are candidates for removal
-- ==============================================================================

CREATE OR REPLACE FUNCTION query_advisor.unused_indexes(
    p_schema       text    DEFAULT NULL,
    p_min_size_mb  numeric DEFAULT 0,
    p_max_scans    bigint  DEFAULT 50
)
RETURNS TABLE(
    schema_name    text,
    table_name     text,
    index_name     text,
    index_size     text,
    index_size_mb  numeric,
    index_scans    bigint,
    is_unique      boolean,
    is_primary     boolean,
    drop_command   text,
    recommendation text
)
LANGUAGE sql
STABLE
SECURITY INVOKER
AS $$
    SELECT
        s.schemaname::text,
        s.relname::text,
        s.indexrelname::text,
        pg_size_pretty(pg_relation_size(s.indexrelid)),
        round(pg_relation_size(s.indexrelid)::numeric / (1024 * 1024), 2),
        s.idx_scan,
        ix.indisunique,
        ix.indisprimary,
        CASE
            WHEN ix.indisprimary OR ix.indisunique THEN NULL
            ELSE 'DROP INDEX CONCURRENTLY '
                 || quote_ident(s.schemaname) || '.' || quote_ident(s.indexrelname) || ';'
        END,
        CASE
            WHEN ix.indisprimary
                THEN 'KEEP: primary key'
            WHEN ix.indisunique
                THEN 'REVIEW: unique constraint — verify dependency before dropping'
            WHEN s.idx_scan = 0
                THEN 'DROP CANDIDATE: never used since last statistics reset'
            ELSE
                'MONITOR: only ' || s.idx_scan || ' scans since last reset'
        END
    FROM pg_stat_user_indexes s
    JOIN pg_index ix ON ix.indexrelid = s.indexrelid
    WHERE s.idx_scan <= p_max_scans
      AND (p_schema IS NULL OR s.schemaname = p_schema)
      AND round(pg_relation_size(s.indexrelid)::numeric / (1024 * 1024), 2) >= p_min_size_mb
    ORDER BY ix.indisprimary ASC,
             pg_relation_size(s.indexrelid) DESC,
             s.idx_scan ASC;
$$;

COMMENT ON FUNCTION query_advisor.unused_indexes IS
    'Unused or rarely-used indexes. Includes generated DROP INDEX CONCURRENTLY commands.';

-- ==============================================================================
-- 5. DUPLICATE / REDUNDANT INDEXES
--    Indexes sharing the same leading columns on the same table
-- ==============================================================================

CREATE OR REPLACE FUNCTION query_advisor.duplicate_indexes(
    p_schema text DEFAULT NULL
)
RETURNS TABLE(
    schema_name   text,
    table_name    text,
    index_a       text,
    index_b       text,
    shared_key    text,
    size_a        text,
    size_b        text,
    scans_a       bigint,
    scans_b       bigint,
    recommendation text
)
LANGUAGE sql
STABLE
SECURITY INVOKER
AS $$
    WITH idx_cols AS (
        SELECT
            n.nspname                              AS schema_name,
            c.relname                              AS table_name,
            ci.relname                             AS index_name,
            ci.oid                                 AS index_oid,
            ix.indisunique,
            ix.indisprimary,
            -- First two key columns as a canonical key for comparison
            array_to_string(
                ARRAY(
                    SELECT a.attname
                    FROM   pg_attribute a
                    WHERE  a.attrelid = ix.indrelid
                      AND  a.attnum   = ANY(ix.indkey)
                    ORDER  BY array_position(ix.indkey, a.attnum)
                    LIMIT  2
                ),
                ','
            )                                      AS leading_cols,
            array_to_string(
                ARRAY(
                    SELECT a.attname
                    FROM   pg_attribute a
                    WHERE  a.attrelid = ix.indrelid
                      AND  a.attnum   = ANY(ix.indkey)
                    ORDER  BY array_position(ix.indkey, a.attnum)
                ),
                ','
            )                                      AS all_cols
        FROM pg_index    ix
        JOIN pg_class    c  ON c.oid  = ix.indrelid
        JOIN pg_class    ci ON ci.oid = ix.indexrelid
        JOIN pg_namespace n ON n.oid  = c.relnamespace
        WHERE n.nspname NOT IN ('pg_catalog','information_schema','pg_toast')
          AND (p_schema IS NULL OR n.nspname = p_schema)
    )
    SELECT
        a.schema_name::text,
        a.table_name::text,
        a.index_name::text,
        b.index_name::text,
        a.all_cols::text,
        pg_size_pretty(pg_relation_size(a.index_oid)),
        pg_size_pretty(pg_relation_size(b.index_oid)),
        COALESCE((SELECT idx_scan FROM pg_stat_user_indexes WHERE indexrelid = a.index_oid), 0),
        COALESCE((SELECT idx_scan FROM pg_stat_user_indexes WHERE indexrelid = b.index_oid), 0),
        CASE
            WHEN b.indisprimary
                THEN 'Keep ' || b.index_name || ' (primary key); review ' || a.index_name
            WHEN a.indisprimary
                THEN 'Keep ' || a.index_name || ' (primary key); review ' || b.index_name
            WHEN b.indisunique AND NOT a.indisunique
                THEN 'Keep ' || b.index_name || ' (unique); drop ' || a.index_name
            WHEN a.indisunique AND NOT b.indisunique
                THEN 'Keep ' || a.index_name || ' (unique); drop ' || b.index_name
            ELSE
                'Redundant pair — drop the one with fewer scans'
        END
    FROM idx_cols a
    JOIN idx_cols b
      ON  a.schema_name  = b.schema_name
      AND a.table_name   = b.table_name
      AND a.leading_cols = b.leading_cols
      AND a.index_name   < b.index_name   -- avoid duplicate rows
    ORDER BY a.schema_name, a.table_name, a.index_name;
$$;

COMMENT ON FUNCTION query_advisor.duplicate_indexes IS
    'Finds index pairs that share the same leading columns on the same table.';

-- ==============================================================================
-- 6. SLOW QUERIES (requires pg_stat_statements)
-- ==============================================================================

CREATE OR REPLACE FUNCTION query_advisor.slow_queries(
    p_top_n      int    DEFAULT 20,
    p_min_calls  bigint DEFAULT 5
)
RETURNS TABLE(
    query_id             bigint,
    query_text           text,
    calls                bigint,
    total_exec_ms        numeric,
    mean_exec_ms         numeric,
    max_exec_ms          numeric,
    stddev_exec_ms       numeric,
    rows_returned        bigint,
    shared_blks_hit      bigint,
    shared_blks_read     bigint,
    cache_hit_pct        numeric,
    recommendation       text
)
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_stat_statements') THEN
        RAISE NOTICE
            'pg_stat_statements is not installed. '
            'Add pg_stat_statements to shared_preload_libraries and run: '
            'CREATE EXTENSION pg_stat_statements;';
        RETURN;
    END IF;

    RETURN QUERY EXECUTE format(
        $q$
        SELECT
            queryid,
            left(query, 300)::text                                             AS query_text,
            calls,
            round(total_exec_time::numeric, 2)                                 AS total_exec_ms,
            round(mean_exec_time::numeric,  2)                                 AS mean_exec_ms,
            round(max_exec_time::numeric,   2)                                 AS max_exec_ms,
            round(stddev_exec_time::numeric,2)                                 AS stddev_exec_ms,
            rows                                                               AS rows_returned,
            shared_blks_hit,
            shared_blks_read,
            CASE WHEN (shared_blks_hit + shared_blks_read) > 0
                 THEN round(shared_blks_hit::numeric /
                            (shared_blks_hit + shared_blks_read)::numeric * 100, 2)
                 ELSE 100
            END                                                                AS cache_hit_pct,
            CASE
                WHEN mean_exec_time > 5000
                    THEN 'CRITICAL: avg >5 s — needs immediate plan investigation'
                WHEN mean_exec_time > 1000
                    THEN 'WARNING: avg >1 s — review EXPLAIN (ANALYZE, BUFFERS)'
                WHEN mean_exec_time > 100
                    THEN 'NOTICE: avg >100 ms — consider optimization'
                WHEN (shared_blks_hit + shared_blks_read) > 0
                     AND shared_blks_hit::numeric /
                         (shared_blks_hit + shared_blks_read)::numeric < 0.90
                    THEN 'WARNING: low cache hit ratio — check indexes or increase shared_buffers'
                ELSE 'OK'
            END                                                                AS recommendation
        FROM pg_stat_statements
        WHERE calls >= %s
        ORDER BY mean_exec_time DESC
        LIMIT %s
        $q$,
        p_min_calls,
        p_top_n
    );
END;
$$;

COMMENT ON FUNCTION query_advisor.slow_queries IS
    'Top slow queries from pg_stat_statements with cache hit and recommendations.';

-- ==============================================================================
-- 7. CURRENTLY RUNNING LONG QUERIES
-- ==============================================================================

CREATE OR REPLACE FUNCTION query_advisor.long_running_queries(
    p_min_duration_s int DEFAULT 30
)
RETURNS TABLE(
    pid               int,
    username          text,
    application_name  text,
    database_name     text,
    client_addr       text,
    state             text,
    wait_event_type   text,
    wait_event        text,
    duration_seconds  numeric,
    query_text        text,
    recommendation    text
)
LANGUAGE sql
STABLE
SECURITY INVOKER
AS $$
    SELECT
        pid,
        usename::text,
        application_name::text,
        datname::text,
        host(client_addr)::text,
        state::text,
        wait_event_type::text,
        wait_event::text,
        round(EXTRACT(EPOCH FROM (now() - query_start))::numeric, 1),
        left(query, 300)::text,
        CASE
            WHEN wait_event_type = 'Lock'
                THEN 'BLOCKING: waiting on a lock — check query_advisor.lock_waits()'
            WHEN EXTRACT(EPOCH FROM (now() - query_start)) > 300
                THEN 'CRITICAL: running >5 min — consider pg_cancel_backend(' || pid || ')'
            WHEN EXTRACT(EPOCH FROM (now() - query_start)) > 60
                THEN 'WARNING: running >1 min — review query plan'
            ELSE 'NOTICE: running >30 s'
        END
    FROM pg_stat_activity
    WHERE state = 'active'
      AND query_start < now() - (p_min_duration_s || ' seconds')::interval
      AND pid <> pg_backend_pid()
    ORDER BY query_start ASC;
$$;

COMMENT ON FUNCTION query_advisor.long_running_queries IS
    'Active queries running longer than p_min_duration_s seconds.';

-- ==============================================================================
-- 8. LOCK WAITS
-- ==============================================================================

CREATE OR REPLACE FUNCTION query_advisor.lock_waits()
RETURNS TABLE(
    waiting_pid       int,
    waiting_user      text,
    waiting_query     text,
    waiting_duration  text,
    blocking_pid      int,
    blocking_user     text,
    blocking_query    text,
    lock_type         text,
    relation_name     text
)
LANGUAGE sql
STABLE
SECURITY INVOKER
AS $$
    SELECT
        w.pid                                                     AS waiting_pid,
        w.usename::text                                           AS waiting_user,
        left(w.query, 200)::text                                  AS waiting_query,
        age(now(), w.query_start)::text                           AS waiting_duration,
        b.pid                                                     AS blocking_pid,
        b.usename::text                                           AS blocking_user,
        left(b.query, 200)::text                                  AS blocking_query,
        kl.locktype::text                                         AS lock_type,
        coalesce(
            quote_ident(n.nspname) || '.' || quote_ident(c.relname),
            kl.locktype
        )::text                                                   AS relation_name
    FROM pg_stat_activity w
    JOIN pg_locks         wl ON wl.pid = w.pid AND NOT wl.granted
    JOIN pg_locks         kl ON kl.locktype  = wl.locktype
                             AND kl.database IS NOT DISTINCT FROM wl.database
                             AND kl.relation IS NOT DISTINCT FROM wl.relation
                             AND kl.page     IS NOT DISTINCT FROM wl.page
                             AND kl.tuple    IS NOT DISTINCT FROM wl.tuple
                             AND kl.granted
    JOIN pg_stat_activity b  ON b.pid = kl.pid
    LEFT JOIN pg_class    c  ON c.oid = wl.relation
    LEFT JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE w.pid <> b.pid
    ORDER BY w.query_start;
$$;

COMMENT ON FUNCTION query_advisor.lock_waits IS
    'Shows current lock-wait chains: who is blocking whom.';

-- ==============================================================================
-- 9. TABLE BLOAT (dead-tuple-based estimate)
-- ==============================================================================

CREATE OR REPLACE FUNCTION query_advisor.table_bloat(
    p_schema       text    DEFAULT NULL,
    p_min_waste_mb numeric DEFAULT 1
)
RETURNS TABLE(
    schema_name      text,
    table_name       text,
    table_size       text,
    dead_tuples      bigint,
    dead_ratio_pct   numeric,
    estimated_waste  text,
    last_vacuum      timestamptz,
    last_autovacuum  timestamptz,
    recommendation   text
)
LANGUAGE sql
STABLE
SECURITY INVOKER
AS $$
    SELECT
        s.schemaname::text,
        s.relname::text,
        pg_size_pretty(
            pg_total_relation_size(
                quote_ident(s.schemaname) || '.' || quote_ident(s.relname)
            )
        ),
        s.n_dead_tup,
        CASE WHEN (s.n_live_tup + s.n_dead_tup) > 0
             THEN round(
                      s.n_dead_tup::numeric /
                      (s.n_live_tup + s.n_dead_tup)::numeric * 100, 2)
             ELSE 0
        END,
        pg_size_pretty(
            (
                pg_total_relation_size(
                    quote_ident(s.schemaname) || '.' || quote_ident(s.relname)
                ) *
                s.n_dead_tup::numeric /
                NULLIF((s.n_live_tup + s.n_dead_tup), 0)::numeric
            )::bigint
        ),
        s.last_vacuum,
        s.last_autovacuum,
        CASE
            WHEN (s.n_live_tup + s.n_dead_tup) > 0 AND
                 s.n_dead_tup::numeric /
                 (s.n_live_tup + s.n_dead_tup)::numeric > 0.30
                THEN 'CRITICAL: >30% dead — run VACUUM ANALYZE immediately'
            WHEN (s.n_live_tup + s.n_dead_tup) > 0 AND
                 s.n_dead_tup::numeric /
                 (s.n_live_tup + s.n_dead_tup)::numeric > 0.15
                THEN 'WARNING: >15% dead — schedule VACUUM ANALYZE'
            WHEN s.last_autovacuum < now() - interval '7 days'
                 AND s.n_dead_tup > 10000
                THEN 'WARNING: no autovacuum in 7 days with high dead tuples'
            WHEN s.last_autovacuum IS NULL AND s.last_vacuum IS NULL
                THEN 'WARNING: never vacuumed'
            ELSE 'OK'
        END
    FROM pg_stat_user_tables s
    WHERE (p_schema IS NULL OR s.schemaname = p_schema)
      AND (
              pg_total_relation_size(
                  quote_ident(s.schemaname) || '.' || quote_ident(s.relname)
              ) *
              s.n_dead_tup::numeric /
              NULLIF((s.n_live_tup + s.n_dead_tup), 0)::numeric
          ) >= p_min_waste_mb * 1024 * 1024
    ORDER BY
        s.n_dead_tup::numeric /
        NULLIF((s.n_live_tup + s.n_dead_tup), 0)::numeric DESC;
$$;

COMMENT ON FUNCTION query_advisor.table_bloat IS
    'Dead-tuple-based bloat estimate with vacuum status and recommendations.';

-- ==============================================================================
-- 10. INDEX HEALTH (invalid, oversized)
-- ==============================================================================

CREATE OR REPLACE FUNCTION query_advisor.index_health(
    p_schema text DEFAULT NULL
)
RETURNS TABLE(
    schema_name     text,
    table_name      text,
    index_name      text,
    index_size      text,
    index_scans     bigint,
    is_valid        boolean,
    is_unique       boolean,
    is_primary      boolean,
    recommendation  text
)
LANGUAGE sql
STABLE
SECURITY INVOKER
AS $$
    SELECT
        s.schemaname::text,
        s.relname::text,
        s.indexrelname::text,
        pg_size_pretty(pg_relation_size(s.indexrelid)),
        s.idx_scan,
        ix.indisvalid,
        ix.indisunique,
        ix.indisprimary,
        CASE
            WHEN NOT ix.indisvalid
                THEN 'CRITICAL: invalid index — rebuild with: REINDEX INDEX CONCURRENTLY '
                     || quote_ident(s.schemaname) || '.' || quote_ident(s.indexrelname)
            WHEN s.idx_scan = 0 AND NOT ix.indisprimary AND NOT ix.indisunique
                THEN 'DROP CANDIDATE: unused non-constraint index'
            WHEN pg_relation_size(s.indexrelid) >
                 pg_total_relation_size(
                     quote_ident(s.schemaname) || '.' || quote_ident(s.relname)
                 ) * 0.5
                THEN 'WARNING: index is >50% of total table size — consider REINDEX CONCURRENTLY'
            ELSE 'OK'
        END
    FROM pg_stat_user_indexes s
    JOIN pg_index ix ON ix.indexrelid = s.indexrelid
    WHERE (p_schema IS NULL OR s.schemaname = p_schema)
    ORDER BY ix.indisvalid ASC, pg_relation_size(s.indexrelid) DESC;
$$;

COMMENT ON FUNCTION query_advisor.index_health IS
    'Identifies invalid, oversized, or unused indexes per table.';

-- ==============================================================================
-- 11. AUTOVACUUM SETTINGS ADVISOR
--     Recommends per-table autovacuum tuning for large tables
-- ==============================================================================

CREATE OR REPLACE FUNCTION query_advisor.autovacuum_settings(
    p_schema   text  DEFAULT NULL,
    p_min_rows bigint DEFAULT 100000
)
RETURNS TABLE(
    schema_name               text,
    table_name                text,
    estimated_rows            bigint,
    current_vac_threshold     bigint,
    current_vac_scale         numeric,
    recommended_vac_threshold bigint,
    recommended_vac_scale     numeric,
    last_autovacuum           timestamptz,
    days_since_autovacuum     numeric,
    alter_command             text,
    recommendation            text
)
LANGUAGE sql
STABLE
SECURITY INVOKER
AS $$
    WITH tbl AS (
        SELECT
            n.nspname                                                   AS schema_name,
            c.relname                                                   AS table_name,
            greatest(c.reltuples::bigint, 0)                           AS est_rows,
            COALESCE(
                (SELECT option_value::numeric
                 FROM   pg_options_to_table(c.reloptions)
                 WHERE  option_name = 'autovacuum_vacuum_threshold'),
                current_setting('autovacuum_vacuum_threshold')::numeric
            )::bigint                                                   AS vac_threshold,
            COALESCE(
                (SELECT option_value::numeric
                 FROM   pg_options_to_table(c.reloptions)
                 WHERE  option_name = 'autovacuum_vacuum_scale_factor'),
                current_setting('autovacuum_vacuum_scale_factor')::numeric
            )                                                           AS vac_scale
        FROM pg_class     c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE c.relkind    = 'r'
          AND n.nspname NOT IN ('pg_catalog','information_schema','pg_toast')
          AND (p_schema IS NULL OR n.nspname = p_schema)
    )
    SELECT
        t.schema_name::text,
        t.table_name::text,
        t.est_rows,
        t.vac_threshold,
        t.vac_scale,
        -- Recommended threshold & scale by table size tier
        CASE
            WHEN t.est_rows > 50000000 THEN 50
            WHEN t.est_rows > 10000000 THEN 100
            WHEN t.est_rows >  1000000 THEN 200
            ELSE t.vac_threshold
        END::bigint,
        CASE
            WHEN t.est_rows > 50000000 THEN 0.005
            WHEN t.est_rows > 10000000 THEN 0.01
            WHEN t.est_rows >  1000000 THEN 0.02
            ELSE t.vac_scale
        END,
        s.last_autovacuum,
        round(EXTRACT(EPOCH FROM (now() - s.last_autovacuum)) / 86400.0, 1),
        -- Generate ready-to-run ALTER TABLE command
        CASE
            WHEN t.est_rows > 1000000
                THEN 'ALTER TABLE ' || quote_ident(t.schema_name) || '.' || quote_ident(t.table_name)
                     || ' SET (autovacuum_vacuum_scale_factor = '
                     || CASE
                            WHEN t.est_rows > 50000000 THEN '0.005'
                            WHEN t.est_rows > 10000000 THEN '0.01'
                            ELSE '0.02'
                        END
                     || ', autovacuum_vacuum_threshold = '
                     || CASE
                            WHEN t.est_rows > 50000000 THEN '50'
                            WHEN t.est_rows > 10000000 THEN '100'
                            ELSE '200'
                        END
                     || ');'
            ELSE NULL
        END,
        CASE
            WHEN t.est_rows > 1000000 AND t.vac_scale > 0.05
                THEN 'TUNE: scale_factor too high for this table size — use ALTER TABLE command'
            WHEN s.last_autovacuum < now() - interval '14 days'
                 AND t.est_rows > 10000
                THEN 'WARNING: no autovacuum in 14 days — verify autovacuum is enabled'
            WHEN s.last_autovacuum IS NULL AND t.est_rows > 10000
                THEN 'WARNING: autovacuum has never run on this table'
            ELSE 'OK'
        END
    FROM tbl t
    LEFT JOIN pg_stat_user_tables s
           ON s.schemaname = t.schema_name AND s.relname = t.table_name
    WHERE t.est_rows >= p_min_rows
    ORDER BY t.est_rows DESC;
$$;

COMMENT ON FUNCTION query_advisor.autovacuum_settings IS
    'Recommends autovacuum_vacuum_scale_factor and threshold for large tables. '
    'Generates ready-to-run ALTER TABLE commands.';

-- ==============================================================================
-- 12. BUFFER CACHE HIT RATIO
-- ==============================================================================

CREATE OR REPLACE FUNCTION query_advisor.cache_hit(
    p_schema text DEFAULT NULL
)
RETURNS TABLE(
    object_type    text,
    schema_name    text,
    object_name    text,
    heap_hit_pct   numeric,
    idx_hit_pct    numeric,
    toast_hit_pct  numeric,
    recommendation text
)
LANGUAGE sql
STABLE
SECURITY INVOKER
AS $$
    SELECT
        'TABLE'::text,
        s.schemaname::text,
        s.relname::text,
        CASE WHEN (s.heap_blks_hit + s.heap_blks_read) > 0
             THEN round(s.heap_blks_hit::numeric /
                        (s.heap_blks_hit + s.heap_blks_read)::numeric * 100, 2)
             ELSE 100
        END,
        CASE WHEN (s.idx_blks_hit + s.idx_blks_read) > 0
             THEN round(s.idx_blks_hit::numeric /
                        (s.idx_blks_hit + s.idx_blks_read)::numeric * 100, 2)
             ELSE 100
        END,
        CASE WHEN (s.toast_blks_hit + s.toast_blks_read) > 0
             THEN round(s.toast_blks_hit::numeric /
                        (s.toast_blks_hit + s.toast_blks_read)::numeric * 100, 2)
             ELSE 100
        END,
        CASE
            WHEN (s.heap_blks_hit + s.heap_blks_read) > 0 AND
                 s.heap_blks_hit::numeric /
                 (s.heap_blks_hit + s.heap_blks_read)::numeric < 0.90
                THEN 'WARNING: heap cache hit <90% — consider increasing shared_buffers'
            WHEN (s.idx_blks_hit + s.idx_blks_read) > 0 AND
                 s.idx_blks_hit::numeric /
                 (s.idx_blks_hit + s.idx_blks_read)::numeric < 0.90
                THEN 'WARNING: index cache hit <90% — check effective_cache_size'
            ELSE 'OK'
        END
    FROM pg_statio_user_tables s
    WHERE (s.heap_blks_hit + s.heap_blks_read) > 0
      AND (p_schema IS NULL OR s.schemaname = p_schema)
    ORDER BY
        (s.heap_blks_hit::numeric /
         NULLIF(s.heap_blks_hit + s.heap_blks_read, 0)::numeric) ASC
    LIMIT 30;
$$;

COMMENT ON FUNCTION query_advisor.cache_hit IS
    'Buffer cache hit ratios per table. Low values suggest shared_buffers is too small.';

-- ==============================================================================
-- 13. MASTER RECOMMENDATIONS REPORT
--     Aggregated, prioritized view across all advisor checks
-- ==============================================================================

CREATE OR REPLACE FUNCTION query_advisor.report(
    p_schema text DEFAULT NULL
)
RETURNS TABLE(
    priority       text,
    category       text,
    object_name    text,
    finding        text,
    action         text
)
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
AS $$
BEGIN
    -- Dead tuples / bloat
    RETURN QUERY
    SELECT
        CASE WHEN dead_ratio_pct > 20 THEN '1-CRITICAL'
             WHEN dead_ratio_pct > 10 THEN '2-WARNING'
             ELSE                          '3-NOTICE'
        END::text,
        'DEAD_TUPLES'::text,
        (schema_name || '.' || table_name)::text,
        ('dead ' || dead_tuples || ' rows (' || dead_ratio_pct || '%), '
         || 'last autovacuum: ' || COALESCE(last_autovacuum::text, 'never'))::text,
        ('VACUUM ANALYZE ' || schema_name || '.' || table_name || ';')::text
    FROM query_advisor.table_health(p_schema)
    WHERE dead_ratio_pct > 5 OR health_status <> 'OK'
    ORDER BY dead_ratio_pct DESC;

    -- Unused indexes (non-PK, non-unique)
    RETURN QUERY
    SELECT
        CASE WHEN index_scans = 0 THEN '2-WARNING' ELSE '3-NOTICE' END::text,
        'UNUSED_INDEX'::text,
        (schema_name || '.' || index_name)::text,
        (index_size || ', ' || index_scans || ' scans')::text,
        COALESCE(drop_command, recommendation)::text
    FROM query_advisor.unused_indexes(p_schema)
    WHERE NOT is_primary
      AND index_scans < 10;

    -- Missing indexes (high seq scans)
    RETURN QUERY
    SELECT
        mi.priority::text,
        'MISSING_INDEX'::text,
        (mi.schema_name || '.' || mi.table_name)::text,
        ('seq_scan=' || mi.seq_scan_count || ', idx_scan=' || mi.index_scan_count
         || ', rows=' || mi.live_tuples || ', size=' || mi.table_size)::text,
        mi.recommendation::text
    FROM query_advisor.missing_indexes(p_schema) mi
    WHERE mi.index_scan_count < mi.seq_scan_count;

    -- Autovacuum tuning
    RETURN QUERY
    SELECT
        '3-NOTICE'::text,
        'AUTOVACUUM_TUNE'::text,
        (schema_name || '.' || table_name)::text,
        ('rows ~' || estimated_rows || ', current scale=' || current_vac_scale)::text,
        COALESCE(alter_command, recommendation)::text
    FROM query_advisor.autovacuum_settings(p_schema)
    WHERE recommendation <> 'OK';

    -- Duplicate indexes
    RETURN QUERY
    SELECT
        '3-NOTICE'::text,
        'DUPLICATE_INDEX'::text,
        (schema_name || '.' || index_a || ' / ' || index_b)::text,
        ('shared leading cols: ' || shared_key
         || ', scans: ' || scans_a || ' vs ' || scans_b)::text,
        recommendation::text
    FROM query_advisor.duplicate_indexes(p_schema);

    -- Invalid indexes
    RETURN QUERY
    SELECT
        '1-CRITICAL'::text,
        'INVALID_INDEX'::text,
        (schema_name || '.' || index_name)::text,
        'Index is marked invalid'::text,
        recommendation::text
    FROM query_advisor.index_health(p_schema)
    WHERE NOT is_valid;

END;
$$;

COMMENT ON FUNCTION query_advisor.report IS
    'Master recommendations report. '
    'Returns prioritised findings across dead tuples, indexes, autovacuum and cache.';

-- ==============================================================================
-- CONVENIENCE VIEWS
-- ==============================================================================

CREATE OR REPLACE VIEW query_advisor.health_summary AS
SELECT 'Tables needing VACUUM (dead >10%)'     AS check_name,
       count(*)                                 AS object_count
FROM   query_advisor.table_health()
WHERE  dead_ratio_pct > 10

UNION ALL

SELECT 'Unused indexes (0 scans)',
       count(*)
FROM   query_advisor.unused_indexes()
WHERE  index_scans = 0 AND NOT is_primary

UNION ALL

SELECT 'Tables likely missing indexes (seq >> idx)',
       count(*)
FROM   query_advisor.missing_indexes()
WHERE  index_scan_count < seq_scan_count

UNION ALL

SELECT 'Duplicate / redundant index pairs',
       count(*)
FROM   query_advisor.duplicate_indexes()

UNION ALL

SELECT 'Invalid indexes',
       count(*)
FROM   query_advisor.index_health()
WHERE  NOT is_valid;

COMMENT ON VIEW query_advisor.health_summary IS
    'One-row-per-check summary counters for a quick database health overview.';

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

-- Yeni: idle_in_transaction, vacuum_needs, replication_slots,
--       config_advisor, correlation_check

-- ==============================================================================
-- 1. IDLE IN TRANSACTION
--    Uzun süre açık kalmış transaction'lar: vacuum'u engeller,
--    lock biriktirir, tablo şişmesine yol açar.
-- ==============================================================================

CREATE OR REPLACE FUNCTION query_advisor.idle_in_transaction(
    p_min_duration_s int DEFAULT 30
)
RETURNS TABLE(
    pid               int,
    username          text,
    application_name  text,
    client_addr       text,
    state             text,
    duration_seconds  numeric,
    idle_since        timestamptz,
    lock_count        bigint,
    query_text        text,
    risk_level        text,
    recommendation    text
)
LANGUAGE sql
STABLE
SECURITY INVOKER
AS $$
    SELECT
        a.pid,
        a.usename::text,
        a.application_name::text,
        host(a.client_addr)::text,
        a.state::text,
        round(EXTRACT(EPOCH FROM (now() - a.state_change))::numeric, 1),
        a.state_change,
        count(l.pid)                           AS lock_count,
        left(a.query, 200)::text,
        CASE
            WHEN EXTRACT(EPOCH FROM (now() - a.state_change)) > 3600
                THEN 'CRITICAL: >1 saat idle — autovacuum engelliyor olabilir'
            WHEN EXTRACT(EPOCH FROM (now() - a.state_change)) > 300
                THEN 'WARNING: >5 dakika idle — lock tutuyor olabilir'
            ELSE
                'NOTICE: idle in transaction'
        END,
        'SELECT pg_terminate_backend(' || a.pid || ');'
        || '  -- veya: SELECT pg_cancel_backend(' || a.pid || ');'
    FROM pg_stat_activity a
    LEFT JOIN pg_locks l ON l.pid = a.pid
    WHERE a.state IN ('idle in transaction', 'idle in transaction (aborted)')
      AND a.state_change < now() - (p_min_duration_s || ' seconds')::interval
    GROUP BY a.pid, a.usename, a.application_name,
             a.client_addr, a.state, a.state_change, a.query
    ORDER BY a.state_change ASC;
$$;

COMMENT ON FUNCTION query_advisor.idle_in_transaction IS
    'Uzun sure idle in transaction durumundaki sessionlari listeler. '
    'Bu sessionlar autovacuum u engeller ve lock biriktirir.';

-- ==============================================================================
-- 2. VACUUM NEEDS
--    Autovacuum tetikleme esigine yaklaşan tablolar.
--    Sorun olMAdAN once uyari verir.
-- ==============================================================================

CREATE OR REPLACE FUNCTION query_advisor.vacuum_needs(
    p_schema          text    DEFAULT NULL,
    p_threshold_pct   numeric DEFAULT 70
)
RETURNS TABLE(
    schema_name          text,
    table_name           text,
    live_rows            bigint,
    dead_rows            bigint,
    vacuum_threshold     bigint,
    dead_rows_pct_filled numeric,
    last_autovacuum      timestamptz,
    autovacuum_count     bigint,
    analyze_threshold    bigint,
    mod_rows             bigint,
    analyze_pct_filled   numeric,
    needs_vacuum         boolean,
    needs_analyze        boolean,
    recommendation       text
)
LANGUAGE sql
STABLE
SECURITY INVOKER
AS $$
    WITH settings AS (
        SELECT
            current_setting('autovacuum_vacuum_threshold')::numeric    AS vac_thr,
            current_setting('autovacuum_vacuum_scale_factor')::numeric  AS vac_sf,
            current_setting('autovacuum_analyze_threshold')::numeric   AS an_thr,
            current_setting('autovacuum_analyze_scale_factor')::numeric AS an_sf
    ),
    tbl AS (
        SELECT
            c.oid,
            n.nspname                                                   AS schema_name,
            c.relname                                                   AS table_name,
            s.n_live_tup,
            s.n_dead_tup,
            s.n_mod_since_analyze,
            s.last_autovacuum,
            s.autovacuum_count,
            -- Per-table override veya global setting
            COALESCE(
                (SELECT option_value::numeric FROM pg_options_to_table(c.reloptions)
                 WHERE option_name = 'autovacuum_vacuum_threshold'), g.vac_thr
            ) + COALESCE(
                (SELECT option_value::numeric FROM pg_options_to_table(c.reloptions)
                 WHERE option_name = 'autovacuum_vacuum_scale_factor'), g.vac_sf
            ) * s.n_live_tup                                            AS vac_threshold,
            COALESCE(
                (SELECT option_value::numeric FROM pg_options_to_table(c.reloptions)
                 WHERE option_name = 'autovacuum_analyze_threshold'), g.an_thr
            ) + COALESCE(
                (SELECT option_value::numeric FROM pg_options_to_table(c.reloptions)
                 WHERE option_name = 'autovacuum_analyze_scale_factor'), g.an_sf
            ) * s.n_live_tup                                            AS an_threshold
        FROM pg_class       c
        JOIN pg_namespace   n ON n.oid = c.relnamespace
        JOIN pg_stat_user_tables s
               ON s.schemaname = n.nspname AND s.relname = c.relname,
             settings g
        WHERE c.relkind = 'r'
          AND n.nspname NOT IN ('pg_catalog','information_schema','pg_toast')
          AND (p_schema IS NULL OR n.nspname = p_schema)
    )
    SELECT
        schema_name::text,
        table_name::text,
        n_live_tup,
        n_dead_tup,
        vac_threshold::bigint,
        CASE WHEN vac_threshold > 0
             THEN round(n_dead_tup::numeric / vac_threshold * 100, 1)
             ELSE 0
        END                                    AS dead_pct_filled,
        last_autovacuum,
        autovacuum_count,
        an_threshold::bigint,
        n_mod_since_analyze,
        CASE WHEN an_threshold > 0
             THEN round(n_mod_since_analyze::numeric / an_threshold * 100, 1)
             ELSE 0
        END                                    AS analyze_pct_filled,
        -- Eşik aşıldı mı?
        n_dead_tup >= vac_threshold            AS needs_vacuum,
        n_mod_since_analyze >= an_threshold    AS needs_analyze,
        CASE
            WHEN n_dead_tup >= vac_threshold
                THEN 'VACUUM GEREKLI: esik asildi — VACUUM ANALYZE ' || schema_name || '.' || table_name
            WHEN n_dead_tup::numeric / NULLIF(vac_threshold,0) >= p_threshold_pct / 100.0
                THEN 'UYARI: esige %' || round(n_dead_tup::numeric / NULLIF(vac_threshold,0) * 100, 0)
                     || ' yaklasildi — yakin zamanda autovacuum calisacak'
            WHEN n_mod_since_analyze >= an_threshold
                THEN 'ANALYZE GEREKLI: istatistik eskidi — ANALYZE ' || schema_name || '.' || table_name
            ELSE 'OK'
        END
    FROM tbl
    WHERE n_dead_tup::numeric / NULLIF(vac_threshold, 0) >= p_threshold_pct / 100.0
       OR n_dead_tup   >= vac_threshold
       OR n_mod_since_analyze >= an_threshold
    ORDER BY
        (n_dead_tup::numeric / NULLIF(vac_threshold, 0)) DESC;
$$;

COMMENT ON FUNCTION query_advisor.vacuum_needs IS
    'Autovacuum tetikleme esigine yaklasan veya esen tablolari listeler. '
    'p_threshold_pct: esige kac %da uyari verilsin (varsayilan 70).';

-- ==============================================================================
-- 3. REPLICATION SLOTS
--    Tikanmis veya geride kalmis slot'lar WAL birikimine yol acar —
--    disk doluncaya kadar sessizce buyur.
-- ==============================================================================

CREATE OR REPLACE FUNCTION query_advisor.replication_slots()
RETURNS TABLE(
    slot_name        text,
    slot_type        text,
    plugin           text,
    database_name    text,
    active           boolean,
    active_pid       int,
    restart_lsn      text,
    confirmed_lsn    text,
    wal_retained_mb  numeric,
    replication_lag  text,
    risk_level       text,
    recommendation   text
)
LANGUAGE sql
STABLE
SECURITY INVOKER
AS $$
    SELECT
        s.slot_name::text,
        s.slot_type::text,
        s.plugin::text,
        s.database::text,
        s.active,
        s.active_pid,
        s.restart_lsn::text,
        s.confirmed_flush_lsn::text,
        -- Tutulan WAL miktari (MB)
        round(
            (pg_wal_lsn_diff(pg_current_wal_lsn(), s.restart_lsn))::numeric
            / (1024 * 1024), 1
        )                                           AS wal_retained_mb,
        -- Streaming replikasyon için write lag
        CASE WHEN s.active
             THEN COALESCE(
                 (SELECT write_lag::text
                  FROM pg_stat_replication r
                  WHERE r.pid = s.active_pid),
                 'N/A'
             )
             ELSE 'N/A'
        END                                         AS replication_lag,
        CASE
            WHEN NOT s.active
                 AND (pg_wal_lsn_diff(pg_current_wal_lsn(), s.restart_lsn))
                     > 1024::bigint * 1024 * 1024
                THEN 'CRITICAL: pasif slot, >1 GB WAL tutuyor'
            WHEN NOT s.active
                THEN 'WARNING: slot pasif — WAL birikiyor'
            WHEN (pg_wal_lsn_diff(pg_current_wal_lsn(), s.restart_lsn))
                 > 512::bigint * 1024 * 1024
                THEN 'WARNING: aktif slot ama >512 MB WAL biriktirmis'
            ELSE 'OK'
        END,
        CASE
            WHEN NOT s.active
                THEN 'SELECT pg_drop_replication_slot(''' || s.slot_name
                     || ''');  -- kullanilmiyorsa dusur'
            ELSE 'Izle: wal_retained_mb artiyorsa subscriber tarafini kontrol et'
        END
    FROM pg_replication_slots s
    ORDER BY
        s.active ASC,
        (pg_wal_lsn_diff(pg_current_wal_lsn(), s.restart_lsn)) DESC;
$$;

COMMENT ON FUNCTION query_advisor.replication_slots IS
    'Replication slot durumunu ve tutulan WAL miktarini raporlar. '
    'Pasif veya geride kalmis slot''lar disk dolumuna yol acabilir.';

-- ==============================================================================
-- 4. KONFIGÜRASYON DANISMANI
--    Sunucu RAM''ine gore shared_buffers, work_mem, effective_cache_size
--    ve diger kritik ayarlar icin oneri uretir.
-- ==============================================================================

CREATE OR REPLACE FUNCTION query_advisor.config_advisor()
RETURNS TABLE(
    parameter         text,
    current_value     text,
    recommended_value text,
    unit              text,
    risk_level        text,
    explanation       text
)
LANGUAGE sql
STABLE
SECURITY INVOKER
AS $$
    WITH ram AS (
        SELECT
            -- pg_catalog.pg_total_memory() PG16+ , fallback: shared_buffers * 8 tahmin
            CASE WHEN current_setting('shared_buffers') ~ '^\d+$'
                 THEN current_setting('shared_buffers')::bigint * 8192  -- 8 kB blok
                 ELSE 8::bigint * 1024 * 1024 * 1024                    -- 8 GB varsayilan
            END                                                AS est_total_ram
    )
    SELECT * FROM (VALUES

        -- shared_buffers: RAM''in %25''i onerilir
        (
            'shared_buffers',
            current_setting('shared_buffers'),
            pg_size_pretty((SELECT est_total_ram / 4 FROM ram)),
            'bytes',
            CASE
                WHEN pg_size_bytes(current_setting('shared_buffers'))
                     < (SELECT est_total_ram / 8 FROM ram)
                THEN 'WARNING'
                ELSE 'OK'
            END,
            'RAM''in ~%25''i onerilir. Cok kucuk: disk I/O artar.'
        ),

        -- effective_cache_size: RAM''in %75''i
        (
            'effective_cache_size',
            current_setting('effective_cache_size'),
            pg_size_pretty((SELECT est_total_ram * 3 / 4 FROM ram)),
            'bytes',
            CASE
                WHEN pg_size_bytes(current_setting('effective_cache_size'))
                     < (SELECT est_total_ram / 2 FROM ram)
                THEN 'WARNING'
                ELSE 'OK'
            END,
            'Planner tahmini icin. RAM''in ~%75''i. Dusukse hash join/sort maliyeti fazla hesaplanir.'
        ),

        -- work_mem: paralel islem ve sorgu sayisina gore
        (
            'work_mem',
            current_setting('work_mem'),
            '64MB',
            'bytes',
            CASE
                WHEN pg_size_bytes(current_setting('work_mem')) < 4 * 1024 * 1024
                THEN 'WARNING'
                ELSE 'OK'
            END,
            'Sort/Hash icin. Cok kucuk: disk sort. Cok buyuk: max_connections * work_mem RAM''e sigmayabilir.'
        ),

        -- maintenance_work_mem: VACUUM/CREATE INDEX icin
        (
            'maintenance_work_mem',
            current_setting('maintenance_work_mem'),
            pg_size_pretty((SELECT est_total_ram / 16 FROM ram)),
            'bytes',
            CASE
                WHEN pg_size_bytes(current_setting('maintenance_work_mem'))
                     < 64 * 1024 * 1024
                THEN 'NOTICE'
                ELSE 'OK'
            END,
            'VACUUM/CREATE INDEX icin. RAM''in ~%6''si onerilir. Buyuk tablolarda critical.'
        ),

        -- wal_buffers
        (
            'wal_buffers',
            current_setting('wal_buffers'),
            '64MB',
            'bytes',
            CASE
                WHEN pg_size_bytes(current_setting('wal_buffers')) < 16 * 1024 * 1024
                THEN 'NOTICE'
                ELSE 'OK'
            END,
            'WAL yazma tamponu. -1 (otomatik) veya 64MB onerilir. Yazma yogun sistemlerde critical.'
        ),

        -- max_connections
        (
            'max_connections',
            current_setting('max_connections'),
            '100-200 (PgBouncer kullanimi onerilir)',
            'connections',
            CASE
                WHEN current_setting('max_connections')::int > 500
                THEN 'WARNING'
                ELSE 'OK'
            END,
            '>500 baglantiyla shared memory ciddi artar. PgBouncer/pgpool ile connection pooling onerilir.'
        ),

        -- checkpoint_completion_target
        (
            'checkpoint_completion_target',
            current_setting('checkpoint_completion_target'),
            '0.9',
            '',
            CASE
                WHEN current_setting('checkpoint_completion_target')::numeric < 0.7
                THEN 'WARNING'
                ELSE 'OK'
            END,
            'I/O yukunu zamana yayar. 0.9 onerilir. Dusukse checkpoint''te I/O spike olur.'
        ),

        -- log_min_duration_statement
        (
            'log_min_duration_statement',
            current_setting('log_min_duration_statement'),
            '1000 (ms)',
            'ms',
            CASE
                WHEN current_setting('log_min_duration_statement')::int = -1
                THEN 'NOTICE'
                WHEN current_setting('log_min_duration_statement')::int = 0
                THEN 'WARNING'
                ELSE 'OK'
            END,
            '-1: loglama kapali (uretimde sorun tespiti zor). 0: her sorgu loglanir (performans riski). 1000ms onerilir.'
        ),

        -- autovacuum
        (
            'autovacuum',
            current_setting('autovacuum'),
            'on',
            '',
            CASE
                WHEN current_setting('autovacuum') = 'off'
                THEN 'CRITICAL'
                ELSE 'OK'
            END,
            'Kapali ise tablolar sismeler, sorgular yavaslar. Hicbir uretim ortaminda kapali olmamali.'
        ),

        -- fsync
        (
            'fsync',
            current_setting('fsync'),
            'on',
            '',
            CASE
                WHEN current_setting('fsync') = 'off'
                THEN 'CRITICAL'
                ELSE 'OK'
            END,
            'Kapali: cok hizli ama guc kesintisinde veri kaybi/bozulmasi. ASLA uretimde kapatmayin.'
        )

    ) AS t(parameter, current_value, recommended_value, unit, risk_level, explanation)
    ORDER BY
        CASE risk_level
            WHEN 'CRITICAL' THEN 0
            WHEN 'WARNING'  THEN 1
            WHEN 'NOTICE'   THEN 2
            ELSE                 3
        END;
$$;

COMMENT ON FUNCTION query_advisor.config_advisor IS
    'Kritik postgresql.conf parametrelerini mevcut degerle karsilastirir, '
    'RAM bazli oneri uretir ve risk seviyesi bildirir.';

-- ==============================================================================
-- 5. KORELASYON KONTROLU
--    Dusuk korelasyonlu kolonlarda index olsa da PostgreSQL Seq Scan
--    tercih edebilir. Neden "index var ama kullanilmiyor" sorusunun cevabi.
-- ==============================================================================

CREATE OR REPLACE FUNCTION query_advisor.correlation_check(
    p_schema          text    DEFAULT NULL,
    p_max_correlation numeric DEFAULT 0.3
)
RETURNS TABLE(
    schema_name      text,
    table_name       text,
    column_name      text,
    data_type        text,
    correlation      numeric,
    null_frac        numeric,
    n_distinct       numeric,
    has_index        boolean,
    index_name       text,
    live_rows        bigint,
    table_size       text,
    finding          text,
    recommendation   text
)
LANGUAGE sql
STABLE
SECURITY INVOKER
AS $$
    SELECT
        st.schemaname::text,
        st.tablename::text,
        st.attname::text,
        pa.atttypid::regtype::text,
        round(st.correlation::numeric, 4),
        round(st.null_frac::numeric, 4),
        st.n_distinct,
        -- Index var mi?
        EXISTS(
            SELECT 1
            FROM   pg_index   ix
            JOIN   pg_attribute a
                   ON a.attrelid = ix.indrelid AND a.attnum = ANY(ix.indkey)
            WHERE  ix.indrelid = (
                       SELECT c.oid FROM pg_class c
                       JOIN   pg_namespace n ON n.oid = c.relnamespace
                       WHERE  c.relname = st.tablename
                         AND  n.nspname = st.schemaname
                   )
              AND  a.attname = st.attname
              AND  ix.indkey[0] = a.attnum   -- sadece leading kolon
        )                                                       AS has_index,
        -- Index ismi
        (   SELECT i.relname
            FROM   pg_index   ix
            JOIN   pg_class   i ON i.oid = ix.indexrelid
            JOIN   pg_attribute a
                   ON a.attrelid = ix.indrelid AND a.attnum = ANY(ix.indkey)
            WHERE  ix.indrelid = (
                       SELECT c.oid FROM pg_class c
                       JOIN   pg_namespace n ON n.oid = c.relnamespace
                       WHERE  c.relname = st.tablename
                         AND  n.nspname = st.schemaname
                   )
              AND  a.attname   = st.attname
              AND  ix.indkey[0] = a.attnum
            LIMIT 1
        )::text                                                 AS index_name,
        pst.n_live_tup,
        pg_size_pretty(
            pg_total_relation_size(
                quote_ident(st.schemaname) || '.' || quote_ident(st.tablename)
            )
        ),
        CASE
            WHEN abs(st.correlation) < 0.1
                THEN 'KRITIK: korelasyon neredeyse sifir — B-tree index verimsiz'
            WHEN abs(st.correlation) < p_max_correlation
                THEN 'DUSUK korelasyon — index varsa planner seq scan tercih edebilir'
            ELSE
                'ORTA korelasyon — kabul edilebilir'
        END,
        CASE
            WHEN abs(st.correlation) < 0.1
                THEN 'BRIN index deneyin: CREATE INDEX CONCURRENTLY ON '
                     || quote_ident(st.schemaname) || '.' || quote_ident(st.tablename)
                     || ' USING BRIN (' || quote_ident(st.attname) || ');'
                     || ' -- veya CLUSTER komutu ile fiziksel siralama yapabilirsiniz'
            WHEN abs(st.correlation) < p_max_correlation
                THEN 'Sorgularda bu kolonu WHERE ile kullaniyor musunuz? '
                     || 'Varsa: CLUSTER ' || quote_ident(st.tablename)
                     || ' USING <index_adi>;  (tablo yeniden fiziksel siralar)'
            ELSE NULL
        END
    FROM pg_stats st
    JOIN pg_stat_user_tables pst
      ON pst.schemaname = st.schemaname AND pst.relname = st.tablename
    JOIN pg_attribute pa
      ON pa.attname    = st.attname
     AND pa.attrelid   = (
             SELECT c.oid FROM pg_class c
             JOIN pg_namespace n ON n.oid = c.relnamespace
             WHERE c.relname = st.tablename AND n.nspname = st.schemaname
         )
     AND pa.attnum > 0
     AND NOT pa.attisdropped
    WHERE abs(st.correlation) < p_max_correlation
      AND st.null_frac < 0.5
      AND pst.n_live_tup > 10000
      AND (p_schema IS NULL OR st.schemaname = p_schema)
      AND pa.atttypid::regtype::text NOT IN ('bool','uuid')
    ORDER BY abs(st.correlation) ASC, pst.n_live_tup DESC;
$$;

COMMENT ON FUNCTION query_advisor.correlation_check IS
    '"Index var ama hala Seq Scan" sorusunun cevabi. '
    'Fiziksel siralama ile veri dagilimi tutarsizsa B-tree index verimsizlesmektedir. '
    'Dusuk korelasyonlu kolonlar icin BRIN index veya CLUSTER onerir.';

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
