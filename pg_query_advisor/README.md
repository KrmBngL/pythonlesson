# pg_query_advisor

PostgreSQL 18 için saf SQL extension. Sorgu optimizasyonu, index yönetimi ve bakım önerileri sunar.

Tüm fonksiyonlar **`query_advisor`** şeması altındadır.

---

## Fonksiyonlar

| Fonksiyon | Açıklama |
|-----------|----------|
| `query_advisor.table_health()` | Dead tuple oranı, last_vacuum/analyze, durum mesajı |
| `query_advisor.table_bloat()` | Dead tuple'a dayalı tahmini waste boyutu |
| `query_advisor.index_usage()` | Index başına scan sayısı, ACTIVE/LOW/UNUSED sınıfı |
| `query_advisor.index_health()` | Invalid ve oversized index tespiti |
| `query_advisor.missing_indexes()` | Seq scan >> index scan olan tablolar |
| `query_advisor.unused_indexes()` | Kullanılmayan index'ler + hazır `DROP INDEX CONCURRENTLY` |
| `query_advisor.duplicate_indexes()` | Aynı leading column'ları paylaşan redundant çiftler |
| `query_advisor.slow_queries()` | `pg_stat_statements` üzerinden top N yavaş sorgu |
| `query_advisor.long_running_queries()` | Şu an çalışan uzun sorgular |
| `query_advisor.lock_waits()` | Blocking/waiting zinciri analizi |
| `query_advisor.autovacuum_settings()` | Büyük tablolar için ölçek faktörü önerisi + `ALTER TABLE` |
| `query_advisor.cache_hit()` | Tablo başına buffer cache hit oranı |
| `query_advisor.report()` | 1-CRITICAL / 2-WARNING / 3-NOTICE öncelikli master rapor |
| `query_advisor.health_summary` | Her kontrol için tek satır özet view |

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

### Adım 4 — pg_stat_statements İçin postgresql.conf Düzenle

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
systemctl status postgresql-18
```

### Adım 6 — Extension Dosyalarını Kur

```bash
# Repoyu klonla (veya dosyaları sunucuya kopyala)
git clone https://github.com/KrmBngL/pythonlesson.git
cd pythonlesson/pg_query_advisor

make install PG_CONFIG=/usr/pgsql-18/bin/pg_config
```

Kurulumu doğrula:

```bash
ls /usr/pgsql-18/share/extension/pg_query_advisor*
# Çıktı:
# /usr/pgsql-18/share/extension/pg_query_advisor--1.0.sql
# /usr/pgsql-18/share/extension/pg_query_advisor.control
```

### Adım 7 — Extension'ları Veritabanında Oluştur

```bash
sudo -u postgres psql
```

```sql
-- pg_stat_statements (yavaş sorgu analizi için)
CREATE EXTENSION pg_stat_statements;

-- pg_query_advisor
CREATE EXTENSION pg_query_advisor;

-- Kurulumu doğrula
\dx
```

Beklenen çıktı:

```
        Name        | Version |   Schema        | Description
--------------------+---------+-----------------+-------------------------------
 pg_query_advisor   | 1.0     | public          | PostgreSQL Query Advisor ...
 pg_stat_statements | 1.10    | public          | track planning and execution ...
 plpgsql            | 1.0     | pg_catalog      | PL/pgSQL procedural language
```

---

## Kullanım

### Genel Sağlık Özeti

```sql
SELECT * FROM query_advisor.health_summary;
```

```
                 check_name                 | object_count
--------------------------------------------+--------------
 Tables needing VACUUM (dead >10%)          |            2
 Unused indexes (0 scans)                   |            5
 Tables likely missing indexes (seq >> idx) |            3
 Duplicate / redundant index pairs          |            1
 Invalid indexes                            |            0
```

### Master Öneri Raporu

```sql
SELECT priority, category, object_name, finding, action
FROM query_advisor.report()
ORDER BY priority, category;
```

### Dead Tuple ve Vacuum Durumu

```sql
-- Sorunlu tablolar
SELECT table_name, live_tuples, dead_tuples, dead_ratio_pct,
       last_autovacuum, health_status
FROM query_advisor.table_health()
WHERE health_status <> 'OK'
ORDER BY dead_ratio_pct DESC;
```

### Kullanılmayan Index'ler

```sql
-- 0 scan — hazır DROP komutu ile
SELECT schema_name, table_name, index_name,
       index_size, index_scans, drop_command
