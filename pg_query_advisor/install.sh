#!/usr/bin/env bash
# install.sh — pg_query_advisor kurulum yardımcı scripti
# RHEL 8 / RHEL 9 — PostgreSQL 17 veya 18 için

set -euo pipefail

# ---------------------------------------------------------------------------
# Kullanım
# ---------------------------------------------------------------------------
usage() {
    cat <<EOF
Kullanım: $0 [SEÇENEKLER]

  -v, --pg-version NUM    PostgreSQL major version (varsayılan: 18)
  -d, --database   DB     Extension'ı kuracak veritabanı (varsayılan: postgres)
  -h, --help              Bu yardım mesajını göster

Örnekler:
  $0                          # PG18, postgres DB
  $0 -v 17 -d mydb            # PG17, mydb
EOF
    exit 0
}

PG_VERSION=18
DBNAME=postgres

while [[ $# -gt 0 ]]; do
    case $1 in
        -v|--pg-version) PG_VERSION="$2"; shift 2 ;;
        -d|--database)   DBNAME="$2";     shift 2 ;;
        -h|--help)       usage ;;
        *) echo "Bilinmeyen parametre: $1"; usage ;;
    esac
done

PG_CONFIG="/usr/pgsql-${PG_VERSION}/bin/pg_config"
PSQL="/usr/pgsql-${PG_VERSION}/bin/psql"

# ---------------------------------------------------------------------------
# Kontroller
# ---------------------------------------------------------------------------
if [[ ! -x "$PG_CONFIG" ]]; then
    echo "HATA: $PG_CONFIG bulunamadı."
    echo "PostgreSQL ${PG_VERSION} kurulu mu? PGDG repo'dan kurabilirsiniz:"
    echo "  dnf install -y postgresql${PG_VERSION}-server"
    exit 1
fi

echo "========================================"
echo " pg_query_advisor Kurulum"
echo " PostgreSQL : $PG_VERSION"
echo " Veritabanı : $DBNAME"
echo "========================================"

# ---------------------------------------------------------------------------
# Extension dosyalarını kur
# ---------------------------------------------------------------------------
echo "[1/3] Extension dosyaları kopyalanıyor..."
make install PG_CONFIG="$PG_CONFIG"
echo "      OK"

# ---------------------------------------------------------------------------
# pg_stat_statements kontrolü (zorunlu değil ama önerilir)
# ---------------------------------------------------------------------------
echo "[2/3] pg_stat_statements kontrolü..."
SL_LIBS=$("$PSQL" -U postgres -d "$DBNAME" -tAc \
    "SELECT current_setting('shared_preload_libraries');" 2>/dev/null || true)

if echo "$SL_LIBS" | grep -q "pg_stat_statements"; then
    echo "      pg_stat_statements shared_preload_libraries içinde — OK"
else
    echo "      UYARI: pg_stat_statements shared_preload_libraries içinde değil."
    echo "      Yavaş sorgu analizi için postgresql.conf dosyasına ekleyin:"
    echo "        shared_preload_libraries = 'pg_stat_statements'"
    echo "      Ardından PostgreSQL'i yeniden başlatın ve şunu çalıştırın:"
    echo "        CREATE EXTENSION pg_stat_statements;"
fi

# ---------------------------------------------------------------------------
# Extension'ı veritabanında oluştur
# ---------------------------------------------------------------------------
echo "[3/3] Extension oluşturuluyor: $DBNAME..."
"$PSQL" -U postgres -d "$DBNAME" -c "CREATE EXTENSION IF NOT EXISTS pg_query_advisor;"
echo "      OK"

# ---------------------------------------------------------------------------
# Kullanım özeti
# ---------------------------------------------------------------------------
cat <<'EOF'

======================================== Kurulum Tamamlandı ========================================

Hızlı başlangıç:

  -- Genel sağlık özeti
  SELECT * FROM pg_advisor.health_summary;

  -- Tam öneri raporu (tüm şemalar)
  SELECT * FROM pg_advisor.report() ORDER BY priority, category;

  -- Belirli şema için
  SELECT * FROM pg_advisor.report('public') ORDER BY priority;

  -- Dead tuple / vacuum durumu
  SELECT * FROM pg_advisor.table_health() WHERE health_status <> 'OK';

  -- Kullanılmayan index'ler ve DROP komutları
  SELECT index_name, index_size, index_scans, drop_command
  FROM   pg_advisor.unused_indexes()
  WHERE  NOT is_primary AND index_scans = 0;

  -- Büyük tablolar için autovacuum ayar önerisi
  SELECT table_name, estimated_rows, current_vac_scale,
         recommended_vac_scale, alter_command
  FROM   pg_advisor.autovacuum_settings()
  WHERE  recommendation <> 'OK';

  -- Yavaş sorgular (pg_stat_statements gerektirir)
  SELECT query_text, calls, mean_exec_ms, recommendation
  FROM   pg_advisor.slow_queries(p_top_n => 10);

  -- Anlık uzun çalışan sorgular
  SELECT pid, username, duration_seconds, query_text, recommendation
  FROM   pg_advisor.long_running_queries(p_min_duration_s => 5);

  -- Duplicate / redundant index'ler
  SELECT * FROM pg_advisor.duplicate_indexes();

====================================================================================================
EOF
