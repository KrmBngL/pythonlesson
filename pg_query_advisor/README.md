# pg_query_advisor

PostgreSQL 18 için saf SQL extension. Sorgu optimizasyonu, index yönetimi ve bakım önerileri sunar.

Tüm fonksiyonlar **`query_advisor`** şeması altındadır.

---

## Sürüm Geçmişi

| Sürüm | Yenilikler |
|-------|-----------|
| **1.0** | 13 temel fonksiyon + health_summary view |
| **1.1** | EXPLAIN analizi, büyüme tahmini, partition adayları, index öneri motoru |
| **1.2** | Idle transaction, vacuum ihtiyaç analizi, replication slot izleme, config danışmanı, korelasyon kontrolü |

---

## Tüm Fonksiyonlar

### v1.0 — Temel Analiz

| Fonksiyon | Açıklama |
|-----------|----------|
| `query_advisor.table_health()` | Dead tuple oranı, last_vacuum/analyze, durum mesajı |
| `query_advisor.table_bloat()` | Dead tuple'a dayalı tahmini waste boyutu |
| `query_advisor.index_usage()` | Index başına scan sayısı, ACTIVE/LOW/UNUSED sınıfı |
| `query_advisor.index_health()` | Invalid ve oversized index tespiti |
| `query_advisor.missing_indexes()` | Seq scan >> index scan olan tablolar |
| `query_advisor.unused_indexes()` | Kullanılmayan indexler + hazır `DROP INDEX CONCURRENTLY` |
| `query_advisor.duplicate_indexes()` | Aynı leading column'ları paylaşan redundant çiftler |
| `query_advisor.slow_queries()` | `pg_stat_statements` üzerinden top N yavaş sorgu |
| `query_advisor.long_running_queries()` | Şu an çalışan uzun sorgular |
| `query_advisor.lock_waits()` | Blocking/waiting zinciri analizi |
| `query_advisor.autovacuum_settings()` | Büyük tablolar için ölçek faktörü önerisi + `ALTER TABLE` |
| `query_advisor.cache_hit()` | Tablo başına buffer cache hit oranı |
| `query_advisor.report()` | 1-CRITICAL / 2-WARNING / 3-NOTICE öncelikli master rapor |
| `query_advisor.health_summary` | Her kontrol için tek satır özet (VIEW) |

### v1.1 — Sorgu Planı ve Büyüme Analizi

| Fonksiyon | Açıklama |
|-----------|----------|
| `query_advisor.explain_plan(query, params)` | EXPLAIN (FORMAT JSON) çıktısını tablo olarak döner, plan node'larını açıklar |
| `query_advisor.table_growth_forecast()` | Günlük insert/delete istatistiğiyle 30/90/180/365 gün boyut tahmini |
| `query_advisor.partition_candidates()` | Büyük tablolarda RANGE/LIST/HASH partition stratejisi + örnek DDL |
| `query_advisor.index_recommendations()` | Seq scan + pg_stat_statements birleştirerek sütun bazlı index önerisi + DDL |

### v1.2 — Operasyonel İzleme

| Fonksiyon | Açıklama |
|-----------|----------|
| `query_advisor.idle_in_transaction()` | Açık kalmış transaction'lar — autovacuum engelleyici, lock biriktirir |
| `query_advisor.vacuum_needs()` | Autovacuum eşiğine yaklaşan tablolar; erken uyarı |
| `query_advisor.replication_slots()` | Takılı/geride kalmış slot'lar — WAL disk baskısı riski |
| `query_advisor.config_advisor()` | shared_buffers, work_mem, fsync vb. için RAM bazlı öneriler |
| `query_advisor.correlation_check()` | Düşük korelasyonlu sütunlarda B-tree verimsizliği; BRIN/CLUSTER önerisi |

---

## Kurulum — RHEL 8 / RHEL 9 + PostgreSQL 18

### Adım 1 — PGDG Reposunu Ekle

