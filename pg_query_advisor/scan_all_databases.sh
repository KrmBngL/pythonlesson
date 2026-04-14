#!/usr/bin/env bash
# scan_all_databases.sh — PostgreSQL instance'taki tüm veritabanlarını tarar,
# pg_query_advisor kurulu olanları listeler, kritik sorunları özetler.
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
crit()   { echo -e "${RED}${BOLD}[CRITICAL]${RESET} $*"; }

# ---------------------------------------------------------------------------
# Kullanım
# ---------------------------------------------------------------------------
usage() {
    cat <<EOF
Kullanım: $0 [SEÇENEKLER]

  -v, --pg-version NUM    PostgreSQL major version (varsayılan: 18)
  -U, --user       USER   PostgreSQL superuser (varsayılan: postgres)
  -s, --summary           Sadece özet (CRITICAL/WARNING sayısı)
  -i, --install           pg_query_advisor kurulu olmayan DB'lere de kur
  -o, --output-dir DIR    JSON ve CSV çıktı dizini (varsayılan: ./scan_results)
  -h, --help              Bu yardım mesajını göster

Örnekler:
  $0                       # Tüm veritabanlarını tara, özet göster
  $0 -v 17 -s              # PG17, kısa özet
  $0 -v 18 -i              # Kurulu olmayanlara da kur, sonra tara
  $0 -v 18 -o /var/scans   # Özel çıktı dizini
EOF
    exit 0
}

# ---------------------------------------------------------------------------
# Varsayılanlar
# ---------------------------------------------------------------------------
PG_VERSION=18
PG_USER=postgres
SUMMARY_ONLY=false
AUTO_INSTALL=false
OUTPUT_DIR="./scan_results"
TIMESTAMP=$(date '+%Y%m%d_%H%M%S')
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

while [[ $# -gt 0 ]]; do
    case $1 in
        -v|--pg-version) PG_VERSION="$2"; shift 2 ;;
        -U|--user)       PG_USER="$2";    shift 2 ;;
        -s|--summary)    SUMMARY_ONLY=true; shift ;;
        -i|--install)    AUTO_INSTALL=true; shift ;;
        -o|--output-dir) OUTPUT_DIR="$2"; shift 2 ;;
        -h|--help)       usage ;;
        *) err "Bilinmeyen parametre: $1"; usage ;;
    esac
done

PSQL="/usr/pgsql-${PG_VERSION}/bin/psql"

# ---------------------------------------------------------------------------
# Kontroller
# ---------------------------------------------------------------------------
if [[ ! -x "$PSQL" ]]; then
    err "$PSQL bulunamadı. PostgreSQL ${PG_VERSION} kurulu mu?"
    exit 1
fi

# ---------------------------------------------------------------------------
# Fonksiyonlar
# ---------------------------------------------------------------------------

# Tek veritabanında extension var mı?
ext_version() {
    local db="$1"
    "$PSQL" -U "$PG_USER" -d "$db" -tAc \
        "SELECT extversion FROM pg_extension WHERE extname = 'pg_query_advisor';" \
        2>/dev/null | tr -d ' \n' || true
}

