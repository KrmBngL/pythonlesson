#!/usr/bin/env bash
# check_all.sh — pg_query_advisor tam raporu çalıştırır, HTML çıktısı üretir
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
  -d, --database   DB     Hedef veritabanı (varsayılan: postgres)
  -a, --all-db            Tüm kullanıcı veritabanlarında çalıştır
  -o, --output-dir DIR    HTML rapor dizini (varsayılan: ./reports)
  -t, --text-only         HTML üretme, sadece psql çıktısı göster
  -h, --help              Bu yardım mesajını göster

Örnekler:
  $0                              # PG18, postgres DB, HTML rapor
  $0 -v 17 -d mydb                # PG17, mydb
  $0 -v 18 -a -o /var/reports     # PG18, tüm veritabanları, özel dizin
  $0 -t                           # HTML olmadan terminale yaz
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
TEXT_ONLY=false
OUTPUT_DIR="./reports"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TIMESTAMP=$(date '+%Y%m%d_%H%M%S')

while [[ $# -gt 0 ]]; do
    case $1 in
        -v|--pg-version) PG_VERSION="$2"; shift 2 ;;
        -U|--user)       PG_USER="$2";    shift 2 ;;
        -d|--database)   DBNAME="$2";     shift 2 ;;
        -a|--all-db)     ALL_DB=true;     shift ;;
        -o|--output-dir) OUTPUT_DIR="$2"; shift 2 ;;
        -t|--text-only)  TEXT_ONLY=true;  shift ;;
        -h|--help)       usage ;;
        *) err "Bilinmeyen parametre: $1"; usage ;;
    esac
done

PSQL="/usr/pgsql-${PG_VERSION}/bin/psql"
CHECK_SQL="${SCRIPT_DIR}/check_all.sql"

# ---------------------------------------------------------------------------
# Kontroller
# ---------------------------------------------------------------------------
if [[ ! -x "$PSQL" ]]; then
    err "$PSQL bulunamadı. PostgreSQL ${PG_VERSION} kurulu mu?"
    exit 1
fi

if [[ ! -f "$CHECK_SQL" ]]; then
    err "check_all.sql bulunamadı: $CHECK_SQL"
    exit 1
fi