```bash
# RHEL 8
dnf install -y https://download.postgresql.org/pub/repos/yum/reporpms/EL-8-x86_64/pgdg-redhat-repo-latest.noarch.rpm
dnf -qy module disable postgresql

# RHEL 9
dnf install -y https://download.postgresql.org/pub/repos/yum/reporpms/EL-9-x86_64/pgdg-redhat-repo-latest.noarch.rpm
dnf -qy module disable postgresql
```

### Adım 2 — PostgreSQL 18'i Kur

```bash
dnf install -y postgresql18-server postgresql18
```

### Adım 3 — Veritabanını İlklendir

```bash
/usr/pgsql-18/bin/postgresql-18-setup initdb
systemctl enable postgresql-18
systemctl start postgresql-18
```

### Adım 4 — pg_stat_statements için postgresql.conf Düzenle

```bash
vi /var/lib/pgsql/18/data/postgresql.conf
```

Şu satırı ekle veya uncomment et:

```
shared_preload_libraries = 'pg_stat_statements'
```

İsteğe bağlı ek ayarlar:

```
pg_stat_statements.max             = 10000
pg_stat_statements.track           = all
pg_stat_statements.track_utility   = on
pg_stat_statements.save            = on
```

### Adım 5 — PostgreSQL'i Yeniden Başlat

```bash
systemctl restart postgresql-18
```

### Adım 6 — Extension Dosyalarını Kopyala

**Yöntem A: make install (postgresql18-devel gerekli)**

```bash
cd pg_query_advisor
make PG_CONFIG=/usr/pgsql-18/bin/pg_config install
```

**Yöntem B: Manuel kopyalama (devel paketi olmadan)**

```bash
EXT_DIR=/usr/pgsql-18/share/extension
cp pg_query_advisor.control          $EXT_DIR/
cp pg_query_advisor--1.0.sql         $EXT_DIR/
cp pg_query_advisor--1.0--1.1.sql    $EXT_DIR/
cp pg_query_advisor--1.1.sql         $EXT_DIR/
cp pg_query_advisor--1.1--1.2.sql    $EXT_DIR/
cp pg_query_advisor--1.2.sql         $EXT_DIR/
```

### Adım 7 — Extension'ı Oluştur

```bash
psql -U postgres -d mydb -c "CREATE EXTENSION IF NOT EXISTS pg_stat_statements;"
psql -U postgres -d mydb -c "CREATE EXTENSION pg_query_advisor;"
```

Zaten 1.0 veya 1.1 yüklüyse güncelleme:

```bash
psql -U postgres -d mydb -c "ALTER EXTENSION pg_query_advisor UPDATE TO '1.2';"
```

Kurulumu doğrula:

```bash
psql -U postgres -d mydb -c "SELECT extversion FROM pg_extension WHERE extname = 'pg_query_advisor';"
```

---

## Kullanım

### Tam Kontrol Raporu (Tüm Bölümler)

```bash
psql -U postgres -d mydb -f check_all.sql
```

Sadece belirli bir şema için:

```bash
psql -U postgres -d mydb -v SCHEMA=public -f check_all.sql
```

`check_all.sql` çalıştırılabilecek 21 bölüm:

| Bölüm | Fonksiyon |
|-------|-----------|
| 0 | health_summary |
| 1 | report() |
| 2 | table_health() |
| 3 | table_bloat() |
| 4 | index_usage() |
| 5 | unused_indexes() |
| 6 | duplicate_indexes() |
| 7 | missing_indexes() |
| 8 | index_health() |
| 9 | autovacuum_settings() |
| 10 | cache_hit() |
| 11 | slow_queries() |
| 12 | long_running_queries() |
| 13 | lock_waits() |
| 14 | table_growth_forecast() |
| 15 | partition_candidates() |
| 16 | index_recommendations() |
| 17 | idle_in_transaction() |
| 18 | vacuum_needs() |
| 19 | replication_slots() |
| 20 | config_advisor() |
| 21 | correlation_check() |

