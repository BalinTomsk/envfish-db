# Generate a random throwaway database name for a mysql/UNIT_TESTS run.
#
# Unlike the mssql/UNIT_TESTS variant, mysql/ffi2.sql never embeds a database name -
# mysql/script0.sql does not CREATE DATABASE / USE (shared MySQL hosting typically has no
# CREATE DATABASE privilege, so the live schema is selected via the connection's database
# argument instead - see script0.sql's header comment). So there is no template text inside
# ffi2.sql to find-and-replace; this just picks a name and hands it to autorun.bat via
# dbname.ini, which then CREATEs that database directly before applying ffi2.sql to it.
import uuid

newdbdb = str(uuid.uuid4())[:8]
print(newdbdb)

with open('dbname.ini', 'w') as inifile:
    inifile.write('dbname=' + newdbdb)
