# Index Performance Comparison

Measured with `EXPLAIN ANALYZE` in [`sql/06_indexes_performance.sql`](../sql/06_indexes_performance.sql)
on PostgreSQL 18, with ~50,000 tickets and ~170,000 ticket updates.
Each number is the middle of three runs.

| # | Query | Before (plan, time) | Index added | After (plan, time) | Speed-up |
|---|-------|---------------------|-------------|--------------------|----------|
| P1 | History of one ticket | Seq Scan, 8.2 ms | `ticket_updates (ticket_id)` | Index Scan, 0.07 ms | ~120x |
| P2 | One technician's open queue | Seq Scan, 4.4 ms | `tickets (technician_id, status)` | Bitmap Index Scan, 0.11 ms | ~40x |
| P3 | One application, one month | Seq Scan, 4.4 ms | `tickets (application_id, created_at)` | Bitmap Index Scan, 0.32 ms | ~14x |
| P4 | Open backlog, most urgent first (top 50) | Seq Scan + Sort, 4.4 ms | partial `tickets (priority_id, created_at) WHERE resolved_at IS NULL` | Index Scan, 0.08 ms | ~55x |

## Lessons

1. **PostgreSQL does not index foreign keys automatically.** P1 was the
   slowest query because `ticket_updates.ticket_id` had no index. It's the
   most common query in a support tool.
2. **Column order in a composite index matters.** Put equality filters
   (`application_id = 2`) first and range filters (`created_at >= ...`) last.
3. **Partial indexes stay small.** Only ~700 of 50,000 tickets are unresolved,
   so P4's index covers just those, already sorted the way the backlog
   screen needs. PostgreSQL reads the first 50 entries and stops.
4. **Don't wrap indexed columns in functions.** Filtering on
   `created_at::date = '2026-09-15'` took 2.0 ms, because the index could only
   narrow down to the ~7,100 Payroll rows. Writing the same filter as a range
   (`created_at >= '2026-09-15' AND created_at < '2026-09-16'`) took 0.06 ms
   and read just 153 rows.

At this size every query is already fast. The point is the shape of the
plans: a Seq Scan's cost grows with the table, while an index lookup stays
almost flat. At millions of tickets, the "before" times become seconds.