---

## Fonksiyon Referansı

### table_health()

```sql
SELECT * FROM query_advisor.table_health();
SELECT * FROM query_advisor.table_health(p_schema => 'public');
```

**Döndürdüğü sütunlar:** schema_name, table_name, live_tuples, dead_tuples, dead_ratio_pct, table_size, last_autovacuum, last_autoanalyze, health_status

Dead tuple oranı %20'nin üzerindeyse `VACUUM NEEDED`, altındaysa `OK` döner.

---

### table_bloat()

```sql
SELECT * FROM query_advisor.table_bloat();
```

**Döndürdüğü sütunlar:** schema_name, table_name, table_size, dead_tuples, dead_ratio_pct, estimated_waste, last_autovacuum, recommendation

`estimated_waste`: dead tuple × ortalama tuple boyutu tahmini.

---

### index_usage()

```sql
SELECT * FROM query_advisor.index_usage();
SELECT * FROM query_advisor.index_usage(p_schema => 'public');
```

**Döndürdüğü sütunlar:** schema_name, table_name, index_name, index_scans, tuples_read, tuples_fetched, index_size, usage_status

`usage_status` değerleri: `UNUSED — consider DROP INDEX CONCURRENTLY`, `RARELY USED — monitor`, `LOW USAGE`, `ACTIVE`

---

### index_health()

```sql
SELECT * FROM query_advisor.index_health()
WHERE recommendation <> 'OK';
```

**Döndürdüğü sütunlar:** schema_name, table_name, index_name, index_size, index_scans, is_valid, is_unique, recommendation

Invalid index tespiti + boyutça büyük ama az kullanılan indexleri raporlar.

---

### missing_indexes()

```sql
SELECT * FROM query_advisor.missing_indexes();
SELECT * FROM query_advisor.missing_indexes(p_schema => 'public');
```

**Döndürdüğü sütunlar:** schema_name, table_name, seq_scan_count, index_scan_count, live_tuples, table_size, priority, recommendation

`seq_scan_count > index_scan_count * 10` ve tablo > 10.000 satırsa önerir.

---

### unused_indexes()

```sql
SELECT * FROM query_advisor.unused_indexes();
```

**Döndürdüğü sütunlar:** schema_name, table_name, index_name, index_size, index_scans, is_unique, is_primary, drop_command, recommendation

`drop_command` sütunu: `DROP INDEX CONCURRENTLY schema.index_name;`

---

### duplicate_indexes()

```sql
SELECT * FROM query_advisor.duplicate_indexes();
```

**Döndürdüğü sütunlar:** schema_name, table_name, index_a, index_b, shared_key, size_a, size_b, scans_a, scans_b, recommendation

Aynı leading key'e sahip iki index varsa ikisini birlikte gösterir.

---

### slow_queries()

> `pg_stat_statements` extension gereklidir.

```sql
SELECT * FROM query_advisor.slow_queries();
SELECT * FROM query_advisor.slow_queries(p_top_n => 20, p_min_calls => 5);
```

**Parametreler:** p_top_n (default 10), p_min_calls (default 3)

**Döndürdüğü sütunlar:** query_id, query_text, calls, total_exec_ms, mean_exec_ms, max_exec_ms, stddev_exec_ms, rows_returned, cache_hit_pct, recommendation

---

### long_running_queries()

```sql
SELECT * FROM query_advisor.long_running_queries();
SELECT * FROM query_advisor.long_running_queries(p_min_duration_s => 10);
```

**Parametreler:** p_min_duration_s (default 30)

**Döndürdüğü sütunlar:** pid, username, application_name, state, wait_event_type, wait_event, duration_seconds, query_text, recommendation

---

### lock_waits()

```sql
SELECT * FROM query_advisor.lock_waits();
```

**Döndürdüğü sütunlar:** waiting_pid, waiting_user, waiting_query, waiting_duration, blocking_pid, blocking_user, blocking_query, lock_type, relation_name

