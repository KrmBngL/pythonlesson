#!/usr/bin/env bash
# uninstall.sh — pg_query_advisor extension'ını kaldırır
# RHEL 8 / RHEL 9 — PostgreSQL 17 veya 18

set -euo pipefail

RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
info()   { echo -e "${CYAN}[INFO]${RESET}  $*"; }
ok()     { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()   { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
err()    { echo -e "${RED}[ERROR]${RESET} $*" >&2; }
header() { echo -e "\n${BOLD}${CYAN}=== $* ===${RESET}"; }

usage() {
    cat <<EOF
Kullanım: $0 [SEÇENEKLER]

  -v, --pg-version NUM    PostgreSQL major version (varsayılan: 18)
  -U, --user       USER   PostgreSQL superuser (varsayılan: postgres)
  -d, --database   DB     Hedef veritabanı (varsayılan: postgres)
  -a, --all-db            Tüm veritabanlarından kaldır
  -f, --files             Extension dosyalarını da sil (share/extension)
  -y, --yes               Onay sormadan devam et
  -h, --help              Bu yardım mesajını göster

Örnekler:
  $0 -d mydb              # mydb'den kaldır
  $0 -a                   # Tüm veritabanlarından kaldır
  $0 -a -f -y             # Tüm DB + dosyalar, onay yok
EOF
    exit 0
}

PG_VERSION=18
PG_USER=postgres
DBNAME=postgres
ALL_DB=false
REMOVE_FILES=false
AUTO_YES=false

while [[ $# -gt 0 ]]; do
    case $1 in
        -v|--pg-version) PG_VERSION="$2"; shift 2 ;;
        -U|--user)       PG_USER="$2";    shift 2 ;;
        -d|--database)   DBNAME="$2";     shift 2 ;;
        -a|--all-db)     ALL_DB=true;     shift ;;
        -f|--files)      REMOVE_FILES=true; shift ;;
        -y|--yes)        AUTO_YES=true;   shift ;;
        -h|--help)       usage ;;
        *) err "Bilinmeyen parametre: $1"; usage ;;
    esac
done

PSQL="/usr/pgsql-${PG_VERSION}/bin/psql"
EXT_DIR="/usr/pgsql-${PG_VERSION}/share/extension"

if [[ ! -x "$PSQL" ]]; then
    err "$PSQL bulunamadı."
    exit 1
fi

# ---------------------------------------------------------------------------
# Onay
# ---------------------------------------------------------------------------
if ! $AUTO_YES; then
    header "Kaldırma Özeti"
    $ALL_DB && info "Hedef: Tüm kullanıcı veritabanları" || info "Hedef: ${DBNAME}"
    $REMOVE_FILES && warn "Extension dosyaları da silinecek: ${EXT_DIR}/pg_query_advisor*"
    echo ""
    read -r -p "Devam etmek istiyor musunuz? [e/H] " confirm
    [[ "${confirm,,}" != "e" ]] && { info "İptal edildi."; exit 0; }
fi

# ---------------------------------------------------------------------------
# Veritabanından kaldırma fonksiyonu
# ---------------------------------------------------------------------------
drop_from_db() {
    local db="$1"

    local ext_ver
    ext_ver=$("$PSQL" -U "$PG_USER" -d "$db" -tAc \
        "SELECT extversion FROM pg_extension WHERE extname = 'pg_query_advisor';" \
        2>/dev/null | tr -d ' \n' || true)

    if [[ -z "$ext_ver" ]]; then
        warn "[$db] pg_query_advisor kurulu değil — atlanıyor"
        return
    fi

    info "[$db] pg_query_advisor ${ext_ver} kaldırılıyor..."
    "$PSQL" -U "$PG_USER" -d "$db" -c \
        "DROP EXTENSION pg_query_advisor CASCADE;" > /dev/null
    ok "[$db] pg_query_advisor kaldırıldı"
}

# ---------------------------------------------------------------------------
# Ana akış
# ---------------------------------------------------------------------------
header "pg_query_advisor Kaldırma"

if $ALL_DB; then
    mapfile -t DB_LIST < <("$PSQL" -U "$PG_USER" -d postgres -tAc \
        "SELECT datname FROM pg_database
         WHERE datistemplate = false
         ORDER BY datname;" 2>/dev/null)

    for db in "${DB_LIST[@]}"; do
        [[ -z "$db" ]] && continue
        drop_from_db "$db"
    done
else
    drop_from_db "$DBNAME"
fi

# ---------------------------------------------------------------------------
# Dosya kaldırma (isteğe bağlı)
# ---------------------------------------------------------------------------
if $REMOVE_FILES; then
    header "Extension dosyaları siliniyor"
    if ls "${EXT_DIR}"/pg_query_advisor* 2>/dev/null | grep -q .; then
        rm -f "${EXT_DIR}"/pg_query_advisor.control \
              "${EXT_DIR}"/pg_query_advisor--*.sql
        ok "Dosyalar silindi: ${EXT_DIR}/pg_query_advisor*"
    else
        warn "Silinecek dosya bulunamadı: ${EXT_DIR}/pg_query_advisor*"
    fi
fi

header "Tamamlandı"
ok "pg_query_advisor başarıyla kaldırıldı."
