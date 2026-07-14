# Tests for sigil_runtime — annex of sigil_runtime.jac (`jac test sigil_runtime.jac`).
# Pure path/slug/name helpers; no subprocess, no model.

test "module_name slugs the signature and appends the version" {
    assert module_name("PDF Extract!", 2) == "pdf_extract_v2";
    assert module_name("a b/c", 1) == "a_b_c_v1";
    assert module_name("email-extract", 1) == "email_extract_v1";
}

test "agir_name reads the frontmatter name, else slugs the head" {
    assert agir_name("name: Email-Extractor\nshape: gen") == "email_extractor";
    assert agir_name("name: \"CSV To Chart\"\n") == "csv_to_chart";
    assert agir_name("Just a plain description with no name field") == "just_a_plain_description_with_no_name_field"[:48];
}

test "repo_root points at the agent package dir and the contract loads" {
    # repo_root() is the dir that owns sigil_runtime.jac — the `src/` agent package,
    # where contracts/ and crystallized/ live as siblings. That default_contract()
    # loads is the real invariant (contracts/ resolves relative to repo_root()).
    assert repo_root().endswith("src");
    assert len(default_contract()) > 100;
}
