"""Native cron schedule-math — compiled to a standalone LLVM binary with
`jac nacompile cron_native.na.jac -o cron_native`. Pure integer arithmetic over
epoch-ms timestamps (the native codespace: no walkers/byLLM/PyPI), the fast path
for the Gateway scheduler's due-time computation.

    ./cron_native <kind_code> <interval_s> <at_ms> <now_ms>   # -> next fire (epoch-ms)
    kind_code: 1 = every (interval from now) ; 0 = at (fixed instant)
"""

import sys;

def next_run(kind_code: int, interval_s: int, at_ms: int, now_ms: int) -> int {
    if kind_code == 1 {
        if interval_s <= 0 { return now_ms; }
        return now_ms + (interval_s * 1000);
    }
    return at_ms;
}

def due(next_run_ms: int, now_ms: int) -> int {
    # 1 if the job is due (and enabled/next>0), else 0
    if next_run_ms <= 0 { return 0; }
    if next_run_ms <= now_ms { return 1; }
    return 0;
}

with entry {
    args = sys.argv;
    if len(args) < 5 {
        print("usage: cron_native <kind_code> <interval_s> <at_ms> <now_ms>");
        sys.exit(1);
    }
    kc = int(args[1]);
    iv = int(args[2]);
    at = int(args[3]);
    now = int(args[4]);
    print(next_run(kc, iv, at, now));
}
