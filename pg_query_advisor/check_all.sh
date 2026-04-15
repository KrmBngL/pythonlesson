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

    # Her fonksiyonu ayrı ayrı çalıştır → temiz HTML tablo döner
    psql_html() {
        "$PSQL" -U "$PG_USER" -d "$db" --html -c "$1" 2>/dev/null \
            | sed -n '/<table\b/,/<\/table>/p' || true
    }

    # Bölüm kartı yaz
    write_section() {
        local sid="$1" title="$2" desc="$3" query="$4"
        local tbl
        tbl=$(psql_html "$query") || true
        {
            echo "<div class='section' id='${sid}'>"
            echo "<div class='section-head'><h2>${title}</h2><a class='back' href='#toc'>↑ İçindekiler</a></div>"
            echo "<div class='section-desc'>${desc}</div>"
            echo "<div class='section-body'>"
            if [[ -n "$tbl" ]]; then
                echo "$tbl"
            else
                echo "<p class='no-data'>Sonuç bulunamadı — bu kontrol için sorun tespit edilmedi.</p>"
            fi
            echo "</div></div>"
        } >> "$html_file" || true
    }

    # DB bilgilerini topla
    local pg_ver host_name db_size
    pg_ver=$("$PSQL"  -U "$PG_USER" -d "$db" -tAc "SELECT version();" 2>/dev/null | cut -d' ' -f1-2 || echo "PostgreSQL ${PG_VERSION}")
    host_name=$(hostname -f 2>/dev/null || hostname)
    db_size=$("$PSQL" -U "$PG_USER" -d "$db" -tAc "SELECT pg_size_pretty(pg_database_size(current_database()));" 2>/dev/null || echo "?")

    # CRITICAL / WARNING sayıları
    local cnt_crit cnt_warn cnt_notice
    cnt_crit=$(  "$PSQL" -U "$PG_USER" -d "$db" -tAc "SELECT COUNT(*) FROM query_advisor.report() WHERE priority='1';" 2>/dev/null | tr -d ' ' || echo 0)
    cnt_warn=$(  "$PSQL" -U "$PG_USER" -d "$db" -tAc "SELECT COUNT(*) FROM query_advisor.report() WHERE priority='2';" 2>/dev/null | tr -d ' ' || echo 0)
    cnt_notice=$("$PSQL" -U "$PG_USER" -d "$db" -tAc "SELECT COUNT(*) FROM query_advisor.report() WHERE priority='3';" 2>/dev/null | tr -d ' ' || echo 0)

    # Tam HTML sayfasını oluştur
    cat > "$html_file" <<HTML
