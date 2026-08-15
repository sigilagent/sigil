"""Cron time helpers — the clock, one-shot spec parsing, and cron-expression
arithmetic. The interval math for `every` lives in cron.jac's `compute_next`;
this module turns a spec string into an absolute epoch-ms fire time.

`cron_next` is a self-contained 5/6-field evaluator: no croniter, no apscheduler.
It has to be. The native `jac` runtime ships its own Python closure, `import
croniter` never resolved inside it, and the old `except` fell through to
`from_ms + 60000` — which turned `0 9 * * *` into "every minute" without saying
so. A schedule that lies quietly is worse than one that refuses.

Fields, in order:  [second] minute hour day-of-month month day-of-week
A 5-field expression omits seconds (second = 0). Every field accepts `*`, `?`,
`a`, `a-b`, `*/n`, `a-b/n`, `a/n`, and comma-separated lists of those; months and
weekdays also accept their three-letter names. Day-of-month and day-of-week are
OR'd when both are restricted, matching every other cron.

An expression this module cannot parse returns 0 — "never" — rather than a
guessed time, so cron.jac can refuse the job at `cron add` instead of firing it
at some hour nobody asked for.
"""

import os;
import time;
import from datetime { datetime, timedelta, timezone }

glob _MONTHS: dict = {
    "jan": 1, "feb": 2, "mar": 3, "apr": 4, "may": 5, "jun": 6,
    "jul": 7, "aug": 8, "sep": 9, "oct": 10, "nov": 11, "dec": 12
};
glob _DOWS: dict = {
    "sun": 0, "mon": 1, "tue": 2, "wed": 3, "thu": 4, "fri": 5, "sat": 6
};
glob _NONE: dict = {};

def now_ms() -> int {
    return int(time.time() * 1000);
}

def fmt_when(ms: int, tz: str = "") -> str {
    # An epoch-ms as something a person can check against a wall clock. `sigil
    # cron list` printing `next=1786025736575` is how "it never ran" goes
    # unnoticed for a week.
    if ms <= 0 { return "never"; }
    try {
        zone = tzinfo_for(tz) if tz else None;
        d = datetime.fromtimestamp(ms / 1000.0, zone) if zone else datetime.fromtimestamp(ms / 1000.0);
        stamp = d.strftime("%Y-%m-%d %H:%M:%S");
    } except Exception as e {
        return str(ms);
    }
    delta = int((ms - now_ms()) / 1000);
    if delta < 0 { return stamp + " (overdue by " + human_secs(0 - delta) + ")"; }
    return stamp + " (in " + human_secs(delta) + ")";
}

