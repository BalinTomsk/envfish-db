@echo off
rem build.cmd is a top-level entry point, so turning echo off here is safe -
rem autorun.bat calls generate_db_script_ffi2.cmd / dbcreator.cmd directly, not this file.

call generate_db_script_ffi2.cmd
if errorlevel 1 (
    echo ERROR: generate_db_script_ffi2.cmd failed - ffi2.sql was not generated
    exit /b 1
)

call dbcreator.cmd ffi2.sql
if errorlevel 1 (
    echo.
    echo ERROR: database build FAILED - see the sqlcmd messages above.
    echo        These scripts build a FRESH database. If [ffi] already exists,
    echo        drop it first, then re-run this script:
    echo            sqlcmd -S localhost -E -Q "DROP DATABASE [ffi]"
    echo        ffi2.sql has been kept so the failing statement can be located.
    exit /b 1
)

if exist ffi2.sql del ffi2.sql > nul
echo %date%
