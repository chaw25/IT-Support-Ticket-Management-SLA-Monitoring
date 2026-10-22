# Entity-Relationship Diagram

GitHub renders the diagram below automatically.
`||--o{` reads as "one ... to zero-or-many".

```mermaid
erDiagram
    DEPARTMENTS  ||--o{ EMPLOYEES      : "employs"
    DEPARTMENTS  ||--o{ APPLICATIONS   : "owns"
    EMPLOYEES    ||--o{ TICKETS        : "reports"
    APPLICATIONS ||--o{ TICKETS        : "affected by"
    CATEGORIES   ||--o{ TICKETS        : "classifies"
    CATEGORIES   ||--o{ ERROR_CODES    : "groups"
    ERROR_CODES  |o--o{ TICKETS        : "logged on"
    PRIORITIES   ||--o{ TICKETS        : "sets SLA for"
    TECHNICIANS  |o--o{ TICKETS        : "assigned"
    TICKETS      ||--o{ TICKET_UPDATES : "has history"
    TECHNICIANS  |o--o{ TICKET_UPDATES : "writes"

    DEPARTMENTS {
        smallint department_id PK
        varchar  department_name UK
    }
    EMPLOYEES {
        int      employee_id PK
        varchar  first_name
        varchar  last_name
        varchar  email UK
        smallint department_id FK
    }
    TECHNICIANS {
        smallint technician_id PK
        varchar  first_name
        varchar  last_name
        varchar  email UK
        char     support_level "L1, L2, L3"
        boolean  is_active
    }
    APPLICATIONS {
        smallint application_id PK
        varchar  application_name UK
        smallint owner_department FK
        varchar  criticality "High, Medium, Low"
    }
    CATEGORIES {
        smallint category_id PK
        varchar  category_name UK
    }
    PRIORITIES {
        smallint priority_id PK
        varchar  priority_name UK
        numeric  response_sla_hours
        numeric  resolution_sla_hours
    }
    ERROR_CODES {
        varchar  error_code PK
        smallint category_id FK
        varchar  description
    }
    TICKETS {
        int       ticket_id PK
        varchar   title
        text      description
        int       reporter_id FK
        smallint  application_id FK
        smallint  category_id FK
        varchar   error_code FK "nullable"
        smallint  priority_id FK
        smallint  technician_id FK "nullable = unassigned"
        varchar   status
        timestamp created_at
        timestamp first_response_at
        timestamp resolved_at
        timestamp closed_at
    }
    TICKET_UPDATES {
        bigint    update_id PK
        int       ticket_id FK
        smallint  technician_id FK
        varchar   update_type
        text      note
        timestamp updated_at
    }
```

## Design decisions

- **3rd normal form.** Names of departments, applications, categories and
  priorities are stored once and referenced by ID, so renaming one is a
  single-row update.
- **SLA targets live on `priorities`**, not on each ticket. Changing the
  policy for "High" changes it everywhere.
- **Employees and technicians are separate tables.** They play different
  roles (reporting vs. resolving) and have different attributes.
- **`ticket_updates` is an append-only audit trail**, so an investigation can
  rebuild exactly what happened to a ticket and when.
- **CHECK constraints enforce business rules** in the database itself:
  a ticket cannot be resolved before it was created, and a "Closed" ticket
  must have a `closed_at` time.
