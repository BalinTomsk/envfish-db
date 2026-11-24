rem Concatenates the envdata/ scriptNN_*.sql sources into ffi2.sql (same convention as ../generate_db_script_ffi2.cmd):
rem add new scriptNN files here, in dependency order. /B = binary copy, so a stray 0x1A byte never truncates a file.
copy /B /Y "script0.sql"+"script01_createTable.sql"+"script01_createView.sql"+"script02_Proc.sql" "ffi2.sql"
