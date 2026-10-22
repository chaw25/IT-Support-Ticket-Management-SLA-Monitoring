-- =====================================================================
-- 06_indexes_performance.sql
-- Measure common support queries, add indexes, measure again.
-- EXPLAIN ANALYZE runs the query and shows HOW PostgreSQL executed it
-- ("Seq Scan" = read the whole table, "Index Scan" = jump to the rows)
-- and how long it took. Results are recorded in docs/performance.md.
-- =====================================================================

SET search_path TO support;

-- Start from "no extra indexes" so the file can be re-run.
DROP INDEX IF EXISTS idx_ticket_updates_ticket_id;
DROP INDEX IF EXISTS idx_tickets_technician_status;
DROP INDEX IF EXISTS idx_tickets_app_created;
DROP INDEX IF EXISTS idx_tickets_open_priority;
ANALYZE tickets;
ANALYZE ticket_updates;

-- ---------------------------- BEFORE ---------------------------------

-- P1. Show the history of one ticket (support agents do this constantly).
EXPLAIN ANALYZE
SELECT * FROM ticket_updates WHERE ticket_id = 25000;

-- P2. "My queue": a technician's open tickets.
EXPLAIN ANALYZE
SELECT ticket_id, title, priority_id, created_at
FROM tickets
WHERE technician_id = 3 AND status IN ('Open', 'In Progress', 'On Hold');

-- P3. All tickets for one application in one month.
EXPLAIN ANALYZE
SELECT ticket_id, error_code, created_at
FROM tickets
WHERE application_id = 2
  AND created_at >= '2026-09-01' AND created_at < '2026-10-01';

-- P4. The open backlog, most urgent first.
EXPLAIN ANALYZE
SELECT ticket_id, priority_id, created_at
FROM tickets
WHERE resolved_at IS NULL
ORDER BY priority_id, created_at
LIMIT 50;

-- ---------------------------- INDEXES --------------------------------

-- PostgreSQL does NOT index foreign keys automatically.
CREATE INDEX idx_ticket_updates_ticket_id ON ticket_updates (ticket_id);

-- Composite index: equality column first (technician), then status.
CREATE INDEX idx_tickets_technician_status ON tickets (technician_id, status);

-- Equality column first, then the range column.
CREATE INDEX idx_tickets_app_created ON tickets (application_id, created_at);

-- Partial index: only the small set of unresolved tickets is indexed,
-- already in the order the backlog screen needs.
CREATE INDEX idx_tickets_open_priority ON tickets (priority_id, created_at)
WHERE resolved_at IS NULL;

ANALYZE tickets;
ANALYZE ticket_updates;

-- ---------------------------- AFTER ----------------------------------

EXPLAIN ANALYZE
SELECT * FROM ticket_updates WHERE ticket_id = 25000;

EXPLAIN ANALYZE
SELECT ticket_id, title, priority_id, created_at
FROM tickets
WHERE technician_id = 3 AND status IN ('Open', 'In Progress', 'On Hold');

EXPLAIN ANALYZE
SELECT ticket_id, error_code, created_at
FROM tickets
WHERE application_id = 2
  AND created_at >= '2026-09-01' AND created_at < '2026-10-01';

EXPLAIN ANALYZE
SELECT ticket_id, priority_id, created_at
FROM tickets
WHERE resolved_at IS NULL
ORDER BY priority_id, created_at
LIMIT 50;

-- ------------------------ COMMON MISTAKE -----------------------------
-- Wrapping an indexed column in a function/cast hides it from the index.

-- Slower: the index can only narrow by application_id (~7,100 Payroll rows),
-- then created_at::date is computed and checked on every one of them.
EXPLAIN ANALYZE
SELECT COUNT(*) FROM tickets
WHERE application_id = 2 AND created_at::date = '2026-09-15';

-- Fast: same question as a range on the raw column -> the index jumps
-- straight to that day's ~150 rows.
EXPLAIN ANALYZE
SELECT COUNT(*) FROM tickets
WHERE application_id = 2
  AND created_at >= '2026-09-15' AND created_at < '2026-09-16';
