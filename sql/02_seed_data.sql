-- =====================================================================
-- 02_seed_data.sql
-- Reproducible synthetic dataset (~50,000 tickets, Jan-Sep 2026).
--
-- setseed() fixes PostgreSQL's random number generator, so every run
-- produces exactly the same data. Run 01_schema.sql first.
-- =====================================================================

SET search_path TO support;
SELECT setseed(0.42);

-- ---------------------------------------------------------------------
-- Reference data
-- ---------------------------------------------------------------------

INSERT INTO departments (department_name) VALUES
    ('Human Resources'), ('Finance'), ('Operations'), ('Sales'),
    ('Customer Service'), ('IT'), ('Warehouse'), ('Marketing');

INSERT INTO applications (application_name, owner_department, criticality) VALUES
    ('HR Portal',             1, 'High'),
    ('Payroll System',        2, 'High'),
    ('Inventory Manager',     7, 'Medium'),
    ('CRM',                   4, 'High'),
    ('Customer Support Desk', 5, 'Medium'),
    ('Expense Tracker',       2, 'Low'),
    ('Email & Calendar',      6, 'Medium');

INSERT INTO categories (category_name) VALUES
    ('Login Failure'), ('Database Error'), ('Application Crash'),
    ('Slow Performance'), ('Data Issue'), ('Access Request');

INSERT INTO priorities (priority_id, priority_name, response_sla_hours, resolution_sla_hours) VALUES
    (1, 'Critical', 0.5,  4),
    (2, 'High',     1,    8),
    (3, 'Medium',   4,   24),
    (4, 'Low',      8,   72);

INSERT INTO error_codes (error_code, category_id, description) VALUES
    ('AUTH-401',   1, 'Invalid username or password'),
    ('AUTH-423',   1, 'Account locked after failed attempts'),
    ('SSO-504',    1, 'Single sign-on provider timed out'),
    ('DB-1205',    2, 'Deadlock detected, transaction rolled back'),
    ('DB-TIMEOUT', 2, 'Query exceeded timeout'),
    ('DB-CONN',    2, 'Connection pool exhausted'),
    ('APP-500',    3, 'Unhandled server exception'),
    ('APP-OOM',    3, 'Application ran out of memory'),
    ('PERF-PAGE',  4, 'Page load took longer than 10 seconds'),
    ('PERF-BATCH', 4, 'Scheduled batch job overran its window'),
    ('DATA-DUP',   5, 'Duplicate record created'),
    ('DATA-MISS',  5, 'Expected record not found'),
    ('ACC-PERM',   6, 'User lacks required permission');

-- Technician 12 left the company (inactive) - see the troubleshooting script.
INSERT INTO technicians (first_name, last_name, email, support_level, is_active) VALUES
    ('Aung',    'Kyaw',     'aung.kyaw@company.com',     'L1', TRUE),
    ('Maria',   'Lopez',    'maria.lopez@company.com',   'L1', TRUE),
    ('James',   'Carter',   'james.carter@company.com',  'L1', TRUE),
    ('Priya',   'Sharma',   'priya.sharma@company.com',  'L1', TRUE),
    ('Daniel',  'Kim',      'daniel.kim@company.com',    'L1', TRUE),
    ('Sophie',  'Martin',   'sophie.martin@company.com', 'L2', TRUE),
    ('Omar',    'Hassan',   'omar.hassan@company.com',   'L2', TRUE),
    ('Lin',     'Chen',     'lin.chen@company.com',      'L2', TRUE),
    ('Thandar', 'Win',      'thandar.win@company.com',   'L2', TRUE),
    ('Lucas',   'Silva',    'lucas.silva@company.com',   'L3', TRUE),
    ('Emma',    'Novak',    'emma.novak@company.com',    'L3', TRUE),
    ('Ryan',    'Brooks',   'ryan.brooks@company.com',   'L2', FALSE);

-- 300 employees built from name lists.
INSERT INTO employees (first_name, last_name, email, department_id)
SELECT f, l,
       lower(f || '.' || l || g) || '@company.com',
       1 + floor(random() * 8)::int
