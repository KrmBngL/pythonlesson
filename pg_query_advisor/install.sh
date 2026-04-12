#!/usr/bin/env bash
# install.sh — pg_query_advisor kurulum / güncelleme yardımcı scripti
# RHEL 8 / RHEL 9 — PostgreSQL 17 veya 18

set -euo pipefail

# ---------------------------------------------------------------------------
# Renkli çıktı
# ---------------------------------------------------------------------------
RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
info()   { echo -e "${CYAN}[INFO]${RESET}  $*"; }
ok()     { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()   { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
err()    { echo -e "${RED}[ERROR]${RESET} $*" >&2; }
header() { echo -e "\n${BOLD}${CYAN}=== $* ===${RESET}"; }

# ---------------------------------------------------------------------------
# Kullanım
# ---------------------------------------------------------------------------
usage() {
    cat <<EOF
Kullanım: $0 [SEÇENEKLER]

  -v, --pg-version NUM    PostgreSQL major version (varsayılan: 18)
  -U, --user       USER   PostgreSQL superuser (varsayılan: postgres)
  -d, --database   DB     Extension kurulacak veritabanı (varsayılan: postgres)
  -a, --all-db            Tüm kullanıcı veritabanlarına kur
  -u, --upgrade           Mevcut extension'ı 1.5'e güncelle (ALTER EXTENSION ... UPDATE)
  -h, --help              Bu yardım mesajını göster

Örnekler:
  $0                              # PG18, postgres DB
  $0 -v 17 -d mydb                # PG17, mydb
  $0 -v 18 -a                     # PG18, tüm veritabanları
  $0 -v 18 -d mydb -u             # PG18, mydb — güncelle (1.x -> 1.5)
  $0 -v 18 -a -u                  # PG18, tüm DB — güncelle
EOF
    exit 0
}

# ---------------------------------------------------------------------------
# Varsayılanlar
# ---------------------------------------------------------------------------
PG_VERSION=18
PG_USER=postgres
DBNAME=postgres
ALL_DB=false
UPGRADE=false

while [[ $# -gt 0 ]]; do
    case $1 in
        -v|--pg-version) PG_VERSION="$2"; shift 2 ;;
        -U|--user)       PG_USER="$2";    shift 2 ;;
        -d|--database)   DBNAME="$2";     shift 2 ;;
        -a|--all-db)     ALL_DB=true;     shift ;;
        -u|--upgrade)    UPGRADE=true;    shift ;;
        -h|--help)       usage ;;
        *) err "Bilinmeyen parametre: $1"; usage ;;
    esac
done

PG_CONFIG="/usr/pgsql-${PG_VERSION}/bin/pg_config"
PSQL="/usr/pgsql-${PG_VERSION}/bin/psql"
EXT_DIR="/usr/pgsql-${PG_VERSION}/share/extension"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_VERSION="1.5"

# ---------------------------------------------------------------------------
# pg_config kontrolü
# ---------------------------------------------------------------------------
if [[ ! -x "$PG_CONFIG" ]]; then
    err "$PG_CONFIG bulunamadı. PostgreSQL ${PG_VERSION} kurulu mu?"
    echo ""
    echo "  # RHEL 8:"
    echo "  dnf install -y https://download.postgresql.org/pub/repos/yum/reporpms/EL-8-x86_64/pgdg-redhat-repo-latest.noarch.rpm"
    echo "  dnf -qy module disable postgresql"
    echo "  dnf install -y postgresql${PG_VERSION}-server postgresql${PG_VERSION}"
    echo ""
    echo "  # RHEL 9:"
    echo "  dnf install -y https://download.postgresql.org/pub/repos/yum/reporpms/EL-9-x86_64/pgdg-redhat-repo-latest.noarch.rpm"
    echo "  dnf -qy module disable postgresql"
    echo "  dnf install -y postgresql${PG_VERSION}-server postgresql${PG_VERSION}"
    exit 1
fi

if [[ ! -x "$PSQL" ]]; then
    err "$PSQL bulunamadı."
    exit 1
fi

# ---------------------------------------------------------------------------
# Özet
# ---------------------------------------------------------------------------
header "pg_query_advisor ${TARGET_VERSION} Kurulum"
info "PostgreSQL sürümü : ${PG_VERSION}"
info "Kullanıcı         : ${PG_USER}"
if $ALL_DB; then
    info "Hedef             : Tüm kullanıcı veritabanları"
else
    info "Veritabanı        : ${DBNAME}"
fi
$UPGRADE && info "Mod               : UPGRADE (ALTER EXTENSION ... UPDATE TO '${TARGET_VERSION}')" \
         || info "Mod               : Yeni kurulum (CREATE EXTENSION)"

# ---------------------------------------------------------------------------
# Adım 1 — Extension dosyalarını PostgreSQL dizinine kopyala
# ---------------------------------------------------------------------------
header "Adım 1/3 — Extension dosyaları kopyalanıyor"

if make -C "$SCRIPT_DIR" install PG_CONFIG="$PG_CONFIG" 2>/dev/null; then
    ok "make install başarılı"
