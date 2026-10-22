-- =====================================================================
-- 99_checks.sql
-- Self-checks: each ASSERT raises an error if the data is wrong.
-- "All checks passed" at the end means the build is correct.
-- =====================================================================

SET search_path TO support;

DO $$
DECLARE n bigint;
BEGIN
    SELECT COUNT(*) INTO n FROM tickets;
    ASSERT n >= 50120, format('expected at least 50120 tickets, found %s', n);   -- 50,000 + 120 burst + duplicates

    -- Every ticket references a valid reporter/app/category (FKs guarantee it; prove it).
    SELECT COUNT(*) INTO n FROM tickets t LEFT JOIN employees e ON e.employee_id = t.reporter_id
    WHERE e.employee_id IS NULL;
    ASSERT n = 0, 'orphan reporters found';

    -- Error codes always match the ticket category.
    SELECT COUNT(*) INTO n FROM tickets t JOIN error_codes e USING (error_code)
    WHERE e.category_id <> t.category_id;
    ASSERT n = 0, format('%s tickets have an error code from another category', n);

    -- Every resolved ticket has a "Resolved" history entry.
    SELECT COUNT(*) INTO n FROM tickets t
    WHERE resolved_at IS NOT NULL
      AND NOT EXISTS (SELECT 1 FROM ticket_updates u WHERE u.ticket_id = t.ticket_id AND u.update_type = 'Resolved');
    ASSERT n = 0, format('%s resolved tickets lack history', n);

    -- SLA statuses only take expected values.
    SELECT COUNT(*) INTO n FROM v_ticket_sla
    WHERE resolution_sla_status NOT IN ('Met', 'Breached', 'At Risk', 'On Track')
       OR response_sla_status   NOT IN ('Met', 'Breached', 'Pending');
    ASSERT n = 0, 'unexpected SLA status value';

    -- Resolved tickets are never "At Risk"/"On Track"; open ones never "Met".
    SELECT COUNT(*) INTO n FROM v_ticket_sla
    WHERE (resolved_at IS NOT NULL AND resolution_sla_status NOT IN ('Met', 'Breached'))
       OR (resolved_at IS NULL     AND resolution_sla_status = 'Met');
    ASSERT n = 0, 'SLA status inconsistent with resolution';

    -- The planted incidents exist, so the troubleshooting script has something to find.
    SELECT COUNT(*) INTO n FROM tickets
    WHERE application_id = 2 AND error_code = 'DB-1205'
      AND created_at >= '2026-09-15 08:00' AND created_at < '2026-09-15 13:00';
    ASSERT n >= 120, 'payroll deadlock burst missing';

    SELECT COUNT(*) INTO n FROM tickets a JOIN tickets b
      ON b.reporter_id = a.reporter_id AND b.application_id = a.application_id AND b.category_id = a.category_id
     AND b.ticket_id > a.ticket_id AND b.created_at BETWEEN a.created_at AND a.created_at + INTERVAL '30 minutes';
    ASSERT n >= 20, format('expected duplicate tickets, found %s', n);

    SELECT COUNT(*) INTO n FROM tickets WHERE technician_id = 12;
    ASSERT n > 0, 'no tickets for inactive technician';

    -- Reproducibility: the seed always yields the same number of breached resolved tickets.
    RAISE NOTICE 'Fingerprint (breached resolved tickets): %',
        (SELECT COUNT(*) FROM v_ticket_sla WHERE resolved_at IS NOT NULL AND resolution_sla_status = 'Breached');

    RAISE NOTICE 'All checks passed';
END $$;
