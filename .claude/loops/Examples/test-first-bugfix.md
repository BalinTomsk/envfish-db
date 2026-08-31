# Loop: Test-First Bug Fix

Write failing test, fix bug, verify with passing test.

## Prompt

```
/loop
Test-first bug fix workflow for database issues.

1. Ask user: "What's the bug?" — describe the issue
2. Read CLAUDE.md in this project (workflow reference)
3. Create scriptNN_failing_test.sql:
   a. USE envfish (local test DB, stub data)
   b. Write a test that PROVES the bug (fails before fix)
   c. Run: sqlcmd -S (local) -i scriptNN_failing_test.sql
   d. Verify it FAILS (shows expected vs. actual)
4. Show user the failing test output — ask "Correct?" — STOP if NO
5. Create scriptNN_fix.sql:
   a. ALTER PROCEDURE / ALTER FUNCTION / INSERT etc.
   b. Include comment explaining WHY
6. Run fix on local DB:
   a. sqlcmd -i scriptNN_fix.sql
   b. Check for errors
7. Run test again — should now PASS
8. Show before/after test results
9. Ask user: "Ready to deploy to prod?" — STOP if NO
10. On YES: 
    a. Backup prod
    b. Run scriptNN_fix.sql on prod
    c. Run test on prod
    d. Commit scriptNN_*.sql to git
11. Stop

Max iterations: 3
```

## When to Use

- Database schema bugs (bad trigger logic, constraint issues)
- Data integrity problems (orphaned rows, missing updates)
- Stored proc bugs (wrong calculation, missing columns)

## Notes

- Always test locally FIRST (envfish DB)
- Never skip the failing test — proves bug exists
- Backup prod before applying fix
- Commit SQL scripts, not generated migration files
- Run `mssql/UNIT_TESTS/autorun.bat` after changes

## Critical

- Read envfish-db CLAUDE.md for full workflow
- No prod changes without user approval
- Schema must match prod before applying
