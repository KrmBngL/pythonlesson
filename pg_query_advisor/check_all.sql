-- =============================================================================
-- pg_query_advisor — Tam Kontrol Scripti
-- Versiyon : 1.2
-- Kullanim : psql -U postgres -d <veritabani> -f check_all.sql
--            psql -U postgres -d <veritabani> -v SCHEMA=public -f check_all.sql
-- Bolumler : 0-Genel Saglik, 1-Master Rapor, 2-Dead Tuple, 3-Bloat,
--            4-Index Kullanim, 5-Unused Index, 6-Duplicate Index,
--            7-Missing Index, 8-Index Saglik, 9-Autovacuum,
--            10-Cache Hit, 11-Yavaş Sorgular, 12-Uzun Sorgular,
--            13-Lock Zinciri, 14-Buyume Tahmini, 15-Partitioning,
--            16-Index Oneri, 17-Idle Txn, 18-Vacuum Needs,
--            19-Replication Slots, 20-Config Advisor, 21-Korelasyon
-- =============================================================================

\set QUIET on
\pset linestyle unicode
\pset border 2
\pset null '(null)'
\timing off

-- Şema filtresi: psql -v SCHEMA=public ile dışarıdan verilebilir
-- Verilmezse tüm şemalar taranır
\if :{?SCHEMA}
\else
  \set SCHEMA NULL
\endif

\echo ''
\echo '============================================================'
\echo '  pg_query_advisor — Veritabani Saglik Raporu'
\echo '  Tarih : ' :'HOST'
\echo '============================================================'
\echo ''

-- Bağlantı ve versiyon bilgisi
SELECT
    current_database()                        AS veritabani,
    current_user                              AS kullanici,
    version()                                 AS pg_versiyon,
    (SELECT extversion FROM pg_extension
     WHERE extname = 'pg_query_advisor')      AS advisor_versiyon,
    now()::timestamptz(0)                     AS rapor_zamani;

-- =============================================================================
-- 0. GENEL SAGLIK OZETI
-- =============================================================================
\echo ''
\echo '------------------------------------------------------------'
\echo '  0. GENEL SAGLIK OZETI'
\echo '------------------------------------------------------------'

SELECT * FROM query_advisor.health_summary;

-- =============================================================================
-- 1. ONCELIKLI ONERI RAPORU  (1-CRITICAL / 2-WARNING / 3-NOTICE)
-- =============================================================================
\echo ''
\echo '------------------------------------------------------------'
\echo '  1. MASTER ONERI RAPORU'
\echo '------------------------------------------------------------'

SELECT
    priority,
    category,
    object_name,
    finding,
    action
FROM query_advisor.report()
ORDER BY priority, category, object_name;

-- =============================================================================
-- 2. DEAD TUPLE / VACUUM DURUMU
-- =============================================================================
\echo ''
\echo '------------------------------------------------------------'
\echo '  2. DEAD TUPLE / VACUUM DURUMU'
\echo '------------------------------------------------------------'

SELECT
    schema_name,
    table_name,
    live_tuples,
    dead_tuples,
    dead_ratio_pct      AS "dead_%",
    table_size,
    last_autovacuum,
    last_autoanalyze,
    health_status
FROM query_advisor.table_health()
ORDER BY dead_ratio_pct DESC, dead_tuples DESC;

-- =============================================================================
-- 3. TABLO BLOAT (TAHMINI WASTE)
-- =============================================================================
\echo ''
\echo '------------------------------------------------------------'
\echo '  3. TABLO BLOAT (dead tuple bazli tahmini israf)'
\echo '------------------------------------------------------------'

SELECT
    schema_name,
    table_name,
    table_size,
    dead_tuples,
    dead_ratio_pct      AS "dead_%",
    estimated_waste,
    last_autovacuum,
    recommendation
FROM query_advisor.table_bloat()
ORDER BY dead_ratio_pct DESC;

-- =============================================================================
-- 4. INDEX KULLANIM ISTATISTIKLERI
-- =============================================================================
\echo ''
\echo '------------------------------------------------------------'
\echo '  4. INDEX KULLANIM ISTATISTIKLERI'
\echo '------------------------------------------------------------'

SELECT
    schema_name,
    table_name,
    index_name,
    index_scans,
    tuples_read,
    tuples_fetched,
    index_size,
    usage_status
