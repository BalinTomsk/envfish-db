# Build cleaned.txt from result.txt and report a PASS/FAIL summary.
#
# THE OUTPUT CONTRACT: every test prints exactly ONE line, `TEST n PASS: <what held>` or
# `TEST n FAIL: <what broke>`, and that line is shorter than 80 characters. cleaned.txt therefore holds
# only the `unit_test@<file>.sql` header lines and those TEST lines, nothing else.
#
# WHY THIS FILTERS: several tests call a stored procedure that ends in a SELECT (sp_news_admin_publish,
# sp_news_doc_insert, ...), and MySQL cannot suppress or capture a called procedure's result set from
# inside a test -- the mysql client prints it. Those rows (a uuid, `inserted`, `1  1`) are noise, not
# results, so they are dropped here. Anything that is NOT noise must never be dropped, so:
#   * a line beginning `ERROR` (a mysql client/server error) is KEPT and counted as a failure;
#   * a TEST line of 80 or more characters is a FAILURE of the contract, reported by name;
#   * a TEST line that says neither PASS nor FAIL is a failure too.
# result.txt keeps everything, for anyone who wants the raw output.
#
# Deliberately does NOT do what mssql/UNIT_TESTS/averify.py does (md5-diff against a stored
# crcstate and email the result via smtppart.py on change): this mysql/ harness is local-only, and
# mssql/UNIT_TESTS/config.ini's [mail] section holds live SMTP credentials that CLAUDE.md says never to
# copy into another file. So there is no [mail] section here and no email is ever sent - exit code +
# stdout summary is the whole contract.
import re
import sys

MAX_LINE = 79  # "less than 80 symbols"

HEADER = re.compile(r"^unit_test@[\w.@-]+\.sql\s*$")
TEST_LINE = re.compile(r"^TEST \d+ ")
RESULT_LINE = re.compile(r"^TEST \d+ (PASS|FAIL): \S")


def main() -> int:
    result_path = "result.txt"
    cleaned_path = "cleaned.txt"

    main_text = open(result_path, "r", encoding="utf-8", errors="ignore").read()

    kept = []
    contract_violations = []
    error_lines = 0
    for raw in main_text.splitlines():
        line = raw.strip().strip('"')
        if not line:
            continue
        if HEADER.match(line):
            kept.append(line)
        elif TEST_LINE.match(line):
            kept.append(line)
            if not RESULT_LINE.match(line):
                contract_violations.append(f"not PASS/FAIL: {line[:60]}")
            elif len(line) > MAX_LINE:
                contract_violations.append(f"{len(line)} chars: {line[:60]}...")
        elif line.startswith("ERROR"):
            kept.append(line)
            error_lines += 1
        # anything else is a called procedure's result row: dropped, see the header comment

    with open(cleaned_path, "w", encoding="utf-8", errors="ignore") as out:
        for line in kept:
            out.write(line + "\n")

    pass_count = sum(1 for l in kept if RESULT_LINE.match(l) and " PASS: " in l)
    fail_count = sum(1 for l in kept if RESULT_LINE.match(l) and " FAIL: " in l)

    print(f"averify.py: {pass_count} PASS, {fail_count} FAIL - see cleaned.txt")
    for v in contract_violations:
        print(f"averify.py: OUTPUT CONTRACT VIOLATED ({v})")
    if error_lines:
        print(f"averify.py: {error_lines} SQL ERROR line(s) - see cleaned.txt")

    if fail_count > 0 or contract_violations or error_lines:
        print("averify.py: FAILURES FOUND")
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
