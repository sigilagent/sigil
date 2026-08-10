"""Tests — the skill linter's code disposes (guards + apply).

The suggestion slot is model-judged; everything that decides whether an edit
can touch the skill is pure code and locked in here: verbatim-old, actually-
changes, marker-stated-force, variant-per-modality, shared-old-span, the
content-preservation guards (length floor, code-token survival, sentence-span
cap, no punctuation wreckage), and the apply step's skip-on-vanish. (The slot
itself follows the MockLLM-in-scenarios convention — see spec_loop.test.jac's
note.)
"""

glob SKILL_L: str = """# Migrate residue
Confirm whether it needs `useMemo` (only if the computation is expensive).
Resolve each against the real React binding.
it never silently guesses.
- `Router` -> emitted `const navigate = useNavigate()`; rewrite call sites.
""";

test "validate_edits attaches guarded variants keyed by the human's modality" {
    fs = [LintFinding(rule_id="r1", quote="Resolve each", kind="modality")];
    edits = [
        FixEdit(rule_id="r1", modality="do",
                old="Resolve each against the real React binding.",
                new="Always resolve each against the real React binding."),
        FixEdit(rule_id="r1", modality="maybe",
                old="Resolve each against the real React binding.",
                new="When a `this` residue appears, resolve each against the real React binding."),
        FixEdit(rule_id="r1", modality="bogus",
                old="Resolve each against the real React binding.",
                new="Never resolve anything against the real React binding at all.")
    ];
    validate_edits(SKILL_L, fs, edits);
    assert fs[0].applicable;
    assert "do" in fs[0].variants;
    assert "maybe" in fs[0].variants;
    assert "bogus" not in fs[0].variants;
    assert fs[0].old == "Resolve each against the real React binding.";
}

test "variants must share one old span; a divergent old is refused" {
    fs = [LintFinding(rule_id="r1", quote="Resolve each", kind="modality")];
    edits = [
        FixEdit(rule_id="r1", modality="do",
                old="Resolve each against the real React binding.",
                new="Always resolve each against the real React binding."),
        FixEdit(rule_id="r1", modality="maybe",
                old="Confirm whether it needs `useMemo` (only if the computation is expensive).",
                new="If needed, confirm whether it needs `useMemo` (only if the computation is expensive).")
    ];
    validate_edits(SKILL_L, fs, edits);
    assert "do" in fs[0].variants;
    assert "maybe" not in fs[0].variants;
}

test "non-verbatim old, no-change, and markerless variants are refused" {
    fs = [
        LintFinding(rule_id="r1", quote="Resolve each", kind="modality"),
        LintFinding(rule_id="r2", quote="Resolve each", kind="modality"),
        LintFinding(rule_id="r3", quote="Resolve each", kind="modality")
    ];
    edits = [
        FixEdit(rule_id="r1", modality="do",
                old="Resolve each against the correct React binding.",
                new="Always resolve each against the correct React binding."),
        FixEdit(rule_id="r2", modality="do",
                old="Resolve each against the real React binding.",
                new="Resolve each against the real React binding."),
        FixEdit(rule_id="r3", modality="do",
                old="Resolve each against the real React binding.",
                new="Map every member to the real React binding, one at a time.")
    ];
    validate_edits(SKILL_L, fs, edits);
    assert not fs[0].applicable;   # old is not verbatim ('correct' vs 'real')
    assert not fs[1].applicable;   # old == new changes nothing
    assert not fs[2].applicable;   # new states no modal force
}

test "content-preservation: no summarizing, no token loss, no bullet-block spans" {
    fs = [
        LintFinding(rule_id="r1", quote="Router", kind="modality"),
        LintFinding(rule_id="r2", quote="Router", kind="modality"),
        LintFinding(rule_id="r3", quote="useMemo", kind="modality")
    ];
    edits = [
        # summarizes the sentence away (under the length floor) -> refused
        FixEdit(rule_id="r1", modality="maybe",
                old="- `Router` -> emitted `const navigate = useNavigate()`; rewrite call sites.",
                new="If needed, wire `Router`."),
        # drops a backtick code token (`useNavigate()`) -> refused
        FixEdit(rule_id="r2", modality="maybe",
                old="- `Router` -> emitted `const navigate = useNavigate()`; rewrite call sites.",
                new="If a `Router` residue appears -> emitted `const navigate = ...`; you may rewrite the call sites now."),
        # spans a whole bullet block (more than one hard-wrap) -> refused
        FixEdit(rule_id="r3", modality="maybe",
                old="Confirm whether it needs `useMemo` (only if the computation is expensive).\nResolve each against the real React binding.\nit never silently guesses.",
                new="If needed, confirm whether it needs `useMemo` (only if the computation is expensive).\nWhen appropriate, resolve each against the real React binding.\nit never silently guesses.")
    ];
    validate_edits(SKILL_L, fs, edits);
    assert not fs[0].applicable;
    assert not fs[1].applicable;
    assert not fs[2].applicable;
}

test "punctuation wreckage is refused; honest abbreviations are not" {
    assert _mangled("You must **verify the deps array**. (it defaults) and You must confirm timing.");
    assert _mangled("You must subscribe inside a `useEffect`., unsubscribe in the returned cleanup");
    assert _mangled("in the template. and You must read `.current`");
    assert not _mangled("a reserved-word method (e.g. `delete`) renamed; you must update its call sites.");
    assert not _mangled("If a `state` residue appears, verify the read/set rewrites: `sig()` -> `sig`.");
}

test "a faithful modality rewrite passes every preservation guard" {
    fs = [LintFinding(rule_id="r1", quote="Router", kind="modality")];
    edits = [FixEdit(rule_id="r1", modality="maybe",
                     old="- `Router` -> emitted `const navigate = useNavigate()`; rewrite call sites.",
                     new="- `Router` -> emitted `const navigate = useNavigate()`; when this residue appears, rewrite call sites.")];
    validate_edits(SKILL_L, fs, edits);
    assert fs[0].applicable;
    assert "maybe" in fs[0].variants;
}

test "apply_edits applies the CHOSEN phrasing once, skipping vanished and unchosen" {
    fs = [
        LintFinding(rule_id="r1", old="it never silently guesses.",
                    new="the harness never silently guesses.", applicable=True),
        LintFinding(rule_id="r2", old="it never silently guesses.",
                    new="MUST NOT APPLY", applicable=True),
        LintFinding(rule_id="r3", old="Resolve each against the real React binding.",
                    new="", applicable=True)
    ];
    out = apply_edits(SKILL_L, fs);
    assert "the harness never silently guesses." in out;
    assert "MUST NOT APPLY" not in out;       # r1 consumed the span
    assert "Resolve each against the real React binding." in out;   # no chosen phrasing -> untouched
}