def human_secs(secs: int) -> str {
    s = int(secs);
    if s < 60 { return str(s) + "s"; }
    if s < 3600 { return str(s // 60) + "m"; }
    if s < 86400 { return str(s // 3600) + "h" + str((s % 3600) // 60) + "m"; }
    return str(s // 86400) + "d" + str((s % 86400) // 3600) + "h";
}

glob _DOW_NAMES: list = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"];

def _hhmm(hour: str, minute: str) -> str {
    # "9", "5" -> "09:05". Only for concrete single values; "" otherwise.
    if not (str(hour).isdigit() and str(minute).isdigit()) { return ""; }
    return str(int(hour)).rjust(2, "0") + ":" + str(int(minute)).rjust(2, "0");
}

def _dow_num(tok: str) -> str {
    # A weekday token as its cron number, name or digit alike. "" if neither.
    t: str = str(tok).strip().lower();
    if t in _DOWS { return str(_DOWS[t]); }
    return t if t.isdigit() else "";
}

def _dow_label(field: str) -> str {
    # "1" -> "Mon"; "1-5" -> "Mon-Fri"; "1,3" -> "Mon,Wed". "" if not decodable.
    out: list[str] = [];
    for raw in str(field).split(",") {
        part: str = str(raw).strip().lower();
        if "-" in part {
            bits: list = part.split("-", 1);
            a: str = _dow_num(str(bits[0]));
            b: str = _dow_num(str(bits[1]));
            if (not a) or (not b) { return ""; }
            out.append(str(_DOW_NAMES[int(a) % 8]) + "-" + str(_DOW_NAMES[int(b) % 8]));
        } else {
            n: str = _dow_num(part);
            if not n { return ""; }
            out.append(str(_DOW_NAMES[int(n) % 8]));
        }
    }
    return ",".join(out);
}

def describe_schedule(kind: str, spec: str, tz: str = "") -> str {
    # A schedule as a person would say it. `cron · 0 3 * * *` tells you nothing
    # you can check against a wall clock; "daily at 03:00 America/New_York" does.
    # Anything this cannot decode falls back to the raw spec rather than guessing.
    k = str(kind or "").strip();
    s = str(spec or "").strip();
    zone = str(tz or "").strip() or local_tz() or "local time";
    if k == "at" {
        return "once, at " + fmt_when(parse_at(s));
    }
    if k == "every" {
        try { return "every " + human_secs(int(float(s))); }
        except Exception as e { return "every " + s + "s"; }
    }
    if k != "cron" { return s; }
    f: list = cron_fields(s);
    if not f { return s + " (unparseable)"; }
    f_min: str = str(f[1]);
    f_hour: str = str(f[2]);
    f_dom: str = str(f[3]);
    f_mon: str = str(f[4]);
    f_dow: str = str(f[5]);
    at: str = _hhmm(f_hour, f_min);
    every_day: bool = _open(f_dom) and _open(f_mon) and _open(f_dow);
    # */n in the hour field, everything below it pinned -> "every n hours"
    if f_hour.startswith("*/") and f_hour[2:].isdigit() and f_min.isdigit() and every_day {
        return "every " + f_hour[2:] + "h (at :" + str(int(f_min)).rjust(2, "0") + ") " + zone;
    }
    if f_min.startswith("*/") and f_min[2:].isdigit() and _open(f_hour) and every_day {
        return "every " + f_min[2:] + " minutes";
    }
    if not at { return s + " · " + zone; }
    if every_day { return "daily at " + at + " " + zone; }
    if _open(f_dom) and _open(f_mon) {
        d: str = _dow_label(f_dow);
        if d { return d + " at " + at + " " + zone; }
    }
    if _open(f_dow) and _open(f_mon) and f_dom.isdigit() {
        return "monthly on the " + str(int(f_dom)) + " at " + at + " " + zone;
    }
    return s + " · " + zone;
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

# ---------------------------------------------------------------------------
# Cron expression evaluation
# ---------------------------------------------------------------------------
def local_tz() -> str {
    # The host's wall-clock zone, as an IANA name ("America/New_York").
    # "11am" from a person means 11am on THEIR clock: a hardcoded UTC made
    # `0 11,15 * * *` fire at 07:00 local, and nobody could say why.
    tz = str(os.getenv("TZ") or "").strip();
    if tz and ("/" in tz) { return tz; }
    try {
        real = str(os.path.realpath("/etc/localtime"));
        if "zoneinfo/" in real { return real.split("zoneinfo/", 1)[1]; }
    } except Exception as e {
        return "";
    }
    return "";
}

def tzinfo_for(tz: str) -> any {
    # An EMPTY zone means the host's local wall clock — the default a person
    # means when they say "9am". Only an explicit "UTC" gets UTC. An unknown
    # zone falls back to local rather than raising: a job with a typo'd
    # timezone should still run, an hour off, not vanish.
    given: str = str(tz or "").strip();
    if given.upper() == "UTC" {
        return timezone.utc;
    }
    name: str = given if given else local_tz();
    if not name {
        return None;   # no IANA name resolvable — a naive datetime is local
    }
    try {
        import from zoneinfo { ZoneInfo }
        return ZoneInfo(name);
    } except Exception as e {
        return None;
    }
}

def _token(tok: str, names: dict) -> int {
    s = str(tok).strip().lower();
    if s in names {
        return int(names[s]);
    }
    return int(s);
}

def _matches(field: str, value: int, lo: int, hi: int, names: dict) -> bool {
    # One cron field against one concrete value. Unparseable list members are
    # skipped, not fatal — a partly-broken field still matches what it can.
    for raw in str(field).split(",") {
        part = str(raw).strip().lower();
        if not part {
            continue;
        }
        step = 1;
        if "/" in part {
            bits = part.split("/", 1);
            part = bits[0].strip();
            try {
                step = int(bits[1]);
            } except Exception as e {
                continue;
            }
            if step <= 0 {
                continue;
            }
        }
        start = lo;
        end = hi;
        if (part == "*") or (part == "?") or (not part) {
            start = lo;
            end = hi;
        } elif "-" in part {
            bits = part.split("-", 1);
            try {
                start = _token(bits[0], names);
                end = _token(bits[1], names);
            } except Exception as e {
                continue;
            }
        } else {
            try {
                start = _token(part, names);
            } except Exception as e {
                continue;
            }
            # `5/15` means "from 5, every 15"; a bare `5` means exactly 5.
            end = hi if step > 1 else start;
        }
        if (start > end) or (value < start) or (value > end) {
            continue;
        }
        if ((value - start) % step) == 0 {
            return True;
        }
    }
    return False;
}

def _dow_matches(field: str, py_weekday: int) -> bool {
    # datetime is Mon=0..Sun=6; cron is Sun=0..Sat=6, and accepts 7 for Sunday too.
    d = (py_weekday + 1) % 7;
    if _matches(field, d, 0, 7, _DOWS) {
        return True;
    }
    if d == 0 {
        return _matches(field, 7, 7, 7, _DOWS);
    }
    return False;
}

def _open(field: str) -> bool {
    f = str(field).strip();
    return (f == "*") or (f == "?") or (f == "");
}

def cron_fields(expr: str) -> list {
    # Normalize to the 6-field [sec min hour dom mon dow] form. [] = unparseable.
    parts = str(expr or "").split();
    if len(parts) == 6 {
        return parts;
    }
    if len(parts) == 5 {
        return ["0"] + parts;
    }
    return [];
}

def cron_valid(expr: str) -> bool {
    # A shape check plus one real evaluation: an expression that parses but can
    # never match (`0 0 30 2 *` — February 30th) is invalid in the way that
    # matters, and the only honest test is to try to find its next fire.
    if not cron_fields(expr) {
        return False;
    }
    return cron_next(expr, now_ms()) > 0;
}

def _next_month(d: datetime) -> datetime {
    y = d.year;
    m = d.month + 1;
    if m > 12 {
        m = 1;
        y += 1;
    }
    return d.replace(year=y, month=m, day=1, hour=0, minute=0, second=0, microsecond=0);
}

def _next_day(d: datetime) -> datetime {
    return d.replace(hour=0, minute=0, second=0, microsecond=0) + timedelta(days=1);
}

def _next_hour(d: datetime) -> datetime {
    return d.replace(minute=0, second=0, microsecond=0) + timedelta(hours=1);
}

def _next_minute(d: datetime) -> datetime {
    return d.replace(second=0, microsecond=0) + timedelta(minutes=1);
}

def cron_next(expr: str, from_ms: int, tz: str = "") -> int {
    # Next fire strictly after `from_ms`, in epoch-ms. 0 = never (unparseable, or
    # no match inside the search horizon).
    #
    # The search walks calendar units coarse-to-fine and jumps: a month that
    # cannot match skips to the 1st of the next one, a day to the next midnight,
    # and so on. A naive minute-by-minute scan needs half a million steps to
    # prove `0 0 29 2 *` in a non-leap year; this needs a few hundred.
    f = cron_fields(expr);
    if not f {
        return 0;
    }
    f_sec = f[0];
    f_min = f[1];
    f_hour = f[2];
    f_dom = f[3];
    f_mon = f[4];
    f_dow = f[5];
    zone = tzinfo_for(tz);
    try {
        base = datetime.fromtimestamp(from_ms / 1000.0, zone);
    } except Exception as e {
        return 0;
    }
    cand = base.replace(microsecond=0) + timedelta(seconds=1);
    # Five years, not one: `30 4 29 2 *` is a legal expression whose next fire can
    # be three years out, and a one-year horizon would call it invalid. The
    # coarse-to-fine jumps make the longer horizon nearly free.
    limit = base + timedelta(days=1830);
    dom_restricted = not _open(f_dom);
    dow_restricted = not _open(f_dow);
    guard = 0;
    while (cand <= limit) and (guard < 100000) {
        guard += 1;
        if not _matches(f_mon, cand.month, 1, 12, _MONTHS) {
            cand = _next_month(cand);
            continue;
        }
        dom_ok = _matches(f_dom, cand.day, 1, 31, _NONE);
        dow_ok = _dow_matches(f_dow, cand.weekday());
        day_ok = (dom_ok or dow_ok) if (dom_restricted and dow_restricted) else (dom_ok and dow_ok);
        if not day_ok {
            cand = _next_day(cand);
            continue;
        }
        if not _matches(f_hour, cand.hour, 0, 23, _NONE) {
            cand = _next_hour(cand);
            continue;
        }
        if not _matches(f_min, cand.minute, 0, 59, _NONE) {
            cand = _next_minute(cand);
            continue;
        }
        if not _matches(f_sec, cand.second, 0, 59, _NONE) {
            cand = cand + timedelta(seconds=1);
            continue;
        }
        return int(cand.timestamp() * 1000);
    }
    return 0;
}
