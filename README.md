# Library Management System (LMS) — MySQL 8

A university DBMS demonstration project: a complete Library Management System database built entirely in MySQL.

## Files

| File | Description |
|---|---|
| `lms_schema.sql` | Full schema: 14 tables, constraints, indexes, triggers, stored procedures, views, sample data and demo queries |
| `LMS_Schema_Design.pdf` | Design document: rationale and motive behind every table, relationships, data types and trade-offs |

## Quick start

```bash
mysql -u root -p < lms_schema.sql
```

This creates the `lms` database with sample data. Then run the demo queries listed in section 9 of the SQL file, for example:

```sql
USE lms;
SELECT * FROM v_book_availability;
SELECT * FROM v_overdue_loans;
CALL sp_return_book(1, CURRENT_DATE);   -- creates a late fine
SELECT * FROM fine;
```

## What it demonstrates

- 3NF design: master, catalogue, people and transaction layers
- 1:N, M:N (junction table), 1:1 and self-referencing relationships
- `PRIMARY KEY`, `FOREIGN KEY` (`CASCADE` / `SET NULL` / `RESTRICT`), `UNIQUE`, `CHECK`, `ENUM`
- Indexes and `FULLTEXT` search
- Triggers (audit log, issue validation)
- Stored procedures with transactions, `ROLLBACK`, `SIGNAL` and row locking (`FOR UPDATE`)
- Views, joins, `GROUP BY`, `GROUP_CONCAT`, window functions

Tested on MySQL 8.0.