FROM generate_series(1, 300) AS g,
LATERAL (SELECT (ARRAY['Anna','Ben','Chloe','David','Ella','Felix','Grace','Hiro','Isla','Jack',
                       'Kyaw','Lena','Mya','Noah','Olivia','Paul','Quinn','Rosa','Sam','Tara'])[1 + (g % 20)] AS f,
                (ARRAY['Smith','Tun','Garcia','Nguyen','Brown','Htet','Patel','Lee','Wilson','Khan',
                       'Moore','Aye','Taylor','Ito','Clark','Soe','Lewis','Young','Hall','Zaw'])[1 + ((g / 20) % 20)] AS l) AS names;

-- ---------------------------------------------------------------------
-- Tickets
-- ---------------------------------------------------------------------
-- Each ticket gets random draws, which are then shaped into realistic
-- timings: higher priority = tighter SLA, some tickets breach their SLA,
-- recent tickets are still open, and ~1% get stuck "On Hold".

WITH draws AS (
    SELECT TIMESTAMP '2026-01-01' + random() * (TIMESTAMP '2026-09-30 23:59' - TIMESTAMP '2026-01-01') AS created_at,
           1 + floor(random() * 300)::int AS reporter_id,
           1 + floor(random() * 7)::int   AS application_id,
           1 + floor(random() * 6)::int   AS category_id,
           1 + floor(random() * 11)::int  AS technician_id,      -- active technicians 1-11
           random() AS r_priority, random() AS r_response, random() AS r_resolve,
           random() AS r_stuck,    random() AS r_unassigned, random() AS r_error
    FROM generate_series(1, 50000)
),
shaped AS (
    SELECT d.*,
           CASE WHEN r_priority < 0.05 THEN 1      -- 5%  Critical
                WHEN r_priority < 0.25 THEN 2      -- 20% High
                WHEN r_priority < 0.70 THEN 3      -- 45% Medium
                ELSE 4 END AS priority_id          -- 30% Low
    FROM draws d
),
timed AS (
    SELECT s.*,
           s.created_at + p.response_sla_hours * (0.1 + r_response * 1.2) * INTERVAL '1 hour' AS response_at,
           s.created_at + p.resolution_sla_hours * (0.1 + r_resolve ^ 2 * 1.5)
               * CASE WHEN technician_id = 7 THEN 1.4 ELSE 1 END                        -- one slower technician
               * CASE WHEN application_id = 2 AND category_id = 2 THEN 1.5 ELSE 1 END   -- payroll DB issues are harder
               * INTERVAL '1 hour' AS resolve_at,
           r_stuck < 0.01 AS is_stuck
    FROM shaped s
    JOIN priorities p USING (priority_id)
),
queued AS (
    -- 30% of tickets from the last 3 days are still waiting in the queue.
    SELECT t.*, (r_unassigned < 0.3 AND created_at > report_time() - INTERVAL '3 days') AS is_waiting
    FROM timed t
),
final AS (
    SELECT q.*,
           CASE WHEN NOT is_stuck AND NOT is_waiting AND resolve_at <= report_time() THEN resolve_at END AS resolved_at,
           CASE WHEN NOT is_waiting AND response_at <= report_time() THEN LEAST(response_at, resolve_at) END AS first_response_at
    FROM queued q
),
codes AS (
    SELECT category_id, array_agg(error_code ORDER BY error_code) AS code_list
    FROM error_codes GROUP BY category_id
)
INSERT INTO tickets (title, description, reporter_id, application_id, category_id, error_code,
                     priority_id, technician_id, status, created_at, first_response_at, resolved_at, closed_at)
