%global extname        pg_query_advisor
%global extversion     1.5
%global pgmajorversion 18
%global pginstdir      /usr/pgsql-%{pgmajorversion}

Name:       %{extname}_%{pgmajorversion}
Version:    %{extversion}
Release:    1%{?dist}
Summary:    PostgreSQL %{pgmajorversion} Query Advisor — 35 DBA advisory functions
License:    PostgreSQL
URL:        https://github.com/KrmBngL/pythonlesson
Source0:    %{extname}-%{extversion}.tar.gz
BuildArch:  noarch

Requires:       postgresql%{pgmajorversion}-server
BuildRequires:  postgresql%{pgmajorversion}

%description
pg_query_advisor is a pure-SQL PostgreSQL extension providing 35 DBA advisory
functions across 5 versions. All functions live in the query_advisor schema.

v1.0 — Temel Analiz (13 fonksiyon):
  table_health, table_bloat, index_usage, index_health, missing_indexes,
  unused_indexes, duplicate_indexes, slow_queries, long_running_queries,
  lock_waits, autovacuum_settings, cache_hit, report + health_summary view

v1.1 — Sorgu Plani ve Buyume (4 fonksiyon):
  explain_plan, table_growth_forecast, partition_candidates, index_recommendations

v1.2 — Operasyonel Izleme (5 fonksiyon):
  idle_in_transaction, vacuum_needs, replication_slots, config_advisor,
  correlation_check

v1.3 — Guvenlik Agi ve Kaynak (5 fonksiyon):
  sequence_health, fk_without_index, connection_stats, temp_file_stats,
  vacuum_progress

v1.4 — Depolama ve Bellek (4 fonksiyon):
  tablespace_usage, toast_analysis, deadlock_stats, buffercache_top

v1.5 — Performans Tani ve Guvenlik (4 fonksiyon):
  wait_event_summary, index_bloat_estimate, table_privileges_audit,
  table_access_methods

Tam rapor icin: psql -U postgres -d mydb -f check_all.sql
Compatible with PostgreSQL %{pgmajorversion} on RHEL 8 / RHEL 9.

# -----------------------------------------------------------------------
%prep
%setup -q -n %{extname}-%{extversion}

%build
# Pure SQL extension — nothing to compile.

%install
install -d %{buildroot}%{pginstdir}/share/extension

# Control + tum SQL dosyalari
install -m 0644 %{extname}.control         %{buildroot}%{pginstdir}/share/extension/
install -m 0644 %{extname}--*.sql          %{buildroot}%{pginstdir}/share/extension/

# Dokumantasyon dizini
install -d %{buildroot}%{_docdir}/%{name}
install -m 0644 README.md      %{buildroot}%{_docdir}/%{name}/
install -m 0644 check_all.sql  %{buildroot}%{_docdir}/%{name}/

%files
%{pginstdir}/share/extension/%{extname}.control
%{pginstdir}/share/extension/%{extname}--*.sql
%doc %{_docdir}/%{name}/README.md
%doc %{_docdir}/%{name}/check_all.sql

# -----------------------------------------------------------------------
%post
echo ""
echo "================================================================"
echo " pg_query_advisor %{extversion} basariyla kuruldu!"
echo " PostgreSQL %{pgmajorversion}"
echo "================================================================"
echo ""
echo "1. pg_stat_statements icin postgresql.conf duzenle:"
echo "     shared_preload_libraries = 'pg_stat_statements'"
echo "   Ardindan: systemctl restart postgresql-%{pgmajorversion}"
echo ""
echo "2. Extension'i aktif et:"
echo "     psql -U postgres -d <veritabani> -c \\"
echo "       \"CREATE EXTENSION IF NOT EXISTS pg_stat_statements;\""
echo "     psql -U postgres -d <veritabani> -c \\"
echo "       \"CREATE EXTENSION pg_query_advisor;\""
echo ""
echo "3. Zaten yuklu ise guncelle:"
echo "     psql -U postgres -d <veritabani> -c \\"
echo "       \"ALTER EXTENSION pg_query_advisor UPDATE TO '%{extversion}';\""
echo ""
echo "4. Tam raporu calistir:"
echo "     psql -U postgres -d <veritabani> \\"
echo "       -f %{_docdir}/%{name}/check_all.sql"
echo ""
echo "================================================================"

%postun
echo "pg_query_advisor %{pgmajorversion} kaldirildi."

# -----------------------------------------------------------------------
%changelog
* Sat Apr 12 2026 pg_query_advisor <noreply@example.com> - 1.5-1
- v1.5: wait_event_summary, index_bloat_estimate, table_privileges_audit,
  table_access_methods eklendi (35 fonksiyon toplam)

* Sat Apr 12 2026 pg_query_advisor <noreply@example.com> - 1.4-1
- v1.4: tablespace_usage, toast_analysis, deadlock_stats, buffercache_top

* Sat Apr 12 2026 pg_query_advisor <noreply@example.com> - 1.3-1
- v1.3: sequence_health, fk_without_index, connection_stats,
  temp_file_stats, vacuum_progress

* Sat Apr 12 2026 pg_query_advisor <noreply@example.com> - 1.2-1
- v1.2: idle_in_transaction, vacuum_needs, replication_slots,
  config_advisor, correlation_check

* Sat Apr 12 2026 pg_query_advisor <noreply@example.com> - 1.1-1
- v1.1: explain_plan, table_growth_forecast, partition_candidates,
  index_recommendations

* Wed Apr 09 2026 pg_query_advisor <noreply@example.com> - 1.0-1
- Initial release: 13 temel fonksiyon + health_summary view
- Pure SQL extension, RHEL 8/9, PostgreSQL 18
