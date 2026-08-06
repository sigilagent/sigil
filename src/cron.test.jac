# Tests for cron — annex of cron.jac (`jac test cron.jac`).
#
# Nothing here fires a job: `_fire` runs a real solve. What is tested is the
# arithmetic and the state machine around it — which is where the bugs were.
# The graph round-trip uses a far-future spec and removes itself.

import from datetime { datetime, timezone }

def _at(y: int, mo: int, d: int, h: int, mi: int) -> int {
    return int(datetime(y, mo, d, h, mi, tzinfo=timezone.utc).timestamp() * 1000);
}

test "compute_next: interval math and one-shot passthrough" {
    now = 1_700_000_000_000;
    assert compute_next(1, 300, 0, now) == now + 300_000;
    assert compute_next(1, 0, 0, now) == now;          # a zero interval cannot advance
    assert compute_next(0, 0, 42, now) == 42;          # `at` keeps its absolute time
}

test "_schedule_next: each kind resolves through its own arithmetic" {
    base = _at(2026, 3, 10, 12, 0);
    ev = CronJob(name="e", kind="every", spec="600");
    assert _schedule_next(ev, base) == base + 600_000;

    cr = CronJob(name="c", kind="cron", spec="0 9 * * *");
    assert _schedule_next(cr, base) == _at(2026, 3, 11, 9, 0);

    # tz is not decoration: the same expression fires at a different instant.
    cr_ny = CronJob(name="c", kind="cron", spec="0 9 * * *", tz="America/New_York");
    assert _schedule_next(cr_ny, base) == _at(2026, 3, 10, 13, 0);

    one = CronJob(name="o", kind="at", spec=str(base + 5000));
    assert _schedule_next(one, base) == base + 5000;
}

test "_schedule_next: an unschedulable cron expression resolves to never" {
    base = _at(2026, 3, 10, 12, 0);
    bad = CronJob(name="b", kind="cron", spec="0 0 30 2 *");
    assert _schedule_next(bad, base) == 0;
}

test "_rearm: a FAILED one-shot retires instead of re-firing every tick" {
    # The bug: `at` jobs kept their due time in the past, so a job whose task
    # errored re-fired on every tick, forever, billing a model call each time.
    t = _at(2026, 3, 10, 12, 0);
    j = CronJob(name="oneshot", kind="at", spec=str(t - 1000), delete_after_run=True);
    j.last_status = "error";
    consumed = _rearm(j, t);
    assert not consumed;
    assert not j.enabled, "a spent one-shot must not stay armed";
    assert j.next_run_ms == 0;
}

test "_rearm: a recurring job moves strictly forward" {
    t = _at(2026, 3, 10, 12, 0);
    j = CronJob(name="rep", kind="every", spec="900");
    j.last_status = "ok";
    assert not _rearm(j, t);
    assert j.next_run_ms == t + 900_000;
    assert j.enabled;
}

test "_rearm: a recurring job whose schedule went unschedulable parks itself" {
    t = _at(2026, 3, 10, 12, 0);
    j = CronJob(name="rot", kind="cron", spec="0 0 30 2 *");
    assert not _rearm(j, t);
    assert j.next_run_ms == 0;
    assert not j.enabled, "a job that can never fire again must not stay armed";
}

test "parse_target: channel, channel:peer, and nothing" {
    assert parse_target("") == ["", ""];
    assert parse_target("   ") == ["", ""];
    assert parse_target("ops") == ["ops", "cron"];
    assert parse_target("telegram:12345") == ["telegram", "12345"];
    assert parse_target("telegram:") == ["telegram", "cron"];
    assert parse_target(":12345") == ["", ""];
}

test "cron_add refuses a schedule it cannot compute" {
    bad = cron_add("_t_bad_cron", "cron", "0 0 30 2 *", "never happens");
    assert not bad["ok"];
    assert "cron expression" in str(bad["error"]);

    zero = cron_add("_t_bad_every", "every", "0", "never happens");
    assert not zero["ok"];
    assert "positive interval" in str(zero["error"]);

    junk = cron_add("_t_bad_every2", "every", "soon", "never happens");
    assert not junk["ok"];

    # a refusal must not leave the job on the graph
    names = [j["name"] for j in cron_list()];
    assert "_t_bad_cron" not in names;
    assert "_t_bad_every" not in names;
}

test "cron round-trip: add, list, next-due, tick-not-due, remove" {
    cron_remove("_t_roundtrip");
    r = cron_add("_t_roundtrip", "cron", "0 4 1 1 *", "a job that is not due");
    assert r["ok"];
    assert int(r["next_run_ms"]) > now_ms();

    rows = [j for j in cron_list() if j["name"] == "_t_roundtrip"];
    assert len(rows) == 1;
    assert rows[0]["enabled"];
    assert int(rows[0]["runs"]) == 0;

    assert next_due_ms() > 0;

    # nothing is due, so a tick must not fire anything (and must not raise)
    t = cron_tick();
    fired = [f["name"] for f in list(t["fired"])];
    assert "_t_roundtrip" not in fired;

    assert "removed" in cron_remove("_t_roundtrip");
    assert "_t_roundtrip" not in [j["name"] for j in cron_list()];
}

test "cron_enable re-arms a recurring job from now, not from its stale due time" {
    cron_remove("_t_rearm");
    cron_add("_t_rearm", "every", "3600", "x");
    cron_enable("_t_rearm", False);
    before = cron_show("_t_rearm");
    assert not before["enabled"];
    cron_enable("_t_rearm", True);
    after = cron_show("_t_rearm");
    assert after["enabled"];
    assert int(after["next_run_ms"]) > now_ms();
    cron_remove("_t_rearm");
}
