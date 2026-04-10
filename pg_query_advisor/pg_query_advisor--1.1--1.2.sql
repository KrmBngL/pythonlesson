-- pg_query_advisor--1.1--1.2.sql
-- Upgrade: 1.1 → 1.2
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
