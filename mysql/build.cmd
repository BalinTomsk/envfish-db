@echo off
rem build.cmd is a top-level entry point for the mysql/ scripts, mirroring mssql/build.cmd.
rem Usage: build.cmd <host> <user> <database>
rem Unlike mssql/dbcreator.cmd (hardcoded -S localhost -E Windows auth), there is no local MySQL
rem instance here, so host/user/database are passed through to dbcreator.cmd and the password is
rem prompted for interactively by the mysql CLI - never pass it on the command line.

call generate_db_script_ffi2.cmd
if errorlevel 1 (
    echo ERROR: generate_db_script_ffi2.cmd failed - ffi2.sql was not generated
    exit /b 1
)

call dbcreator.cmd ffi2.sql %1 %2 %3
if errorlevel 1 (
    echo.
    echo ERROR: database build FAILED - see the mysql CLI messages above.
    echo        These scripts assume the target database exists and its tables do not yet -
    echo        CREATE TABLE has no IF NOT EXISTS guard. If e.g. `news` already exists there,
    echo        drop it first, then re-run this script:
    echo            mysql -h %1 -u %2 -p %3 -e "DROP TABLE news"
    echo        ffi2.sql has been kept so the failing statement can be located.
    exit /b 1
)

if exist ffi2.sql del ffi2.sql > nul
echo %date%
