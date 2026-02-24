# Fractalyze GitHub Actions

Shared GitHub Actions for fractalyze organization.

## Available Actions

### knowledge-extractor

Extracts knowledge from merged PRs and stores in the central knowledge-graph repository.

**Usage:**

```yaml
- uses: fractalyze/github-actions/knowledge-extractor@v1
  with:
    anthropic_api_key: ${{ secrets.ANTHROPIC_API_KEY }}
    knowledge_repo_token: ${{ secrets.KNOWLEDGE_REPO_TOKEN }}
```

See [knowledge-extractor/README.md](./knowledge-extractor/README.md) for details.

### commit-lint

Validates PR title and commit messages against the [conventional commit format](https://github.com/fractalyze/.github/blob/main/COMMIT_MESSAGE_GUIDELINE.md).

**Usage:**

```yaml
- uses: fractalyze/github-actions/commit-lint@main
  with:
    github_token: ${{ secrets.GITHUB_TOKEN }}
    scopes: >-
      backends backends/cpu backends/gpu
      hlo hlo/ir hlo/pass
```

| Input          | Required | Description                                                    |
| -------------- | -------- | -------------------------------------------------------------- |
| `github_token` | yes      | GitHub token for API access                                    |
| `scopes`       | no       | Space-separated allowed scopes (empty = skip scope validation) |