# ---------------------------------------------------------------------------
# Tek veritabanı için rapor üretme fonksiyonu
# ---------------------------------------------------------------------------
run_report() {
    local db="$1"
    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S')

    # Extension kurulu mu kontrol et
    local ext_ver
    ext_ver=$("$PSQL" -U "$PG_USER" -d "$db" -tAc \
        "SELECT extversion FROM pg_extension WHERE extname = 'pg_query_advisor';" \
        2>/dev/null || true)
    ext_ver="${ext_ver// /}"

    if [[ -z "$ext_ver" ]]; then
        warn "[$db] pg_query_advisor kurulu değil — atlanıyor"
        return
    fi

    info "[$db] pg_query_advisor ${ext_ver} raporu üretiliyor..."

    if $TEXT_ONLY; then
        echo ""
        header "Veritabanı: ${db} | pg_query_advisor ${ext_ver} | ${ts}"
        "$PSQL" -U "$PG_USER" -d "$db" \
            --pset=border=2 \
            --pset=format=aligned \
            -f "$CHECK_SQL"
        ok "[$db] Rapor tamamlandı"
        return
    fi

    # HTML rapor oluştur
    mkdir -p "$OUTPUT_DIR"
    local html_file="${OUTPUT_DIR}/${db}_${TIMESTAMP}.html"
    local latest_link="${OUTPUT_DIR}/${db}_latest.html"

    # psql HTML çıktısını bir geçici dosyaya al
    local tmp_body
    tmp_body=$(mktemp /tmp/pg_report_XXXXX.html)

    "$PSQL" -U "$PG_USER" -d "$db" \
        --html \
        -f "$CHECK_SQL" > "$tmp_body" 2>&1 || true

    # Tam HTML sayfasını oluştur
    cat > "$html_file" <<HTML
<!DOCTYPE html>
<html lang="tr">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>pg_query_advisor — ${db} — ${ts}</title>
  <style>
    body        { font-family: 'Segoe UI', Arial, sans-serif; background:#f4f6f8; color:#222; margin:0; padding:0; }
    header      { background:#1a3a5c; color:#fff; padding:18px 32px; }
    header h1   { margin:0; font-size:1.4em; }
    header p    { margin:4px 0 0; font-size:0.9em; opacity:0.8; }
    main        { padding:24px 32px; max-width:1400px; margin:auto; }
    h2          { color:#1a3a5c; border-bottom:2px solid #1a3a5c; padding-bottom:4px; margin-top:32px; }
    table       { border-collapse:collapse; width:100%; margin:12px 0 24px; font-size:0.88em; background:#fff;
                  box-shadow:0 1px 4px rgba(0,0,0,.12); border-radius:6px; overflow:hidden; }
    th          { background:#1a3a5c; color:#fff; padding:8px 12px; text-align:left; }
    tr:nth-child(even) { background:#f0f4f8; }
    td          { padding:7px 12px; border-bottom:1px solid #e0e6ed; }
    .critical   { color:#c0392b; font-weight:bold; }
    .warning    { color:#e67e22; font-weight:bold; }
    .ok         { color:#27ae60; }
    footer      { text-align:center; padding:16px; color:#888; font-size:0.8em; border-top:1px solid #ddd; margin-top:32px; }
    .badge      { display:inline-block; padding:2px 10px; border-radius:12px; font-size:0.8em; font-weight:bold; }
    .badge-ext  { background:#1a3a5c; color:#fff; }
    .badge-db   { background:#2980b9; color:#fff; }
  </style>
</head>
<body>
<header>
  <h1>pg_query_advisor Raporu</h1>
  <p>
    <span class="badge badge-db">Veritabanı: ${db}</span>&nbsp;
    <span class="badge badge-ext">Sürüm: ${ext_ver}</span>&nbsp;
    &nbsp;Oluşturulma: ${ts}
  </p>
</header>
<main>
HTML

    cat "$tmp_body" >> "$html_file"

    cat >> "$html_file" <<HTML
</main>
<footer>
  pg_query_advisor ${ext_ver} &bull; PostgreSQL ${PG_VERSION} &bull; Oluşturulma: ${ts}
</footer>
</body>
</html>
HTML

    rm -f "$tmp_body"

    # Sembolik en son linki güncelle
    ln -sf "$(basename "$html_file")" "$latest_link"

    ok "[$db] HTML rapor: ${html_file}"
    ok "[$db] En son link: ${latest_link}"
}

# ---------------------------------------------------------------------------
# Ana akış
# ---------------------------------------------------------------------------
header "pg_query_advisor Rapor Üretici"
info "PostgreSQL sürümü : ${PG_VERSION}"
info "Kullanıcı         : ${PG_USER}"
$TEXT_ONLY && info "Mod               : Metin (terminal)" || info "Çıktı dizini      : ${OUTPUT_DIR}"

if $ALL_DB; then
    mapfile -t DB_LIST < <("$PSQL" -U "$PG_USER" -d postgres -tAc \
        "SELECT datname FROM pg_database
         WHERE datistemplate = false
         ORDER BY datname;" 2>/dev/null)

    if [[ ${#DB_LIST[@]} -eq 0 ]]; then
        err "Veritabanı listesi alınamadı."
        exit 1
    fi

    info "Bulunan veritabanları: ${DB_LIST[*]}"

    for db in "${DB_LIST[@]}"; do
        [[ -z "$db" ]] && continue
        run_report "$db"
    done
else
    run_report "$DBNAME"
fi

header "Tamamlandı"
if ! $TEXT_ONLY; then
    info "Tüm HTML raporlar: ${OUTPUT_DIR}/"
    ls -lh "${OUTPUT_DIR}"/*.html 2>/dev/null || true
fi
