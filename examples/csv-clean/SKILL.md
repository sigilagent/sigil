---
name: clean-csv
description: Use when a messy CSV file needs its headers normalized to clean snake_case names and blank rows removed, saved to a verified output file.
---

# Clean a messy CSV

Normalize a messy CSV export into a clean one: readable snake_case headers, no
blank rows, written to disk and verified. A realistic skill — one genuine
judgment call, ordered mechanical steps, a required output file, and a
verification gate.

## Steps

1. Read the input CSV file named in the task.
2. Rename every column header to a clean, readable `snake_case` identifier.
   Real exports carry units, punctuation, vendor prefixes and parenthetical
   qualifiers that a literal character substitution mangles — decide what each
   column actually *means* and name it that. For example:

   | messy header | good name | a literal transform gives |
   |---|---|---|
   | `Cust. E-mail (primary)` | `customer_email` | `cust__e_mail__primary_` |
   | `Total Spend ($)` | `total_spend` | `total_spend____` |
   | `Signup Date (UTC)` | `signup_date` | `signup_date__utc_` |
   | `First  Name` | `first_name` | `first__name` |

3. Drop any row where every field is empty.
4. Write the cleaned rows to `cleaned.csv` in the working directory, header row
   first.
5. Verify the result before reporting success.

## Rules

- Every output header MUST be lowercase `snake_case`: letters, digits and single
  underscores only. No leading, trailing or doubled underscores.
- You MUST produce exactly one name per input column, in the original order.
  Do not drop, add, merge or reorder columns.
- Header names MUST be unique.
- The cleaned data MUST be written to `cleaned.csv` — do not just print it.

## Verification

- Re-read `cleaned.csv` and confirm it parses as valid CSV with a header row.
- Confirm every header matches `^[a-z][a-z0-9]*(_[a-z0-9]+)*$`.
- Confirm the output column count equals the input column count.
- Confirm the output row count equals the input row count minus the fully-empty
  rows that were removed.
- If verification fails, fix the output and check again before reporting done.
