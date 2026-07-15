# Automation and cron

Sigil can schedule work to run later or on a repeat. Jobs live on the graph as `CronJob`
nodes (no `jobs.json`); each fire records a `CronRun`.

## From chat

Just ask — "every morning summarize my notes", "in 2 hours check the build", "on a cron
at 9am email me". The agent calls `schedule_task`, and you manage jobs with
`list_scheduled` / `cancel_scheduled`.

## Schedule kinds

| Kind | Spec | Example |
|---|---|---|
| `at` | a relative time (`30m`, `2h`, `1d`), ISO timestamp, or epoch-ms | one-shot; auto-deletes after a successful run |
| `every` | interval in **seconds** | `every 3600` = hourly |
| `cron` | a 5-field cron expression (+ optional tz) | `0 9 * * *` = 9am daily |

## From the CLI

```bash
sigil cron add <name> <at|every|cron> <spec> "<task>" [tz] [channel]
sigil cron list
sigil cron show <name>
sigil cron runs <name>          # run history
sigil cron rm <name>
sigil cron enable|disable <name>
sigil cron tick                 # fire any due jobs now
```

## Firing the scheduler

`cron_tick` fires all due jobs. In production it's driven by the jac-scale scheduler
(server mode); locally you can run it from an external cron/daemon or hit the tick
manually. Each fire runs the job's task through the normal solve/agent path and records
the outcome as a `CronRun` (visible via `sigil cron runs <name>` and the `tasks` ledger).

## Delivery

A job may name a `channel`; its result can be delivered there (see [channels](channels.md)).
The unified background ledger — `sigil tasks list` / `tasks show <n>` — shows solve
attempts and cron fires together, newest first.
