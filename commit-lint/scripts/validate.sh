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
#   INPUT_SCOPE_MODE     - "manual" (default) or "auto"
#   INPUT_SCOPES         - Space-separated allowed scopes (manual mode)
#   INPUT_SCOPE_PREFIXES - Space-separated dir prefixes to strip (auto mode)

set -euo pipefail

# Org-wide standard types from COMMIT_MESSAGE_GUIDELINE.md
TYPES=(
  build chore ci docs feat fix perf refactor revert style test
)

SCOPE_MODE="${INPUT_SCOPE_MODE:-manual}"

# Manual mode: repo-specific scopes from action input
SCOPES=()
if [[ -n "${INPUT_SCOPES:-}" ]]; then
  read -ra SCOPES <<< "$INPUT_SCOPES"
fi

# Auto mode: directory prefixes to strip
PREFIXES=()
if [[ -n "${INPUT_SCOPE_PREFIXES:-}" ]]; then
  read -ra PREFIXES <<< "$INPUT_SCOPE_PREFIXES"
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

# ---------------------------------------------------------------------------
# Auto scope derivation
# ---------------------------------------------------------------------------

# Finds longest common directory prefix of two slash-separated paths.
#   common_dir_prefix "backends/gpu" "backends/cpu" → "backends"
#   common_dir_prefix "hlo/ir" "hlo/ir"             → "hlo/ir"
#   common_dir_prefix "hlo" "mlir"                   → ""
common_dir_prefix() {
  local a="$1" b="$2"
  IFS='/' read -ra pa <<< "$a"
  IFS='/' read -ra pb <<< "$b"

  local -a result=()
  local len=${#pa[@]}
  (( ${#pb[@]} < len )) && len=${#pb[@]}

  for (( i = 0; i < len; i++ )); do
    if [[ "${pa[$i]}" == "${pb[$i]}" ]]; then
      result+=("${pa[$i]}")
    else
      break
    fi
  done

  local IFS='/'
  echo "${result[*]}"
}

# Derives expected scope from file paths.
#   Reads newline-separated file list from $1.
#   Prints scope string (empty = scope should be omitted).
derive_scope() {
  local files="$1"
  local -a dirs=()

  while IFS= read -r file; do
    [[ -z "$file" ]] && continue

    # Try to match and strip a prefix
    local stripped=""
    for prefix in "${PREFIXES[@]}"; do
      if [[ "$file" == "${prefix}/"* ]]; then
        stripped="${file#"${prefix}/"}"
        break
      fi
    done
    [[ -z "$stripped" ]] && continue

    # Extract directory components (skip files at prefix root)
    local dir
    dir="$(dirname "$stripped")"
    [[ "$dir" == "." ]] && continue

    # Take up to 2 directory levels
    IFS='/' read -ra parts <<< "$dir"
    local key="${parts[0]}"
    if (( ${#parts[@]} >= 2 )); then
      key="${parts[0]}/${parts[1]}"
    fi
    dirs+=("$key")
  done <<< "$files"

  if (( ${#dirs[@]} == 0 )); then
    return
  fi

  # Fold with common_dir_prefix
  local result="${dirs[0]}"
  for entry in "${dirs[@]:1}"; do
    result="$(common_dir_prefix "$result" "$entry")"
    [[ -z "$result" ]] && break
  done

  echo "$result"
}

get_pr_files() {
  gh api "repos/${REPO}/pulls/${PR_NUMBER}/files" \
    --paginate --jq '.[].filename'
}

get_commit_files() {
  local sha="$1"
  gh api "repos/${REPO}/commits/${sha}" --jq '.files[].filename'
}

# ---------------------------------------------------------------------------
# Header validation
# ---------------------------------------------------------------------------

# Validates a commit/PR header.
#   $1 - header string
#   $2 - label (e.g. "PR title", "Commit 1 (3a1b2c3)")
#   $3 - expected scope (auto mode only; omit for manual mode)
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
    validate_header "$inner" "${label} (revert)" "${3-}"
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

  # Validate scope
  if [[ "$SCOPE_MODE" == "auto" ]]; then
    local expected="${3-}"
    if [[ -n "$expected" ]]; then
      if [[ -z "$scope" ]]; then
        [[ $has_error -eq 0 ]] && echo "✗ ${label}: ${header}"
        echo "  Missing scope. Changed files suggest: '${expected}'"
        has_error=1
      elif [[ "$scope" != "$expected" ]]; then
        [[ $has_error -eq 0 ]] && echo "✗ ${label}: ${header}"
        echo "  Scope '${scope}' does not match changed files. Expected: '${expected}'"
        has_error=1
      fi
    else
      if [[ -n "$scope" ]]; then
        [[ $has_error -eq 0 ]] && echo "✗ ${label}: ${header}"
        echo "  Unexpected scope '${scope}'. Changed files don't share a common directory"
        has_error=1
      fi
    fi
  elif [[ "$SCOPE_MODE" == "manual" ]]; then
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

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

echo "=== Validating PR title ==="
if [[ "$SCOPE_MODE" == "auto" ]]; then
  pr_files="$(get_pr_files)"
  pr_scope="$(derive_scope "$pr_files")"
  if ! validate_header "$PR_TITLE" "PR title" "$pr_scope"; then
    errors=$((errors + 1))
  fi
else
  if ! validate_header "$PR_TITLE" "PR title"; then
    errors=$((errors + 1))
  fi
fi

echo ""
echo "=== Validating commit messages ==="

i=0
if [[ "$SCOPE_MODE" == "auto" ]]; then
  while IFS=$'\t' read -r sha header; do
    [[ -z "$sha" ]] && continue
    i=$((i + 1))
    commit_files="$(get_commit_files "$sha")"
    commit_scope="$(derive_scope "$commit_files")"
    short="${sha:0:7}"
    if ! validate_header "$header" "Commit ${i} (${short})" "$commit_scope"; then
      errors=$((errors + 1))
    fi
  done < <(gh api "repos/${REPO}/pulls/${PR_NUMBER}/commits" \
    --paginate --jq '.[] | .sha + "\t" + (.commit.message | split("\n")[0])')
else
  while IFS= read -r header; do
    [[ -z "$header" ]] && continue
    i=$((i + 1))
    if ! validate_header "$header" "Commit ${i}"; then
      errors=$((errors + 1))
    fi
  done < <(gh api "repos/${REPO}/pulls/${PR_NUMBER}/commits" \
    --paginate --jq '.[].commit.message | split("\n")[0]')
fi

echo ""
total=$((i + 1))
if [[ $errors -gt 0 ]]; then
  echo "Found ${errors} error(s) in ${total} messages."
  exit 1
else
  echo "All ${total} messages passed."
fi
