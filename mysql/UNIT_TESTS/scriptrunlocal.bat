rem ----- pass database name (%1) and sql filename (%2) as parameters ----
@echo  %2 >> result.txt

for /f "tokens=1,2 delims==" %%a in (config.ini) do (
if %%a==server     set server=%%b
if %%a==port       set port=%%b
if %%a==user       set dbuser=%%b
if %%a==mysqlcmd   set mysqlcmd=%%b
)

rem -N/--skip-column-names drops the SELECT header row so cleaned.txt stays one line per
rem assertion (matches the mssql PRINT-based convention - see unit_test@NewsMySQL.sql, which
rem emits each PASS/FAIL as `SELECT '...' AS message;`).
rem --default-character-set=utf8mb4 is the mysql-CLI equivalent of sqlcmd's -f 65001: keeps
rem non-ASCII test literals readable (see mysql/dbcreator.cmd for the same rationale).
"%mysqlcmd%" --default-character-set=utf8mb4 -N -h %server% -P %port% -u %dbuser% -D %1 < %2 >> result.txt 2>&1
