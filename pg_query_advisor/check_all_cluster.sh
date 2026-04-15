#!/usr/bin/env bash
# check_all_cluster.sh — Tüm cluster'ı tarar, tek HTML'de her DB ayrı sekme
# Kullanım: bash check_all_cluster.sh -v 18 -o /var/reports

set -uo pipefail

RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
info()   { echo -e "${CYAN}[INFO]${RESET}  $*"; }
ok()     { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()   { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
err()    { echo -e "${RED}[ERROR]${RESET} $*" >&2; }

usage() {
    cat <<EOF
Kullanım: $0 [SEÇENEKLER]

  -v, --pg-version NUM    PostgreSQL major version (varsayılan: 18)
  -U, --user       USER   PostgreSQL superuser (varsayılan: postgres)
  -o, --output-dir DIR    HTML rapor dizini (varsayılan: ./reports)
  -h, --help

Örnek:
  $0 -v 18 -o /var/reports
EOF
    exit 0
}

PG_VERSION=18
PG_USER=postgres
OUTPUT_DIR="./reports"
TIMESTAMP=$(date '+%Y%m%d_%H%M%S')

while [[ $# -gt 0 ]]; do
    case $1 in
        -v|--pg-version) PG_VERSION="$2"; shift 2 ;;
        -U|--user)       PG_USER="$2";    shift 2 ;;
        -o|--output-dir) OUTPUT_DIR="$2"; shift 2 ;;
        -h|--help)       usage ;;
        *) err "Bilinmeyen parametre: $1"; usage ;;
    esac
done

PSQL="/usr/pgsql-${PG_VERSION}/bin/psql"

if [[ ! -x "$PSQL" ]]; then
    err "$PSQL bulunamadı."; exit 1
fi

