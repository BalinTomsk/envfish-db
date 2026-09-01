rem Concatenates the mysql/ scriptNN_*.sql sources into ffi2.sql, in the same append-only
rem ordering convention as mssql/generate_db_script_ffi2.cmd - add new scriptNN files here, in
rem order, as they're introduced.
rem /B forces binary-mode concatenation: `copy`'s default ASCII mode treats a stray 0x1A byte as
rem end-of-file, which would silently truncate a UTF-8 source file at that point.
copy /B /Y "script0.sql"+"script01_createTable.sql"+"script02_Proc.sql" "ffi2.sql"