---

### autovacuum_settings()

```sql
SELECT * FROM query_advisor.autovacuum_settings();
SELECT * FROM query_advisor.autovacuum_settings(p_min_rows => 100000);
```

**Parametreler:** p_min_rows (default 100000)

**Döndürdüğü sütunlar:** schema_name, table_name, estimated_rows, current_vac_threshold, current_vac_scale, recommended_vac_threshold, recommended_vac_scale, last_autovacuum, days_since_autovacuum, alter_command, recommendation

`alter_command`: Tabloyu per-table ayarla güncelleyen hazır `ALTER TABLE ... SET (autovacuum_...)` komutu.

---

### cache_hit()

```sql
SELECT * FROM query_advisor.cache_hit();
SELECT * FROM query_advisor.cache_hit(p_schema => 'public');
```

**Döndürdüğü sütunlar:** schema_name, object_name, heap_hit_pct, idx_hit_pct, toast_hit_pct, recommendation

Hit oranı %99 altındaysa WARNING, %95 altındaysa CRITICAL.

---

### report()

```sql
SELECT * FROM query_advisor.report()
ORDER BY priority, category;
```

**Döndürdüğü sütunlar:** priority (1/2/3), category, object_name, finding, action

Tüm fonksiyonları çalıştırıp öncelik sırasına göre düzenlenmiş birleşik rapor.

---

### health_summary (VIEW)

```sql
SELECT * FROM query_advisor.health_summary;
```

Her kategori için tek satır özet. Sorunlu öğe sayısını ve en yüksek önceliği gösterir.

---

### explain_plan() — v1.1

```sql
SELECT * FROM query_advisor.explain_plan(
    'SELECT * FROM orders WHERE customer_id = $1',
    ARRAY['123']
);
```

**Parametreler:** p_query text, p_params text[] DEFAULT NULL

**Döndürdüğü sütunlar:** node_type, startup_cost, total_cost, plan_rows, plan_width, actual_rows, actual_loops, filter, index_name, join_type, sort_key, extra, recommendation

EXPLAIN (ANALYZE, FORMAT JSON) çıktısını recursive olarak düzleştirir. Sequential Scan için index önerisi, Hash Join için maliyet uyarısı verir.

---

### table_growth_forecast() — v1.1

```sql
SELECT * FROM query_advisor.table_growth_forecast();
SELECT * FROM query_advisor.table_growth_forecast(p_schema => 'public');
```

**Döndürdüğü sütunlar:** schema_name, table_name, current_size, current_rows, days_of_stats, daily_inserts, daily_deletes, net_daily_rows, est_size_30d, est_size_90d, est_size_180d, est_size_1y, growth_rate_pct, recommendation

`pg_stat_user_tables.n_tup_ins` / `n_tup_del` verisiyle günlük net büyüme hesaplar. %100+ yıllık büyümede partition önerir.

---

### partition_candidates() — v1.1

```sql
SELECT * FROM query_advisor.partition_candidates();
SELECT * FROM query_advisor.partition_candidates(p_schema => 'public', p_min_size_mb => 500);
```

**Parametreler:** p_schema (default NULL), p_min_size_mb (default 100)

**Döndürdüğü sütunlar:** schema_name, table_name, table_size, row_count, partition_strategy, partition_key, key_type, sample_ddl, recommendation

- `partition_strategy`: RANGE / LIST / HASH
- `sample_ddl`: Oluşturulacak partition tablosu için örnek DDL
- `recommendation`: CRITICAL (>10 GB veya >50M satır) / HIGH / MEDIUM

---

### index_recommendations() — v1.1

> `pg_stat_statements` extension gereklidir.

```sql
SELECT * FROM query_advisor.index_recommendations();
SELECT * FROM query_advisor.index_recommendations(p_schema => 'public', p_min_seq_scans => 100);
```

**Parametreler:** p_schema (default NULL), p_min_seq_scans (default 50)