FROM query_advisor.index_usage()
ORDER BY
    CASE usage_status
        WHEN 'UNUSED — consider DROP INDEX CONCURRENTLY' THEN 0
        WHEN 'RARELY USED — monitor'                     THEN 1
        WHEN 'LOW USAGE'                                 THEN 2
        ELSE                                                  3
    END,
    index_scans ASC;

-- =============================================================================
-- 5. KULLANILMAYAN INDEXLER + DROP KOMUTLARI
-- =============================================================================
\echo ''
\echo '------------------------------------------------------------'
\echo '  5. KULLANILMAYAN INDEXLER'
\echo '------------------------------------------------------------'

SELECT
    schema_name,
    table_name,
    index_name,
    index_size,
    index_scans,
    is_unique,
    is_primary,
    drop_command,
    recommendation
FROM query_advisor.unused_indexes()
ORDER BY is_primary ASC, index_scans ASC, index_size_mb DESC;

-- =============================================================================
-- 6. DUPLICATE / REDUNDANT INDEXLER
-- =============================================================================
\echo ''
\echo '------------------------------------------------------------'
\echo '  6. DUPLICATE / REDUNDANT INDEXLER'
\echo '------------------------------------------------------------'

SELECT
    schema_name,
    table_name,
    index_a,
    index_b,
    shared_key,
    size_a,
    size_b,
    scans_a,
    scans_b,
    recommendation
FROM query_advisor.duplicate_indexes()
ORDER BY schema_name, table_name;

-- =============================================================================
-- 7. INDEX EKSIKLIGI (SEQ SCAN >> INDEX SCAN)
-- =============================================================================
\echo ''
\echo '------------------------------------------------------------'
\echo '  7. INDEX EKSIKLIGI (yuksek sequential scan)'
\echo '------------------------------------------------------------'

SELECT
    schema_name,
    table_name,
    seq_scan_count,
    index_scan_count,
    live_tuples,
    table_size,
    priority,
    recommendation
FROM query_advisor.missing_indexes()
ORDER BY priority, seq_scan_count DESC;

-- =============================================================================
-- 8. INDEX SAGLIK KONTROLU (invalid, oversized)
-- =============================================================================
\echo ''
\echo '------------------------------------------------------------'
\echo '  8. INDEX SAGLIK KONTROLU'
\echo '------------------------------------------------------------'

SELECT
    schema_name,
    table_name,
    index_name,
    index_size,
    index_scans,
    is_valid,
    is_unique,
    recommendation
FROM query_advisor.index_health()
WHERE recommendation <> 'OK'
ORDER BY is_valid ASC, index_size DESC;

-- =============================================================================
-- 9. AUTOVACUUM AYAR ONERISI
-- =============================================================================
\echo ''
\echo '------------------------------------------------------------'
\echo '  9. AUTOVACUUM AYAR ONERISI (buyuk tablolar)'
\echo '------------------------------------------------------------'

SELECT
    schema_name,
    table_name,
    estimated_rows,
    current_vac_threshold,
    current_vac_scale,
    recommended_vac_threshold,
    recommended_vac_scale,
    last_autovacuum,
    days_since_autovacuum,
    alter_command,
    recommendation
FROM query_advisor.autovacuum_settings()
ORDER BY estimated_rows DESC;

-- =============================================================================
-- 10. BUFFER CACHE HIT ORANLARI
-- =============================================================================
\echo ''
\echo '------------------------------------------------------------'
\echo '  10. BUFFER CACHE HIT ORANLARI'
\echo '------------------------------------------------------------'

SELECT
    schema_name,
    object_name,
    heap_hit_pct,
    idx_hit_pct,
    toast_hit_pct,
    recommendation
FROM query_advisor.cache_hit()
ORDER BY heap_hit_pct ASC;

-- =============================================================================
-- 11. YAVAŞ SORGULAR  (pg_stat_statements)
-- =============================================================================
\echo ''
\echo '------------------------------------------------------------'
\echo '  11. EN YAVAS 20 SORGU  (pg_stat_statements)'
\echo '------------------------------------------------------------'

SELECT
    query_id,
    query_text,
    calls,
    total_exec_ms,
    mean_exec_ms,
    max_exec_ms,
    stddev_exec_ms,
    rows_returned,
    cache_hit_pct,
    recommendation
