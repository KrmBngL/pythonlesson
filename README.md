# pg_query_advisor

PostgreSQL 18 için saf SQL DBA danışman extension'ı.
35 fonksiyon, 34 bölümlük rapor, Grafana dashboard, RPM paketi.

---

## Branch'ler

| Branch | İçerik |
|--------|--------|
| `main` | Boş / başlangıç |
| `claude/postgres-query-analysis-extension-cBBlJ` | Extension v1.0–v1.5 (35 fonksiyon) |
| `extension` | Extension + RPM spec + build-rpm.sh |
| `grafana` | Extension + RPM + Grafana dashboard ← **bu branch** |

---

## Hızlı Başlangıç

### 1. Repoyu Clone'la

```bash
git clone https://github.com/KrmBngL/pythonlesson.git
cd pythonlesson
```

### 2. Bu Branch'e Geç (grafana — her şey dahil)

```bash
git checkout grafana
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
# veya
bash build-rpm.sh 17        # PostgreSQL 17 için
```

RPM çıktısı: `~/rpmbuild/RPMS/noarch/pg_query_advisor_18-1.5-*.noarch.rpm`

```bash
# Kurulum
rpm -ivh ~/rpmbuild/RPMS/noarch/pg_query_advisor_18-1.5*.noarch.rpm
```

---

## Grafana Dashboard Kur

```bash
# Datasource ayarını düzenle (url, user, database)
vi pg_query_advisor/grafana/provisioning/datasources/postgres.yml

# Dosyaları kopyala
cp pg_query_advisor/grafana/provisioning/datasources/postgres.yml \
   /etc/grafana/provisioning/datasources/
cp pg_query_advisor/grafana/provisioning/dashboards/pg_query_advisor.yml \
   /etc/grafana/provisioning/dashboards/
cp pg_query_advisor/grafana/dashboards/pg_query_advisor.json \
   /etc/grafana/provisioning/dashboards/

systemctl restart grafana-server
# Arayüz: http://<sunucu>:3000
```

Ya da Grafana → Dashboards → Import → JSON dosyasını yükle.

---

## Dizin Yapısı

```
pg_query_advisor/
├── pg_query_advisor.control         # Extension metadata (v1.5)
├── Makefile
├── pg_query_advisor--1.0.sql        # v1.0 tam kurulum
├── pg_query_advisor--1.0--1.1.sql   # v1.0→v1.1 upgrade
├── pg_query_advisor--1.1.sql
├── pg_query_advisor--1.1--1.2.sql
├── pg_query_advisor--1.2.sql
├── pg_query_advisor--1.2--1.3.sql
├── pg_query_advisor--1.3.sql
├── pg_query_advisor--1.3--1.4.sql
├── pg_query_advisor--1.4.sql
├── pg_query_advisor--1.4--1.5.sql
├── pg_query_advisor--1.5.sql        # v1.5 tam kurulum (35 fonksiyon)
├── check_all.sql                    # 34 bölümlük tam rapor scripti
├── install.sh                       # Otomatik kurulum scripti
├── README.md                        # Extension detaylı dokümantasyon
├── grafana/
│   ├── dashboards/pg_query_advisor.json
│   ├── provisioning/datasources/postgres.yml
│   └── provisioning/dashboards/pg_query_advisor.yml
└── rpm/
    ├── pg_query_advisor.spec
    └── build-rpm.sh
```

---

## Mevcut Sürümler

| Sürüm | Fonksiyon Sayısı | Eklenenler |
|-------|-----------------|-----------|
| v1.0 | 13 | Temel analiz |
| v1.1 | 17 | Sorgu planı, büyüme tahmini |
| v1.2 | 22 | Operasyonel izleme |
| v1.3 | 27 | Güvenlik ağı, kaynak analizi |
| v1.4 | 31 | Depolama, bellek |
| v1.5 | 35 | Performans tanı, güvenlik denetimi |

Detaylı fonksiyon referansı: [pg_query_advisor/README.md](pg_query_advisor/README.md)
