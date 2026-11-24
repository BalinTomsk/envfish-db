# News MySQL database — manual backup and restore

The news data (owned by the `csnews-env` service) lives in a MySQL database on Winhost.
This runbook covers taking a backup by hand, scheduling it, checking it and restoring it.

| Item       | Value                                  |
|------------|----------------------------------------|
| Server     | `my06.winhost.com`, port `3306`        |
| Engine     | MySQL 5                                |
| Database   | `mysql_111487_envfish`                 |
| User       | `portos`                               |
| Password   | not written here — ask the DB owner / Winhost control panel |

> Never put the password in this file, in a script, on a command line or in git.

---

## 1. One-time prerequisites

1. **MySQL client tools.** `mysqldump.exe` and `mysql.exe` 8.0 are needed. On the dev machine they come
   with MySQL Workbench:
   `C:\Program Files\MySQL\MySQL Workbench 8.0 CE\mysqldump.exe`.
   Check:
   ```powershell
   & 'C:\Program Files\MySQL\MySQL Workbench 8.0 CE\mysqldump.exe' --version
   ```
2. **Remote access on Winhost.** Winhost blocks remote MySQL connections unless they are allowed:
   Winhost Control Panel → *Sites* → *MySQL* → database `mysql_111487_envfish` → *Remote access* →
   add the public IP of the machine that runs the backup. (Find it with `curl.exe -s https://api.ipify.org`.)
3. **Connection test** (asks for the password):
   ```powershell
   & 'C:\Program Files\MySQL\MySQL Workbench 8.0 CE\mysql.exe' -h my06.winhost.com -P 3306 -u portos -p -e "SELECT VERSION(); SHOW TABLES;" mysql_111487_envfish
   ```
   If it hangs or says `Can't connect`, step 2 is not done (or the IP changed).

---

## 2. Take a backup — with the script (recommended)

Script: `C:\envoinx\fishfind\prod_backup\backup-news-mysql.ps1`

```powershell
& 'C:\envoinx\fishfind\prod_backup\backup-news-mysql.ps1'
```

1. Type the password at the prompt (input is hidden).
2. Wait for `OK  ...\news_mysql\mysql_111487_envfish_<yyyyMMdd_HHmmss>.zip  (N MB)`.

What the script does:

- writes the password to a temp option file readable only by the current user, passes it with
  `--defaults-extra-file`, deletes it afterwards (password never appears in the process list or history);
- dumps with `--single-transaction` (consistent snapshot, no table locks, site stays up), `--triggers`,
  `--hex-blob`, `utf8mb4`;
- adds `--column-statistics=0`, `--set-gtid-purged=OFF`, `--no-tablespaces` so an 8.0 client works
  against a MySQL 5 shared-hosting server without extra privileges;
- fails if the dump does not end with `-- Dump completed` (truncated dump);
- zips the `.sql`, deletes the raw file, keeps the newest 30 zips.

Options:

| Option            | Default                         | Meaning |
|-------------------|---------------------------------|---------|
| `-OutDir <path>`  | `prod_backup\news_mysql`        | where zips are written |
| `-KeepLast <n>`   | `30`                            | older zips are deleted |
| `-Routines`       | off                             | also dump stored procedures/functions (may be refused on shared hosting) |
| `$env:NEWS_MYSQL_PWD` | unset                       | if set, used instead of the prompt (for scheduled runs) |

---

## 3. Take a backup — fully manual (no script)

Use this if the script is unavailable.

```powershell
$dump = 'C:\Program Files\MySQL\MySQL Workbench 8.0 CE\mysqldump.exe'
$out  = "C:\envoinx\fishfind\prod_backup\news_mysql\mysql_111487_envfish_$(Get-Date -Format yyyyMMdd_HHmmss).sql"
New-Item -ItemType Directory -Force (Split-Path $out) | Out-Null
& $dump -h my06.winhost.com -P 3306 -u portos -p --single-transaction --quick --triggers --no-tablespaces --column-statistics=0 --set-gtid-purged=OFF --default-character-set=utf8mb4 --hex-blob --result-file=$out mysql_111487_envfish
```

1. Type the password when `Enter password:` appears (`-p` with no value = prompt).
2. Check the last line of the file (see section 5).
3. Compress it:
   ```powershell
   Compress-Archive -Path $out -DestinationPath ([IO.Path]::ChangeExtension($out, '.zip')); Remove-Item $out
   ```

### Alternative: MySQL Workbench GUI

1. Workbench → *Database* → *Manage Connections* → *New*: host `my06.winhost.com`, port `3306`,
   user `portos`; *Store in Vault* only on a personal, encrypted machine.
2. Connect → *Server* → *Data Export*.
3. Tick schema `mysql_111487_envfish`, all tables; *Dump Structure and Data*.
4. *Export to Self-Contained File* → choose `prod_backup\news_mysql\...sql`;
   tick *Create Dump in a Single Transaction*, *Include Create Schema* off.
5. *Advanced Options*: `column-statistics` = off (otherwise the 8.0 client fails on MySQL 5).
6. *Start Export*.

---