SELECT c.category_name || ' - ' || a.application_name,
       'User reports ' || lower(c.category_name) || ' in ' || a.application_name || '.',
       f.reporter_id, f.application_id, f.category_id,
       CASE WHEN f.r_error < 0.9   -- 10% of tickets have no error code
            THEN k.code_list[1 + floor(f.r_error / 0.9 * array_length(k.code_list, 1))::int] END,
       f.priority_id,
       CASE WHEN f.is_waiting THEN NULL ELSE f.technician_id END,
       CASE WHEN f.resolved_at + INTERVAL '48 hours' <= report_time() THEN 'Closed'
            WHEN f.resolved_at IS NOT NULL THEN 'Resolved'
            WHEN f.is_stuck AND f.first_response_at IS NOT NULL THEN 'On Hold'
            WHEN f.first_response_at IS NOT NULL THEN 'In Progress'
            ELSE 'Open' END,
       f.created_at,
       f.first_response_at,
       f.resolved_at,
       CASE WHEN f.resolved_at + INTERVAL '48 hours' <= report_time() THEN f.resolved_at + INTERVAL '48 hours' END
FROM final f
JOIN categories   c USING (category_id)
JOIN applications a USING (application_id)
JOIN codes        k USING (category_id)
ORDER BY f.created_at;   -- ticket_id follows creation time, like a real system

-- ---------------------------------------------------------------------
-- Planted incidents for the troubleshooting script (05)
-- ---------------------------------------------------------------------

-- Incident A: a burst of Payroll deadlock errors on the morning of 15 Sep.
INSERT INTO tickets (title, description, reporter_id, application_id, category_id, error_code,
                     priority_id, technician_id, status, created_at, first_response_at, resolved_at, closed_at)
SELECT 'Database Error - Payroll System',
       'Payroll run failed: deadlock detected while saving timesheets.',
       1 + floor(random() * 300)::int, 2, 2, 'DB-1205', 2, 10, 'Closed',
       ts, ts + INTERVAL '20 minutes', ts + INTERVAL '6 hours', ts + INTERVAL '54 hours'
FROM (SELECT TIMESTAMP '2026-09-15 08:30' + random() * INTERVAL '4 hours' AS ts
      FROM generate_series(1, 120)) burst;

-- Incident B: technician 12 left in August, but some open tickets were never reassigned.
UPDATE tickets SET technician_id = 12
WHERE ticket_id IN (SELECT ticket_id FROM tickets
                    WHERE status IN ('In Progress', 'On Hold') AND created_at < '2026-08-01'
                    ORDER BY ticket_id LIMIT 25);
UPDATE tickets SET technician_id = 12
WHERE ticket_id IN (SELECT ticket_id FROM tickets
                    WHERE status = 'Closed' AND created_at < '2026-08-01' AND ticket_id % 23 = 0);

-- Incident C: users who submitted the same ticket twice within minutes.
INSERT INTO tickets (title, description, reporter_id, application_id, category_id, error_code,
                     priority_id, technician_id, status, created_at)
SELECT title, description, reporter_id, application_id, category_id, error_code,
       priority_id, NULL, 'Open', created_at + INTERVAL '7 minutes'
FROM tickets
WHERE status = 'Open' AND ticket_id % 5 = 0
ORDER BY ticket_id
LIMIT 30;

-- ---------------------------------------------------------------------
-- Ticket history (audit trail), derived from the ticket timestamps
-- ---------------------------------------------------------------------

INSERT INTO ticket_updates (ticket_id, technician_id, update_type, note, updated_at)
SELECT ticket_id, technician_id, 'Assigned', 'Ticket picked up by technician.', first_response_at
FROM tickets WHERE first_response_at IS NOT NULL
UNION ALL
SELECT ticket_id, technician_id, 'Comment', 'Investigating; requested logs from the user.',
       first_response_at + (COALESCE(resolved_at, report_time()) - first_response_at) / 2
FROM tickets WHERE first_response_at IS NOT NULL AND ticket_id % 5 < 2
UNION ALL
SELECT ticket_id, technician_id, 'Status Change', 'Waiting on vendor fix.', first_response_at + INTERVAL '1 hour'
FROM tickets WHERE status = 'On Hold'
UNION ALL
SELECT ticket_id, technician_id, 'Resolved', 'Fix applied and confirmed with user.', resolved_at
FROM tickets WHERE resolved_at IS NOT NULL
UNION ALL
SELECT ticket_id, technician_id, 'Closed', 'Closed automatically 48h after resolution.', closed_at
FROM tickets WHERE closed_at IS NOT NULL;

-- Refresh planner statistics after the bulk load.
ANALYZE;
