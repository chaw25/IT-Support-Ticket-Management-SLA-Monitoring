-- =====================================================================
-- 07_transactions.sql
-- Safe data changes. A transaction groups statements so they either ALL
-- happen (COMMIT) or NONE happen (ROLLBACK).
--
-- Run this file on its own, after the database is built:
--   psql -U postgres -d it_support -f sql/07_transactions.sql
-- Demo 3 deliberately triggers an error, so do not use ON_ERROR_STOP here.
-- =====================================================================

SET search_path TO support;

-- ---------------------------------------------------------------------
-- Demo 1. Reassign tickets from the technician who left (fixes Case 2 in 05).
-- The ticket change and its audit-trail entry must succeed together.
-- ---------------------------------------------------------------------
BEGIN;

WITH new_owner AS (
    -- the active L2 technician with the fewest open tickets
    SELECT technician_id
    FROM v_technician_workload
    WHERE is_active AND support_level = 'L2'
    ORDER BY open_tickets, technician_id
    LIMIT 1
),
moved AS (
    UPDATE tickets
    SET technician_id = (SELECT technician_id FROM new_owner)
    WHERE technician_id = 12
      AND status IN ('Open', 'In Progress', 'On Hold')
    RETURNING ticket_id, technician_id
)
INSERT INTO ticket_updates (ticket_id, technician_id, update_type, note, updated_at)
SELECT ticket_id, technician_id, 'Reassigned',
       'Reassigned from inactive technician Ryan Brooks.', report_time()
FROM moved;

-- Verify before committing: expect 0 open tickets left on technician 12.
SELECT COUNT(*) AS still_on_inactive_technician
FROM tickets
WHERE technician_id = 12 AND status IN ('Open', 'In Progress', 'On Hold');

COMMIT;

-- ---------------------------------------------------------------------
-- Demo 2. Catching a mistake with ROLLBACK.
-- The UPDATE below "forgot" its WHERE clause and changes every ticket.
-- ---------------------------------------------------------------------
BEGIN;

UPDATE tickets SET priority_id = 4;          -- oops: no WHERE clause
SELECT COUNT(*) AS low_priority_tickets FROM tickets WHERE priority_id = 4;   -- every ticket!

ROLLBACK;                                    -- undo everything since BEGIN

SELECT priority_id, COUNT(*) AS tickets      -- original priorities are back
FROM tickets GROUP BY priority_id ORDER BY priority_id;

-- ---------------------------------------------------------------------
-- Demo 3. SAVEPOINT: undo one failed step without losing the earlier work.
-- ---------------------------------------------------------------------
BEGIN;

INSERT INTO tickets (title, description, reporter_id, application_id, category_id,
                     error_code, priority_id, status, created_at)
VALUES ('Login Failure - HR Portal', 'User locked out after password reset.',
        42, 1, 1, 'AUTH-423', 2, 'Open', report_time());

SAVEPOINT before_resolve;

-- This violates chk_resolved_after_create (resolved before it was created)
-- and fails. The CHECK constraint protects the data.
UPDATE tickets
SET status = 'Resolved', resolved_at = created_at - INTERVAL '1 hour'
WHERE ticket_id = (SELECT MAX(ticket_id) FROM tickets);

ROLLBACK TO SAVEPOINT before_resolve;        -- the INSERT above is kept

COMMIT;

SELECT ticket_id, title, status, created_at
FROM tickets ORDER BY ticket_id DESC LIMIT 1;

-- ---------------------------------------------------------------------
-- Demo 4. Two technicians clicking "take next ticket" at the same moment.
-- FOR UPDATE locks the chosen row; SKIP LOCKED makes the second technician
-- get the NEXT ticket instead of waiting or taking the same one.
-- ---------------------------------------------------------------------
BEGIN;

WITH next_ticket AS (
    SELECT ticket_id
    FROM tickets
    WHERE technician_id IS NULL AND status = 'Open'
    ORDER BY priority_id, created_at
    LIMIT 1
    FOR UPDATE SKIP LOCKED
)
UPDATE tickets t
SET technician_id = 5, status = 'In Progress', first_response_at = report_time()
FROM next_ticket n
WHERE t.ticket_id = n.ticket_id
RETURNING t.ticket_id, t.priority_id, t.status;

COMMIT;
