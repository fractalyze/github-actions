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
