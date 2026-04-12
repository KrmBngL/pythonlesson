EXTENSION    = pg_query_advisor
DATA         = pg_query_advisor--1.0.sql \
               pg_query_advisor--1.0--1.1.sql \
               pg_query_advisor--1.1.sql \
               pg_query_advisor--1.1--1.2.sql \
               pg_query_advisor--1.2.sql \
               pg_query_advisor--1.2--1.3.sql \
               pg_query_advisor--1.3.sql

# Detect pg_config; override with: make PG_CONFIG=/usr/pgsql-18/bin/pg_config
PG_CONFIG   ?= pg_config

PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)

# ---- Convenience targets ----

.PHONY: installcheck-pg18
installcheck-pg18:
	$(MAKE) installcheck PG_CONFIG=/usr/pgsql-18/bin/pg_config

.PHONY: install-pg18
install-pg18:
	$(MAKE) install PG_CONFIG=/usr/pgsql-18/bin/pg_config

.PHONY: install-pg17
install-pg17:
	$(MAKE) install PG_CONFIG=/usr/pgsql-17/bin/pg_config
