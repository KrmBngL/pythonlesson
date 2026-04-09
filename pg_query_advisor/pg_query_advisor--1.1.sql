-- pg_query_advisor--1.1.sql
-- PostgreSQL Query Advisor Extension v1.1
-- Compatible with PostgreSQL 17 / 18
-- Targets: RHEL 8 / RHEL 9

\echo Use "CREATE EXTENSION pg_query_advisor" to load this file. \quit

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
