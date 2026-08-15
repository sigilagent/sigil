# Tests for sigil_cron — annex of sigil_cron.jac (`jac test sigil_cron.jac`).
# Deterministic time parsing; no graph / no model. Every cron assertion pins an
# absolute instant, not just "later than base" — the old implementation advanced
# past the base time on every expression by adding 60s, and that is exactly what
# shipped broken.

import from datetime { datetime, timezone }

def _ms(y: int, mo: int, d: int, h: int, mi: int, s: int = 0) -> int {
    return int(datetime(y, mo, d, h, mi, s, tzinfo=timezone.utc).timestamp() * 1000);
}

test "parse_at: epoch-ms passes through verbatim" {
    assert parse_at("1000") == 1000;
    assert parse_at("1735689600000") == 1735689600000;
}

test "parse_at: relative offsets resolve to now + delta" {
    base = now_ms();
    two_h = parse_at("2h") - base;
    assert two_h >= 7100000 and two_h <= 7300000, f"2h delta was {two_h}";
    ninety = parse_at("90s") - now_ms();
    assert ninety >= 89000 and ninety <= 91000, f"90s delta was {ninety}";
}

test "cron_next: always advances past the base time" {
    base = 1000000000000;
    assert cron_next("*/5 * * * *", base, "UTC") > base;
    assert cron_next("0 0 * * *", base, "UTC") > base;
}

test "cron_next: daily 9am lands on 9am, not one minute later" {
    # The regression that started this: croniter was never importable inside the
    # native runtime, so `0 9 * * *` fell through to base + 60s — an every-minute
    # job wearing a daily digest's name.
    base = _ms(2026, 3, 10, 12, 0);
    assert cron_next("0 9 * * *", base, "UTC") == _ms(2026, 3, 11, 9, 0);
    before = _ms(2026, 3, 10, 8, 59);
    assert cron_next("0 9 * * *", before, "UTC") == _ms(2026, 3, 10, 9, 0);
}

test "cron_next: step, list and range fields" {
    base = _ms(2026, 3, 10, 12, 2);
    assert cron_next("*/5 * * * *", base, "UTC") == _ms(2026, 3, 10, 12, 5);
    assert cron_next("0,30 * * * *", base) == _ms(2026, 3, 10, 12, 30);
    assert cron_next("15 9-17 * * *", base, "UTC") == _ms(2026, 3, 10, 12, 15);
    assert cron_next("0 9-17/4 * * *", _ms(2026, 3, 10, 10, 0), "UTC") == _ms(2026, 3, 10, 13, 0);
}

test "cron_next: weekday names and numbers agree, Sunday is 0 and 7" {
    # 2026-03-10 is a Tuesday.
    tue = _ms(2026, 3, 10, 12, 0);
    mon = _ms(2026, 3, 16, 0, 0);
    assert cron_next("0 0 * * mon", tue, "UTC") == mon;
    assert cron_next("0 0 * * 1", tue, "UTC") == mon;
    sun = _ms(2026, 3, 15, 0, 0);
    assert cron_next("0 0 * * 0", tue, "UTC") == sun;
    assert cron_next("0 0 * * 7", tue, "UTC") == sun;
    assert cron_next("0 0 * * sun", tue, "UTC") == sun;
}

test "cron_next: day-of-month and day-of-week are OR'd when both restricted" {
    # Standard cron: `0 0 1 * mon` fires on the 1st AND on every Monday.
    base = _ms(2026, 3, 10, 12, 0);                                    # Tue 10 Mar 2026
    assert cron_next("0 0 1 * mon", base, "UTC") == _ms(2026, 3, 16, 0, 0);   # the Monday comes first
    assert cron_next("0 0 1 * *", base, "UTC") == _ms(2026, 4, 1, 0, 0);      # dom alone: the next 1st
}

test "cron_next: month names and a date a year out" {
    base = _ms(2026, 3, 10, 12, 0);
    assert cron_next("0 0 1 jan *", base, "UTC") == _ms(2027, 1, 1, 0, 0);
    assert cron_next("30 4 29 2 *", base, "UTC") == _ms(2028, 2, 29, 4, 30);  # leap year only
}

test "cron_next: six fields put seconds in front" {
    base = _ms(2026, 3, 10, 12, 0, 10);
    assert cron_next("30 * * * * *", base, "UTC") == _ms(2026, 3, 10, 12, 0, 30);
    assert cron_next("*/15 * * * * *", base, "UTC") == _ms(2026, 3, 10, 12, 0, 15);
}

test "cron_next: timezone shifts the wall-clock hour" {
    base = _ms(2026, 3, 10, 12, 0);
    # 09:00 New York on 2026-03-10 (EDT, UTC-4) is 13:00 UTC.
    assert cron_next("0 9 * * *", base, "America/New_York") == _ms(2026, 3, 10, 13, 0);
    assert cron_next("0 9 * * *", base, "UTC") == _ms(2026, 3, 11, 9, 0);
}

test "cron_next: an unparseable or impossible expression is never, not a guess" {
    base = _ms(2026, 3, 10, 12, 0);
    assert cron_next("not a cron", base, "UTC") == 0;
    assert cron_next("0 9 * *", base, "UTC") == 0;          # four fields
    assert cron_next("0 0 30 2 *", base, "UTC") == 0;       # February 30th
    assert not cron_valid("0 0 30 2 *");
    assert cron_valid("0 9 * * *");
    assert cron_valid("*/10 * * * * *");
}

# ---------------------------------------------------------------------------
# Zone policy: an unset tz means the HOST's wall clock, not UTC. Every
# assertion above pins "UTC" explicitly so it tests cron arithmetic on any
# machine; these test the default itself, which is what a person means by "9am".
# ---------------------------------------------------------------------------

test "tzinfo_for: empty means local, explicit UTC means UTC" {
    assert tzinfo_for("UTC") == timezone.utc;
    assert tzinfo_for("utc") == timezone.utc;
    # "" resolves the host zone; on a host with no IANA name it is None, which
    # datetime.fromtimestamp reads as local either way.
    z = tzinfo_for("");
    assert (z is None) or (str(z) != "UTC");
}

test "cron_next: an unset tz fires on the local wall clock" {
    # 09:00 with no zone must land on local 9am. The old default put it on UTC
    # 9am — `0 11,15 * * *` firing at 07:00 local is the bug this encodes.
    base = _ms(2026, 3, 10, 12, 0);
    got = cron_next("0 9 * * *", base);
    assert got > 0;
    d = datetime.fromtimestamp(got / 1000.0);
    assert d.hour == 9;
    assert d.minute == 0;
}

test "cron_next: an explicit zone still overrides the local default" {
    base = _ms(2026, 3, 10, 12, 0);
    assert cron_next("0 9 * * *", base, "UTC") == _ms(2026, 3, 11, 9, 0);
    assert cron_next("0 9 * * *", base, "America/New_York") == _ms(2026, 3, 10, 13, 0);
}

test "describe_schedule: a spec a person can check against a clock" {
    assert describe_schedule("cron", "0 3 * * *", "UTC") == "daily at 03:00 UTC";
    assert describe_schedule("cron", "30 8 * * 1-5", "UTC") == "Mon-Fri at 08:30 UTC";
    assert describe_schedule("cron", "0 */4 * * *", "UTC").startswith("every 4h");
    assert describe_schedule("cron", "*/15 * * * *", "UTC") == "every 15 minutes";
    assert describe_schedule("every", "600", "") == "every 10m";
    # an expression it cannot decode says so rather than inventing a phrasing
    assert "unparseable" in describe_schedule("cron", "not a cron", "");
}
