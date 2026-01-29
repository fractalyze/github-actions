# Knowledge Extractor Action

Extracts knowledge from merged PRs using Claude Code Action and stores in the central knowledge-graph repository.

## How It Works

1. Triggered when a PR is merged to main
2. Checks out the source repo and knowledge-graph repo
3. Analyzes each commit in the PR using Claude
4. Extracts relevant knowledge (concepts, decisions, pitfalls)
5. Updates or creates knowledge files with [[wikilinks]]
6. Commits changes to knowledge-graph repo

## Inputs

| Input | Required | Description |
|-------|----------|-------------|
| `anthropic_api_key` | Yes | Anthropic API key for Claude |
| `knowledge_repo_token` | Yes | PAT with write access to knowledge-graph repo |

## Usage

Add this workflow to your repository at `.github/workflows/extract-knowledge.yml`:

```yaml
name: Extract Knowledge from PR

on:
  pull_request:
    types: [closed]
    branches: [main]

jobs:
  extract-knowledge:
    if: github.event.pull_request.merged == true
    runs-on: ubuntu-latest
    steps:
      - uses: fractalyze/github-actions/knowledge-extractor@v1
        with:
          anthropic_api_key: ${{ secrets.ANTHROPIC_API_KEY }}
          knowledge_repo_token: ${{ secrets.KNOWLEDGE_REPO_TOKEN }}
```

## Required Secrets

Add these secrets to your repository:

1. **ANTHROPIC_API_KEY**: Your Anthropic API key
2. **KNOWLEDGE_REPO_TOKEN**: GitHub PAT with `repo` scope for fractalyze/knowledge-graph

## Knowledge Output

Knowledge is stored in [fractalyze/knowledge-graph](https://github.com/fractalyze/knowledge-graph) with:

- Obsidian-style [[wikilinks]]
- Frontmatter with tags, sources, file patterns
- Max 500 lines per file
- Searchable via `_meta/` indices
