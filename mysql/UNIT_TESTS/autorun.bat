@echo off
setlocal EnableExtensions EnableDelayedExpansion

REM ------------------------------
REM Save current folder
REM ------------------------------
set "back=%CD%"

echo Reading config.ini

REM ------------------------------
REM Initialize variables
REM ------------------------------
set "server="
set "port="
set "dbuser="
set "mysqlcmd="
set "script="
set "dbmaker="

REM ------------------------------
REM Robust INI parser: supports "key=value", ignores [sections], ; and # comments
REM ------------------------------
for /f "usebackq delims=" %%L in ("config.ini") do (
    set "LINE=%%L"

    if not "!LINE!"=="" (
        if not "!LINE:~0,1!"==";" (
            if not "!LINE:~0,1!"=="#" (
                if not "!LINE:~0,1!"=="[" (
                    for /f "tokens=1,* delims==" %%A in ("!LINE!") do (
                        set "K=%%A"
                        set "V=%%B"

                        if "!K:~0,1!"=="﻿" set "K=!K:~1!"

                        for /f "tokens=* delims= " %%X in ("!K!") do set "K=%%X"
                        for /f "tokens=* delims= " %%Y in ("!V!") do set "V=%%Y"

                        set "K=!K: =!"

                        if /I "!K!"=="server"   set "server=!V!"
                        if /I "!K!"=="port"     set "port=!V!"
                        if /I "!K!"=="user"     set "dbuser=!V!"
                        if /I "!K!"=="mysqlcmd" set "mysqlcmd=!V!"
                        if /I "!K!"=="script"   set "script=!V!"
                        if /I "!K!"=="dbmaker"  set "dbmaker=!V!"
                    )
                )
            )
        )
    )
)

REM ------------------------------
REM Defaults
REM ------------------------------
if not defined server set "server=127.0.0.1"
if not defined port set "port=3306"
if not defined dbuser set "dbuser=root"
if not defined mysqlcmd set "mysqlcmd=mysql.exe"

echo server=[%server%]
echo port=[%port%]
echo user=[%dbuser%]
echo mysqlcmd=[%mysqlcmd%]
echo script=[%script%]
echo dbmaker=[%dbmaker%]

REM ------------------------------
REM Cleanup in current folder
REM ------------------------------
if defined script (
  if exist "%script%" del /q "%script%" >nul 2>&1
)
if exist "dbname.ini" del /q "dbname.ini" >nul 2>&1
if exist "result.txt" del /q "result.txt" >nul 2>&1
if exist "final.txt"  del /q "final.txt"  >nul 2>&1

cd ..
echo Going upper folder

REM ------------------------------
REM Generate DB script (concatenates mysql\scriptNN_*.sql into ffi2.sql)
REM ------------------------------
if not defined dbmaker (
  echo ERROR: config.ini does not define "dbmaker="
  cd /d "%back%"
  exit /b 1
)

call "%dbmaker%"
if errorlevel 1 (
  echo ERROR: %dbmaker% failed
  cd /d "%back%"
  exit /b 1
)

REM ------------------------------
REM Copy generated script back into unit tests folder
REM ------------------------------
if not defined script (
  echo ERROR: config.ini does not define "script="
  cd /d "%back%"
  exit /b 1
)

if exist "%script%" (
  copy /Y /B "%script%" "%back%\%script%" >nul
  del /q "%script%" >nul 2>&1
) else (
  echo ERROR: expected script "%script%" not found after %dbmaker%
  cd /d "%back%"
  exit /b 1
)

cd /d "%back%"

REM ------------------------------
REM Pick a random throwaway database name
REM ------------------------------
python replacedb.py
if errorlevel 1 (
  echo ERROR: replacedb.py failed
  exit /b 1
)

set "dbname="
for /f "usebackq eol=; tokens=1,* delims==" %%A in ("dbname.ini") do (
  set "K=%%A"
  set "V=%%B"
  for /f "tokens=* delims= " %%X in ("!K!") do set "K=%%X"
  for /f "tokens=* delims= " %%Y in ("!V!") do set "V=%%Y"
  if /I "!K!"=="dbname" set "dbname=!V!"
)

if not defined dbname (
  echo ERROR: dbname not found in dbname.ini
  exit /b 1
)

echo DBNAME=%dbname%

REM ------------------------------
REM Create the throwaway database and apply the schema
REM ------------------------------
echo Creating temp database %dbname%
"%mysqlcmd%" -h %server% -P %port% -u %dbuser% -e "CREATE DATABASE `%dbname%`;"
if errorlevel 1 (
  echo ERROR: failed to create database %dbname%
  cd /d "%back%"
  exit /b 1
)

echo Applying %script% to %dbname%
"%mysqlcmd%" --default-character-set=utf8mb4 -h %server% -P %port% -u %dbuser% %dbname% < "%script%"
if errorlevel 1 (
  echo ERROR: failed to apply %script% to %dbname% - dropping it and aborting
  "%mysqlcmd%" -h %server% -P %port% -u %dbuser% -e "DROP DATABASE IF EXISTS `%dbname%`;"
  cd /d "%back%"
  exit /b 1
)

if exist "%script%" del /q "%script%" >nul 2>&1

REM ------------------------------
REM Run unit tests
REM ------------------------------
call "autorunlocal.bat" "%dbname%"
if errorlevel 1 (
  echo ERROR: autorunlocal.bat failed
  REM continue to drop DB anyway
)

REM ------------------------------
REM Drop the throwaway database
REM ------------------------------
echo Dropping temp database %dbname%
"%mysqlcmd%" -h %server% -P %port% -u %dbuser% -e "DROP DATABASE IF EXISTS `%dbname%`;"

REM ------------------------------
REM Final cleanup
REM ------------------------------
if exist "dbname.ini" del /q "dbname.ini" >nul 2>&1
if exist "final.txt"  del /q "final.txt"  >nul 2>&1

endlocal
exit /b 0
