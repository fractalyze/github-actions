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

mkdir -p src/Field tests/Field
cat > .fractal-commit-lint.toml <<'TOML'
roots = ["src"]
require_scope = false
[scopes]
field = ["src/Field", "tests/Field"]
TOML
git add .; git commit -q -m "chore: seed policy" -m "Seed the scope policy for the test repo."
base="$(git rev-parse HEAD)"

# run_case <expected_rc> <subject> <body|-> <file>
run_case() {
  mkdir -p "$(dirname "$4")"; echo "field change" >> "$4"; git add "$4"
  if [[ "$3" == "-" ]]; then git commit -q -m "$2"; else git commit -q -m "$2" -m "$3"; fi
  local head; head="$(git rev-parse HEAD)" rc=0
  INPUT_FRACTAL_LINT_VERSION="${FRACTAL_LINT_VERSION:-v0.5.0}" \
    INPUT_BASE_SHA="${base}" INPUT_HEAD_SHA="${head}" \
    bash "${script}" >/tmp/clh_out 2>&1 || rc=$?
  if [[ "${rc}" -ne "$1" ]]; then
    echo "FAIL: '$2' expected rc=$1 got rc=${rc}"; cat /tmp/clh_out; exit 1
  fi
  echo "ok (rc=${rc}): $2"
  git reset -q --hard "${base}"
}

B="Explain why, on its own line."
# blessed [scopes] alias, lowercase summary, files under the scope -> pass
run_case 0 "feat(field): add shape-aware lowering" "$B" src/Field/a.cc
# directory-fallback scope (src/Field is a real dir under roots) -> pass
run_case 0 "feat(src/Field): add shape-aware lowering" "$B" src/Field/b.cc
# uppercase summary -> header-case failure
run_case 1 "feat(field): Add shape-aware lowering" "$B" src/Field/c.cc
# unknown scope (no map entry, not a real dir) -> scope-enum failure
run_case 1 "feat(bogus): add shape-aware lowering" "$B" src/Field/d.cc
# missing body -> body-missing failure
run_case 1 "feat(field): add shape-aware lowering" - src/Field/e.cc

echo "ALL HYBRID TESTS PASSED"
