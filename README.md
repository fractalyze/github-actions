# Fractalyze GitHub Actions

Shared GitHub Actions for fractalyze organization.

## Available Actions

### knowledge-extractor

Extracts knowledge from merged PRs and stores in the central knowledge-graph
repository.

**Usage:**

```yaml
- uses: fractalyze/github-actions/knowledge-extractor@v1
  with:
    anthropic_api_key: ${{ secrets.ANTHROPIC_API_KEY }}
    knowledge_repo_token: ${{ secrets.KNOWLEDGE_REPO_TOKEN }}
```

See [knowledge-extractor/README.md](./knowledge-extractor/README.md) for
details.

### commit-lint

Validates PR title and commit messages against the
[conventional commit format](https://github.com/fractalyze/.github/blob/main/COMMIT_MESSAGE_GUIDELINE.md).

Two scope validation modes:

- **manual** — validate scope against a provided list (for semantic scopes)
- **auto** — derive expected scope from changed file paths (for directory-based
  scopes)

**Manual mode** (e.g., prime-ir — scopes are semantic):

```yaml
- uses: fractalyze/github-actions/commit-lint@main
  with:
    github_token: ${{ secrets.GITHUB_TOKEN }}
    scopes: 'field ec ntt msm'
```

**Auto mode** (e.g., zkx — scopes match directory structure):

```yaml
- uses: fractalyze/github-actions/commit-lint@main
  with:
    github_token: ${{ secrets.GITHUB_TOKEN }}
    scope_mode: auto
    scope_prefixes: 'zkx xla'
```

| Input            | Required | Description                                     |
| ---------------- | -------- | ----------------------------------------------- |
| `github_token`   | yes      | GitHub token for API access                     |
| `scope_mode`     | no       | `manual` (default) or `auto`                    |
| `scopes`         | no       | Space-separated allowed scopes (manual mode)    |
| `scope_prefixes` | no       | Directory prefixes to strip for auto derivation |

### bzlmod-pin-sync

Syncs a bzlmod `git_override` commit pin — and the pip pin that has to match it —
onto one force-pushed branch, then creates or refreshes a single bump PR.

The bzlmod sibling of `pin-bump`. That one rewrites `<PREFIX>_COMMIT` /
`<PREFIX>_SHA256` in a `workspace.bzl`; a bzlmod consumer pins through a
`git_override` commit and carries a `MODULE.bazel.lock` only `bazel mod deps` can
refresh, so the file surgery and the lock refresh differ entirely.

**Both pins move in one commit.** An upstream Bazel module resolves its own pip
dependencies from its own lock, so bumping one side alone puts two copies of the
same package on a single test's `sys.path` — which surfaces as a dtype error
inside an unrelated test rather than as a version conflict. `paired_package` is
read from the upstream `requirements.in` **at the target commit**, so the answer
is what the consumer must match rather than whatever was published most recently.

**One branch, force-pushed.** A branch per upstream commit cannot update an open
PR, so it accumulates one PR per upstream commit — each staler than the last, each
burning a CI run, with the pin worth merging at the bottom of the list.
Re-cutting from the checked-out base also rebases for free.

**Usage** (the caller owns its triggers; the runner needs bazel):

```yaml
- uses: actions/checkout@v4
  with:
    token: ${{ secrets.BUMPER_GH_PAT }}
- uses: fractalyze/github-actions/bzlmod-pin-sync@main
  with:
    upstream_repo: hash-frx
    module_name: hash_frx
    paired_package: frx
    github_token: ${{ secrets.BUMPER_GH_PAT }}
```

| Input                        | Required | Description                                              |
| ---------------------------- | -------- | -------------------------------------------------------- |
| `upstream_repo`              | yes      | Upstream repo name under fractalyze                      |
| `module_name`                | yes      | Bazel module name of the dep                             |
| `paired_package`             | no       | pip package to keep in step; empty syncs the commit only |
| `requirements_in`            | no       | pip requirements source (`requirements.in`)              |
| `requirements_lock`          | no       | compiled lock (`requirements_lock_3_11.txt`)             |
| `requirements_update_target` | no       | lock recompile target (`//:requirements.update`)         |
| `base_branch`                | no       | branch the PR targets (`main`)                           |
| `github_token`               | yes      | PAT with repo scope for push and PR creation             |
