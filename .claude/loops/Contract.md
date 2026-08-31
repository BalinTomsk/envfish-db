# Loop Contract - ENVFISH Database

Safety guardrails for database automation loops.

## Stop Conditions (Non-Negotiable)

- **NEVER TOUCH PROD without explicit user approval** — ask first, wait for "yes", verify user knows the risk
- **Stop on test failures** — don't auto-fix; let user decide
- **Stop on permission denial** — never retry or work around
- **Stop on schema validation errors** — verify before proceeding
- **Stop on migration errors** — rollback immediately, report to user
- **Max 3 retries per operation** — no infinite retry loops
- **Always backup before DDL** — snapshot prod before any ALTER TABLE

## Tone & Scope

- **Terse output** — no trailing summaries
- **Verify before execute** — preview SQL before running
- **Test-first workflow** — write FAILING test, then fix, then PASSING test
- **Document schema assumptions** — comment why a change is needed
- **No force-commit** — clean git history only

## Secrets & Safety

- **Never commit real connection strings** — use `.env.local` (gitignored)
- **No hardcoded credentials in scripts** — use environment variables
- **Read-only queries only** — no INSERT/UPDATE/DELETE in exploration
- **Always use transactions** — wrap DDL/DML in BEGIN/ROLLBACK guards

## Scope for This Project

- **SQL scripts** — procs, functions, views, triggers
- **Schema changes** — ALTER TABLE, ADD COLUMN, etc. (TEST FIRST)
- **Seed data** — INSERT statements for test/reference data
- **Migrations** — scriptNN_*.sql files (NOT generated ffi2.sql)
- **Unit tests** — mssql/UNIT_TESTS/ (autorun.bat)

## Database Environments

- **Local**: MSSQL 2022, sa user, password = FTP password, envfish (stub data only)
- **Prod**: Live FishFind database (NEVER without approval)

## Before Making ANY Database Change

1. **Read envfish-db CLAUDE.md first** — it has the authoritative workflow
2. **Write a FAILING unit test** — prove the bug exists
3. **Test locally** — fix on local envfish DB, run autorun.bat
4. **Verify schema** — check live prod schema (don't assume main is deployed)
5. **Get approval** — show user the change, wait for YES before touching prod
6. **Backup prod** — snapshot before applying
7. **Apply + verify** — run script, check data integrity
8. **Commit** — document why the change was needed

## Critical Gotchas

- **QUOTED_IDENTIFIER** — baked into proc at CREATE time, not call time
- **No nested SqlDataReader** — materialize rows first; no MARS on shared connection
- **DECLARE + SELECT gotchas** — inline `DECLARE @v = (SELECT...)` is rejected
- **Schemabound deps** — regulations.fish_id is referenced by triggers; can't drop

## When to Loop

**Loop for:** iterating test failures, schema exploration, bulk data operations
**Single-shot for:** one-time DDL, schema design, major refactors
