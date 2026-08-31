-- script0.sql: MySQL preamble.
-- Unlike mssql/script0.sql, this does NOT `CREATE DATABASE` / `USE` a database - the target
-- schema (e.g. the live `mysql_111487_envfish` on Winhost) already exists and is selected via
-- the `mysql -h <host> -u <user> -p <database>` connection argument in dbcreator.cmd, not from
-- inside the script. Shared MySQL hosting typically doesn't grant CREATE DATABASE privileges
-- anyway.
SET NAMES utf8mb4;
