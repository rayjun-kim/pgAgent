EXTENSION = pg_agent
DATA = pg_agent--0.1.0.sql
PGFILEDESC = "pg_agent: Autonomous Agent capabilities for PostgreSQL"

SQL_FILES = sql/00_init.sql \
            sql/01_tables.sql \
            sql/02_functions.sql \
            sql/03_hybrid_search.sql \
            sql/04_chunking.sql \
            sql/05_settings.sql

PG_CONFIG = pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)

pg_agent--0.1.0.sql: $(SQL_FILES)
	echo "-- ============================================================================" > $@
	echo "-- pg_agent for PostgreSQL v0.1.0" >> $@
	echo "-- Generated on $$(date)" >> $@
	echo "-- ============================================================================" >> $@
	echo "" >> $@
	for f in $(SQL_FILES); do \
		echo "-- Source: $$f" >> $@; \
		cat $$f >> $@; \
		echo "" >> $@; \
	done

dev-install: pg_agent--0.1.0.sql
	psql -c "DROP EXTENSION IF EXISTS pg_agent"
	psql -c "CREATE EXTENSION pg_agent"

test:
	psql -f tests/smoke_test.sql

stats:
	@echo "SQL Extension size (lines):"
	@wc -l pg_agent--0.1.0.sql
