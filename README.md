# Fractalyze GitHub Actions

Shared GitHub Actions for fractalyze organization.

## Available Actions

### merge-digest

Posts a digest of pull requests merged across the whole org to a Slack DM or
channel, on a schedule. Runs from one repository, not per repo.

**Usage:**

```yaml
- uses: fractalyze/github-actions/merge-digest@main
  with:
    github_token: ${{ secrets.ORG_READ_TOKEN }}
    slack_bot_token: ${{ secrets.SLACK_BOT_TOKEN }}
    slack_target: ${{ secrets.SLACK_DIGEST_TARGET }}
    exclude_authors: fractalyze-dev
```

Defaults to a per-repo listing with no LLM call; set `mode: summarize` with an
`anthropic_api_key` to prepend a Claude briefing that reads across repositories.

See [merge-digest/README.md](./merge-digest/README.md) for details.

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
