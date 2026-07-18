---
name: clean-csv
description: Use when a messy CSV file needs its headers normalized and blank rows removed, saved to a clean output file.
---

# Clean a messy CSV

Normalize a messy CSV into a clean one: tidy headers, no blank rows, written to
disk and verified. A realistic skill — ordered steps, a required output file,
and a verification gate.

## Steps

1. Read the input CSV file named in the task.
2. Normalize every column header to lowercase `snake_case` (spaces and hyphens
   become underscores).
3. Drop any row where every field is empty.
4. Write the cleaned rows to `cleaned.csv` in the working directory, header row
   first.
5. Verify the result before reporting success.

## Rules

- The output header row MUST be lowercase `snake_case`.
- You MUST NOT drop or reorder any column.
- The cleaned data MUST be written to `cleaned.csv` — do not just print it.

## Verification

- Re-read `cleaned.csv` and confirm it parses as valid CSV with a header row.
- Confirm the output row count equals the input row count minus the fully-empty
  rows that were removed.
- If verification fails, fix the output and check again before reporting done.
