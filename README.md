# pg_query_advisor

PostgreSQL 18 için saf SQL DBA danışman extension'ı.
35 fonksiyon, Grafana dashboard, RPM paketi.

---

## Branch'ler

| Branch | İçerik |
|--------|--------|
| `main` | Bu sayfa ← genel giriş |
| `claude/postgres-query-analysis-extension-cBBlJ` | Extension v1.0–v1.5 (35 fonksiyon) |
| `extension` | Extension + RPM build scripti |
| `grafana` | Extension + RPM + Grafana dashboard (tam paket) |

---

## Nereden Başlamalıyım?

### Sadece extension kurmak istiyorum:

```bash
git clone https://github.com/KrmBngL/pythonlesson.git
cd pythonlesson
git checkout claude/postgres-query-analysis-extension-cBBlJ
```

### RPM paketi oluşturmak istiyorum:

```bash
git clone https://github.com/KrmBngL/pythonlesson.git
cd pythonlesson
git checkout extension
```

### Grafana dashboard da istiyorum:

```bash
git clone https://github.com/KrmBngL/pythonlesson.git
cd pythonlesson
git checkout grafana
```

---

## Hızlı Kurulum (grafana branch — her şey dahil)

```bash
git clone https://github.com/KrmBngL/pythonlesson.git
cd pythonlesson
git checkout grafana

# Extension dosyalarını kopyala
EXT_DIR=/usr/pgsql-18/share/extension
cp pg_query_advisor/pg_query_advisor.control $EXT_DIR/
cp pg_query_advisor/pg_query_advisor--*.sql  $EXT_DIR/

# PostgreSQL'e kur
psql -U postgres -d mydb -c "CREATE EXTENSION IF NOT EXISTS pg_stat_statements;"
psql -U postgres -d mydb -c "CREATE EXTENSION pg_query_advisor;"

# Tam raporu çalıştır
psql -U postgres -d mydb -f pg_query_advisor/check_all.sql
```

---

## Branch Arası Geçiş

```bash
# Mevcut branch'i gör
git branch

# Branch listesini gör (remote dahil)
git branch -a

# Branch değiştir
git checkout grafana
git checkout extension
git checkout claude/postgres-query-analysis-extension-cBBlJ
git checkout main

# En son değişiklikleri çek
git pull origin grafana
```

---

## Sürüm Özeti

| Sürüm | Fonksiyon | Eklenenler |
|-------|-----------|-----------|
| v1.0 | 13 | Temel analiz (index, vacuum, cache, sorgu) |
| v1.1 | 17 | Explain plan, büyüme tahmini, partition, index öneri |
| v1.2 | 22 | Idle txn, vacuum needs, replication slot, config, korelasyon |
| v1.3 | 27 | Sequence, FK index, bağlantı, temp file, vacuum progress |
| v1.4 | 31 | Tablespace, TOAST, deadlock, buffer cache |
| v1.5 | 35 | Wait event, index bloat, yetki denetimi, access method |