FROM query_advisor.slow_queries(p_top_n => 20, p_min_calls => 3)
ORDER BY mean_exec_ms DESC;

-- =============================================================================
-- 12. ANLIK UZUN CALISHAN SORGULAR
-- =============================================================================
\echo ''
\echo '------------------------------------------------------------'
\echo '  12. ANLIK UZUN CALISHAN SORGULAR  (>5 saniye)'
\echo '------------------------------------------------------------'

SELECT
    pid,
    username,
    application_name,
    state,
    wait_event_type,
    wait_event,
    duration_seconds,
    query_text,
    recommendation
FROM query_advisor.long_running_queries(p_min_duration_s => 5)
ORDER BY duration_seconds DESC;

-- =============================================================================
-- 13. LOCK BEKLEME ZİNCİRİ
-- =============================================================================
\echo ''
\echo '------------------------------------------------------------'
\echo '  13. LOCK BEKLEME ZİNCİRİ'
\echo '------------------------------------------------------------'

SELECT
    waiting_pid,
    waiting_user,
    waiting_query,
    waiting_duration,
    blocking_pid,
    blocking_user,
    blocking_query,
    lock_type,
    relation_name
FROM query_advisor.lock_waits()
ORDER BY waiting_duration DESC;

-- =============================================================================
-- 14. TABLO BUYUME TAHMİNİ
-- =============================================================================
\echo ''
\echo '------------------------------------------------------------'
\echo '  14. TABLO BUYUME TAHMİNİ  (30 / 90 / 180 / 365 gun)'
\echo '------------------------------------------------------------'

SELECT
    schema_name,
    table_name,
    current_size,
    current_rows,
    days_of_stats,
    daily_inserts,
    daily_deletes,
    net_daily_rows,
    est_size_30d,
    est_size_90d,
    est_size_180d,
    est_size_1y,
    growth_rate_pct     AS "yillik_%",
    recommendation
FROM query_advisor.table_growth_forecast()
ORDER BY growth_rate_pct DESC NULLS LAST;

-- =============================================================================
-- 15. PARTITIONING ADAYLARI
-- =============================================================================
\echo ''
\echo '------------------------------------------------------------'
\echo '  15. PARTITIONING ADAYLARI'
\echo '------------------------------------------------------------'

SELECT
    schema_name,
    table_name,
    table_size,
    row_count,
    partition_strategy,
    partition_key,
    key_type,
    recommendation
FROM query_advisor.partition_candidates()
ORDER BY
    CASE
        WHEN recommendation LIKE 'CRITICAL%' THEN 0
        WHEN recommendation LIKE 'HIGH%'     THEN 1
        WHEN recommendation LIKE 'MEDIUM%'   THEN 2
        ELSE                                      3
    END,
    row_count DESC;

-- DDL önerisini ayrı göster (geniş çıktı)
\echo ''
\echo '  15b. PARTITIONING DDL ONERILERI'
\echo ''

\pset format wrapped
\pset columns 100
SELECT
    schema_name || '.' || table_name   AS tablo,
    partition_strategy                  AS strateji,
    partition_key                       AS anahtar,
    sample_ddl                          AS ddl_oneri
FROM query_advisor.partition_candidates()
ORDER BY row_count DESC;
\pset format aligned

-- =============================================================================
-- 16. INDEX ONERİ MOTORU  (pg_stat_statements bazli)
-- =============================================================================
\echo ''
\echo '------------------------------------------------------------'
\echo '  16. INDEX ONERİ MOTORU  (seq scan + sorgu analizi)'
\echo '------------------------------------------------------------'

SELECT
    schema_table,
    seq_scan_count,
    live_rows,
    candidate_columns,
    matching_queries,
    total_exec_time_ms,
    existing_indexes,
    recommendation
FROM query_advisor.index_recommendations()
ORDER BY
    CASE
        WHEN recommendation LIKE 'HIGH%'   THEN 0
        WHEN recommendation LIKE 'MEDIUM%' THEN 1
        ELSE                                    2
    END,
    seq_scan_count DESC;

-- DDL önerilerini ayrı göster
\echo ''
\echo '  16b. INDEX DDL ONERILERI'
\echo ''

