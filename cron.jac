"""Cron / scheduled jobs — OpenClaw parity, but jobs live ON THE GRAPH (no jobs.json).

Schedule kinds match OpenClaw: `at` (one-shot ISO/epoch/relative), `every` (fixed
interval), `cron` (5/6-field expression + tz). Jobs persist as CronJob nodes off the
Soul; each fire records a CronRun (the "background task" record) and runs the job's
task through solve(). One-shot `at` jobs auto-delete after a successful run.

The due-time arithmetic is compiled NATIVE (`na def compute_next`) — a pure integer
hot path over timestamps, the kind of thing the native codespace is for.
"""

import from prometheus { awaken, Soul }
import from agent { run_task }
import from hooks { fire_hooks }
import from prom_cron { now_ms, parse_at, cron_next }

edge Schedules {}   # Soul -> CronJob
edge Fired {}       # CronJob -> CronRun

node CronJob {
    has name: str;
    has kind: str = "at";          # at | every | cron
    has spec: str = "";            # at: epoch-ms ; every: seconds ; cron: expression
    has tz: str = "UTC";
    has task: str = "";            # the system-event / prompt run when the job fires
    has channel: str = "";         # optional delivery channel (name of a Channel node)
    has wake: bool = True;
    has delete_after_run: bool = False;
    has enabled: bool = True;
    has next_run_ms: int = 0;
    has runs: int = 0;
    has errors: int = 0;
    has last_status: str = "pending";
}

node CronRun {
    has started_ms: int = 0;
    has ok: bool = False;
    has summary: str = "";
}

# ---------------------------------------------------------------------------
# Due-time arithmetic. The SAME routine is compiled to a native LLVM binary in
# cron_native.na.jac (built with `jac nacompile`) — pure int math over
# timestamps, the native pathway per the design ask. (Inline `na def` hits an
# ICE in this jaclang build, so the native artifact is the standalone binary
# and this in-process copy stays on the Python codespace.)
# ---------------------------------------------------------------------------
def compute_next(kind_code: int, interval_s: int, at_ms: int, now_ms: int) -> int {
    if kind_code == 1 {
        if interval_s <= 0 { return now_ms; }
        return now_ms + (interval_s * 1000);
    }
    return at_ms;
}

def _schedule_next(job: CronJob, from_ms: int) -> int {
    if job.kind == "every" {
        return compute_next(1, int(job.spec or "0"), 0, from_ms);
    }
    if job.kind == "cron" {
        return cron_next(job.spec, from_ms);
    }
    return compute_next(0, 0, int(job.spec or "0"), from_ms);
}

# ---------------------------------------------------------------------------
# Job management (graph mutations).
# ---------------------------------------------------------------------------
def _jobs(soul: Soul) -> list[CronJob] {
    return [soul -->[?:CronJob]];
}

def cron_add(name: str, kind: str, spec: str, task: str,
             tz: str = "UTC", channel: str = "", delete_after_run: bool = False) -> dict {
    soul = awaken();
    resolved = spec;
    if kind == "at" { resolved = str(parse_at(spec)); }   # normalize to epoch-ms
    job = CronJob(name=name, kind=kind, spec=resolved, task=task, tz=tz,
                  channel=channel, delete_after_run=(delete_after_run or (kind == "at")));
    soul +>:Schedules:+> job;
    job.next_run_ms = _schedule_next(job, now_ms());
    return {"name": job.name, "kind": job.kind, "next_run_ms": job.next_run_ms,
            "delete_after_run": job.delete_after_run};
}

def cron_list() -> list {
    soul = awaken();
    out: list = [];
    for j in _jobs(soul) {
        out.append({"name": j.name, "kind": j.kind, "spec": j.spec, "enabled": j.enabled,
                    "next_run_ms": j.next_run_ms, "runs": j.runs, "errors": j.errors,
                    "last_status": j.last_status, "task": j.task[:60]});
    }
    return out;
}

def cron_show(name: str) -> dict {
    soul = awaken();
    for j in _jobs(soul) {
        if j.name == name {
            return {"name": j.name, "kind": j.kind, "spec": j.spec, "tz": j.tz,
                    "task": j.task, "channel": j.channel, "enabled": j.enabled,
                    "next_run_ms": j.next_run_ms, "runs": j.runs, "errors": j.errors,
                    "last_status": j.last_status, "delete_after_run": j.delete_after_run};
        }
    }
    return {};
}

def cron_runs(name: str) -> list {
    soul = awaken();
    for j in _jobs(soul) {
        if j.name == name {
            return [{"started_ms": r.started_ms, "ok": r.ok, "summary": r.summary[:120]}
                    for r in [j -->[?:CronRun]]];
        }
    }
    return [];
}

def cron_remove(name: str) -> str {
    soul = awaken();
    for j in _jobs(soul) {
        if j.name == name { del j; return "removed cron job '" + name + "'"; }
    }
    return "no such cron job: " + name;
}

def cron_enable(name: str, on: bool) -> str {
    soul = awaken();
    for j in _jobs(soul) {
        if j.name == name { j.enabled = on; return name + (" enabled" if on else " disabled"); }
    }
    return "no such cron job: " + name;
}

# ---------------------------------------------------------------------------
# The tick — fire every due job. Driven by jac-scale's scheduler in server mode,
# a `cron daemon` loop from the CLI, or an external cron hitting api_cron_tick.
# ---------------------------------------------------------------------------
def cron_tick() -> dict {
    soul = awaken();
    t = now_ms();
    fired: list = [];
    for j in _jobs(soul) {
        if (not j.enabled) or (j.next_run_ms <= 0) or (j.next_run_ms > t) { continue; }
        fire_hooks("cron_fired", j.name);
        res = run_task(j.task, "");
        ok = "DONE ok" in str(res["trace"]);
        run = CronRun(started_ms=t, ok=ok, summary=str(res["result"])[:400]);
        j +>:Fired:+> run;
        j.runs += 1;
        if not ok { j.errors += 1; }
        j.last_status = "ok" if ok else "error";
        fired.append({"name": j.name, "ok": ok});
        if j.delete_after_run and ok {
            del j;
        } else {
            j.next_run_ms = _schedule_next(j, t);
        }
    }
    return {"now_ms": t, "fired": fired, "count": len(fired)};
}
