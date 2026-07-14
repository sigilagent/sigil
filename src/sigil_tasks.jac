"""Background task ledger — a read-only projection over episodic run history.

Every solve records an `Attempt` (TaskGraph --Ran--> Attempt) and every cron fire a
`CronRun` (CronJob --Fired--> CronRun). `tasks_list` merges both into one time-ordered
feed (newest first); `tasks_show` returns the full record of the Nth entry. No new
state — this is OpenClaw's `tasks list/show` over the graph Sigil already keeps.
"""

import from .sigil { Registry, TaskGraph, Attempt, Soul }
import from .cron { CronJob, CronRun }

def _rows() -> list {
    rows: list = [];
    regs = [root -->[?:Registry]];
    if regs {
        for tg in [regs[0] -->[?:TaskGraph]] {
            for a in [tg -->[?:Attempt]] {
                rows.append({
                    "kind": "solve", "label": tg.signature, "ok": a.ok,
                    "model": a.model, "at_ms": a.at_ms, "summary": a.summary, "detail": a.task
                });
            }
        }
    }
    souls = [root -->[?:Soul]];
    if souls {
        for job in [souls[0] -->[?:CronJob]] {
            for cr in [job -->[?:CronRun]] {
                rows.append({
                    "kind": "cron", "label": job.name, "ok": cr.ok,
                    "model": "", "at_ms": cr.started_ms, "summary": cr.summary, "detail": job.name
                });
            }
        }
    }
    return rows;
}

def _by_at(r: dict) -> int {
    return int(r["at_ms"]);
}

def tasks_list(limit: int = 20) -> list {
    # newest first; sort the run records by their epoch-ms timestamp
    rows = _rows();
    ranked = sorted(rows, key=_by_at, reverse=True);
    out: list = [];
    for row in ranked[:limit] { out.append(row); }
    return out;
}

def tasks_show(n: int) -> dict {
    items = tasks_list(100000);
    if (n < 1) or (n > len(items)) { return {}; }
    return dict(items[n - 1]);
}
