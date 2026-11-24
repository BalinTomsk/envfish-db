@echo off
rem build.cmd: builds the envdata schema into an EXISTING database. Usage: build.cmd <host> <user> <database>
rem The mysql CLI prompts for the password (never pass it on the command line). Same shape as ../build.cmd.
call generate_db_script_ffi2.cmd
if errorlevel 1 exit /b 1
mysql --default-character-set=utf8mb4 -h %1 -u %2 -p %3 < ffi2.sql
if errorlevel 1 (
    echo ERROR: envdata build FAILED - ffi2.sql kept so the failing statement can be located.
    exit /b 1
)
if exist ffi2.sql del ffi2.sql > nul
