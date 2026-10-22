-- =====================================================================
-- 05_troubleshooting.sql
-- Incident investigations, written the way an Application Support
-- Engineer works: symptom -> query -> finding -> action.
-- =====================================================================

SET search_path TO support;

-- ---------------------------------------------------------------------
-- Case 1. "Payroll keeps failing this morning!"
-- Find hours where an application + error code got far more tickets than usual.
-- ---------------------------------------------------------------------
WITH hourly AS (
    SELECT a.application_name, t.error_code,
           date_trunc('hour', t.created_at) AS hour,
           COUNT(*) AS tickets
    FROM tickets t
    JOIN applications a ON a.application_id = t.application_id
    WHERE t.error_code IS NOT NULL
    GROUP BY 1, 2, 3
),
with_baseline AS (
    SELECT *, AVG(tickets) OVER (PARTITION BY application_name, error_code) AS avg_per_active_hour
    FROM hourly
)
SELECT application_name, error_code, hour, tickets,
       ROUND(avg_per_active_hour, 2) AS usual
FROM with_baseline
WHERE tickets >= 5 * avg_per_active_hour
ORDER BY tickets DESC
LIMIT 10;
-- Finding: Payroll System / DB-1205 (deadlock) spiked on 2026-09-15 08:00-12:00.
-- Action: raise a problem record with the DBA team; deadlocks point to two
-- jobs updating the same timesheet rows in different order.

-- ---------------------------------------------------------------------
-- Case 2. "Nobody is answering my ticket."
-- Open tickets assigned to a technician who is no longer active.
-- ---------------------------------------------------------------------
SELECT t.ticket_id, t.status, p.priority_name, t.created_at,
       tech.first_name || ' ' || tech.last_name AS assigned_to
FROM tickets t
JOIN technicians tech ON tech.technician_id = t.technician_id
JOIN priorities  p    ON p.priority_id      = t.priority_id
WHERE tech.is_active = FALSE
  AND t.status IN ('Open', 'In Progress', 'On Hold')
ORDER BY t.priority_id, t.created_at;
-- Finding: 25 tickets still sit with Ryan Brooks, who has left.
-- Action: reassign them safely - see 07_transactions.sql.

-- ---------------------------------------------------------------------
-- Case 3. Duplicate tickets inflate the backlog.
-- Same reporter, application and category opened within 30 minutes. [self-join]
-- ---------------------------------------------------------------------
SELECT orig.ticket_id AS original_ticket,
       dup.ticket_id  AS duplicate_ticket,
       e.email        AS reporter,
       orig.title,
       dup.created_at - orig.created_at AS gap
FROM tickets orig
JOIN tickets dup
  ON  dup.reporter_id    = orig.reporter_id
  AND dup.application_id = orig.application_id
  AND dup.category_id    = orig.category_id
  AND dup.ticket_id      > orig.ticket_id
  AND dup.created_at BETWEEN orig.created_at AND orig.created_at + INTERVAL '30 minutes'
JOIN employees e ON e.employee_id = orig.reporter_id
ORDER BY orig.ticket_id;
-- Finding: ~40 pairs. Action: merge each duplicate into its original and
-- close it, so it no longer counts against the SLA.

-- ---------------------------------------------------------------------
-- Case 4. "Why is this ticket so late?"
-- Rebuild the timeline of the most overdue open ticket. [LAG over history]
-- ---------------------------------------------------------------------
WITH target AS (
    SELECT ticket_id FROM v_overdue_tickets ORDER BY hours_overdue DESC, ticket_id LIMIT 1
),
events AS (
    SELECT t.ticket_id, 'Created' AS event, NULL::text AS note, t.created_at AS at
    FROM tickets t JOIN target USING (ticket_id)
    UNION ALL
    SELECT u.ticket_id, u.update_type, u.note, u.updated_at
    FROM ticket_updates u JOIN target USING (ticket_id)
)
SELECT ticket_id, event, note, at,
       at - LAG(at) OVER (ORDER BY at) AS time_since_previous_event
FROM events
ORDER BY at;
-- Finding: ticket 253 went On Hold "waiting on vendor fix" on 2 Jan and has had
-- no update since - it belongs to Ryan Brooks (Case 2), so nobody followed it up.

-- ---------------------------------------------------------------------
-- Case 5. Unassigned tickets that have already missed the response SLA.
-- ---------------------------------------------------------------------
SELECT ticket_id, priority_name, application_name, created_at, response_due_at
FROM v_ticket_sla
WHERE technician_id IS NULL
  AND response_sla_status = 'Breached'
ORDER BY priority_id, created_at
LIMIT 20;

-- ---------------------------------------------------------------------
-- Case 6. Data integrity check: resolved tickets with no "Resolved" history entry.
-- [anti-join with NOT EXISTS] - expected result: 0 rows.
-- ---------------------------------------------------------------------
SELECT t.ticket_id, t.status, t.resolved_at
FROM tickets t
WHERE t.resolved_at IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM ticket_updates u
                  WHERE u.ticket_id = t.ticket_id AND u.update_type = 'Resolved');

-- ---------------------------------------------------------------------
-- Case 7. "The application is hanging" - check the live database.
-- These use PostgreSQL's built-in monitoring views.
-- ---------------------------------------------------------------------

-- Queries running longer than 30 seconds.
SELECT pid, usename, state, now() - query_start AS running_for, left(query, 80) AS query
FROM pg_stat_activity
WHERE state <> 'idle'
  AND now() - query_start > INTERVAL '30 seconds'
ORDER BY running_for DESC;

-- Sessions that are blocked, and who is blocking them.
SELECT blocked.pid                 AS blocked_pid,
       left(blocked.query, 60)     AS blocked_query,
       blocker.pid                 AS blocking_pid,
       left(blocker.query, 60)     AS blocking_query
FROM pg_stat_activity blocked
JOIN pg_stat_activity blocker ON blocker.pid = ANY (pg_blocking_pids(blocked.pid));
-- Action if needed: SELECT pg_cancel_backend(<blocking_pid>);  -- cancels the query, keeps the session
