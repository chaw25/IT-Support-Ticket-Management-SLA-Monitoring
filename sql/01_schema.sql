-- =====================================================================
-- 01_schema.sql
-- IT Support Ticket Management & SLA Monitoring - database schema
--
-- Everything lives in its own schema "support", so re-running this file
-- only drops this project's objects, never anything else in the database.
-- =====================================================================

DROP SCHEMA IF EXISTS support CASCADE;
CREATE SCHEMA support;
SET search_path TO support;

-- ---------------------------------------------------------------------
-- Lookup / reference tables
-- ---------------------------------------------------------------------

CREATE TABLE departments (
    department_id   SMALLINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    department_name VARCHAR(60) NOT NULL UNIQUE
);

-- Employees are the people who REPORT issues.
CREATE TABLE employees (
    employee_id   INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    first_name    VARCHAR(50)  NOT NULL,
    last_name     VARCHAR(50)  NOT NULL,
    email         VARCHAR(120) NOT NULL UNIQUE,
    department_id SMALLINT     NOT NULL REFERENCES departments (department_id)
);

-- Technicians are the IT support staff who WORK on tickets.
CREATE TABLE technicians (
    technician_id SMALLINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    first_name    VARCHAR(50)  NOT NULL,
    last_name     VARCHAR(50)  NOT NULL,
    email         VARCHAR(120) NOT NULL UNIQUE,
    support_level CHAR(2)      NOT NULL CHECK (support_level IN ('L1', 'L2', 'L3')),
    is_active     BOOLEAN      NOT NULL DEFAULT TRUE
);

-- Business applications supported by the IT team.
CREATE TABLE applications (
    application_id   SMALLINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    application_name VARCHAR(80) NOT NULL UNIQUE,
    owner_department SMALLINT    NOT NULL REFERENCES departments (department_id),
    criticality      VARCHAR(10) NOT NULL CHECK (criticality IN ('High', 'Medium', 'Low'))
);

CREATE TABLE categories (
    category_id   SMALLINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    category_name VARCHAR(60) NOT NULL UNIQUE
);

-- Each priority carries its SLA targets, so the SLA policy is stored once
-- instead of being repeated on every ticket (normalization).
CREATE TABLE priorities (
    priority_id           SMALLINT PRIMARY KEY,           -- 1 = most urgent
    priority_name         VARCHAR(20)  NOT NULL UNIQUE,
    response_sla_hours    NUMERIC(5,2) NOT NULL CHECK (response_sla_hours > 0),
    resolution_sla_hours  NUMERIC(5,2) NOT NULL CHECK (resolution_sla_hours > response_sla_hours)
);

-- Known error codes, each belonging to one category.
CREATE TABLE error_codes (
    error_code  VARCHAR(20)  PRIMARY KEY,
    category_id SMALLINT     NOT NULL REFERENCES categories (category_id),
    description VARCHAR(200) NOT NULL
);

-- ---------------------------------------------------------------------
-- Core tables
-- ---------------------------------------------------------------------

CREATE TABLE tickets (
    ticket_id         INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    title             VARCHAR(150) NOT NULL,
    description       TEXT,
    reporter_id       INT      NOT NULL REFERENCES employees (employee_id),
    application_id    SMALLINT NOT NULL REFERENCES applications (application_id),
    category_id       SMALLINT NOT NULL REFERENCES categories (category_id),
    error_code        VARCHAR(20)        REFERENCES error_codes (error_code),
    priority_id       SMALLINT NOT NULL REFERENCES priorities (priority_id),
    technician_id     SMALLINT           REFERENCES technicians (technician_id),  -- NULL = unassigned
    status            VARCHAR(15) NOT NULL DEFAULT 'Open'
                      CHECK (status IN ('Open', 'In Progress', 'On Hold', 'Resolved', 'Closed')),
    created_at        TIMESTAMP NOT NULL,
    first_response_at TIMESTAMP,
    resolved_at       TIMESTAMP,
    closed_at         TIMESTAMP,

    -- Timestamps must happen in a sensible order.
    CONSTRAINT chk_response_after_create CHECK (first_response_at >= created_at),
    CONSTRAINT chk_resolved_after_create CHECK (resolved_at >= created_at),
    CONSTRAINT chk_closed_after_resolved CHECK (closed_at >= resolved_at),
    -- A Resolved/Closed ticket must have a resolved time; an open one must not.
    CONSTRAINT chk_status_matches_dates CHECK (
        (status IN ('Resolved', 'Closed') AND resolved_at IS NOT NULL)
        OR (status IN ('Open', 'In Progress', 'On Hold') AND resolved_at IS NULL)
    ),
    CONSTRAINT chk_closed_has_closed_at CHECK ((status = 'Closed') = (closed_at IS NOT NULL))
);

-- History of everything that happened to a ticket (audit trail).
CREATE TABLE ticket_updates (
    update_id     BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    ticket_id     INT       NOT NULL REFERENCES tickets (ticket_id) ON DELETE CASCADE,
    technician_id SMALLINT           REFERENCES technicians (technician_id),
    update_type   VARCHAR(20) NOT NULL
                  CHECK (update_type IN ('Assigned', 'Comment', 'Status Change', 'Reassigned', 'Resolved', 'Closed')),
    note          TEXT,
    updated_at    TIMESTAMP NOT NULL
);

-- ---------------------------------------------------------------------
-- Reporting clock
-- ---------------------------------------------------------------------
-- The SLA views compare open tickets against "now". The dataset is fixed,
-- so a fixed reporting time keeps every result reproducible.
-- In a live system you would simply return now()::timestamp here.
CREATE FUNCTION report_time() RETURNS TIMESTAMP
LANGUAGE sql IMMUTABLE AS $$ SELECT TIMESTAMP '2026-10-01 09:00' $$;
