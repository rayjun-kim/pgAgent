EXTENSION = pgagent
DATA = pgagent--0.1.0.sql
PGFILEDESC = "pgagent: Autonomous Agent capabilities for PostgreSQL"

SQL_FILES = sql/00_init.sql \
            sql/01_tables.sql \
            sql/02_functions.sql \
            sql/03_hybrid_search.sql \
            sql/04_chunking.sql \
            sql/05_settings.sql

PG_CONFIG = pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)

pgagent--0.1.0.sql: $(SQL_FILES)
	echo "-- ============================================================================" > $@
	echo "-- pgagent for PostgreSQL v0.1.0" >> $@
	echo "-- Generated on $$(date)" >> $@
	echo "-- ============================================================================" >> $@
	echo "" >> $@
	for f in $(SQL_FILES); do \
		echo "-- Source: $$f" >> $@; \
		cat $$f >> $@; \
		echo "" >> $@; \
	done

dev-install: pgagent--0.1.0.sql
	psql -c "DROP EXTENSION IF EXISTS pgagent"
	psql -c "CREATE EXTENSION pgagent"

test:
	psql -f tests/smoke_test.sql

stats:
	@echo "SQL Extension size (lines):"
	@wc -l pgagent--0.1.0.sql
