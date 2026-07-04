"""Agent coordinator — the one place that fires the lifecycle hook bus around a solve.

`run_task` wraps the crystallize→execute→learn loop with `before_solve` / `after_solve`
hooks (and surfaces `solve_failed`). Channels, cron, and the CLI route through here so
hooks are load-bearing on every path — without a circular import (this module imports
prometheus + hooks; neither imports this one).
"""

import from prometheus { solve_task }
import from hooks { fire_hooks }

def run_task(task: str, skill: str = "") -> dict {
    fire_hooks("before_solve", task);
    r = solve_task(task, skill);
    ok = "DONE ok" in str(r["trace"]);
    fire_hooks("after_solve" if ok else "solve_failed", str(r["result"]));
    return r;
}