**Döndürdüğü sütunlar:** schema_table, seq_scan_count, live_rows, candidate_columns, matching_queries, total_exec_time_ms, existing_indexes, suggested_ddl, recommendation

Yüksek seq scan + pg_stat_statements WHERE koşullarını birleştirerek hangi sütuna index açılması gerektiğini belirler. `suggested_ddl` hazır `CREATE INDEX CONCURRENTLY` içerir.

---

### idle_in_transaction() — v1.2

```sql
SELECT * FROM query_advisor.idle_in_transaction();
SELECT * FROM query_advisor.idle_in_transaction(p_min_duration_s => 60);
```

**Parametreler:** p_min_duration_s (default 30)

**Döndürdüğü sütunlar:** pid, username, application_name, client_addr, state, duration_seconds, idle_since, lock_count, query_text, risk_level, recommendation

`recommendation` sütunu hazır `pg_terminate_backend(pid)` komutu içerir.

**Risk seviyeleri:**
- `CRITICAL`: > 1 saat — autovacuum engelliyor
- `WARNING`: > 5 dakika — lock tutuyor
- `NOTICE`: > eşik değeri

---

### vacuum_needs() — v1.2

```sql
SELECT * FROM query_advisor.vacuum_needs();
SELECT * FROM query_advisor.vacuum_needs(p_schema => 'public', p_threshold_pct => 80);
```

**Parametreler:** p_schema (default NULL), p_threshold_pct (default 70)

**Döndürdüğü sütunlar:** schema_name, table_name, live_rows, dead_rows, vacuum_threshold, dead_rows_pct_filled, last_autovacuum, autovacuum_count, analyze_threshold, mod_rows, analyze_pct_filled, needs_vacuum, needs_analyze, recommendation

Per-table `autovacuum_vacuum_threshold` ve `autovacuum_vacuum_scale_factor` override'larını dikkate alır. `p_threshold_pct` ile eşiğe kaç % yaklaştığında uyarı verileceği ayarlanır.

---

### replication_slots() — v1.2

```sql
SELECT * FROM query_advisor.replication_slots();
```

**Döndürdüğü sütunlar:** slot_name, slot_type, plugin, database_name, active, active_pid, restart_lsn, confirmed_lsn, wal_retained_mb, replication_lag, risk_level, recommendation

**Risk seviyeleri:**
- `CRITICAL`: Pasif slot + > 1 GB WAL birikimi
- `WARNING`: Pasif slot veya aktif ama > 512 MB birikimi
- `OK`: Normal

Pasif slotlar için `recommendation`: `SELECT pg_drop_replication_slot('slot_name');`

---

### config_advisor() — v1.2

```sql
SELECT * FROM query_advisor.config_advisor();
SELECT parameter, current_value, recommended_value, risk_level
FROM query_advisor.config_advisor()
WHERE risk_level <> 'OK';
```

**Döndürdüğü sütunlar:** parameter, current_value, recommended_value, unit, risk_level, explanation

Kontrol ettiği parametreler:

| Parametre | Önerilen | Açıklama |
|-----------|---------|----------|
| `shared_buffers` | RAM/4 | Küçükse disk I/O artar |
| `effective_cache_size` | RAM×3/4 | Planner tahmini |
| `work_mem` | 64 MB | Sort/Hash belleği |
| `maintenance_work_mem` | RAM/16 | VACUUM/CREATE INDEX |
| `wal_buffers` | 64 MB | WAL yazma tamponu |
| `max_connections` | ≤ 200 | >500 shared memory şişer |
| `checkpoint_completion_target` | 0.9 | I/O spike azaltır |
| `log_min_duration_statement` | 1000 ms | Yavaş sorgu loglama |
| `autovacuum` | on | CRITICAL: kapalıysa tablo şişer |
| `fsync` | on | CRITICAL: kapalıysa veri kaybı riski |

---

### correlation_check() — v1.2

