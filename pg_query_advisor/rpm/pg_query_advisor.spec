%global pgmajorversion 18
%global pginstdir /usr/pgsql-%{pgmajorversion}

Name:           pg_query_advisor_%{pgmajorversion}
Version:        1.0
Release:        1%{?dist}
Summary:        PostgreSQL %{pgmajorversion} Query Advisor Extension
License:        PostgreSQL
URL:            https://github.com/krmbngl/pg_query_advisor
BuildArch:      noarch

# ---------- Runtime ----------
Requires:       postgresql%{pgmajorversion}-server

# ---------- Build ----------
# Pure SQL extension — no C compilation needed.
# pg_config is used only to determine the installation path.
BuildRequires:  postgresql%{pgmajorversion}

%description
pg_query_advisor is a pure-SQL PostgreSQL extension that provides DBA advisory
functions for query optimisation and database maintenance.

All functions live in the query_advisor schema.

  * query_advisor.table_health()         — dead tuples, vacuum/analyze timestamps
  * query_advisor.table_bloat()          — dead-tuple-based bloat estimate
  * query_advisor.index_usage()          — scan counts, ACTIVE/LOW/UNUSED status
  * query_advisor.index_health()         — invalid / oversized index detection
  * query_advisor.missing_indexes()      — tables where seq scans dominate
  * query_advisor.unused_indexes()       — drop candidates + DROP INDEX CONCURRENTLY
  * query_advisor.duplicate_indexes()    — redundant index pairs (same leading cols)
  * query_advisor.slow_queries()         — top slow queries (needs pg_stat_statements)
  * query_advisor.long_running_queries() — active queries exceeding a time threshold
  * query_advisor.lock_waits()           — blocking/waiting pid chain analysis
  * query_advisor.autovacuum_settings()  — scale_factor tuning + ALTER TABLE commands
  * query_advisor.cache_hit()            — buffer cache hit ratios per table
  * query_advisor.report()              — master prioritised recommendations report
  * query_advisor.health_summary        — one-row-per-check count summary view

Compatible with PostgreSQL %{pgmajorversion} on RHEL 8 / RHEL 9.

# -----------------------------------------------------------------------
%prep
# Nothing to unpack — files are copied directly from the source tree.
# When building from a tarball, replace with:
# %setup -q -n pg_query_advisor-%{version}

%build
# Pure SQL extension — nothing to compile.

%install
install -d %{buildroot}%{pginstdir}/share/extension

install -m 0644 \
    ../pg_query_advisor.control \
    %{buildroot}%{pginstdir}/share/extension/

install -m 0644 \
    ../pg_query_advisor--1.0.sql \
    %{buildroot}%{pginstdir}/share/extension/

%files
%{pginstdir}/share/extension/pg_query_advisor.control
%{pginstdir}/share/extension/pg_query_advisor--1.0.sql

# -----------------------------------------------------------------------
%post
echo ""
echo "pg_query_advisor %{version} kuruldu."
echo ""
echo "Aktif etmek için veritabanınıza bağlanın ve çalıştırın:"
echo "  CREATE EXTENSION pg_query_advisor;"
echo ""
echo "pg_stat_statements da önerilir (yavaş sorgu analizi için):"
echo "  /var/lib/pgsql/%{pgmajorversion}/data/postgresql.conf içine ekleyin:"
echo "    shared_preload_libraries = 'pg_stat_statements'"
echo "  Ardından:"
echo "    systemctl restart postgresql-%{pgmajorversion}"
echo "    CREATE EXTENSION pg_stat_statements;"

%postun
echo "pg_query_advisor kaldırıldı."

# -----------------------------------------------------------------------
%changelog
* Wed Apr 09 2026 pg_query_advisor <noreply@example.com> - 1.0-1
- Initial release for PostgreSQL 18 / RHEL 8 / RHEL 9
- Pure SQL extension, no C compilation required
- Functions in query_advisor schema
