---
name: one-line-tldr
description: Use when someone wants a single-sentence summary of a longer piece of text.
---

# One-Line TL;DR

Turn any block of text into exactly one clear sentence that captures its main
point. This is the smallest possible skill — a good first compile to see the
pipeline end to end.

## Steps

1. Read the input text from the task.
2. Write a single-sentence summary of the text's main point.
3. Return the summary as the result.

## Rules

- The summary MUST be exactly one sentence.
- The summary MUST be 25 words or fewer.
- Do NOT add a preamble, a title, or any commentary — return only the sentence.
