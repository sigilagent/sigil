# Automation and cron

Sigil can schedule work to run later or on a repeat. Jobs live on the graph as `CronJob`
nodes (no `jobs.json`); each fire records a `CronRun`.

> **Something has to be ticking.** A scheduled job only fires while a scheduler process
> is running — `sigil cron daemon`, or an external driver hitting the tick. With nothing
> running, jobs sit at `runs=0` indefinitely. `sigil cron add` and `sigil cron list` say
> so when no scheduler is up, and so does the agent in chat.

## Firing the scheduler

```bash
sigil cron daemon          # the scheduler: ticks every 30s until stopped
sigil cron daemon 5        # tick every 5 seconds instead
```

It runs in the foreground, logs every tick, and stops cleanly on ctrl-c or `SIGTERM`,
clearing its pidfile at `$SIGIL_HOME/run/cron.pid` (default `~/.sigil/run/cron.pid`).

Each tick line is a heartbeat — `tick: fired 0 job(s), 3 armed` says the scheduler is
alive *and* can see three jobs. Every tick runs in a fresh process on purpose: a
long-lived jac process serves the graph it loaded at startup, so an in-process loop
would never see a job added after it started. One job runs at a time; a long solve
delays the next tick rather than stacking runs on top of it.

Prefer not to hold a process open? Drive the tick from outside:

```bash
sigil cron tick                                            # fire anything due, once
*/1 * * * * /path/to/sigil cron tick                       # from the system crontab
curl -X POST localhost:8199/walker/api_cron_tick -d '{}'   # over HTTP
```

Each fire runs the job's task through the normal solve/agent path and records the
outcome as a `CronRun` (visible via `sigil cron runs <name>` and the `tasks` ledger).
A tick that lands after a missed window fires the job once and re-arms from now — a
scheduler that was down overnight does not replay a night of backlog at breakfast.

## From chat

Just ask — "every morning summarize my notes", "in 2 hours check the build", "on a cron
at 9am email me". The agent calls `schedule_task`, and you manage jobs with
`list_scheduled` / `cancel_scheduled` / `run_scheduled_now`.

## Schedule kinds

| Kind | Spec | Example |
|---|---|---|
| `at` | a relative time (`30m`, `2h`, `1d`), ISO timestamp, or epoch-ms | one-shot; auto-deletes after a successful run, retires after a failed one |
| `every` | interval in **seconds** | `every 3600` = hourly |
| `cron` | a 5- or 6-field cron expression (+ optional tz) | `0 9 * * *` = 9am daily |

### Cron expressions

Fields are `[second] minute hour day-of-month month day-of-week`; a 5-field expression
omits seconds. Each field takes `*`, `?`, `5`, `9-17`, `*/15`, `9-17/4`, and
comma-separated lists of those. Months and weekdays also take names (`jan`, `mon`).
Sunday is both `0` and `7`. When day-of-month and day-of-week are both restricted they
are OR'd, as in every other cron.

The timezone argument applies to `cron` jobs — `sigil cron add digest cron "0 9 * * *"
"summarize my inbox" America/New_York` fires at 9am New York, DST included.

An expression Sigil cannot schedule — a typo, or something impossible like
`0 0 30 2 *` — is **rejected at `cron add`** rather than accepted and quietly fired at
some other time.

## From the CLI

```bash
sigil cron add <name> <at|every|cron> <spec> "<task>" [tz] [channel]
sigil cron list                 # includes the next fire time, in words
sigil cron show <name>
sigil cron runs <name>          # run history (last 50 fires per job)
sigil cron run <name>           # fire it now, once, without touching its schedule
sigil cron rm <name>
sigil cron enable|disable <name>
sigil cron tick                 # fire anything due, once
sigil cron daemon [interval]    # keep ticking
```

## Delivery

A job may name a delivery target as `<channel>` or `<channel>:<peer>` — for example
`telegram:123456789`. On a successful fire the result is sent there through the channel
(see [channels](channels.md)); the peer half carries the chat id or room the adapter
needs. Without a target the result is only recorded on the graph.

The unified background ledger — `sigil tasks list` / `tasks show <n>` — shows solve
attempts and cron fires together, newest first.
