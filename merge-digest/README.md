# Merge Digest Action

Posts a digest of pull requests merged across the whole org to a Slack DM or
channel, on a schedule.

## How It Works

1. A cron workflow in one repo triggers the action — this is org-wide, so it
   runs once centrally rather than per repository.
2. One search query collects everything merged in the window across every repo
   in the org.
3. PRs by `[bot]` authors, and by any login in `exclude_authors`, are dropped.
4. The remainder is grouped by repository, busiest first.
5. In `summarize` mode, Claude also writes a briefing that can connect activity
   across repositories; the per-repo listing is kept underneath it either way.
6. The message is posted via `chat.postMessage`, opening a DM channel first when
   the target is a user ID.

Merged pull requests are the unit, not raw commits: PR titles are already
written for humans, one search call covers every repo, and merge commits and
squashed intermediate commits stay out of the digest.

## Modes

| Mode | What you get | Cost |
| --- | --- | --- |
| `list` (default) | Per-repo listing of merged PR titles, authors, links | none |
| `summarize` | The above, plus a Claude briefing above it | one Claude request per run |

Start on `list`. It needs no Anthropic key and no spend, and it already answers
"what shipped". Switch to `summarize` when you want the cross-repo reading.

At ~26 merged PRs a day, a `summarize` run sends roughly 4K input tokens and
returns 1–3K, so a daily digest lands near $1–4 a month depending on `model`.
`effort` defaults to `low` to keep it at the bottom of that range; thinking is
left on because Claude Opus 5 can leak `<thinking>` tags into the answer when
it is disabled. Set `model: claude-haiku-4-5` to cut it to well under a dollar.

## Inputs

| Input | Required | Default | Description |
| --- | --- | --- | --- |
| `slack_bot_token` | Yes | — | Slack bot token (`xoxb-`) with `chat:write` and `im:write` |
| `slack_target` | Yes | — | Slack user ID (`U…`) to DM, or channel ID (`C…`) |
| `github_token` | Yes | — | Token with **org-wide** read access — see below |
| `org` | No | current org | GitHub org to scan |
| `since_hours` | No | `24` | Look-back window; match it to the cron interval |
| `mode` | No | `list` | `list` or `summarize` |
| `exclude_authors` | No | — | Comma-separated logins to omit (machine users) |
| `anthropic_api_key` | No | — | Required when `mode: summarize` |
| `model` | No | `claude-opus-5` | Claude model for the summary |
| `effort` | No | `low` | Claude effort level |
| `skip_if_empty` | No | `true` | Post nothing when the window is empty |
| `dry_run` | No | `false` | Print the Slack blocks to the log instead of posting |

## Usage

See [examples/merge-digest.yml](./examples/merge-digest.yml) for the full
workflow. The short version:

```yaml
on:
  schedule:
    - cron: '0 23 * * 1-5'

jobs:
  digest:
    runs-on: ubuntu-latest
    steps:
      - uses: fractalyze/github-actions/merge-digest@main
        with:
          github_token: ${{ secrets.ORG_READ_TOKEN }}
          slack_bot_token: ${{ secrets.SLACK_BOT_TOKEN }}
          slack_target: ${{ secrets.SLACK_DIGEST_TARGET }}
          exclude_authors: fractalyze-dev
```

## Required Secrets

1. **`ORG_READ_TOKEN`** — `secrets.GITHUB_TOKEN` is scoped to the single
   repository running the workflow, so it cannot see the rest of the org. Use a
   GitHub App installation token (survives personnel changes and PAT expiry) or
   a fine-grained PAT with read access to org repositories.
2. **`SLACK_BOT_TOKEN`** — create a Slack app, add the `chat:write` and
   `im:write` bot scopes, install it to the workspace, and copy the `xoxb-`
   token. Incoming webhooks cannot open a DM, so a bot token is required.
3. **`SLACK_DIGEST_TARGET`** — your Slack member ID, from Slack profile →
   ⋮ → *Copy member ID*. A secret rather than an input so the workflow file does
   not name an individual.
4. **`ANTHROPIC_API_KEY`** — only for `mode: summarize`.

## Picking a Cadence

`since_hours` must match the cron interval or PRs get double-reported or
missed. A daily digest is a reasonable default; at 150+ merges a week a weekly
run produces a wall of titles that is harder to read than the PR list itself.

Cron runs on UTC and GitHub delays scheduled jobs under load, so treat the
window as approximate. Overlapping it slightly (`since_hours: 25` on a daily
cron) re-reports a boundary PR occasionally but never drops one.

## Limits

- GitHub's search API stops paging at 1000 results. A window that exceeds it
  logs a warning naming the shortfall rather than silently truncating.
- Slack allows 50 blocks per message and 3000 characters per block. Beyond that
  the listing is cut with a note saying how many repositories were omitted.
- Search indexing is eventually consistent — a PR merged seconds before the run
  may land in the next digest.
