#!/usr/bin/env bash
# Copyright 2026 Fractalyze Inc. All rights reserved.
#
# Functional test for scripts/validate_hybrid.sh: builds a throwaway git repo
# with a .fractal-commit-lint.toml policy and a few commits, then asserts the
# script accepts conforming commits and rejects non-conforming ones.
#
# Requires: python3, git, network (installs fractalyze/fractal-lint).
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="${here}/../scripts/validate_hybrid.sh"

repo="$(mktemp -d)"
trap 'rm -rf "${repo}"' EXIT
cd "${repo}"
git init -q
git config user.email t@t; git config user.name t
git config commit.gpgsign false

# Codegen/Emitters has no [scopes] alias, so a title naming 'codegen' exercises
# the ancestor waiver rather than the alias path.
mkdir -p src/Field tests/Field src/Codegen/Emitters
cat > .fractal-commit-lint.toml <<'TOML'
roots = ["src"]
require_scope = false
[scopes]
field = ["src/Field", "tests/Field"]
TOML
git add .; git commit -q -m "chore: seed policy" -m "Seed the scope policy for the test repo."
base="$(git rev-parse HEAD)"

flv="${FRACTAL_LINT_VERSION:-v0.8.0}"

# stage_commit <file> <subject> <body|->
stage_commit() {
  mkdir -p "$(dirname "$1")"; echo "a change" >> "$1"; git add "$1"
  if [[ "$3" == "-" ]]; then git commit -q -m "$2"; else git commit -q -m "$2" -m "$3"; fi
}

# expect <expected_rc> <label> <pr_title> [expected_substring]
# Runs the script over base..HEAD, asserts, then rewinds so the next case starts
# from the seeded policy commit with its file gone.
expect() {
  local head rc=0; head="$(git rev-parse HEAD)"
  INPUT_FRACTAL_LINT_VERSION="${flv}" PR_TITLE="$3" \
    INPUT_BASE_SHA="${base}" INPUT_HEAD_SHA="${head}" \
    bash "${script}" >/tmp/clh_out 2>&1 || rc=$?
  if [[ "${rc}" -ne "$1" ]]; then
    echo "FAIL: $2 expected rc=$1 got rc=${rc}"; cat /tmp/clh_out; exit 1
  fi
  if [[ -n "${4:-}" ]] && ! grep -q -- "$4" /tmp/clh_out; then
    echo "FAIL: $2 expected output to mention '$4'"; cat /tmp/clh_out; exit 1
  fi
  echo "ok (rc=${rc}): $2"
  git reset -q --hard "${base}"
}

# run_case <expected_rc> <subject> <body|-> <file>
# Empty PR_TITLE, so the title step has nothing to lint and only the commit
# messages decide the outcome.
run_case() {
  stage_commit "$4" "$2" "$3"
  expect "$1" "'$2'" ""
}

# run_title_case <expected_rc> <pr_title> <commit_subject> [expected_substring]
# The commit is always conforming, so only the title can change the outcome.
run_title_case() {
  stage_commit "${CODEGEN}" "$3" "${B}"
  expect "$1" "title '$2'" "$2" "${4:-}"
}

B="Explain why, on its own line."
# One path per scope is enough: expect() rewinds to base after every case, taking
# the staged file with it.
CODEGEN=src/Codegen/Emitters/a.cc

# blessed [scopes] alias, lowercase summary, files under the scope -> pass
run_case 0 "feat(field): add shape-aware lowering" "$B" src/Field/a.cc
# directory-fallback scope: derived from a real dir under roots, with no alias
# covering it. The scope is the DERIVED form (roots stripped, camel_to_snake), so
# the raw path 'src/Codegen/Emitters' would not match.
run_case 0 "feat(codegen/emitters): add shape-aware lowering" "$B" "${CODEGEN}"
# uppercase summary -> header-case failure
run_case 1 "feat(field): Add shape-aware lowering" "$B" src/Field/c.cc
# unknown scope (no map entry, not a real dir) -> scope-enum failure
run_case 1 "feat(bogus): add shape-aware lowering" "$B" src/Field/d.cc
# missing body -> body-missing failure
run_case 1 "feat(field): add shape-aware lowering" - src/Field/e.cc

# --- PR title ---
# Every title case stages the same file under the same scope, so the title is the
# only variable; CS is the conforming commit subject that file's scope requires.
CS="feat(codegen/emitters): add shape-aware lowering"

# A title is a lone header: it never has a body, so passing at all proves the
# body rules are not applied to it.
run_title_case 0 "feat(codegen/emitters): add shape-aware lowering" "${CS}"
# Ancestor of the canonical scope, and not a [scopes] alias -> waived for a title.
run_title_case 0 "feat(codegen): add shape-aware lowering" "${CS}"
# The same scope on a COMMIT is still too broad — the waiver is title-only.
run_case 1 "feat(codegen): add shape-aware lowering" "$B" "${CODEGEN}"
# A scope that does not contain the changed files is still rejected.
run_title_case 1 "feat(bogus): add shape-aware lowering" "${CS}" "scope-enum"
# Header rules still apply to the title.
run_title_case 1 "frob(codegen/emitters): add shape-aware lowering" "${CS}" "header-type"
run_title_case 1 "feat(codegen/emitters): Add shape-aware lowering" "${CS}" "header-case"
run_title_case 1 "feat(codegen/emitters): add shape-aware lowering." "${CS}" "header-period"
# A bad title fails the run even though every commit is conforming.
run_title_case 1 "not a conventional title" "${CS}" "header-format"
# git generates the "This reverts commit <SHA>." body, so a revert TITLE lacking
# it must still pass.
run_title_case 0 "revert: feat(codegen/emitters): add shape-aware lowering" "${CS}"

echo "ALL HYBRID TESTS PASSED"