## 4. Schedule a daily backup (Windows Task Scheduler)

The password must come from somewhere non-interactive. Use a **user-level environment variable on that
machine only** (never in the task's command line):

1. Set it once, as the account that will run the task:
   ```powershell
   [Environment]::SetEnvironmentVariable('NEWS_MYSQL_PWD', (Read-Host 'news MySQL password'), 'User')
   ```
2. Create the task (runs daily at 03:30 as the current user):
   ```powershell
   $a = New-ScheduledTaskAction -Execute 'pwsh.exe' -Argument '-NoProfile -File "C:\envoinx\fishfind\prod_backup\backup-news-mysql.ps1"'
   $t = New-ScheduledTaskTrigger -Daily -At 3:30am
   Register-ScheduledTask -TaskName 'FishFind news MySQL backup' -Action $a -Trigger $t -Description 'Daily dump of mysql_111487_envfish'
   ```
3. Test it now: `Start-ScheduledTask -TaskName 'FishFind news MySQL backup'`, then check that a new zip appeared
   and `(Get-ScheduledTaskInfo 'FishFind news MySQL backup').LastTaskResult` is `0`.
4. The machine must be on and its public IP must stay in Winhost's remote-access list.
5. Copy zips off the machine periodically (another disk / cloud storage) — one copy on one disk is not a backup.

To remove: `Unregister-ScheduledTask -TaskName 'FishFind news MySQL backup' -Confirm:$false` and
`[Environment]::SetEnvironmentVariable('NEWS_MYSQL_PWD', $null, 'User')`.

---

## 5. Verify a backup

1. Size is plausible (compare with previous zips; a sudden drop means missing tables).
2. The `.sql` ends with the completion marker:
   ```powershell
   Get-Content <file>.sql -Tail 1     # expect: -- Dump completed on 2026-...
   ```
3. Table list matches the server:
   ```powershell
   Select-String -Path <file>.sql -Pattern '^CREATE TABLE' | ForEach-Object { $_.Line }
   ```
4. Best check: restore it into a scratch database (section 6, "test restore") and count rows of the main
   news tables against production.

---

## 6. Restore

### Test restore (local, safe — do this first)

```powershell
Expand-Archive <file>.zip -DestinationPath $env:TEMP\newsrestore
& 'C:\Program Files\MySQL\MySQL Workbench 8.0 CE\mysql.exe' -h localhost -u root -p -e "CREATE DATABASE news_restore_test CHARACTER SET utf8mb4"
Get-Content $env:TEMP\newsrestore\<file>.sql -Raw | & 'C:\Program Files\MySQL\MySQL Workbench 8.0 CE\mysql.exe' -h localhost -u root -p news_restore_test
```

Then compare row counts, and drop `news_restore_test` when done.

### Production restore (destructive — overwrites live news data)

1. Agree a time; the news pages and `csnews-env` writes will be inconsistent during the restore.
2. **Take a fresh backup first** (section 2) so the restore itself can be undone.
3. Optionally stop `csnews-env` so nothing writes during the restore.
4. Unzip and load:
   ```powershell
   Expand-Archive <file>.zip -DestinationPath $env:TEMP\newsrestore
   cmd /c "`"C:\Program Files\MySQL\MySQL Workbench 8.0 CE\mysql.exe`" -h my06.winhost.com -P 3306 -u portos -p --default-character-set=utf8mb4 mysql_111487_envfish < `"$env:TEMP\newsrestore\<file>.sql`""
   ```
   (the dump contains `DROP TABLE IF EXISTS` + `CREATE TABLE` for every table, so tables are replaced.)
5. Start `csnews-env` again, open the news list on fishfind.info and the `/api/v1/csnews/*` endpoints to confirm.
6. Delete the unzipped `.sql` from `%TEMP%`.

---

## 7. Troubleshooting

| Error | Cause / fix |
|-------|-------------|
| `Can't connect to MySQL server on 'my06.winhost.com'` | IP not in Winhost remote-access list (section 1.2), or firewall blocks outbound 3306 |
| `Access denied for user 'portos'` | wrong password, or password was rotated — get the current one |
| `Unknown table 'COLUMN_STATISTICS' in information_schema` | 8.0 client vs MySQL 5: add `--column-statistics=0` |
| `Access denied; you need (at least one of) the PROCESS privilege(s)` | add `--no-tablespaces` |
| `... when using LOCK TABLES` / `SHOW CREATE PROCEDURE` denied | drop `--routines` (or `-Routines` in the script) |
| Dump ends without `-- Dump completed` | connection dropped mid-dump — rerun; keep the previous zip |
| Garbled non-Latin text after restore | restore with `--default-character-set=utf8mb4` (both dump and restore) |

---

## 8. Password hygiene

- The password is stored only in the Winhost control panel, the `csnews-env` deployment config,
  and (if a schedule is used) the `NEWS_MYSQL_PWD` user variable on the backup machine.
- After rotating it in Winhost, update `csnews-env`'s config **and** the `NEWS_MYSQL_PWD` variable,
  then run one manual backup to confirm.
- Backup zips contain all news data in plain text — keep them out of git and out of public folders.
