#!/bin/bash
# =============================================================================
# build-rpm.sh — pg_query_advisor RPM paketi olusturucu
# Kullanim: cd pg_query_advisor/rpm && bash build-rpm.sh [pg_version]
# Ornek   : bash build-rpm.sh 18        # PG18 icin (varsayilan)
#           bash build-rpm.sh 17        # PG17 icin
# =============================================================================

set -euo pipefail

EXTNAME="pg_query_advisor"
VERSION="1.5"
PGVER="${1:-18}"
SRCDIR="$(cd "$(dirname "$0")/.." && pwd)"   # pg_query_advisor/ dizini
TMPDIR_BASE=$(mktemp -d)
PKGDIR="${TMPDIR_BASE}/${EXTNAME}-${VERSION}"

echo "================================================================"
echo " pg_query_advisor v${VERSION} — RPM Build (PostgreSQL ${PGVER})"
echo "================================================================"
echo ""

# 1. Tarball icin gecici dizin olustur
mkdir -p "${PKGDIR}"

echo "[1/4] Dosyalar kopyalaniyor -> ${PKGDIR}"
cp "${SRCDIR}/${EXTNAME}.control"   "${PKGDIR}/"
cp "${SRCDIR}/${EXTNAME}"--*.sql    "${PKGDIR}/"
cp "${SRCDIR}/README.md"            "${PKGDIR}/"
cp "${SRCDIR}/check_all.sql"        "${PKGDIR}/"

# 2. Tarball olustur
echo "[2/4] Tarball olusturuluyor: ${EXTNAME}-${VERSION}.tar.gz"
cd "${TMPDIR_BASE}"
tar czf "${EXTNAME}-${VERSION}.tar.gz" "${EXTNAME}-${VERSION}/"
cd - > /dev/null

# 3. rpmbuild dizin agaci
echo "[3/4] rpmbuild dizinleri hazirlaniyor"
mkdir -p ~/rpmbuild/{SOURCES,SPECS,BUILD,RPMS,SRPMS}
cp "${TMPDIR_BASE}/${EXTNAME}-${VERSION}.tar.gz" ~/rpmbuild/SOURCES/
cp "$(dirname "$0")/pg_query_advisor.spec"       ~/rpmbuild/SPECS/

# 4. RPM olustur
echo "[4/4] RPM olusturuluyor (pgmajorversion=${PGVER})"
rpmbuild -ba ~/rpmbuild/SPECS/pg_query_advisor.spec \
    --define "pgmajorversion ${PGVER}" \
    --define "dist .el$(rpm -E '%{?rhel}' 2>/dev/null || echo 8)"

# Temizlik
rm -rf "${TMPDIR_BASE}"

echo ""
echo "================================================================"
echo " RPM hazir:"
ls ~/rpmbuild/RPMS/noarch/${EXTNAME}_${PGVER}-${VERSION}*.rpm 2>/dev/null || \
ls ~/rpmbuild/RPMS/noarch/*.rpm | tail -2
echo ""
echo " Kurulum:"
echo "   rpm -ivh ~/rpmbuild/RPMS/noarch/${EXTNAME}_${PGVER}-${VERSION}*.noarch.rpm"
echo "   -- veya --"
echo "   dnf install ~/rpmbuild/RPMS/noarch/${EXTNAME}_${PGVER}-${VERSION}*.noarch.rpm"
echo "================================================================"