<!DOCTYPE html>
<html lang="tr">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>pg_query_advisor AWR — ${db} — ${ts}</title>
<style>
/* ── Reset & Base ─────────────────────────────────────────── */
*{box-sizing:border-box;margin:0;padding:0}
body{font-family:'Segoe UI',Arial,sans-serif;font-size:13px;background:#eef1f5;color:#1a1a1a}
a{color:#1a5276;text-decoration:none}
a:hover{text-decoration:underline}

/* ── Top Banner ───────────────────────────────────────────── */
.banner{background:linear-gradient(135deg,#003366 0%,#00509e 100%);color:#fff;padding:0}
.banner-inner{max-width:1300px;margin:auto;padding:18px 28px 14px}
.banner h1{font-size:1.35em;font-weight:700;letter-spacing:.5px}
.banner h1 span{font-size:.7em;font-weight:400;opacity:.8;margin-left:10px}

/* ── DB Info Grid ─────────────────────────────────────────── */
.db-info{background:#00285a;color:#cfe3ff;display:flex;flex-wrap:wrap;gap:0;border-top:1px solid #004080}
.db-info-cell{padding:7px 22px;border-right:1px solid #004d99;font-size:.82em}
.db-info-cell strong{display:block;font-size:.78em;text-transform:uppercase;opacity:.7;margin-bottom:2px}

/* ── Scorecard ────────────────────────────────────────────── */
.scorecard{display:flex;gap:12px;max-width:1300px;margin:16px auto 0;padding:0 28px}
.score-box{flex:1;border-radius:6px;padding:12px 16px;text-align:center;font-weight:700}
.score-box .num{font-size:2.2em;display:block;line-height:1.1}
.score-box .lbl{font-size:.75em;text-transform:uppercase;letter-spacing:.5px;opacity:.85}
.sc-critical{background:#c0392b;color:#fff}
.sc-warning {background:#e67e22;color:#fff}
.sc-notice  {background:#2980b9;color:#fff}
.sc-ok      {background:#27ae60;color:#fff}

/* ── TOC ──────────────────────────────────────────────────── */
.toc{background:#fff;border:1px solid #d0dae8;border-radius:6px;max-width:1300px;margin:20px auto 0;padding:18px 28px}
.toc h2{color:#003366;font-size:1em;border-bottom:1px solid #d0dae8;padding-bottom:6px;margin-bottom:10px}
.toc ol{column-count:3;column-gap:28px;padding-left:20px}
.toc li{font-size:.82em;margin-bottom:3px}
@media(max-width:900px){.toc ol{column-count:2}}

/* ── Main Content ─────────────────────────────────────────── */
.content{max-width:1300px;margin:20px auto 0;padding:0 28px 40px}

/* ── Section ─────────────────────────────────────────────── */
.section{background:#fff;border:1px solid #d0dae8;border-radius:6px;margin-bottom:18px;overflow:hidden}
.section-head{background:#003366;color:#fff;padding:9px 16px;display:flex;justify-content:space-between;align-items:center}
.section-head h2{font-size:.95em;font-weight:600}
.section-head .back{font-size:.78em;opacity:.8;color:#aad4ff}
.section-body{padding:0}
.section-desc{padding:8px 16px 4px;font-size:.8em;color:#555;border-bottom:1px solid #eef}

/* ── Tables ───────────────────────────────────────────────── */
.section-body table{width:100%;border-collapse:collapse;font-size:.82em}
.section-body table th{
  background:#336699;color:#fff;padding:7px 10px;
  text-align:left;font-weight:600;white-space:nowrap;
  position:sticky;top:0;
}
.section-body table td{padding:6px 10px;border-bottom:1px solid #e8eef5;vertical-align:top;word-break:break-word}
.section-body table tr:nth-child(even) td{background:#f4f8ff}
.section-body table tr:hover td{background:#e8f0fb}

/* ── Row Highlighting ─────────────────────────────────────── */
tr.rc  td{background:#fff0f0!important;border-left:3px solid #c0392b}
tr.rw  td{background:#fffbf0!important;border-left:3px solid #e67e22}
tr.rn  td{background:#f0f8ff!important}
tr.rok td{background:#f0fff4!important}

/* ── Inline Badges ────────────────────────────────────────── */
.bc{display:inline-block;padding:1px 7px;border-radius:3px;font-size:.78em;font-weight:700;background:#c0392b;color:#fff}
.bw{display:inline-block;padding:1px 7px;border-radius:3px;font-size:.78em;font-weight:700;background:#e67e22;color:#fff}
.bn{display:inline-block;padding:1px 7px;border-radius:3px;font-size:.78em;font-weight:700;background:#2980b9;color:#fff}
.bo{display:inline-block;padding:1px 7px;border-radius:3px;font-size:.78em;font-weight:700;background:#27ae60;color:#fff}

/* ── No Data ──────────────────────────────────────────────── */
.no-data{padding:14px 16px;color:#888;font-style:italic;font-size:.85em}

/* ── Footer ───────────────────────────────────────────────── */
.footer{text-align:center;padding:18px;color:#888;font-size:.78em;border-top:1px solid #ddd;margin-top:10px}

/* ── Print ────────────────────────────────────────────────── */
@media print{
  .banner{-webkit-print-color-adjust:exact;print-color-adjust:exact}
  .section{break-inside:avoid}
}
</style>
</head>
<body>

<!-- ── Banner ───────────────────────────────────────────────── -->
<div class="banner">
  <div class="banner-inner">
    <h1>pg_query_advisor Performance Report <span>v${ext_ver}</span></h1>
  </div>
  <div class="db-info">
    <div class="db-info-cell"><strong>Veritabanı</strong>${db}</div>
    <div class="db-info-cell"><strong>Sürüm</strong>${pg_ver}</div>
    <div class="db-info-cell"><strong>Sunucu</strong>${host_name}</div>
    <div class="db-info-cell"><strong>DB Boyutu</strong>${db_size}</div>
    <div class="db-info-cell"><strong>Rapor Tarihi</strong>${ts}</div>
    <div class="db-info-cell"><strong>Extension</strong>pg_query_advisor ${ext_ver}</div>
  </div>
</div>

<!-- ── Scorecard ─────────────────────────────────────────────── -->
<div class="scorecard">
  <div class="score-box sc-critical"><span class="num">${cnt_crit}</span><span class="lbl">Critical</span></div>
  <div class="score-box sc-warning"> <span class="num">${cnt_warn}</span><span class="lbl">Warning</span></div>
  <div class="score-box sc-notice">  <span class="num">${cnt_notice}</span><span class="lbl">Notice</span></div>
  <div class="score-box sc-ok">      <span class="num">$(date '+%H:%M')</span><span class="lbl">Rapor Saati</span></div>
</div>

<!-- ── Table of Contents ─────────────────────────────────────── -->
<div class="toc" id="toc">
  <h2>İçindekiler</h2>
  <ol>
    <li><a href="#s0">Genel Sağlık Özeti</a></li>
    <li><a href="#s1">Öncelikli Bulgular</a></li>
    <li><a href="#s2">Tablo Sağlığı</a></li>
    <li><a href="#s3">Tablo Bloat Analizi</a></li>
    <li><a href="#s4">Index Kullanımı</a></li>
    <li><a href="#s5">Kullanılmayan Indexler</a></li>
    <li><a href="#s6">Tekrarlayan Indexler</a></li>
    <li><a href="#s7">Eksik Indexler</a></li>
    <li><a href="#s8">Index Sağlığı</a></li>
    <li><a href="#s9">Autovacuum Ayarları</a></li>
    <li><a href="#s10">Cache Hit Oranı</a></li>
    <li><a href="#s11">Yavaş Sorgular</a></li>
    <li><a href="#s12">Uzun Çalışan Sorgular</a></li>
    <li><a href="#s13">Lock Bekleme Zinciri</a></li>
    <li><a href="#s14">Tablo Büyüme Tahmini</a></li>
    <li><a href="#s15">Partition Adayları</a></li>
    <li><a href="#s16">Index Önerileri</a></li>
    <li><a href="#s17">Idle Transaction</a></li>
    <li><a href="#s18">Vacuum Gereksinimi</a></li>
    <li><a href="#s19">Replication Slotları</a></li>
    <li><a href="#s20">Konfigurasyon Danışmanı</a></li>
    <li><a href="#s21">Korelasyon Kontrolü</a></li>
    <li><a href="#s22">Sequence Sağlığı</a></li>
    <li><a href="#s23">FK Index Eksiklikleri</a></li>
    <li><a href="#s24">Bağlantı İstatistikleri</a></li>
    <li><a href="#s25">Temp File İstatistikleri</a></li>
    <li><a href="#s26">Vacuum İlerlemesi</a></li>
    <li><a href="#s27">Tablespace Kullanımı</a></li>
    <li><a href="#s28">TOAST Analizi</a></li>
    <li><a href="#s29">Deadlock İstatistikleri</a></li>
    <li><a href="#s30">Buffer Cache Doluluk</a></li>
    <li><a href="#s31">Wait Event Özeti</a></li>
    <li><a href="#s32">Index Bloat Tahmini</a></li>
    <li><a href="#s33">Yetki Denetimi</a></li>
    <li><a href="#s34">Tablo Erişim Metodları</a></li>
  </ol>
</div>

<!-- ── Report Body ────────────────────────────────────────────── -->
<div class="content">
HTML

    # Her bölümü ayrı ayrı çalıştır ve doğrudan yaz
    write_section "s0"  "0. Genel Sağlık Özeti"        "health_summary — tüm kategorilerin özet skoru" \
        "SELECT * FROM query_advisor.health_summary"
    write_section "s1"  "1. Öncelikli Bulgular"         "report() — CRITICAL/WARNING/NOTICE sıralı master rapor" \
        "SELECT * FROM query_advisor.report() ORDER BY priority, category"
    write_section "s2"  "2. Tablo Sağlığı"              "table_health() — dead tuple oranı, last vacuum/analyze" \
        "SELECT * FROM query_advisor.table_health() ORDER BY dead_ratio_pct DESC"
    write_section "s3"  "3. Tablo Bloat Analizi"        "table_bloat() — boşa harcanan alan tahmini" \
        "SELECT * FROM query_advisor.table_bloat() ORDER BY dead_ratio_pct DESC"
    write_section "s4"  "4. Index Kullanımı"            "index_usage() — scan sayısı, ACTIVE/UNUSED sınıfı" \
        "SELECT * FROM query_advisor.index_usage() ORDER BY index_scans ASC"
    write_section "s5"  "5. Kullanılmayan Indexler"     "unused_indexes() — hazır DROP INDEX CONCURRENTLY" \
        "SELECT * FROM query_advisor.unused_indexes() ORDER BY index_size_mb DESC"
    write_section "s6"  "6. Tekrarlayan Indexler"       "duplicate_indexes() — aynı leading key paylaşan çiftler" \
        "SELECT * FROM query_advisor.duplicate_indexes()"
    write_section "s7"  "7. Eksik Indexler"             "missing_indexes() — seq scan >> index scan tablolar" \
        "SELECT * FROM query_advisor.missing_indexes() ORDER BY seq_scan_count DESC"
    write_section "s8"  "8. Index Sağlığı"              "index_health() — invalid index tespiti" \
        "SELECT * FROM query_advisor.index_health() ORDER BY recommendation"
    write_section "s9"  "9. Autovacuum Ayarları"        "autovacuum_settings() — hazır ALTER TABLE önerileri" \
        "SELECT * FROM query_advisor.autovacuum_settings() ORDER BY estimated_rows DESC"
    write_section "s10" "10. Cache Hit Oranı"           "cache_hit() — buffer cache doluluk oranı" \
        "SELECT * FROM query_advisor.cache_hit() ORDER BY heap_hit_pct ASC"
    write_section "s11" "11. Yavaş Sorgular"            "slow_queries() — pg_stat_statements top 20" \
        "SELECT * FROM query_advisor.slow_queries(p_top_n => 20)"
    write_section "s12" "12. Uzun Çalışan Sorgular"     "long_running_queries() — şu an çalışan uzun sorgular" \
        "SELECT * FROM query_advisor.long_running_queries()"
    write_section "s13" "13. Lock Bekleme Zinciri"      "lock_waits() — blocking/waiting session zinciri" \
        "SELECT * FROM query_advisor.lock_waits()"
    write_section "s14" "14. Tablo Büyüme Tahmini"      "table_growth_forecast() — 30/90/180/365 gün tahmini" \
        "SELECT * FROM query_advisor.table_growth_forecast() ORDER BY growth_rate_pct DESC"
    write_section "s15" "15. Partition Adayları"        "partition_candidates() — RANGE/HASH DDL önerisi" \
        "SELECT schema_name,table_name,table_size,row_count,partition_strategy,partition_key,recommendation FROM query_advisor.partition_candidates()"
    write_section "s16" "16. Index Önerileri"           "index_recommendations() — CREATE INDEX CONCURRENTLY DDL" \
        "SELECT schema_table,seq_scan_count,live_rows,candidate_columns,suggested_ddl,recommendation FROM query_advisor.index_recommendations()"
    write_section "s17" "17. Idle Transaction"          "idle_in_transaction() — açık kalmış transaction tespiti" \
        "SELECT * FROM query_advisor.idle_in_transaction()"
    write_section "s18" "18. Vacuum Gereksinimi"        "vacuum_needs() — autovacuum eşiğine yaklaşan tablolar" \
        "SELECT * FROM query_advisor.vacuum_needs() ORDER BY dead_rows_pct_filled DESC"
    write_section "s19" "19. Replication Slotları"      "replication_slots() — takılı slot / WAL birikim riski" \
        "SELECT * FROM query_advisor.replication_slots()"
    write_section "s20" "20. Konfigurasyon Danışmanı"   "config_advisor() — RAM bazlı parametre önerileri" \
        "SELECT * FROM query_advisor.config_advisor()"
    write_section "s21" "21. Korelasyon Kontrolü"       "correlation_check() — B-tree verimsizliği / BRIN önerisi" \
        "SELECT schema_name,table_name,column_name,data_type,correlation,has_index,live_rows,finding,recommendation FROM query_advisor.correlation_check()"
    write_section "s22" "22. Sequence Sağlığı"          "sequence_health() — integer taşma riski" \
        "SELECT * FROM query_advisor.sequence_health() ORDER BY used_pct DESC"
    write_section "s23" "23. FK Index Eksiklikleri"     "fk_without_index() — hazır CREATE INDEX DDL" \
        "SELECT * FROM query_advisor.fk_without_index()"
    write_section "s24" "24. Bağlantı İstatistikleri"   "connection_stats() — aktif/idle/max_connections doluluk" \
        "SELECT * FROM query_advisor.connection_stats()"
    write_section "s25" "25. Temp File İstatistikleri"  "temp_file_stats() — work_mem spill analizi" \
        "SELECT * FROM query_advisor.temp_file_stats()"
    write_section "s26" "26. Vacuum İlerlemesi"         "vacuum_progress() — aktif VACUUM/AUTOVACUUM takibi" \
        "SELECT * FROM query_advisor.vacuum_progress()"
    write_section "s27" "27. Tablespace Kullanımı"      "tablespace_usage() — disk alanı ve nesne sayıları" \
        "SELECT * FROM query_advisor.tablespace_usage()"
    write_section "s28" "28. TOAST Analizi"             "toast_analysis() — TEXT/JSONB/BYTEA şişme tespiti" \
        "SELECT * FROM query_advisor.toast_analysis() ORDER BY toast_pct DESC"
    write_section "s29" "29. Deadlock İstatistikleri"   "deadlock_stats() — geçmiş deadlock sayısı" \
        "SELECT * FROM query_advisor.deadlock_stats()"
    write_section "s30" "30. Buffer Cache Doluluk"      "buffercache_top() — cache içindeki en büyük nesneler" \
        "SELECT * FROM query_advisor.buffercache_top()"
    write_section "s31" "31. Wait Event Özeti"          "wait_event_summary() — Lock/IO/CPU darboğaz dağılımı" \
        "SELECT * FROM query_advisor.wait_event_summary() ORDER BY session_count DESC"
    write_section "s32" "32. Index Bloat Tahmini"       "index_bloat_estimate() — REINDEX CONCURRENTLY adayları" \
        "SELECT * FROM query_advisor.index_bloat_estimate() ORDER BY bloat_ratio_pct DESC"
    write_section "s33" "33. Yetki Denetimi"            "table_privileges_audit() — PUBLIC erişim / superuser rolleri" \
        "SELECT * FROM query_advisor.table_privileges_audit()"
    write_section "s34" "34. Tablo Erişim Metodları"    "table_access_methods() — heap/columnar access method analizi" \
        "SELECT * FROM query_advisor.table_access_methods()"

    cat >> "$html_file" <<HTML
</div><!-- /content -->

<div class="footer">
  pg_query_advisor ${ext_ver} &bull; PostgreSQL ${PG_VERSION} &bull; ${host_name} &bull; ${db} &bull; ${ts}
</div>

<script>
document.querySelectorAll('table tr').forEach(function(tr){
  var txt = tr.textContent.toUpperCase();
  if(txt.includes('CRITICAL')||txt.includes('KRITIK'))   tr.className='rc';
  else if(txt.includes('WARNING')||txt.includes('UYARI')) tr.className='rw';
  else if(/\bNOTICE\b/.test(txt))                         tr.className='rn';
  else if(/\| *OK *(\||$)/.test(tr.textContent))          tr.className='rok';
});
document.querySelectorAll('td').forEach(function(td){
  td.innerHTML = td.innerHTML
    .replace(/\bCRITICAL\b/g,'<span class="bc">CRITICAL</span>')
    .replace(/\bWARNING\b/g, '<span class="bw">WARNING</span>')
    .replace(/\bNOTICE\b/g,  '<span class="bn">NOTICE</span>')
    .replace(/(?<![A-Z])\bOK\b(?![A-Z])/g,'<span class="bo">OK</span>');
});
</script>
</body>
</html>
HTML

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
