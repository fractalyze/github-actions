#!/usr/bin/env bash
# Copyright 2026 Fractalyze Inc. All rights reserved.
#
# Hybrid scope validation for `scope_mode: hybrid`.
#
# Runs fractal-commit-lint (the SAME tool as the local pre-commit hook) over the
# PR title and every non-merge commit, enforcing the repo's
# .fractal-commit-lint.toml policy: a scope is a curated [scopes] alias OR
# (fallback) any real directory under `roots`, with scope-path / scope-too-broad
# checked against each commit's own diff.
#
# This path is invoked ONLY when scope_mode is "hybrid"; the "auto" and "manual"
# modes stay on scripts/validate.sh, which is left byte-for-byte unchanged.
# Requires the repo checked out at the PR head (action.yml does that, gated to
# hybrid mode) so the tool can read .fractal-commit-lint.toml and each commit's
# staged files.
set -euo pipefail

fractal_lint_version="${INPUT_FRACTAL_LINT_VERSION:-v0.5.0}"
base_sha="${INPUT_BASE_SHA:?INPUT_BASE_SHA is required for hybrid mode}"
head_sha="${INPUT_HEAD_SHA:?INPUT_HEAD_SHA is required for hybrid mode}"

workdir="$(mktemp -d)"
trap 'rm -rf "${workdir}"' EXIT
python3 -m venv "${workdir}/venv"
"${workdir}/venv/bin/pip" install --quiet \
  "fractal-lint @ git+https://github.com/fractalyze/fractal-lint@${fractal_lint_version}"
fcl="${workdir}/venv/bin/fractal-commit-lint"

rc=0

# NOTE: hybrid mode validates commit messages only, not the PR title.
# fractal-commit-lint enforces `body-missing` (a non-docs commit needs a body),
# which a single-line PR title can never satisfy, and the tool has no
# header-only mode. This mirrors the local pre-commit hook, which lints commit
# messages (commit-msg stage), never the PR title. Repos that also want PR-title
# linting can add a second commit-lint step in auto/manual mode for the title,
# or fractal-lint can grow a `--header-only` flag (follow-up).

echo "=== Validating commit messages ==="
# Lint each non-merge commit with its own files staged, so scope-path and
# scope-too-broad run against the commit's actual diff (not just scope-enum).
for sha in $(git rev-list --reverse --no-merges "${base_sha}..${head_sha}"); do
  git checkout -q -f "${sha}"
  git reset -q --soft "${sha}^"
  git log -1 --format=%B "${sha}" > "${workdir}/commit_msg"
  echo "== ${sha:0:7} =="
  "${fcl}" "${workdir}/commit_msg" || rc=1
done

echo ""
if [[ "${rc}" -ne 0 ]]; then
  echo "Commit lint (hybrid) found errors."
else
  echo "All messages passed (hybrid)."
fi
exit "${rc}"