# ---------------------------------------------------------------------------
# Veritabanı listesi
# ---------------------------------------------------------------------------
mapfile -t DB_LIST < <("$PSQL" -U "$PG_USER" -d postgres -tAc \
    "SELECT datname FROM pg_database
     WHERE datistemplate = false
     ORDER BY datname;" 2>/dev/null)

if [[ ${#DB_LIST[@]} -eq 0 ]]; then
    err "Veritabanı listesi alınamadı."; exit 1
fi

info "Cluster veritabanları: ${DB_LIST[*]}"
mkdir -p "$OUTPUT_DIR"
HTML_FILE="${OUTPUT_DIR}/cluster_${TIMESTAMP}.html"
LATEST_LINK="${OUTPUT_DIR}/cluster_latest.html"

# ---------------------------------------------------------------------------
# Yardımcılar
# ---------------------------------------------------------------------------
psql_html() {
    local db="$1" query="$2"
    "$PSQL" -U "$PG_USER" -d "$db" --html -c "$query" 2>/dev/null \
        | sed -n '/<table\b/,/<\/table>/p' || true
}

write_section() {
    local db="$1" sid="$2" title="$3" desc="$4" query="$5"
    local tbl
    tbl=$(psql_html "$db" "$query") || true
    {
        echo "<div class='section' id='${db}-${sid}'>"
        echo "<div class='section-head'><h2>${title}</h2><a class='back' href='#toc-${db}'>↑ İçindekiler</a></div>"
        echo "<div class='section-desc'>${desc}</div>"
        echo "<div class='section-body'>"
        if [[ -n "$tbl" ]]; then
            echo "$tbl"
        else
            echo "<p class='no-data'>Sonuç bulunamadı — sorun tespit edilmedi.</p>"
        fi
        echo "</div></div>"
    } >> "$HTML_FILE" || true
}

# ---------------------------------------------------------------------------
# HTML başlık + CSS
# ---------------------------------------------------------------------------
HOST_NAME=$(hostname -f 2>/dev/null || hostname)
PG_VER=$("$PSQL" -U "$PG_USER" -d postgres -tAc "SELECT version();" 2>/dev/null | cut -d' ' -f1-2 || echo "PostgreSQL ${PG_VERSION}")

cat > "$HTML_FILE" <<HTML
<!DOCTYPE html>
<html lang="tr">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1.0">
<title>pg_query_advisor Cluster Report — ${HOST_NAME} — $(date '+%Y-%m-%d %H:%M')</title>
<style>
*{box-sizing:border-box;margin:0;padding:0}
body{font-family:'Segoe UI',Arial,sans-serif;font-size:13px;background:#eef1f5;color:#1a1a1a}
a{color:#1a5276;text-decoration:none}
a:hover{text-decoration:underline}

/* Banner */
.banner{background:linear-gradient(135deg,#003366,#00509e);color:#fff}
.banner-inner{max-width:1300px;margin:auto;padding:16px 28px 12px}
.banner h1{font-size:1.3em;font-weight:700}
.banner h1 span{font-size:.7em;font-weight:400;opacity:.8;margin-left:8px}
.db-info{background:#00285a;color:#cfe3ff;display:flex;flex-wrap:wrap;border-top:1px solid #004080}
.db-info-cell{padding:6px 20px;border-right:1px solid #004d99;font-size:.82em}
.db-info-cell strong{display:block;font-size:.78em;text-transform:uppercase;opacity:.7;margin-bottom:1px}

/* DB Tab Bar */
.tab-bar{position:sticky;top:0;z-index:100;background:#002244;display:flex;flex-wrap:wrap;gap:2px;padding:6px 28px;box-shadow:0 2px 6px rgba(0,0,0,.3)}
.tab-btn{background:#003f7a;color:#aad4ff;border:none;padding:6px 16px;border-radius:4px;cursor:pointer;font-size:.82em;font-weight:600;transition:background .15s}
.tab-btn:hover{background:#0059b3}
.tab-btn.active{background:#f0a500;color:#000}

/* Cluster Scorecard */
.cluster-score{max-width:1300px;margin:14px auto 0;padding:0 28px;display:flex;gap:10px;flex-wrap:wrap}
.cs-box{flex:1;min-width:120px;border-radius:6px;padding:10px 14px;text-align:center;font-weight:700}
.cs-box .num{font-size:1.8em;display:block;line-height:1.1}
.cs-box .lbl{font-size:.72em;text-transform:uppercase;letter-spacing:.4px;opacity:.9}
.cs-critical{background:#c0392b;color:#fff}
.cs-warning{background:#e67e22;color:#fff}
.cs-db{background:#2980b9;color:#fff}
.cs-ok{background:#27ae60;color:#fff}

/* DB Panel */
.db-panel{display:none;max-width:1300px;margin:0 auto;padding:16px 28px 40px}
.db-panel.active{display:block}

/* Per-DB scorecard */
.scorecard{display:flex;gap:10px;margin-bottom:16px}
.score-box{flex:1;border-radius:6px;padding:10px 14px;text-align:center;font-weight:700}
.score-box .num{font-size:1.8em;display:block;line-height:1.1}
.score-box .lbl{font-size:.72em;text-transform:uppercase;letter-spacing:.4px;opacity:.9}
.sc-critical{background:#c0392b;color:#fff}
.sc-warning{background:#e67e22;color:#fff}
.sc-notice{background:#2980b9;color:#fff}
.sc-ok{background:#27ae60;color:#fff}

/* TOC */
.toc{background:#fff;border:1px solid #d0dae8;border-radius:6px;padding:14px 20px;margin-bottom:16px}
.toc h2{color:#003366;font-size:.92em;border-bottom:1px solid #d0dae8;padding-bottom:5px;margin-bottom:8px}
.toc ol{column-count:3;column-gap:24px;padding-left:18px}
.toc li{font-size:.8em;margin-bottom:2px}
@media(max-width:900px){.toc ol{column-count:2}}

/* Sections */
.section{background:#fff;border:1px solid #d0dae8;border-radius:6px;margin-bottom:14px;overflow:hidden}
.section-head{background:#003366;color:#fff;padding:8px 14px;display:flex;justify-content:space-between;align-items:center}
.section-head h2{font-size:.9em;font-weight:600}
.section-head .back{font-size:.76em;opacity:.8;color:#aad4ff}
.section-desc{padding:6px 14px 3px;font-size:.78em;color:#555;border-bottom:1px solid #eef}
.section-body{padding:0}
.section-body table{width:100%;border-collapse:collapse;font-size:.8em}
.section-body th{background:#336699;color:#fff;padding:6px 9px;text-align:left;font-weight:600;white-space:nowrap;position:sticky;top:40px}
.section-body td{padding:5px 9px;border-bottom:1px solid #e8eef5;vertical-align:top;word-break:break-word}
.section-body tr:nth-child(even) td{background:#f4f8ff}
.section-body tr:hover td{background:#e8f0fb}
tr.rc td{background:#fff0f0!important;border-left:3px solid #c0392b}
tr.rw td{background:#fffbf0!important;border-left:3px solid #e67e22}
tr.rn td{background:#f0f8ff!important}
tr.rok td{background:#f0fff4!important}
.bc{display:inline-block;padding:1px 6px;border-radius:3px;font-size:.76em;font-weight:700;background:#c0392b;color:#fff}
.bw{display:inline-block;padding:1px 6px;border-radius:3px;font-size:.76em;font-weight:700;background:#e67e22;color:#fff}
.bn{display:inline-block;padding:1px 6px;border-radius:3px;font-size:.76em;font-weight:700;background:#2980b9;color:#fff}
.bo{display:inline-block;padding:1px 6px;border-radius:3px;font-size:.76em;font-weight:700;background:#27ae60;color:#fff}
.no-data{padding:12px 14px;color:#888;font-style:italic;font-size:.82em}

/* Cluster Overview Table */
.overview-table{width:100%;border-collapse:collapse;font-size:.85em;background:#fff;border-radius:6px;overflow:hidden;box-shadow:0 1px 4px rgba(0,0,0,.1)}
.overview-table th{background:#003366;color:#fff;padding:8px 12px;text-align:left}
.overview-table td{padding:7px 12px;border-bottom:1px solid #e0e8f0}
.overview-table tr:nth-child(even) td{background:#f4f8ff}
.overview-table tr:hover td{background:#e8f0fb;cursor:pointer}

.footer{text-align:center;padding:16px;color:#888;font-size:.76em;border-top:1px solid #ddd;margin-top:8px}
@media print{.tab-bar{display:none}.db-panel{display:block!important}}
</style>
</head>
<body>

<div class="banner">
  <div class="banner-inner">
    <h1>pg_query_advisor Cluster Report <span>PostgreSQL ${PG_VERSION}</span></h1>
  </div>
  <div class="db-info">
    <div class="db-info-cell"><strong>Sunucu</strong>${HOST_NAME}</div>
    <div class="db-info-cell"><strong>PG Sürümü</strong>${PG_VER}</div>
    <div class="db-info-cell"><strong>Veritabanı Sayısı</strong>${#DB_LIST[@]}</div>
    <div class="db-info-cell"><strong>Rapor Tarihi</strong>$(date '+%Y-%m-%d %H:%M:%S')</div>
  </div>
</div>

HTML

# ---------------------------------------------------------------------------
# Her DB için scorecard bilgisi topla (cluster özeti için)
# ---------------------------------------------------------------------------
declare -A DB_CRIT DB_WARN DB_VER DB_SIZE DB_HAS_EXT

TOTAL_CRIT=0
TOTAL_WARN=0
ACTIVE_DBS=0

for db in "${DB_LIST[@]}"; do
    [[ -z "$db" ]] && continue
    ext_ver=$("$PSQL" -U "$PG_USER" -d "$db" -tAc \
        "SELECT extversion FROM pg_extension WHERE extname='pg_query_advisor';" \
        2>/dev/null | tr -d ' \n' || true)

    if [[ -z "$ext_ver" ]]; then
        DB_HAS_EXT[$db]="no"
        DB_VER[$db]="-"
        DB_SIZE[$db]="-"
        DB_CRIT[$db]=0
        DB_WARN[$db]=0
        warn "[$db] pg_query_advisor kurulu değil — atlanıyor"
        continue
    fi

    DB_HAS_EXT[$db]="yes"
    DB_VER[$db]="$ext_ver"
    DB_SIZE[$db]=$("$PSQL" -U "$PG_USER" -d "$db" -tAc \
        "SELECT pg_size_pretty(pg_database_size(current_database()));" \
        2>/dev/null | tr -d ' \n' || echo "?")

    c=$("$PSQL" -U "$PG_USER" -d "$db" -tAc \
        "SELECT COUNT(*) FROM query_advisor.report() WHERE priority='1';" \
        2>/dev/null | tr -d ' \n' || echo 0)
    w=$("$PSQL" -U "$PG_USER" -d "$db" -tAc \
        "SELECT COUNT(*) FROM query_advisor.report() WHERE priority='2';" \
        2>/dev/null | tr -d ' \n' || echo 0)

    DB_CRIT[$db]="${c:-0}"
    DB_WARN[$db]="${w:-0}"
    (( TOTAL_CRIT += ${c:-0} )) || true
    (( TOTAL_WARN += ${w:-0} )) || true
    (( ACTIVE_DBS++ )) || true
    ok "[$db] CRITICAL:${c:-0} WARNING:${w:-0}"
done

# ---------------------------------------------------------------------------
# Cluster scorecard + tab bar
# ---------------------------------------------------------------------------
cat >> "$HTML_FILE" <<HTML
<div class="cluster-score">
  <div class="cs-box cs-critical"><span class="num">${TOTAL_CRIT}</span><span class="lbl">Toplam Critical</span></div>
  <div class="cs-box cs-warning"> <span class="num">${TOTAL_WARN}</span><span class="lbl">Toplam Warning</span></div>
  <div class="cs-box cs-db">      <span class="num">${ACTIVE_DBS}</span><span class="lbl">Tarana DB</span></div>
  <div class="cs-box cs-ok">      <span class="num">${#DB_LIST[@]}</span><span class="lbl">Toplam DB</span></div>
</div>

<div class="tab-bar">
  <button class="tab-btn active" onclick="showDB('__overview__',this)">Cluster Özeti</button>
HTML

for db in "${DB_LIST[@]}"; do
    [[ -z "$db" ]] && continue
    echo "  <button class='tab-btn' onclick=\"showDB('${db}',this)\">${db}</button>" >> "$HTML_FILE"
done

cat >> "$HTML_FILE" <<HTML
</div>
HTML

# ---------------------------------------------------------------------------
# Cluster Overview paneli
# ---------------------------------------------------------------------------
cat >> "$HTML_FILE" <<HTML
<div id="panel-__overview__" class="db-panel active">
  <table class="overview-table">
    <thead><tr>
      <th>Veritabanı</th>
      <th>Extension</th>
      <th>Boyut</th>
      <th>Critical</th>
      <th>Warning</th>
      <th>Durum</th>
    </tr></thead>
    <tbody>
HTML

for db in "${DB_LIST[@]}"; do
    [[ -z "$db" ]] && continue
    has="${DB_HAS_EXT[$db]:-no}"
    ver="${DB_VER[$db]:-}"
    sz="${DB_SIZE[$db]:-}"
    cr="${DB_CRIT[$db]:-0}"
    wr="${DB_WARN[$db]:-0}"
    if [[ "$has" == "no" ]]; then
        row_style="style='opacity:.55'"
        durum="Kurulu Değil"
    elif [[ "$cr" -gt 0 ]]; then
        row_style="style='cursor:pointer' onclick=\"showDB('${db}',null)\""
        durum="<span class='bc'>CRITICAL</span>"
    elif [[ "$wr" -gt 0 ]]; then
        row_style="style='cursor:pointer' onclick=\"showDB('${db}',null)\""
        durum="<span class='bw'>WARNING</span>"
    else
        row_style="style='cursor:pointer' onclick=\"showDB('${db}',null)\""
        durum="<span class='bo'>OK</span>"
    fi
    echo "      <tr ${row_style}><td>${db}</td><td>${ver}</td><td>${sz}</td><td>${cr}</td><td>${wr}</td><td>${durum}</td></tr>" >> "$HTML_FILE"
done

cat >> "$HTML_FILE" <<HTML
    </tbody>
  </table>
</div>
HTML

# ---------------------------------------------------------------------------
# Her DB için tam rapor paneli
# ---------------------------------------------------------------------------
SECTIONS=(
    "s0|0. Genel Sağlık Özeti|health_summary|SELECT * FROM query_advisor.health_summary"
    "s1|1. Öncelikli Bulgular|report() — CRITICAL/WARNING/NOTICE|SELECT * FROM query_advisor.report() ORDER BY priority,category"
    "s2|2. Tablo Sağlığı|table_health() — dead tuple oranı|SELECT * FROM query_advisor.table_health() ORDER BY dead_ratio_pct DESC"
    "s3|3. Tablo Bloat|table_bloat() — boşa harcanan alan|SELECT * FROM query_advisor.table_bloat() ORDER BY dead_ratio_pct DESC"
    "s4|4. Index Kullanımı|index_usage() — ACTIVE/UNUSED sınıfı|SELECT * FROM query_advisor.index_usage() ORDER BY index_scans ASC"
    "s5|5. Kullanılmayan Indexler|unused_indexes() — DROP INDEX DDL|SELECT * FROM query_advisor.unused_indexes() ORDER BY index_size_mb DESC"
    "s6|6. Tekrarlayan Indexler|duplicate_indexes()|SELECT * FROM query_advisor.duplicate_indexes()"
    "s7|7. Eksik Indexler|missing_indexes() — seq scan yüksek tablolar|SELECT * FROM query_advisor.missing_indexes() ORDER BY seq_scan_count DESC"
    "s8|8. Index Sağlığı|index_health() — invalid index|SELECT * FROM query_advisor.index_health() ORDER BY recommendation"
    "s9|9. Autovacuum Ayarları|autovacuum_settings() — ALTER TABLE önerileri|SELECT * FROM query_advisor.autovacuum_settings() ORDER BY estimated_rows DESC"
    "s10|10. Cache Hit Oranı|cache_hit() — buffer cache doluluk|SELECT * FROM query_advisor.cache_hit() ORDER BY heap_hit_pct ASC"
    "s11|11. Yavaş Sorgular|slow_queries() — top 20|SELECT * FROM query_advisor.slow_queries(p_top_n => 20)"
    "s12|12. Uzun Çalışan Sorgular|long_running_queries()|SELECT * FROM query_advisor.long_running_queries()"
    "s13|13. Lock Bekleme Zinciri|lock_waits()|SELECT * FROM query_advisor.lock_waits()"
    "s14|14. Tablo Büyüme Tahmini|table_growth_forecast() — 30/90/180/365 gün|SELECT * FROM query_advisor.table_growth_forecast() ORDER BY growth_rate_pct DESC"
    "s15|15. Partition Adayları|partition_candidates()|SELECT schema_name,table_name,table_size,row_count,partition_strategy,partition_key,recommendation FROM query_advisor.partition_candidates()"
    "s16|16. Index Önerileri|index_recommendations()|SELECT schema_table,seq_scan_count,live_rows,candidate_columns,suggested_ddl,recommendation FROM query_advisor.index_recommendations()"
    "s17|17. Idle Transaction|idle_in_transaction()|SELECT * FROM query_advisor.idle_in_transaction()"
    "s18|18. Vacuum Gereksinimi|vacuum_needs()|SELECT * FROM query_advisor.vacuum_needs() ORDER BY dead_rows_pct_filled DESC"
    "s19|19. Replication Slotları|replication_slots()|SELECT * FROM query_advisor.replication_slots()"
    "s20|20. Konfigurasyon Danışmanı|config_advisor()|SELECT * FROM query_advisor.config_advisor()"
    "s21|21. Korelasyon Kontrolü|correlation_check()|SELECT schema_name,table_name,column_name,correlation,has_index,live_rows,finding,recommendation FROM query_advisor.correlation_check()"
    "s22|22. Sequence Sağlığı|sequence_health()|SELECT * FROM query_advisor.sequence_health() ORDER BY used_pct DESC"
    "s23|23. FK Index Eksiklikleri|fk_without_index()|SELECT * FROM query_advisor.fk_without_index()"
    "s24|24. Bağlantı İstatistikleri|connection_stats()|SELECT * FROM query_advisor.connection_stats()"
    "s25|25. Temp File|temp_file_stats()|SELECT * FROM query_advisor.temp_file_stats()"
    "s26|26. Vacuum İlerlemesi|vacuum_progress()|SELECT * FROM query_advisor.vacuum_progress()"
    "s27|27. Tablespace|tablespace_usage()|SELECT * FROM query_advisor.tablespace_usage()"
    "s28|28. TOAST Analizi|toast_analysis()|SELECT * FROM query_advisor.toast_analysis() ORDER BY toast_pct DESC"
    "s29|29. Deadlock|deadlock_stats()|SELECT * FROM query_advisor.deadlock_stats()"
    "s30|30. Buffer Cache|buffercache_top()|SELECT * FROM query_advisor.buffercache_top()"
    "s31|31. Wait Event|wait_event_summary()|SELECT * FROM query_advisor.wait_event_summary() ORDER BY session_count DESC"
    "s32|32. Index Bloat|index_bloat_estimate()|SELECT * FROM query_advisor.index_bloat_estimate() ORDER BY bloat_ratio_pct DESC"
    "s33|33. Yetki Denetimi|table_privileges_audit()|SELECT * FROM query_advisor.table_privileges_audit()"
    "s34|34. Erişim Metodları|table_access_methods()|SELECT * FROM query_advisor.table_access_methods()"
)

for db in "${DB_LIST[@]}"; do
    [[ -z "$db" ]] && continue
    [[ "${DB_HAS_EXT[$db]:-no}" == "no" ]] && continue

    info "[$db] bölümler yazılıyor..."

    cr="${DB_CRIT[$db]:-0}"
    wr="${DB_WARN[$db]:-0}"
    sz="${DB_SIZE[$db]:-?}"
    ver="${DB_VER[$db]:-?}"

    # DB panel başlığı
    cat >> "$HTML_FILE" <<HTML
<div id="panel-${db}" class="db-panel">
  <div class="scorecard">
    <div class="score-box sc-critical"><span class="num">${cr}</span><span class="lbl">Critical</span></div>
    <div class="score-box sc-warning"> <span class="num">${wr}</span><span class="lbl">Warning</span></div>
    <div class="score-box sc-ok">      <span class="num">${sz}</span><span class="lbl">DB Boyutu</span></div>
    <div class="score-box sc-notice">  <span class="num">${ver}</span><span class="lbl">Extension</span></div>
  </div>
  <div class="toc" id="toc-${db}">
    <h2>İçindekiler — ${db}</h2>
    <ol>
HTML
    for sec in "${SECTIONS[@]}"; do
        sid="${sec%%|*}"; rest="${sec#*|}"; stitle="${rest%%|*}"
        echo "      <li><a href='#${db}-${sid}'>${stitle}</a></li>" >> "$HTML_FILE"
    done
    echo "    </ol></div>" >> "$HTML_FILE"

    # Her bölümü yaz
    for sec in "${SECTIONS[@]}"; do
        IFS='|' read -r sid title desc query <<< "$sec"
        write_section "$db" "$sid" "$title" "$desc" "$query"
    done

    echo "</div>" >> "$HTML_FILE"
    ok "[$db] tamamlandı"
done

# ---------------------------------------------------------------------------
# Footer + JS
# ---------------------------------------------------------------------------
cat >> "$HTML_FILE" <<HTML

<div class="footer">
  pg_query_advisor Cluster Report &bull; PostgreSQL ${PG_VERSION} &bull; ${HOST_NAME} &bull; $(date '+%Y-%m-%d %H:%M:%S')
</div>

<script>
function showDB(db, btn) {
    document.querySelectorAll('.db-panel').forEach(function(p){ p.classList.remove('active'); });
    document.querySelectorAll('.tab-btn').forEach(function(b){ b.classList.remove('active'); });
    var panel = document.getElementById('panel-' + db);
    if (panel) panel.classList.add('active');
    if (btn) { btn.classList.add('active'); }
    else {
        document.querySelectorAll('.tab-btn').forEach(function(b){
            if (b.textContent.trim() === db) b.classList.add('active');
        });
    }
}

document.querySelectorAll('table tr').forEach(function(tr){
    var txt = tr.textContent.toUpperCase();
    if(txt.includes('CRITICAL'))      tr.className='rc';
    else if(txt.includes('WARNING'))  tr.className='rw';
    else if(/\bNOTICE\b/.test(txt))   tr.className='rn';
    else if(/\| *OK *(\||$)/.test(tr.textContent)) tr.className='rok';
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

ln -sf "$(basename "$HTML_FILE")" "$LATEST_LINK"
ok "Cluster raporu: ${HTML_FILE}"
ok "En son link  : ${LATEST_LINK}"