FROM query_advisor.unused_indexes()
WHERE index_scans = 0
  AND NOT is_primary
ORDER BY index_size_mb DESC;
```

### Index Eksikliği Tespiti

```sql
-- Seq scan çok fazla, index scan az olan tablolar
SELECT schema_name, table_name,
       seq_scan_count, index_scan_count,
       live_tuples, table_size, priority, recommendation
FROM query_advisor.missing_indexes()
ORDER BY priority, seq_scan_count DESC;
```

### Duplicate Index'ler

```sql
SELECT schema_name, table_name,
       index_a, index_b, shared_key,
       scans_a, scans_b, recommendation
FROM query_advisor.duplicate_indexes();
```

### Autovacuum Tuning (Büyük Tablolar)

```sql
-- Hazır ALTER TABLE komutu ile
SELECT table_name, estimated_rows,
       current_vac_scale, recommended_vac_scale,
       alter_command
FROM query_advisor.autovacuum_settings(p_min_rows => 100000)
WHERE recommendation <> 'OK';
```

Çıktıdaki `alter_command` doğrudan çalıştırılabilir:

```sql
ALTER TABLE public.big_table
  SET (autovacuum_vacuum_scale_factor = 0.01,
       autovacuum_vacuum_threshold    = 50);
```

### Yavaş Sorgular

```sql
-- pg_stat_statements gerektirir
SELECT query_text, calls,
       mean_exec_ms, max_exec_ms,
       cache_hit_pct, recommendation
FROM query_advisor.slow_queries(p_top_n => 20, p_min_calls => 10)
ORDER BY mean_exec_ms DESC;
```

### Anlık Uzun Çalışan Sorgular

```sql
SELECT pid, username, duration_seconds,
       wait_event_type, wait_event,
       query_text, recommendation
FROM query_advisor.long_running_queries(p_min_duration_s => 30);

-- Gerekirse iptal etmek için:
SELECT pg_cancel_backend(<pid>);
```

### Lock Bekleme Zinciri

```sql
SELECT waiting_pid, waiting_user, waiting_query,
       waiting_duration,
       blocking_pid, blocking_user, blocking_query,
       lock_type, relation_name
FROM query_advisor.lock_waits();
```

### Cache Hit Oranı

```sql
SELECT schema_name, object_name,
       heap_hit_pct, idx_hit_pct, recommendation
FROM query_advisor.cache_hit()
WHERE recommendation <> 'OK';
```

---

## RPM ile Kurulum (RHEL 8 / RHEL 9)

```bash
# rpmbuild kurulu değilse
dnf install -y rpm-build

# Build
cd pg_query_advisor
rpmbuild -bb rpm/pg_query_advisor.spec \
    --define "_topdir $(pwd)/rpmbuild" \
    --define "_sourcedir $(pwd)"

# Kurulum
rpm -ivh rpmbuild/RPMS/noarch/pg_query_advisor_18-1.0-1.*.noarch.rpm

# Kaldırma
rpm -e pg_query_advisor_18
```

---

## Parametreler

Her fonksiyon isteğe bağlı filtre parametreleri alır:

```sql
-- Sadece belirli şema
SELECT * FROM query_advisor.table_health('myschema');

-- Minimum dead tuple filtresi
SELECT * FROM query_advisor.table_health(p_min_dead_tup => 1000);

-- Minimum boyut filtresi (MB)
SELECT * FROM query_advisor.unused_indexes(p_min_size_mb => 10);

-- Minimum seq scan filtresi
SELECT * FROM query_advisor.missing_indexes(p_min_seq_scan => 500, p_min_rows => 5000);

-- Top 10 yavaş sorgu, en az 100 çağrısı olanlar
SELECT * FROM query_advisor.slow_queries(p_top_n => 10, p_min_calls => 100);
```

---

## Gereksinimler

- PostgreSQL 18 (RHEL 8 / RHEL 9)
- `pg_stat_statements` — `slow_queries()` için zorunlu, diğerleri için gerekmez

## Kaldırma

```sql
DROP EXTENSION pg_query_advisor;
```

```bash
make uninstall PG_CONFIG=/usr/pgsql-18/bin/pg_config
```
