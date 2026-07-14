"""Cron time helpers — clock + schedule parsing. The due-time integer math lives
in cron.jac's native `compute_next`; this module only turns a spec string into an
absolute epoch-ms fire time."""

import time;
import from datetime { datetime }

def now_ms() -> int {
    return int(time.time() * 1000);
}

def parse_at(spec: str) -> int {
    # epoch-ms | ISO-8601 | relative ('90s','20m','2h','3d') -> epoch-ms.
    s = (spec or "").strip();
    if s and (s[-1] in "smhd") and s[:-1].isdigit() {
        mult = {"s": 1000, "m": 60000, "h": 3600000, "d": 86400000}[s[-1]];
        return now_ms() + int(s[:-1]) * mult;
    }
    if s.isdigit() {
        return int(s);
    }
    try {
        return int(datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp() * 1000);
    } except Exception as e {
        return now_ms();
    }
}

def cron_next(expr: str, from_ms: int) -> int {
    # Next fire time (epoch-ms) for a 5/6-field cron expr; croniter if present, else +60s.
    try {
        import from croniter { croniter }
        base = datetime.fromtimestamp(from_ms / 1000.0);
        return int(croniter(expr, base).get_next() * 1000);
    } except Exception as e {
        return from_ms + 60000;
    }
}
