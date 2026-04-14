# Pg_Query_Advisor — Kurulum Kılavuzu

> RHEL 8 / RHEL 9 üzerinde sıfırdan tam kurulum.
> PostgreSQL 17 veya 18 desteklenir.

---

## Adım 1 — PGDG Reposunu Ekle

```bash
# RHEL 8
dnf install -y https://download.postgresql.org/pub/repos/yum/reporpms/EL-8-x86_64/pgdg-redhat-repo-latest.noarch.rpm
dnf -qy module disable postgresql

# RHEL 9
dnf install -y https://download.postgresql.org/pub/repos/yum/reporpms/EL-9-x86_64/pgdg-redhat-repo-latest.noarch.rpm
dnf -qy module disable postgresql
```

---

## Adım 2 — PostgreSQL'i Kur

```bash
# PostgreSQL 18
dnf install -y postgresql18-server postgresql18

# PostgreSQL 17 tercih edenler için
dnf install -y postgresql17-server postgresql17
```

---

## Adım 3 — Veritabanını İlklendir ve Başlat

```bash
# PG18
/usr/pgsql-18/bin/postgresql-18-setup initdb
systemctl enable --now postgresql-18

# PG17
/usr/pgsql-17/bin/postgresql-17-setup initdb
systemctl enable --now postgresql-17
```

Servis durumunu kontrol et:

```bash
systemctl status postgresql-18
```

---

## Adım 4 — pg_stat_statements İçin postgresql.conf Düzenle

```bash
vi /var/lib/pgsql/18/data/postgresql.conf
```

Şu satırı ekle veya uncomment et:

```ini
shared_preload_libraries = 'pg_stat_statements'

# İsteğe bağlı ek ayarlar
pg_stat_statements.max           = 10000
pg_stat_statements.track         = all
pg_stat_statements.track_utility = on
pg_stat_statements.save          = on
```

---

## Adım 5 — PostgreSQL'i Yeniden Başlat

```bash
systemctl restart postgresql-18
```

---

## Adım 6 — Repoyu İndir

```bash
cd /opt
git clone https://github.com/KrmBngL/pythonlesson.git pg_query_advisor_repo
cd pg_query_advisor_repo
git checkout extension
```

---

## Adım 7 — Extension Dosyalarını Kopyala

Üç farklı yöntem mevcuttur. Sırasıyla deneyin:

### Yöntem A — Otomatik Script (Önerilen)

```bash
cd /opt/pg_query_advisor_repo/pg_query_advisor
bash install.sh -v 18 -d mydb
```

Tüm veritabanlarına kurmak için:

```bash
bash install.sh -v 18 -a
```

### Yöntem B — make install

`postgresql18-devel` paketi gerektirir:

```bash
dnf install -y postgresql18-devel
cd /opt/pg_query_advisor_repo/pg_query_advisor
make PG_CONFIG=/usr/pgsql-18/bin/pg_config install
```

### Yöntem C — Manuel Kopyalama

Devel paketi yoksa:

```bash
EXT_DIR=/usr/pgsql-18/share/extension
cd /opt/pg_query_advisor_repo/pg_query_advisor

cp pg_query_advisor.control       $EXT_DIR/
cp pg_query_advisor--1.0.sql      $EXT_DIR/
cp pg_query_advisor--1.0--1.1.sql $EXT_DIR/
cp pg_query_advisor--1.1.sql      $EXT_DIR/
cp pg_query_advisor--1.1--1.2.sql $EXT_DIR/
cp pg_query_advisor--1.2.sql      $EXT_DIR/
cp pg_query_advisor--1.2--1.3.sql $EXT_DIR/
cp pg_query_advisor--1.3.sql      $EXT_DIR/
cp pg_query_advisor--1.3--1.4.sql $EXT_DIR/
cp pg_query_advisor--1.4.sql      $EXT_DIR/
cp pg_query_advisor--1.4--1.5.sql $EXT_DIR/
cp pg_query_advisor--1.5.sql      $EXT_DIR/
```

---

## Adım 8 — Extension'ı Veritabanında Oluştur

```bash
# Önce pg_stat_statements kur
psql -U postgres -d mydb -c "CREATE EXTENSION IF NOT EXISTS pg_stat_statements;"

# Sonra pg_query_advisor kur
psql -U postgres -d mydb -c "CREATE EXTENSION pg_query_advisor;"
```

Kurulumu doğrula:

```bash
psql -U postgres -d mydb -c "SELECT extname, extversion FROM pg_extension WHERE extname = 'pg_query_advisor';"
```

Beklenen çıktı:

```
     extname      | extversion
------------------+------------
 pg_query_advisor | 1.5
```

---

## Adım 9 — Tam Raporu Çalıştır

SQL ile doğrudan:

```bash
psql -U postgres -d mydb -f /opt/pg_query_advisor_repo/pg_query_advisor/check_all.sql
```

Bash ile HTML rapor:

```bash
bash /opt/pg_query_advisor_repo/pg_query_advisor/check_all.sh -v 18 -d mydb -o /var/reports
# Çıktı: /var/reports/mydb_latest.html
```

---

## Mevcut Sürümden Güncelleme

1.x sürümü zaten kuruluysa:

```bash
# Tek veritabanı
psql -U postgres -d mydb -c "ALTER EXTENSION pg_query_advisor UPDATE TO '1.5';"

# Tüm veritabanları
bash /opt/pg_query_advisor_repo/pg_query_advisor/install.sh -v 18 -a -u
```

---

## Kaldırma

```bash
# Veritabanından kaldır
bash /opt/pg_query_advisor_repo/pg_query_advisor/uninstall.sh -v 18 -d mydb

# Tüm veritabanlarından kaldır ve dosyaları sil
bash /opt/pg_query_advisor_repo/pg_query_advisor/uninstall.sh -v 18 -a -f -y
```
