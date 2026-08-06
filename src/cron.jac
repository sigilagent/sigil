"""Cron / scheduled jobs — OpenClaw parity, but jobs live ON THE GRAPH (no jobs.json).

Schedule kinds match OpenClaw: `at` (one-shot ISO/epoch/relative), `every` (fixed
interval), `cron` (5/6-field expression + tz). Jobs persist as CronJob nodes off the
Soul; each fire records a CronRun (the "background task" record) and runs the job's
task through solve(). One-shot `at` jobs auto-delete after a successful run.

Firing is `cron_tick()`, and something has to call it. `cron_daemon()` is that
something: a blocking loop the CLI owns (`sigil cron daemon`), running on the same
local root the rest of the CLI writes to. That detail is load-bearing — a `jac
start` server puts scheduled work on its own system-user root, a different graph
from the one `sigil cron add` writes to, so a server-side scheduler would tick an
empty Soul forever. `api_cron_tick` exists for an external driver (launchd, an
outer cron) and ticks whichever graph its process owns.

The due-time arithmetic is compiled NATIVE (`na def compute_next`) — a pure integer
hot path over timestamps, the kind of thing the native codespace is for.
"""

import time;
import from .sigil { awaken, Soul }
import from .agent { run_task }
import from .hooks { fire_hooks }
import from .channels { message_send }
import from .sigil_cron { now_ms, parse_at, cron_next, cron_valid }
import from .sigil_runtime { write_pidfile, clear_pidfile, process_running }

edge Schedules {}   # Soul -> CronJob
edge Fired {}       # CronJob -> CronRun

glob RUN_HISTORY: int = 50;   # CronRuns kept per job; older fires are pruned

node CronJob {
    has name: str;
    has kind: str = "at";          # at | every | cron
    has spec: str = "";            # at: epoch-ms ; every: seconds ; cron: expression
    has tz: str = "UTC";
    has task: str = "";            # the system-event / prompt run when the job fires
    has channel: str = "";         # optional delivery target: "<channel>" or "<channel>:<peer>"
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
        return cron_next(job.spec, from_ms, job.tz);
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
    # Refuse a schedule we cannot compute rather than accepting it and firing at
    # some hour nobody asked for. This is the whole reason cron_next returns 0
    # instead of guessing.
    if kind == "cron" and not cron_valid(spec) {
        return {"ok": False, "name": name, "kind": kind, "next_run_ms": 0,
                "delete_after_run": False,
                "error": "not a schedulable cron expression: '" + str(spec) + "'"};
    }
    if kind == "every" {
        try { secs = int(spec or "0"); } except Exception as e { secs = 0; }
        if secs <= 0 {
            return {"ok": False, "name": name, "kind": kind, "next_run_ms": 0,
                    "delete_after_run": False,
                    "error": "'every' needs a positive interval in seconds, got '" + str(spec) + "'"};
        }
    }
    job = CronJob(name=name, kind=kind, spec=resolved, task=task, tz=tz,
                  channel=channel, delete_after_run=(delete_after_run or (kind == "at")));
    soul +>:Schedules:+> job;
    job.next_run_ms = _schedule_next(job, now_ms());
    return {"ok": True, "name": job.name, "kind": job.kind, "next_run_ms": job.next_run_ms,
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
        if j.name == name {
            j.enabled = on;
            # Re-arm from now: a job disabled for a week has a next_run in the
            # past, and re-enabling it should mean "from here", not "immediately
            # and then catch up".
            if on and (j.kind != "at") { j.next_run_ms = _schedule_next(j, now_ms()); }
            return name + (" enabled" if on else " disabled");
        }
    }
    return "no such cron job: " + name;
}

# ---------------------------------------------------------------------------
# Firing.
# ---------------------------------------------------------------------------
def parse_target(spec: str) -> list[str] {
    # A job's delivery target is "<channel>" or "<channel>:<peer>" — the peer half
    # is how a Telegram chat id or a Slack channel id rides along without adding a
    # field to CronJob (and without the schema drift that would cost every
    # existing install). Returns ["", ""] for no target.
    raw = str(spec or "").strip();
    if not raw { return ["", ""]; }
    if ":" in raw {
        bits = raw.split(":", 1);
        chan = bits[0].strip();
        peer = bits[1].strip() or "cron";
        return [chan, peer] if chan else ["", ""];
    }
    return [raw, "cron"];
}

def _deliver(job: CronJob, text: str) -> None {
    parts = parse_target(job.channel);
    target = str(parts[0]);
    if not target { return None; }
    try {
        message_send(target, str(parts[1]), text);
    } except Exception as e {
        print("cron: delivery to '" + target + "' failed: " + str(e)[:160]);
    }
    return None;
}

def _prune_runs(job: CronJob) -> None {
    hist = [job -->[?:CronRun]];
    if len(hist) <= RUN_HISTORY { return; }
    for r in hist[:len(hist) - RUN_HISTORY] { del r; }
}

def _fire(job: CronJob, t: int) -> dict {
    # Run one job. A job that raises must not take the tick down with it — the
    # next job in the loop is somebody else's schedule.
    fire_hooks("cron_fired", job.name);
    ok = False;
    summary = "";
    try {
        res = run_task(job.task, "");
        ok = "DONE ok" in str(res["trace"]);
        summary = str(res["result"]);
    } except Exception as e {
        ok = False;
        summary = "job raised: " + str(e)[:400];
    }
    run = CronRun(started_ms=t, ok=ok, summary=summary[:400]);
    job +>:Fired:+> run;
    job.runs += 1;
    if not ok { job.errors += 1; }
    job.last_status = "ok" if ok else "error";
    _prune_runs(job);
    if ok { _deliver(job, summary); }
    return {"name": job.name, "ok": ok, "summary": summary[:400]};
}

