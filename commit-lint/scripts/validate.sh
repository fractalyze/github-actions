#!/usr/bin/env bash
# Copyright 2026 Fractalyze Inc. All rights reserved.
#
# Validates PR title and commit messages against the conventional commit format
# defined in COMMIT_MESSAGE_GUIDELINE.md.
#
# Required env vars:
#   GH_TOKEN     - GitHub token for API access
#   PR_TITLE     - Pull request title
#   PR_NUMBER    - Pull request number
#   REPO         - Repository in "owner/repo" format
#
# Optional env vars:
#   INPUT_SCOPES - Space-separated list of allowed scopes (empty = skip scope validation)

set -euo pipefail

# Org-wide standard types from COMMIT_MESSAGE_GUIDELINE.md
TYPES=(
  build chore ci docs feat fix perf refactor revert style test
)

# Repo-specific scopes from action input
SCOPES=()
if [[ -n "${INPUT_SCOPES:-}" ]]; then
  read -ra SCOPES <<< "$INPUT_SCOPES"
fi

errors=0

contains() {
  local needle="$1"
  shift
  for item in "$@"; do
    [[ "$item" == "$needle" ]] && return 0
  done
  return 1
}

validate_header() {
  local header="$1"
  local label="$2"

  # Skip merge commits
  if [[ "$header" =~ ^Merge\ (pull\ request|branch) ]]; then
    echo "⊘ ${label}: ${header}"
    echo "  Skipped (merge commit)"
    return 0
  fi

  # Handle revert: strip prefix and validate inner header
  if [[ "$header" =~ ^revert:\ (.+)$ ]]; then
    local inner="${BASH_REMATCH[1]}"
    validate_header "$inner" "${label} (revert)"
    return $?
  fi

  # Match: type(scope)!: summary
  local regex='^([a-z]+)(\(([^)]+)\))?(!)?: (.+)$'
  if ! [[ "$header" =~ $regex ]]; then
    echo "✗ ${label}: ${header}"
    echo "  Does not match format: <type>(<scope>)[!]: <summary>"
    return 1
  fi

  local type="${BASH_REMATCH[1]}"
  local scope="${BASH_REMATCH[3]}"
  local summary="${BASH_REMATCH[5]}"
  local has_error=0

  # Validate type
  if ! contains "$type" "${TYPES[@]}"; then
    echo "✗ ${label}: ${header}"
    echo "  Invalid type '${type}'. Allowed types:"
    echo "    ${TYPES[*]}"
    has_error=1
  fi

  # Validate scope (if present and scopes are configured)
  if [[ -n "$scope" ]] && [[ ${#SCOPES[@]} -gt 0 ]]; then
    if ! contains "$scope" "${SCOPES[@]}"; then
      [[ $has_error -eq 0 ]] && echo "✗ ${label}: ${header}"
      echo "  Invalid scope '${scope}'. Allowed scopes:"
      echo "${SCOPES[*]}" | fold -s -w 68 | sed 's/^/    /'
      # Suggest similar scopes
      local suggestions=()
      for s in "${SCOPES[@]}"; do
        if [[ "$s" == *"$scope"* ]]; then
          suggestions+=("$s")
        fi
      done
      if [[ ${#suggestions[@]} -gt 0 ]]; then
        local joined
        joined=$(printf '%s' "${suggestions[0]}")
        for s in "${suggestions[@]:1}"; do
          joined="${joined}, ${s}"
        done
        echo "  Did you mean: ${joined}?"
      fi
      has_error=1
    fi
  fi

  # Validate summary: no uppercase start
  if [[ "$summary" =~ ^[A-Z] ]]; then
    [[ $has_error -eq 0 ]] && echo "✗ ${label}: ${header}"
    echo "  Summary must not start with an uppercase letter"
    has_error=1
  fi

  # Validate summary: no trailing period
  if [[ "$summary" =~ \.$ ]]; then
    [[ $has_error -eq 0 ]] && echo "✗ ${label}: ${header}"
    echo "  Summary must not end with a period"
    has_error=1
  fi

  if [[ $has_error -eq 0 ]]; then
    echo "✓ ${label}: ${header}"
  fi

  return $has_error
}

echo "=== Validating PR title ==="
if ! validate_header "$PR_TITLE" "PR title"; then
  errors=$((errors + 1))
fi

echo ""
echo "=== Validating commit messages ==="

i=0
while IFS= read -r header; do
  [[ -z "$header" ]] && continue
  i=$((i + 1))
  if ! validate_header "$header" "Commit ${i}"; then
    errors=$((errors + 1))
  fi
done < <(gh api "repos/${REPO}/pulls/${PR_NUMBER}/commits" \
  --paginate --jq '.[].commit.message | split("\n")[0]')

echo ""
total=$((i + 1))
if [[ $errors -gt 0 ]]; then
  echo "Found ${errors} error(s) in ${total} messages."
  exit 1
else
  echo "All ${total} messages passed."
fi
