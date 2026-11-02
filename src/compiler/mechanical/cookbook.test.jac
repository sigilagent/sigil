"""Regression guard for the golden AG-IR cookbook.

Every committed docs/reference/agir-cookbook/*.agir is a curated, hand-reviewed
example. It must stay gate-clean: lower + type-check through the mechanical half
(COMPILE) and carry no residual type-unification issue (G4). A compiler change that
breaks a golden IR fails here, loudly, before it ships."""

test "the cookbook is non-empty" {
    assert cookbook_files(), "no golden AG-IRs found in " + cookbook_dir()
        + " — the cookbook must not be empty";
}

test "every golden cookbook AG-IR lowers and type-checks clean (COMPILE + G4)" {
    for r in validate_cookbook() {
        assert r["ok"], "golden '" + str(r["name"]) + "' failed COMPILE:\n" + str(r["errors"]);
        assert not r["g9"], "golden '" + str(r["name"]) + "' has G4 type issues: "
            + "; ".join([str(x) for x in list(r["g9"])])[:400];
    }
}