```sql
SELECT * FROM query_advisor.correlation_check();
SELECT * FROM query_advisor.correlation_check(p_schema => 'public', p_max_correlation => 0.5);
```

**Parametreler:** p_schema (default NULL), p_max_correlation (default 0.3)

**Döndürdüğü sütunlar:** schema_name, table_name, column_name, data_type, correlation, null_frac, n_distinct, has_index, index_name, live_rows, table_size, finding, recommendation

**Bulgular:**
- `KRITIK`: korelasyon ≈ 0 — B-tree index tabloya erişimde fiziksel sıraya uymaz → Heap Fetch maliyeti yüksek
- `DUSUK`: planner seq scan'i index scan'e tercih edebilir

**Öneriler:**
- Korelasyon < 0.1 → `BRIN index` önerisi (insert sırasına yakın fiziksel düzen)
- Korelasyon < eşik → `CLUSTER table USING index_name` (fiziksel yeniden sıralama)

> Sadece > 10.000 satırlı tabloları, null_frac < 0.5 olan sütunları ve bool/uuid hariç tipleri değerlendirir.

---

## Yapı Özeti

```
pg_query_advisor/
├── pg_query_advisor.control         # Extension metadata (default_version = 1.2)
├── Makefile                         # PGXS build
├── pg_query_advisor--1.0.sql        # v1.0 tam kurulum (13 fonksiyon)
├── pg_query_advisor--1.0--1.1.sql   # v1.0 → v1.1 upgrade (4 fonksiyon eklendi)
├── pg_query_advisor--1.1.sql        # v1.1 tam kurulum (17 fonksiyon)
├── pg_query_advisor--1.1--1.2.sql   # v1.1 → v1.2 upgrade (5 fonksiyon eklendi)
├── pg_query_advisor--1.2.sql        # v1.2 tam kurulum (22 fonksiyon)
├── check_all.sql                    # Tüm 21 kontrolü çalıştıran birleşik script
├── install.sh                       # Otomatik kurulum scripti
└── rpm/
    └── pg_query_advisor.spec        # RHEL 8/9 RPM spec
```

---

## Hızlı Başlangıç

```bash
# Tüm raporu çalıştır
psql -U postgres -d mydb -f check_all.sql

# Sadece kritik sorunlar
psql -U postgres -d mydb -c "
  SELECT priority, category, object_name, finding, action
  FROM query_advisor.report()
  WHERE priority = 1
  ORDER BY category, object_name;
"

# Yavaş sorgular (top 10)
psql -U postgres -d mydb -c "SELECT * FROM query_advisor.slow_queries();"

# Index temizliği
psql -U postgres -d mydb -c "SELECT drop_command FROM query_advisor.unused_indexes() WHERE NOT is_primary;"

# Config kontrolü (sadece sorunlar)
psql -U postgres -d mydb -c "SELECT parameter, current_value, recommended_value, risk_level FROM query_advisor.config_advisor() WHERE risk_level <> 'OK';"

# Idle transaction tehlikesi
psql -U postgres -d mydb -c "SELECT pid, username, duration_seconds, risk_level, recommendation FROM query_advisor.idle_in_transaction();"
```

---

## Gereksinimler

| Gereksinim | Açıklama |
|-----------|----------|
| PostgreSQL | 16, 17 veya 18 |
| `pg_stat_statements` | `slow_queries()` ve `index_recommendations()` için zorunlu |
| OS | RHEL 8, RHEL 9 veya uyumlu (AlmaLinux, Rocky Linux, Oracle Linux) |
| Yetkiler | Extension oluşturmak için superuser; fonksiyon çalıştırmak için USAGE on schema |

---

## Kaldırma

```sql
DROP EXTENSION pg_query_advisor CASCADE;
```

Upgrade script'leri bırakmak istemiyorsanız:

```bash
EXT_DIR=/usr/pgsql-18/share/extension
rm -f $EXT_DIR/pg_query_advisor*
```
