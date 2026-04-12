# pg_query_advisor

PostgreSQL 18 için saf SQL DBA danışman extension'ı.
35 fonksiyon, 34 bölümlük rapor, RPM paketi.

---

## Branch'ler

| Branch | İçerik |
|--------|--------|
| `main` | Boş / başlangıç |
| `claude/postgres-query-analysis-extension-cBBlJ` | Extension v1.0–v1.5 (35 fonksiyon) |
| `extension` | Extension + RPM spec + build-rpm.sh ← **bu branch** |
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
git checkout extension
```

### 3. Extension Dosyalarını Kopyala (PostgreSQL 18)

```bash
EXT_DIR=/usr/pgsql-18/share/extension
cp pg_query_advisor/pg_query_advisor.control        $EXT_DIR/
cp pg_query_advisor/pg_query_advisor--*.sql         $EXT_DIR/
```

### 4. PostgreSQL'e Kur

```bash
psql -U postgres -d mydb -c "CREATE EXTENSION IF NOT EXISTS pg_stat_statements;"
psql -U postgres -d mydb -c "CREATE EXTENSION pg_query_advisor;"
```

### 5. Tam Raporu Çalıştır

```bash
psql -U postgres -d mydb -f pg_query_advisor/check_all.sql
```

---

## RPM Paketi Oluştur (RHEL 8/9)

```bash
dnf install -y rpm-build rpmdevtools
cd pg_query_advisor/rpm
bash build-rpm.sh 18        # PostgreSQL 18 için
bash build-rpm.sh 17        # PostgreSQL 17 için
```

RPM çıktısı: `~/rpmbuild/RPMS/noarch/pg_query_advisor_18-1.5-*.noarch.rpm`

```bash
# Kurulum
rpm -ivh ~/rpmbuild/RPMS/noarch/pg_query_advisor_18-1.5*.noarch.rpm

# Başkasına gönder
scp ~/rpmbuild/RPMS/noarch/pg_query_advisor_18-1.5*.noarch.rpm kullanici@sunucu:/tmp/
ssh kullanici@sunucu "rpm -ivh /tmp/pg_query_advisor_18-1.5*.noarch.rpm"
```

---

## Grafana Dashboard İçin

```bash
git checkout grafana
```

---

## Dizin Yapısı

```
pg_query_advisor/
├── pg_query_advisor.control
├── pg_query_advisor--1.0.sql  →  pg_query_advisor--1.5.sql
├── pg_query_advisor--1.0--1.1.sql  →  pg_query_advisor--1.4--1.5.sql
├── check_all.sql
├── README.md
└── rpm/
    ├── pg_query_advisor.spec
    └── build-rpm.sh
```

Detaylı fonksiyon referansı: [pg_query_advisor/README.md](pg_query_advisor/README.md)
