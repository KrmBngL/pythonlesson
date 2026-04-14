#!/usr/bin/env bash
# setup_cron.sh — pg_query_advisor için otomatik tarama/rapor cron job'ı kurar
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
  -s, --schedule   CRON   Cron ifadesi (varsayılan: "0 7 * * *" — her gün 07:00)
  -o, --output-dir DIR    Rapor dizini (varsayılan: /var/log/pg_query_advisor)
  -t, --type       TYPE   scan | report | both (varsayılan: both)
  -r, --remove            Cron job'ı kaldır
  -h, --help              Bu yardım mesajını göster

Zamanlamalar:
  "0 7 * * *"     Her gün 07:00
  "0 7 * * 1"     Her Pazartesi 07:00
  "0 */6 * * *"   Her 6 saatte bir
  "*/30 * * * *"  Her 30 dakikada bir (scan için önerilir)

Örnekler:
  $0                                      # Varsayılan: her gün 07:00, both
  $0 -s "0 */6 * * *" -t scan            # 6 saatte bir tarama
  $0 -s "0 8 * * 1" -t report            # Pazartesi 08:00 HTML rapor
  $0 -v 17 -o /srv/reports               # PG17, özel dizin
  $0 -r                                   # Cron job'ı kaldır
EOF
    exit 0
}

PG_VERSION=18
PG_USER=postgres
SCHEDULE="0 7 * * *"
OUTPUT_DIR="/var/log/pg_query_advisor"
JOB_TYPE="both"
REMOVE=false
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CRON_TAG="# pg_query_advisor_managed"

while [[ $# -gt 0 ]]; do
    case $1 in
        -v|--pg-version) PG_VERSION="$2"; shift 2 ;;
        -U|--user)       PG_USER="$2";    shift 2 ;;
        -s|--schedule)   SCHEDULE="$2";   shift 2 ;;
        -o|--output-dir) OUTPUT_DIR="$2"; shift 2 ;;
        -t|--type)       JOB_TYPE="$2";   shift 2 ;;
        -r|--remove)     REMOVE=true;     shift ;;
        -h|--help)       usage ;;
        *) err "Bilinmeyen parametre: $1"; usage ;;
    esac
done

# ---------------------------------------------------------------------------
# Kaldırma
# ---------------------------------------------------------------------------
if $REMOVE; then
    header "Cron Job Kaldırılıyor"
    if crontab -l 2>/dev/null | grep -q "$CRON_TAG"; then
        crontab -l 2>/dev/null | grep -v "$CRON_TAG" | crontab -
        ok "pg_query_advisor cron job'ları kaldırıldı."
    else
        warn "Kaldırılacak pg_query_advisor cron job'ı bulunamadı."
    fi
    exit 0
fi

# ---------------------------------------------------------------------------
# Kontroller
# ---------------------------------------------------------------------------
PSQL="/usr/pgsql-${PG_VERSION}/bin/psql"
if [[ ! -x "$PSQL" ]]; then
    err "$PSQL bulunamadı. PostgreSQL ${PG_VERSION} kurulu mu?"
    exit 1
fi

if [[ ! -f "${SCRIPT_DIR}/scan_all_databases.sh" ]]; then
    err "scan_all_databases.sh bulunamadı: ${SCRIPT_DIR}"
    exit 1
fi

if [[ ! -f "${SCRIPT_DIR}/check_all.sh" ]]; then
    err "check_all.sh bulunamadı: ${SCRIPT_DIR}"
    exit 1
fi

# ---------------------------------------------------------------------------
# Çıktı dizini
# ---------------------------------------------------------------------------
mkdir -p "$OUTPUT_DIR"
LOG_FILE="${OUTPUT_DIR}/cron.log"

# ---------------------------------------------------------------------------
# Cron satırları oluştur
# ---------------------------------------------------------------------------
SCAN_CMD="${SCRIPT_DIR}/scan_all_databases.sh -v ${PG_VERSION} -U ${PG_USER} -o ${OUTPUT_DIR}/scans >> ${LOG_FILE} 2>&1"
REPORT_CMD="${SCRIPT_DIR}/check_all.sh -v ${PG_VERSION} -U ${PG_USER} -a -o ${OUTPUT_DIR}/reports >> ${LOG_FILE} 2>&1"

# ---------------------------------------------------------------------------
# Mevcut cron'u temizle, yenisini ekle
# ---------------------------------------------------------------------------
header "Cron Job Kuruluyor"

# Mevcut crontab'ı al, pg_query_advisor satırlarını çıkar
CURRENT_CRON=$(crontab -l 2>/dev/null | grep -v "$CRON_TAG" || true)

NEW_CRON="$CURRENT_CRON"

if [[ "$JOB_TYPE" == "scan" || "$JOB_TYPE" == "both" ]]; then
    NEW_CRON="${NEW_CRON}
${SCHEDULE} ${SCAN_CMD} ${CRON_TAG}"
    info "Tarama job'ı: ${SCHEDULE}"
fi

if [[ "$JOB_TYPE" == "report" || "$JOB_TYPE" == "both" ]]; then
    NEW_CRON="${NEW_CRON}
${SCHEDULE} ${REPORT_CMD} ${CRON_TAG}"
    info "Rapor job'ı: ${SCHEDULE}"
fi

echo "$NEW_CRON" | crontab -

# ---------------------------------------------------------------------------
# Logrotate yapılandırması (isteğe bağlı)
# ---------------------------------------------------------------------------
LOGROTATE_CONF="/etc/logrotate.d/pg_query_advisor"
if [[ -d "/etc/logrotate.d" ]]; then
    cat > "$LOGROTATE_CONF" <<LOGROTATE
${OUTPUT_DIR}/cron.log {
    weekly
    rotate 8
    compress
    missingok
    notifempty
    create 0640 root root
}

${OUTPUT_DIR}/scans/*.csv {
    monthly
    rotate 6
    compress
    missingok
    notifempty
}

${OUTPUT_DIR}/reports/*.html {
    monthly
    rotate 3
    compress
    missingok
    notifempty
}
LOGROTATE
    ok "Logrotate yapılandırıldı: ${LOGROTATE_CONF}"
fi

# ---------------------------------------------------------------------------
# Özet
# ---------------------------------------------------------------------------
header "Kurulum Tamamlandı"
echo ""
info "Zamanlama    : ${SCHEDULE}"
info "Tür          : ${JOB_TYPE}"
info "Çıktı dizini : ${OUTPUT_DIR}"
info "Log dosyası  : ${LOG_FILE}"
echo ""
ok "Aktif cron job'ları:"
crontab -l 2>/dev/null | grep "$CRON_TAG" | while read -r line; do
    echo "  $line"
done
echo ""
info "Kaldırmak için: $0 -r"
