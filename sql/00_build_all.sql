-- =====================================================================
-- 00_build_all.sql - builds the whole database in one command:
--   psql -U postgres -d it_support -f sql/00_build_all.sql
-- \ir = include a file relative to this one. ON_ERROR_STOP aborts on the
-- first error instead of carrying on with a half-built database.
-- =====================================================================
\set ON_ERROR_STOP on
\timing on

\echo '== 1/5 schema =='
\ir 01_schema.sql
\echo '== 2/5 seed data =='
\ir 02_seed_data.sql
\echo '== 3/5 views =='
\ir 03_views.sql
\echo '== 4/5 indexes =='
\ir 06_indexes_performance.sql
\echo '== 5/5 checks =='
\ir 99_checks.sql