# health_summary sorgusu
scan_db() {
    local db="$1"
    local ext_ver="$2"

    # CRITICAL ve WARNING sayısını al
    local result
    result=$("$PSQL" -U "$PG_USER" -d "$db" -tAc \
        "SELECT
           COUNT(*) FILTER (WHERE priority = 1) AS critical,
           COUNT(*) FILTER (WHERE priority = 2) AS warning,
           COUNT(*) FILTER (WHERE priority = 3) AS notice
         FROM query_advisor.report();" \
        2>/dev/null || echo "ERROR|0|0|0")

    local critical warning notice
    IFS='|' read -r critical warning notice <<< "$(echo "$result" | tr -s ' ' | xargs | tr ' ' '|')"
    critical="${critical:-0}"; warning="${warning:-0}"; notice="${notice:-0}"

    printf "%-20s %-8s %-10s %-10s %-10s\n" \
        "$db" "$ext_ver" "$critical" "$warning" "$notice"

    # CSV satırı yaz
    echo "${db},${ext_ver},${critical},${warning},${notice}" >> "$CSV_FILE"

    # CRITICAL varsa detay göster
    if [[ "${critical:-0}" -gt 0 ]] && ! $SUMMARY_ONLY; then
        "$PSQL" -U "$PG_USER" -d "$db" -tAc \
            "SELECT '  -> ' || category || ': ' || message
             FROM query_advisor.report()
             WHERE priority = 1
             ORDER BY category;" \
            2>/dev/null | while read -r line; do
            crit "${db} | ${line}"
        done
    fi
}

# ---------------------------------------------------------------------------
# Ana akış
# ---------------------------------------------------------------------------
header "pg_query_advisor Instance Tarayıcı"
info "PostgreSQL sürümü : ${PG_VERSION}"
info "Kullanıcı         : ${PG_USER}"
info "Zaman             : $(date '+%Y-%m-%d %H:%M:%S')"

# Veritabanı listesi al
mapfile -t DB_LIST < <("$PSQL" -U "$PG_USER" -d postgres -tAc \
    "SELECT datname FROM pg_database
     WHERE datistemplate = false
     ORDER BY datname;" 2>/dev/null)

if [[ ${#DB_LIST[@]} -eq 0 ]]; then
    err "Veritabanı listesi alınamadı — PostgreSQL çalışıyor mu?"
    exit 1
fi

info "Toplam veritabanı: ${#DB_LIST[@]}"

# Çıktı dizinini hazırla
mkdir -p "$OUTPUT_DIR"
CSV_FILE="${OUTPUT_DIR}/scan_${TIMESTAMP}.csv"
echo "database,ext_version,critical,warning,notice" > "$CSV_FILE"

# ---------------------------------------------------------------------------
# Tablo başlığı
# ---------------------------------------------------------------------------
header "Tarama Sonuçları"
printf "${BOLD}%-20s %-8s %-10s %-10s %-10s${RESET}\n" \
    "VERİTABANI" "SÜRÜM" "CRITICAL" "WARNING" "NOTICE"
printf '%s\n' "$(printf '─%.0s' {1..62})"

TOTAL_CRITICAL=0
TOTAL_WARNING=0
TOTAL_NOTICE=0
DB_WITH_EXT=0
DB_WITHOUT_EXT=0
DB_INSTALLED=()
DB_SKIPPED=()

for db in "${DB_LIST[@]}"; do
    [[ -z "$db" ]] && continue

    ext_ver=$(ext_version "$db")

    if [[ -z "$ext_ver" ]]; then
        if $AUTO_INSTALL; then
            info "[$db] pg_query_advisor kurulu değil — kuruluyor..."
            "$PSQL" -U "$PG_USER" -d "$db" -c \
                "CREATE EXTENSION IF NOT EXISTS pg_stat_statements;" > /dev/null 2>&1 || true
            "$PSQL" -U "$PG_USER" -d "$db" -c \
                "CREATE EXTENSION pg_query_advisor;" > /dev/null 2>&1 && {
                ext_ver=$(ext_version "$db")
                DB_INSTALLED+=("$db")
                ok "[$db] Kuruldu: ${ext_ver}"
            } || {
                warn "[$db] Kurulum başarısız — atlanıyor"
                DB_SKIPPED+=("$db")
                echo "${db},not_installed,N/A,N/A,N/A" >> "$CSV_FILE"
                continue
            }
        else
            printf "%-20s %-8s %-10s\n" "$db" "—" "(kurulu değil)"
            echo "${db},not_installed,N/A,N/A,N/A" >> "$CSV_FILE"
            (( DB_WITHOUT_EXT++ )) || true
            continue
        fi
    fi

    (( DB_WITH_EXT++ )) || true
    scan_db "$db" "$ext_ver"

    # Toplam sayaçlar (CSV'den oku)
    local_line=$(tail -1 "$CSV_FILE")
    IFS=',' read -r _ _ c w n <<< "$local_line"
    [[ "$c" =~ ^[0-9]+$ ]] && (( TOTAL_CRITICAL += c )) || true
    [[ "$w" =~ ^[0-9]+$ ]] && (( TOTAL_WARNING  += w )) || true
    [[ "$n" =~ ^[0-9]+$ ]] && (( TOTAL_NOTICE   += n )) || true
done

printf '%s\n' "$(printf '─%.0s' {1..62})"
printf "${BOLD}%-20s %-8s ${RED}%-10s${YELLOW}%-10s${GREEN}%-10s${RESET}\n" \
    "TOPLAM" "—" "$TOTAL_CRITICAL" "$TOTAL_WARNING" "$TOTAL_NOTICE"

# ---------------------------------------------------------------------------
# Özet
# ---------------------------------------------------------------------------
header "Özet"
info "Extension kurulu veritabanı sayısı : ${DB_WITH_EXT}"
info "Extension kurulu olmayan           : ${DB_WITHOUT_EXT}"

if [[ ${#DB_INSTALLED[@]} -gt 0 ]]; then
    ok "Bu taramada otomatik kurulan DB'ler: ${DB_INSTALLED[*]}"
fi
if [[ ${#DB_SKIPPED[@]} -gt 0 ]]; then
    warn "Atlanan DB'ler (kurulum başarısız): ${DB_SKIPPED[*]}"
fi

echo ""
if [[ "$TOTAL_CRITICAL" -gt 0 ]]; then
    crit "Toplam CRITICAL uyarı: ${TOTAL_CRITICAL} — HEMEN İNCELEYİN!"
elif [[ "$TOTAL_WARNING" -gt 0 ]]; then
    warn "Toplam WARNING uyarı: ${TOTAL_WARNING} — yakında dikkat gerektiriyor."
else
    ok "Tüm veritabanlarında kritik sorun yok."
fi

info "CSV raporu: ${CSV_FILE}"

# ---------------------------------------------------------------------------
# JSON özet (basit, jq gerektirmez)
# ---------------------------------------------------------------------------
JSON_FILE="${OUTPUT_DIR}/scan_${TIMESTAMP}.json"
cat > "$JSON_FILE" <<JSON
{
  "scan_time": "$(date -u '+%Y-%m-%dT%H:%M:%SZ')",
  "pg_version": ${PG_VERSION},
  "pg_user": "${PG_USER}",
  "databases_total": ${#DB_LIST[@]},
  "databases_with_extension": ${DB_WITH_EXT},
  "databases_without_extension": ${DB_WITHOUT_EXT},
  "totals": {
    "critical": ${TOTAL_CRITICAL},
    "warning": ${TOTAL_WARNING},
    "notice": ${TOTAL_NOTICE}
  },
  "csv_report": "${CSV_FILE}"
}
JSON
info "JSON özet: ${JSON_FILE}"
