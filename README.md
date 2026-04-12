# pg_query_advisor

PostgreSQL 18 için saf SQL DBA danışman extension'ı.
35 fonksiyon, 34 bölümlük rapor scripti.

---

## Branch'ler

| Branch | İçerik |
|--------|--------|
| `main` | Boş / başlangıç |
| `claude/postgres-query-analysis-extension-cBBlJ` | Extension v1.0–v1.5 (35 fonksiyon) ← **bu branch** |
| `extension` | Extension + RPM spec + build-rpm.sh |
| `grafana` | Extension + RPM + Grafana dashboard |

---

## Hızlı Başlangıç

### 1. Repoyu Clone'la

```bash
git clone https://github.com/KrmBngL/pythonlesson.git
cd pythonlesson
```

### 2. Bu Branch'e Geç

```bash
git checkout claude/postgres-query-analysis-extension-cBBlJ
```

### 3. Extension Dosyalarını Kopyala (PostgreSQL 18)

```bash
EXT_DIR=/usr/pgsql-18/share/extension
cp pg_query_advisor/pg_query_advisor.control        $EXT_DIR/
cp pg_query_advisor/pg_query_advisor--*.sql         $EXT_DIR/
```

PostgreSQL 17 için:
```bash
EXT_DIR=/usr/pgsql-17/share/extension
cp pg_query_advisor/pg_query_advisor.control        $EXT_DIR/
cp pg_query_advisor/pg_query_advisor--*.sql         $EXT_DIR/
```

### 4. postgresql.conf Ayarla

```bash
vi /var/lib/pgsql/18/data/postgresql.conf
# Ekle:
# shared_preload_libraries = 'pg_stat_statements'

systemctl restart postgresql-18
```

### 5. Extension'ı Kur

```bash
psql -U postgres -d mydb -c "CREATE EXTENSION IF NOT EXISTS pg_stat_statements;"
psql -U postgres -d mydb -c "CREATE EXTENSION pg_query_advisor;"

# Versiyon kontrolü
psql -U postgres -d mydb -c \
  "SELECT extversion FROM pg_extension WHERE extname = 'pg_query_advisor';"
```

### 6. Tam Raporu Çalıştır

```bash
psql -U postgres -d mydb -f pg_query_advisor/check_all.sql
```

Belirli şema için:
```bash
psql -U postgres -d mydb -v SCHEMA=public -f pg_query_advisor/check_all.sql
```

---

## Önceki Sürümden Güncelleme

```bash
# Önce dosyaları kopyala (yukarıdaki adım 3)
# Sonra:
psql -U postgres -d mydb -c \
  "ALTER EXTENSION pg_query_advisor UPDATE TO '1.5';"
```

---

## Diğer Branch'lere Geç

```bash
# RPM paketi oluşturmak için
git checkout extension

# Grafana dashboard için
git checkout grafana
```

---

## Dizin Yapısı

```
pg_query_advisor/
├── pg_query_advisor.control         # v1.5
├── pg_query_advisor--1.0.sql        # Tam kurulum v1.0
├── pg_query_advisor--1.0--1.1.sql   # Upgrade scripti
├── pg_query_advisor--1.1.sql
├── pg_query_advisor--1.1--1.2.sql
├── pg_query_advisor--1.2.sql
├── pg_query_advisor--1.2--1.3.sql
├── pg_query_advisor--1.3.sql
├── pg_query_advisor--1.3--1.4.sql
├── pg_query_advisor--1.4.sql
├── pg_query_advisor--1.4--1.5.sql
├── pg_query_advisor--1.5.sql        # Tam kurulum v1.5 (35 fonksiyon)
├── check_all.sql                    # 34 bölümlük rapor
├── install.sh
└── README.md                        # Detaylı fonksiyon dokümantasyonu
```

Detaylı fonksiyon referansı: [pg_query_advisor/README.md](pg_query_advisor/README.md)
