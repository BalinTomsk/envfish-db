rem Applies a MySQL script with the `mysql` CLI. Usage: dbcreator.cmd <script.sql> <host> <user> <database>
rem -p (no value after it) makes mysql prompt for the password interactively instead of it being
rem hardcoded here or passed on the command line, per CLAUDE.md's "no real credentials in this repo" rule.
rem --default-character-set=utf8mb4 is the mysql-CLI equivalent of sqlcmd's -f 65001: the
rem scriptNN_*.sql sources are UTF-8, and without pinning the client character set, non-ASCII
rem literals/comments can be misread using the connection's default charset and land corrupted.
rem mysql already stops and returns a non-zero exit code on the first SQL error - sqlcmd's -b
rem flag has no equivalent needed here, that's just mysql's default behavior.
mysql --default-character-set=utf8mb4 -h %2 -u %3 -p %4 < %1
