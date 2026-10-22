-- =====================================================================
-- 04_analysis.sql
-- Business questions the IT support manager asks, answered in SQL.
-- Each query is labelled with the SQL technique it demonstrates.
-- =====================================================================

SET search_path TO support;

-- Q1. What is our SLA compliance per priority?            [JOIN + GROUP BY + FILTER]
SELECT priority_name,
       COUNT(*)                                                         AS resolved_tickets,
       COUNT(*) FILTER (WHERE resolution_sla_status = 'Met')            AS met_sla,
       ROUND(100.0 * COUNT(*) FILTER (WHERE resolution_sla_status = 'Met') / COUNT(*), 1) AS sla_met_pct,
       ROUND(AVG(resolution_hours), 1)                                  AS avg_resolution_hours
FROM v_ticket_sla
WHERE resolved_at IS NOT NULL
GROUP BY priority_id, priority_name
ORDER BY priority_id;

-- Q2. Current backlog: how many unresolved tickets, and how many are overdue?   [CTE]
WITH backlog AS (
    SELECT * FROM v_ticket_sla WHERE resolved_at IS NULL
)
SELECT status,
       COUNT(*)                                                     AS tickets,
       COUNT(*) FILTER (WHERE resolution_sla_status = 'Breached')   AS overdue,
       COUNT(*) FILTER (WHERE resolution_sla_status = 'At Risk')    AS at_risk,
       COUNT(*) FILTER (WHERE technician_id IS NULL)                AS unassigned
FROM backlog
GROUP BY status
ORDER BY tickets DESC;

-- Q3. Is SLA performance improving month over month?      [window function LAG]
WITH monthly AS (
    SELECT date_trunc('month', created_at)::date AS month,
           COUNT(*) AS resolved,
           ROUND(100.0 * COUNT(*) FILTER (WHERE resolution_sla_status = 'Met') / COUNT(*), 1) AS sla_met_pct
    FROM v_ticket_sla
    WHERE resolved_at IS NOT NULL
    GROUP BY 1
)
SELECT month, resolved, sla_met_pct,
       sla_met_pct - LAG(sla_met_pct) OVER (ORDER BY month) AS change_vs_prev_month
FROM monthly
ORDER BY month;

-- Q4. Rank technicians by SLA performance within each support level.   [RANK() OVER PARTITION BY]
SELECT tech.support_level,
       tech.first_name || ' ' || tech.last_name AS technician,
       COUNT(*)                                 AS resolved,
       ROUND(100.0 * COUNT(*) FILTER (WHERE s.resolution_sla_status = 'Met') / COUNT(*), 1) AS sla_met_pct,
       RANK() OVER (PARTITION BY tech.support_level
                    ORDER BY COUNT(*) FILTER (WHERE s.resolution_sla_status = 'Met')::numeric / COUNT(*) DESC) AS rank_in_level
FROM v_ticket_sla s
JOIN technicians tech ON tech.technician_id = s.technician_id
WHERE s.resolved_at IS NOT NULL
GROUP BY tech.technician_id
ORDER BY tech.support_level, rank_in_level;

-- Q5. Top 3 recurring error codes for each application.   [CTE + ROW_NUMBER]
WITH error_counts AS (
    SELECT a.application_name, t.error_code, e.description, COUNT(*) AS occurrences
    FROM tickets t
    JOIN applications a ON a.application_id = t.application_id
    JOIN error_codes  e ON e.error_code     = t.error_code
    GROUP BY a.application_name, t.error_code, e.description
),
ranked AS (
    SELECT *, ROW_NUMBER() OVER (PARTITION BY application_name ORDER BY occurrences DESC, error_code) AS rn
    FROM error_counts
)
SELECT application_name, rn AS rank, error_code, description, occurrences
FROM ranked
WHERE rn <= 3
ORDER BY application_name, rn;

-- Q6. Which applications breach SLA more often than the company average?   [subquery]
SELECT application_name,
       ROUND(100.0 * COUNT(*) FILTER (WHERE resolution_sla_status = 'Breached') / COUNT(*), 1) AS breach_pct
FROM v_ticket_sla
WHERE resolved_at IS NOT NULL
GROUP BY application_name
HAVING 1.0 * COUNT(*) FILTER (WHERE resolution_sla_status = 'Breached') / COUNT(*) >
       (SELECT 1.0 * COUNT(*) FILTER (WHERE resolution_sla_status = 'Breached') / COUNT(*)
        FROM v_ticket_sla WHERE resolved_at IS NOT NULL)
ORDER BY breach_pct DESC;

-- Q7. Median and 90th-percentile resolution time per category.   [ordered-set aggregates]
SELECT category_name,
       ROUND(percentile_cont(0.5) WITHIN GROUP (ORDER BY resolution_hours)::numeric, 1) AS median_hours,
       ROUND(percentile_cont(0.9) WITHIN GROUP (ORDER BY resolution_hours)::numeric, 1) AS p90_hours
FROM v_ticket_sla
WHERE resolved_at IS NOT NULL
GROUP BY category_name
ORDER BY median_hours DESC;

-- Q8. Age of the open backlog in buckets.   [CASE bucketing]
SELECT CASE WHEN age < INTERVAL '1 day'   THEN '1. < 1 day'
            WHEN age < INTERVAL '3 days'  THEN '2. 1-3 days'
            WHEN age < INTERVAL '7 days'  THEN '3. 3-7 days'
            WHEN age < INTERVAL '30 days' THEN '4. 7-30 days'
            ELSE '5. 30+ days' END AS age_bucket,
       COUNT(*) AS open_tickets
FROM (SELECT report_time() - created_at AS age
      FROM tickets WHERE resolved_at IS NULL) open_t
GROUP BY 1
ORDER BY 1;

-- Q9. Weekly tickets created vs resolved, with a running backlog.   [window SUM running total]
WITH weekly AS (
    SELECT wk,
           SUM(created)  AS created,
           SUM(resolved) AS resolved
    FROM (SELECT date_trunc('week', created_at)::date  AS wk, 1 AS created, 0 AS resolved FROM tickets
          UNION ALL
          SELECT date_trunc('week', resolved_at)::date, 0, 1 FROM tickets WHERE resolved_at IS NOT NULL) e
    GROUP BY wk
)
SELECT wk AS week_start, created, resolved,
       SUM(created - resolved) OVER (ORDER BY wk) AS running_backlog
FROM weekly
ORDER BY wk;

-- Q10. Employees who report the most tickets (candidates for training).   [JOIN + subquery in FROM]
SELECT e.first_name || ' ' || e.last_name AS employee,
       d.department_name,
       x.tickets
FROM (SELECT reporter_id, COUNT(*) AS tickets FROM tickets GROUP BY reporter_id) x
JOIN employees   e ON e.employee_id   = x.reporter_id
JOIN departments d ON d.department_id = e.department_id
ORDER BY x.tickets DESC, employee
LIMIT 10;
