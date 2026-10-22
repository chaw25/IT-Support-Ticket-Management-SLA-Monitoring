-- =====================================================================
-- 03_views.sql
-- Reusable views. A view is a saved SELECT: analysts query it like a
-- table, and the SLA rules live in ONE place instead of in every report.
-- =====================================================================

SET search_path TO support;

-- One row per ticket with its SLA deadlines and SLA status.
CREATE OR REPLACE VIEW v_ticket_sla AS
SELECT t.ticket_id,
       t.title,
       t.status,
       t.priority_id,
       p.priority_name,
       a.application_name,
       c.category_name,
       t.error_code,
       t.technician_id,
       tech.first_name || ' ' || tech.last_name                     AS technician_name,
       t.created_at,
       t.first_response_at,
       t.resolved_at,
       t.created_at + p.response_sla_hours   * INTERVAL '1 hour'    AS response_due_at,
       t.created_at + p.resolution_sla_hours * INTERVAL '1 hour'    AS resolution_due_at,
       ROUND(EXTRACT(EPOCH FROM (t.resolved_at - t.created_at)) / 3600, 2) AS resolution_hours,
       -- Response SLA: was the first reply on time?
       CASE WHEN t.first_response_at <= t.created_at + p.response_sla_hours * INTERVAL '1 hour' THEN 'Met'
            WHEN t.first_response_at IS NULL
                 AND report_time() <= t.created_at + p.response_sla_hours * INTERVAL '1 hour' THEN 'Pending'
            ELSE 'Breached' END                                        AS response_sla_status,
       -- Resolution SLA. For open tickets, "At Risk" = over 75% of the allowed time used.
       CASE WHEN t.resolved_at IS NOT NULL THEN
                CASE WHEN t.resolved_at <= t.created_at + p.resolution_sla_hours * INTERVAL '1 hour'
                     THEN 'Met' ELSE 'Breached' END
            WHEN report_time() > t.created_at + p.resolution_sla_hours * INTERVAL '1 hour' THEN 'Breached'
            WHEN report_time() > t.created_at + p.resolution_sla_hours * 0.75 * INTERVAL '1 hour' THEN 'At Risk'
            ELSE 'On Track' END                                        AS resolution_sla_status
FROM tickets t
JOIN priorities   p ON p.priority_id    = t.priority_id
JOIN applications a ON a.application_id = t.application_id
JOIN categories   c ON c.category_id    = t.category_id
LEFT JOIN technicians tech ON tech.technician_id = t.technician_id;   -- LEFT: keep unassigned tickets

-- Unresolved tickets that are past their resolution deadline - the team's "fix first" list.
CREATE OR REPLACE VIEW v_overdue_tickets AS
SELECT ticket_id, title, status, priority_name, application_name, technician_name,
       created_at, resolution_due_at,
       ROUND(EXTRACT(EPOCH FROM (report_time() - resolution_due_at)) / 3600, 1) AS hours_overdue
FROM v_ticket_sla
WHERE resolved_at IS NULL
  AND resolution_sla_status = 'Breached';

-- Current workload per technician (open tickets only).
CREATE OR REPLACE VIEW v_technician_workload AS
SELECT tech.technician_id,
       tech.first_name || ' ' || tech.last_name                         AS technician_name,
       tech.support_level,
       tech.is_active,
       COUNT(t.ticket_id)                                               AS open_tickets,
       COUNT(t.ticket_id) FILTER (WHERE t.priority_id <= 2)             AS open_critical_or_high,
       COUNT(t.ticket_id) FILTER (WHERE report_time() >
             t.created_at + p.resolution_sla_hours * INTERVAL '1 hour') AS open_overdue
FROM technicians tech
LEFT JOIN tickets t
       ON t.technician_id = tech.technician_id
      AND t.status IN ('Open', 'In Progress', 'On Hold')
LEFT JOIN priorities p ON p.priority_id = t.priority_id
GROUP BY tech.technician_id;