def _rearm(job: CronJob, t: int) -> bool {
    # Returns True if the job was consumed (deleted). A one-shot that FAILED used
    # to keep its due time in the past and re-fire on every single tick forever;
    # it retires instead, with its error on the record.
    if job.kind == "at" {
        if job.delete_after_run and job.last_status == "ok" {
            del job;
            return True;
        }
        job.enabled = False;
        job.next_run_ms = 0;
        return False;
    }
    job.next_run_ms = _schedule_next(job, t);
    if job.next_run_ms <= 0 {
        # Only reachable if a cron expression stopped being schedulable; park the
        # job rather than spin on it.
        job.enabled = False;
    }
    return False;
}

def cron_tick() -> dict {
    # Fire every due job. Driven by `cron_daemon` (the CLI loop), `sigil cron
    # tick`, or an external driver through `api_cron_tick`.
    soul = awaken();
    t = now_ms();
    fired: list = [];
    for j in _jobs(soul) {
        if (not j.enabled) or (j.next_run_ms <= 0) or (j.next_run_ms > t) { continue; }
        out = _fire(j, t);
        fired.append({"name": out["name"], "ok": out["ok"]});
        _rearm(j, t);
    }
    return {"now_ms": t, "fired": fired, "count": len(fired)};
}

def cron_run_now(name: str) -> dict {
    # Fire one job immediately, on demand, without disturbing its schedule — the
    # "don't make me wait five minutes to find out if it works" button.
    soul = awaken();
    for j in _jobs(soul) {
        if j.name == name {
            out = _fire(j, now_ms());
            if j.kind == "at" { _rearm(j, now_ms()); }
            return {"ok": True, "ran": out};
        }
    }
    return {"ok": False, "error": "no such cron job: " + name};
}

def next_due_ms() -> int {
    # Earliest next_run_ms across enabled jobs, or 0 when nothing is scheduled.
    soul = awaken();
    best = 0;
    for j in _jobs(soul) {
        if (not j.enabled) or (j.next_run_ms <= 0) { continue; }
        if (best == 0) or (j.next_run_ms < best) { best = j.next_run_ms; }
    }
    return best;
}

glob CRON_PID: str = "cron";           # pidfile name under $SIGIL_HOME/run
glob _STOP: dict = {"now": False};     # set by SIGTERM/SIGINT, read by the loop

def cron_daemon_running() -> bool {
    return process_running(CRON_PID);
}

def _stop_signal(signum: int, frame: any) -> None {
    _STOP["now"] = True;
    return None;
}

def _install_stop_handlers() -> None {
    # A service manager stops things with SIGTERM. Without a handler the process
    # dies where it stands and leaves its pidfile behind, and the next `status`
    # reports a daemon that isn't there.
    import signal;
    try {
        signal.signal(int(signal.SIGTERM), _stop_signal);
        signal.signal(int(signal.SIGINT), _stop_signal);
    } except Exception as e {
        return None;   # not the main thread — the caller owns shutdown
    }
    return None;
}

def _nap(seconds: int) -> None {
    # Sleep in slices so a stop signal is honored in about a second rather than
    # after a full interval. PEP 475 resumes an interrupted sleep, so the slicing
    # is what makes shutdown prompt.
    left = seconds;
    while (left > 0) and (not _STOP["now"]) {
        time.sleep(1 if left > 1 else left);
        left -= 1;
    }
    return None;
}

def cron_daemon(interval_s: int = 30, max_ticks: int = 0, quiet: bool = False) -> dict {
    # The blocking scheduler loop. `max_ticks` bounds it for tests; 0 runs until
    # stopped. Every tick is wrapped: a scheduler that dies on one bad job is the
    # failure this whole change exists to end.
    ticks = 0;
    total = 0;
    _STOP["now"] = False;
    _install_stop_handlers();
    write_pidfile(CRON_PID);
    if not quiet {
        print("cron daemon: ticking every " + str(interval_s) + "s (ctrl-c to stop)", flush=True);
    }
    try {
        while not _STOP["now"] {
            try {
                t = cron_tick();
                total += int(t["count"]);
                if (not quiet) and int(t["count"]) > 0 {
                    for f in list(t["fired"]) {
                        print("  fired " + str(f["name"]) + " -> " + ("ok" if f["ok"] else "err"),
                              flush=True);
                    }
                }
            } except Exception as e {
                print("cron daemon: tick failed: " + str(e)[:200], flush=True);
            }
            ticks += 1;
            if (max_ticks > 0) and (ticks >= max_ticks) { break; }
            _nap(interval_s if interval_s > 0 else 30);
        }
    } except KeyboardInterrupt as e {
        _STOP["now"] = True;
    } finally {
        clear_pidfile(CRON_PID);
        if not quiet { print("cron daemon: stopped", flush=True); }
    }
    return {"ticks": ticks, "fired": total};
}

# ---------------------------------------------------------------------------
# HTTP driver — for an external scheduler (launchd, systemd timer, an outer
# cron) that would rather POST than hold a process open.
#   POST /walker/api_cron_tick   {}
# ---------------------------------------------------------------------------
walker:pub api_cron_tick {
    can run with Root entry {
        report cron_tick();
    }
}
