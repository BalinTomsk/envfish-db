# Build cleaned.txt from result.txt and report a PASS/FAIL summary.
#
# Deliberately does NOT do what mssql/UNIT_TESTS/averify.py does (md5-diff against a stored
# crcstate and email the result via smtppart.py on change): this mysql/ harness is new and
# local-only, and mssql/UNIT_TESTS/config.ini's [mail] section holds live SMTP2GO credentials
# that CLAUDE.md says never to copy into another file. So there is no [mail] section here and
# no email is ever sent - exit code + stdout summary is the whole contract.
import sys


def main() -> int:
    result_path = "result.txt"
    cleaned_path = "cleaned.txt"

    main_text = open(result_path, "r", encoding="utf-8", errors="ignore").read()

    out = open(cleaned_path, "w", encoding="utf-8", errors="ignore")
    for line in main_text.splitlines(keepends=True):
        if (
            "PASSED" not in line
            and "Warning: Null value" not in line
            and "----" not in line
            and line.strip() != ""
        ):
            out.write(line.lstrip())
    out.close()

    cleaned = open(cleaned_path, "r", encoding="utf-8", errors="ignore").read()
    pass_count = cleaned.count("PASS:")
    fail_count = cleaned.count("FAIL:")

    print(f"averify.py: {pass_count} PASS, {fail_count} FAIL - see cleaned.txt")
    if fail_count > 0:
        print("averify.py: FAILURES FOUND")
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
