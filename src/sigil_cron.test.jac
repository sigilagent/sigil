# Tests for sigil_cron — annex of sigil_cron.jac (`jac test sigil_cron.jac`).
# Deterministic time parsing; no graph / no model.

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
    assert cron_next("*/5 * * * *", base) > base;
    assert cron_next("0 0 * * *", base) > base;
}