\pset format wrapped
\pset columns 100
SELECT
    schema_table        AS tablo,
    candidate_columns   AS kolonlar,
    suggested_ddl       AS ddl_oneri
FROM query_advisor.index_recommendations()
WHERE suggested_ddl NOT LIKE 'Kolon tespit%'
ORDER BY seq_scan_count DESC;
\pset format aligned

-- =============================================================================
-- 17. IDLE IN TRANSACTION  (v1.2)
-- =============================================================================
\echo ''
\echo '------------------------------------------------------------'
\echo '  17. IDLE IN TRANSACTION  (>30 saniye)'
\echo '------------------------------------------------------------'

SELECT
    pid,
    username,
    application_name,
    state,
    duration_seconds,
    idle_since,
    lock_count,
    left(query_text, 80)    AS query_text,
    risk_level,
    recommendation
FROM query_advisor.idle_in_transaction(p_min_duration_s => 30)
ORDER BY duration_seconds DESC;

-- =============================================================================
-- 18. VACUUM NEEDS  (v1.2)
-- =============================================================================
\echo ''
\echo '------------------------------------------------------------'
\echo '  18. VACUUM / ANALYZE IHTIYACI  (esige %70 yaklasmis)'
\echo '------------------------------------------------------------'

SELECT
    schema_name,
    table_name,
    live_rows,
    dead_rows,
    vacuum_threshold,
    dead_rows_pct_filled    AS "dead_%filled",
    needs_vacuum,
    analyze_pct_filled      AS "analyze_%filled",
    needs_analyze,
    recommendation
FROM query_advisor.vacuum_needs(p_threshold_pct => 70)
ORDER BY dead_rows_pct_filled DESC;

-- =============================================================================
-- 19. REPLICATION SLOTS  (v1.2)
-- =============================================================================
\echo ''
\echo '------------------------------------------------------------'
\echo '  19. REPLICATION SLOT DURUMU'
\echo '------------------------------------------------------------'

SELECT
    slot_name,
    slot_type,
    plugin,
    database_name,
    active,
    wal_retained_mb,
    replication_lag,
    risk_level,
    recommendation
FROM query_advisor.replication_slots()
ORDER BY wal_retained_mb DESC NULLS LAST;

-- =============================================================================
-- 20. KONFIGÜRASYON DANISMANI  (v1.2)
-- =============================================================================
\echo ''
\echo '------------------------------------------------------------'
\echo '  20. KONFIGURASYON DANISMANI  (postgresql.conf)'
\echo '------------------------------------------------------------'

SELECT
    parameter,
    current_value,
    recommended_value,
    unit,
    risk_level,
    explanation
FROM query_advisor.config_advisor()
ORDER BY
    CASE risk_level
        WHEN 'CRITICAL' THEN 0
        WHEN 'WARNING'  THEN 1
        WHEN 'NOTICE'   THEN 2
        ELSE                 3
    END;

-- =============================================================================
-- 21. KORELASYON KONTROLU  (v1.2)
-- =============================================================================
\echo ''
\echo '------------------------------------------------------------'
\echo '  21. INDEX KORELASYON KONTROLU  (dusuk fiziksel siralama)'
\echo '------------------------------------------------------------'

SELECT
    schema_name,
    table_name,
    column_name,
    data_type,
    correlation,
    has_index,
    index_name,
    live_rows,
    table_size,
    finding,
    recommendation
FROM query_advisor.correlation_check(p_max_correlation => 0.3)
ORDER BY correlation ASC;

-- =============================================================================
-- RAPOR SONU
-- =============================================================================
\echo ''
\echo '============================================================'
\echo '  Rapor tamamlandi.   (pg_query_advisor v1.2)'
\echo '  Oncelik sirasi  : 1-CRITICAL > 2-WARNING > 3-NOTICE'
\echo '  Index kaldirmadan once: SELECT * FROM query_advisor.duplicate_indexes()'
\echo '  Index eklemeden once  : EXPLAIN ANALYZE ile plan dogrulayin'
\echo '  Korelasyon dusukse    : BRIN index veya CLUSTER deneyin'
\echo '  Idle transaction varsa: pg_terminate_backend(pid) ile sonlandirin'
\echo '============================================================'
\echo ''
