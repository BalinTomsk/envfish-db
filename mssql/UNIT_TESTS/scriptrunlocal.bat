@echo  %2 >> result.txt

for /f "tokens=1,2 delims==" %%a in (config.ini) do (
if %%a==server     set server=%%b
if %%a==sqlcmd     set sqlcmd=%%b
) 

rem -f 65001 keeps the UTF-8 test files readable (and the output UTF-8 for averify.py). Without it
rem sqlcmd falls back to the ANSI code page and mangles every non-ASCII literal - see dbcreator.cmd
rem and UNIT_TESTS/unit_test@ScriptEncoding.sql.
call %sqlcmd% -f 65001 -S %server% -E -d %1 -i %2 >> result.txt
