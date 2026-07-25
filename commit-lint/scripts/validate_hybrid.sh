#!/usr/bin/env bash
# Copyright 2026 Fractalyze Inc. All rights reserved.
#
# Hybrid scope validation for `scope_mode: hybrid`.
#
# Runs fractal-commit-lint (the SAME tool as the local pre-commit hook) over the
# PR title and every non-merge commit, enforcing the repo's
# .fractal-commit-lint.toml policy: a scope is a curated [scopes] alias OR
# (fallback) any real directory under `roots`.
#
# Title and commits are staged differently because the scope each should name
# differs: a commit against its own diff, the title against the union diff of the
# whole PR. --header-only is what lets a lone title be judged at all.
#
# This path is invoked ONLY when scope_mode is "hybrid"; the "auto" and "manual"
# modes stay on scripts/validate.sh, which is left byte-for-byte unchanged.
# Requires the repo checked out at the PR head (action.yml does that, gated to
# hybrid mode) so the tool can read .fractal-commit-lint.toml and each commit's
# staged files.
set -euo pipefail

fractal_lint_version="${INPUT_FRACTAL_LINT_VERSION:-v0.8.0}"
base_sha="${INPUT_BASE_SHA:?INPUT_BASE_SHA is required for hybrid mode}"
head_sha="${INPUT_HEAD_SHA:?INPUT_HEAD_SHA is required for hybrid mode}"
pr_title="${PR_TITLE:-}"

workdir="$(mktemp -d)"
trap 'rm -rf "${workdir}"' EXIT
python3 -m venv "${workdir}/venv"
"${workdir}/venv/bin/pip" install --quiet \
  "fractal-lint @ git+https://github.com/fractalyze/fractal-lint@${fractal_lint_version}"
fcl="${workdir}/venv/bin/fractal-commit-lint"

rc=0

# --header-only landed in fractal-lint v0.8.0. Older pins make argparse exit
# non-zero on the unknown flag, which would read as a lint failure on a title
# that is actually fine — so name the real problem instead.
if ! "${fcl}" --help 2>&1 | grep -q -- "--header-only"; then
  echo "commit-lint: fractal_lint_version '${fractal_lint_version}' has no" \
       "--header-only; PR-title linting needs v0.8.0 or newer." >&2
  exit 1
fi

echo "=== Validating PR title ==="
if [[ -z "${pr_title}" ]]; then
  echo "No PR title supplied — skipping."
else
  # Stage the union diff of the PR so the title's scope derives from every file
  # it describes: head's tree in the index, base as HEAD.
  git checkout -q -f "${head_sha}"
  git reset -q --soft "${base_sha}"
  printf '%s\n' "${pr_title}" > "${workdir}/pr_title"
  "${fcl}" --header-only "${workdir}/pr_title" || rc=1
fi

echo ""
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
