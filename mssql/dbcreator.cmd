rem -b makes sqlcmd stop on the first error and return a non-zero exit code,
rem so a failed build is visible to the caller instead of silently "succeeding".
rem -f 65001 is REQUIRED: the scriptNN_*.sql sources are UTF-8 with no BOM, and without it sqlcmd
rem reads them in the ANSI code page, so every non-ASCII literal and comment lands in the database
rem corrupted (N'etang' with an accent becomes N'A-tilde-c-tang'). Covered by
rem UNIT_TESTS/unit_test@ScriptEncoding.sql.
sqlcmd -b -f 65001 -S localhost -E -d master -i %1