else
    warn "make install başarısız — elle kopyalanıyor..."
    if [[ ! -d "$EXT_DIR" ]]; then
        err "$EXT_DIR dizini bulunamadı."
        exit 1
    fi
    install -m 0644 "${SCRIPT_DIR}/pg_query_advisor.control" "$EXT_DIR/"
    install -m 0644 "${SCRIPT_DIR}"/pg_query_advisor--*.sql  "$EXT_DIR/"
    ok "Dosyalar ${EXT_DIR} dizinine kopyalandı"
fi

# ---------------------------------------------------------------------------
# Adım 2 — pg_stat_statements kontrolü
# ---------------------------------------------------------------------------
header "Adım 2/3 — pg_stat_statements kontrolü"

SL_LIBS=$("$PSQL" -U "$PG_USER" -d "${DBNAME}" -tAc \
    "SELECT current_setting('shared_preload_libraries');" 2>/dev/null || true)

if echo "$SL_LIBS" | grep -q "pg_stat_statements"; then
    ok "pg_stat_statements shared_preload_libraries içinde"
else
    warn "pg_stat_statements shared_preload_libraries içinde değil."
    echo "  Yavaş sorgu analizi için postgresql.conf dosyasına ekleyin:"
    echo "    shared_preload_libraries = 'pg_stat_statements'"
    echo "  Ardından PostgreSQL'i yeniden başlatın:"
    echo "    systemctl restart postgresql-${PG_VERSION}"
    echo "  Ve her hedef veritabanında çalıştırın:"
    echo "    CREATE EXTENSION IF NOT EXISTS pg_stat_statements;"
fi

# ---------------------------------------------------------------------------
# Adım 3 — Extension'ı veritabanında oluştur / güncelle
# ---------------------------------------------------------------------------
header "Adım 3/3 — Extension yükleniyor"

install_to_db() {
    local db="$1"
    local current_ver

    current_ver=$("$PSQL" -U "$PG_USER" -d "$db" -tAc \
        "SELECT extversion FROM pg_extension WHERE extname = 'pg_query_advisor';" \
        2>/dev/null || true)
    current_ver="${current_ver// /}"   # trim whitespace

    if [[ -z "$current_ver" ]]; then
        # Kurulu değil — fresh install
        info "[$db] pg_stat_statements kuruluyor..."
        "$PSQL" -U "$PG_USER" -d "$db" -c \
            "CREATE EXTENSION IF NOT EXISTS pg_stat_statements;" > /dev/null 2>&1 || true
        info "[$db] pg_query_advisor ${TARGET_VERSION} kuruluyor..."
        "$PSQL" -U "$PG_USER" -d "$db" -c \
            "CREATE EXTENSION pg_query_advisor;" > /dev/null
        ok "[$db] pg_query_advisor ${TARGET_VERSION} kuruldu"
    elif $UPGRADE; then
        if [[ "$current_ver" == "$TARGET_VERSION" ]]; then
            ok "[$db] Zaten ${TARGET_VERSION} sürümünde — güncelleme gerekmez"
        else
            info "[$db] ${current_ver} → ${TARGET_VERSION} güncelleniyor..."
            "$PSQL" -U "$PG_USER" -d "$db" -c \
                "ALTER EXTENSION pg_query_advisor UPDATE TO '${TARGET_VERSION}';" > /dev/null
            ok "[$db] pg_query_advisor ${TARGET_VERSION} sürümüne güncellendi"
        fi
    else
        warn "[$db] pg_query_advisor zaten kurulu (${current_ver}). Güncellemek için -u bayrağını kullanın."
    fi
}

if $ALL_DB; then
    # Tüm kullanıcı veritabanları (template ve postgres hariç)
    mapfile -t DB_LIST < <("$PSQL" -U "$PG_USER" -d postgres -tAc \
        "SELECT datname FROM pg_database
         WHERE datistemplate = false
           AND datname NOT IN ('postgres')
         ORDER BY datname;" 2>/dev/null)

    # postgres veritabanını da dahil et
    DB_LIST=("postgres" "${DB_LIST[@]}")

    for db in "${DB_LIST[@]}"; do
        [[ -z "$db" ]] && continue
        install_to_db "$db"
    done
else
    install_to_db "$DBNAME"
fi

# ---------------------------------------------------------------------------
# Tamamlandı
# ---------------------------------------------------------------------------
header "Kurulum Tamamlandı"
echo ""
echo "  Hızlı başlangıç:"
echo ""
echo "  -- Genel sağlık özeti"
echo "  SELECT * FROM query_advisor.health_summary;"
echo ""
echo "  -- Tam öneri raporu"
echo "  SELECT * FROM query_advisor.report() ORDER BY priority, category;"
echo ""
echo "  -- Yavaş sorgular"
echo "  SELECT query_text, calls, mean_exec_ms, recommendation"
echo "  FROM   query_advisor.slow_queries(p_top_n => 10);"
echo ""
echo "  -- Kullanılmayan indexler ve DROP komutları"
echo "  SELECT index_name, index_size, drop_command"
echo "  FROM   query_advisor.unused_indexes()"
echo "  WHERE  NOT is_primary AND index_scans = 0;"
echo ""
echo "  Tam rapor için:"
echo "  psql -U ${PG_USER} -d <veritabani> -f ${SCRIPT_DIR}/check_all.sql"
echo ""
