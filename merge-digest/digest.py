#!/usr/bin/env python3
# Copyright 2026 Fractalyze Inc. All rights reserved.
"""Collect pull requests merged across a GitHub org and post them to Slack.

Stdlib only — the action runs this on a bare `ubuntu-latest` with no install step.

Two rendering paths:

  list       group merged PRs by repository and post the titles as-is. No LLM,
             no cost.
  summarize  additionally ask Claude for a prose digest that can draw
             connections a per-repo listing cannot ("three repos all moved to
             the new sumcheck API"). Costs one Claude request per run.
"""

from __future__ import annotations

import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timedelta, timezone

GITHUB_API = "https://api.github.com"
SLACK_API = "https://slack.com/api"
ANTHROPIC_API = "https://api.anthropic.com/v1/messages"

# GitHub's search endpoint refuses to page past 1000 results.
SEARCH_PAGE_SIZE = 100
SEARCH_MAX_PAGES = 10

# Slack caps a message at 50 blocks and a text object at 3000 characters.
SLACK_MAX_BLOCKS = 50
SLACK_MAX_TEXT = 3000


class DigestError(RuntimeError):
    """Fatal misconfiguration or upstream failure — reported without a traceback."""


# --------------------------------------------------------------------------- http


def _request(url: str, *, headers: dict[str, str], data: dict | None = None) -> dict:
    body = json.dumps(data).encode() if data is not None else None
    req = urllib.request.Request(url, data=body, headers=headers, method="POST" if body else "GET")
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            return json.loads(resp.read().decode())
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode(errors="replace")[:500]
        raise DigestError(f"{exc.code} from {urllib.parse.urlparse(url).path}: {detail}") from exc
    except urllib.error.URLError as exc:
        raise DigestError(f"could not reach {urllib.parse.urlparse(url).netloc}: {exc.reason}") from exc


# ------------------------------------------------------------------------- github


def fetch_merged_prs(org: str, since: datetime, token: str) -> tuple[list[dict], int]:
    """Return (pull requests merged since `since`, total the search reported).

    A total larger than the returned list means the 1000-result search ceiling
    truncated the window — the caller surfaces that rather than hiding it.
    """
    query = f"org:{org} is:pr is:merged merged:>={since.strftime('%Y-%m-%dT%H:%M:%SZ')}"
    headers = {
        "Authorization": f"Bearer {token}",
        "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
    }

    prs: list[dict] = []
    total = 0
    for page in range(1, SEARCH_MAX_PAGES + 1):
        params = urllib.parse.urlencode(
            {"q": query, "per_page": SEARCH_PAGE_SIZE, "page": page, "sort": "updated"}
        )
        payload = _request(f"{GITHUB_API}/search/issues?{params}", headers=headers)
        total = payload.get("total_count", 0)
        items = payload.get("items", [])
        for item in items:
            prs.append(
                {
                    # repository_url is the only repo handle the search API returns.
                    "repo": item["repository_url"].rsplit("/", 1)[-1],
                    "number": item["number"],
                    "title": item["title"],
                    "url": item["html_url"],
                    "author": (item.get("user") or {}).get("login", "unknown"),
                    "merged_at": (item.get("pull_request") or {}).get("merged_at") or "",
                    "body": item.get("body") or "",
                }
            )
        if len(items) < SEARCH_PAGE_SIZE:
            break

    prs.sort(key=lambda pr: (pr["repo"].lower(), pr["number"]))
    return prs, total


def group_by_repo(prs: list[dict]) -> dict[str, list[dict]]:
    grouped: dict[str, list[dict]] = {}
    for pr in prs:
        grouped.setdefault(pr["repo"], []).append(pr)
    # Busiest repo first — that is where a reader's attention is best spent.
    return dict(sorted(grouped.items(), key=lambda kv: (-len(kv[1]), kv[0].lower())))


# -------------------------------------------------------------------------- claude


def summarize(prs: list[dict], *, api_key: str, model: str, effort: str) -> str:
    """Ask Claude for a Slack-mrkdwn digest. Returns '' if it produces no text."""
    lines = [f"[{pr['repo']}#{pr['number']}] {pr['title']} (@{pr['author']})" for pr in prs]
    prompt = (
        "Below are the pull requests merged across our engineering org since the "
        "last digest. Write a briefing for an engineer catching up.\n\n"
        "Lead with the two or three things that matter most across the whole org — "
        "themes that span repositories, notable landings, anything that changes what "
        "someone should do next. Then, if useful, a short per-area note. Skip "
        "routine dependency bumps and formatting unless they are the only activity.\n\n"
        "Format for Slack: *bold* for emphasis, `code` for identifiers, plain "
        "hyphens for lists. Slack renders neither markdown headers nor **double "
        "asterisks**, so use neither. No preamble — start with the content.\n\n"
        f"Merged pull requests ({len(prs)}):\n" + "\n".join(lines)
    )

    payload = {
        "model": model,
        "max_tokens": 16000,
        # Adaptive thinking rather than disabling it: on Claude Opus 5 a disabled
        # -thinking request can leak <thinking> tags into the visible answer, and
        # low effort already keeps the spend down.
        "thinking": {"type": "adaptive"},
        "output_config": {"effort": effort},
        "messages": [{"role": "user", "content": prompt}],
    }
    response = _request(
        ANTHROPIC_API,
        headers={
            "x-api-key": api_key,
            "anthropic-version": "2023-06-01",
            "content-type": "application/json",
        },
        data=payload,
    )

    # A safety classifier can decline with HTTP 200 and an empty content array,
    # so the stop reason has to be checked before reading the blocks.
    if response.get("stop_reason") == "refusal":
        print("::warning::Claude declined to summarize; posting the plain listing", file=sys.stderr)
        return ""

    usage = response.get("usage", {})
    print(
        f"Claude usage: {usage.get('input_tokens', 0)} in / "
        f"{usage.get('output_tokens', 0)} out ({response.get('model', model)})",
        file=sys.stderr,
    )
    return "\n".join(
        block["text"] for block in response.get("content", []) if block.get("type") == "text"
    ).strip()


# --------------------------------------------------------------------------- slack


def _truncate(text: str, limit: int = SLACK_MAX_TEXT) -> str:
    return text if len(text) <= limit else text[: limit - 1].rstrip() + "…"


def build_blocks(
    grouped: dict[str, list[dict]], *, total: int, window: str, summary: str
) -> list[dict]:
    blocks: list[dict] = [
        {
            "type": "header",
            "text": {"type": "plain_text", "text": f"Merged in the last {window}: {total} PRs"},
        }
    ]

    if summary:
        blocks.append({"type": "section", "text": {"type": "mrkdwn", "text": _truncate(summary)}})
        blocks.append({"type": "divider"})

    # One section per repo, holding back one block for the truncation notice.
    for shown, (repo, prs) in enumerate(grouped.items()):
        if len(blocks) >= SLACK_MAX_BLOCKS - 1:
            omitted = len(grouped) - shown
            blocks.append(
                {
                    "type": "context",
                    "elements": [
                        {
                            "type": "mrkdwn",
                            "text": f"_Truncated at Slack's {SLACK_MAX_BLOCKS}-block limit — "
                            f"{omitted} more {'repository' if omitted == 1 else 'repositories'} "
                            f"not shown._",
                        }
                    ],
                }
            )
            break
        items = "\n".join(f"• <{pr['url']}|#{pr['number']}> {pr['title']} — _{pr['author']}_" for pr in prs)
        blocks.append(
            {
                "type": "section",
                "text": {"type": "mrkdwn", "text": _truncate(f"*{repo}* ({len(prs)})\n{items}")},
            }
        )

    return blocks


def resolve_dm_channel(target: str, token: str) -> str:
    """Turn a Slack user ID into a DM channel ID; pass channel IDs straight through."""
    if not target.startswith("U"):
        return target
    payload = _request(
        f"{SLACK_API}/conversations.open",
        headers={"Authorization": f"Bearer {token}", "content-type": "application/json"},
        data={"users": target},
    )
    if not payload.get("ok"):
        raise DigestError(f"conversations.open failed: {payload.get('error')}")
    return payload["channel"]["id"]


def post_message(channel: str, blocks: list[dict], fallback: str, token: str) -> None:
    payload = _request(
        f"{SLACK_API}/chat.postMessage",
        headers={"Authorization": f"Bearer {token}", "content-type": "application/json"},
        data={"channel": channel, "blocks": blocks, "text": fallback},
    )
    if not payload.get("ok"):
        # Slack reports application errors in a 200 body, not the status code.
        raise DigestError(f"chat.postMessage failed: {payload.get('error')}")


# ----------------------------------------------------------------------------- cli


def _env_flag(name: str, default: bool = False) -> bool:
    raw = os.environ.get(name, "").strip().lower()
    return default if not raw else raw in {"1", "true", "yes"}


def main() -> int:
    org = os.environ.get("DIGEST_ORG", "").strip()
    if not org:
        raise DigestError("DIGEST_ORG is required")

    github_token = os.environ.get("GITHUB_TOKEN", "").strip()
    if not github_token:
        raise DigestError("GITHUB_TOKEN is required")

    since_hours = float(os.environ.get("DIGEST_SINCE_HOURS", "24"))
    dry_run = _env_flag("DIGEST_DRY_RUN")
    mode = os.environ.get("DIGEST_MODE", "list").strip().lower()
    if mode not in {"list", "summarize"}:
        raise DigestError(f"DIGEST_MODE must be 'list' or 'summarize', got {mode!r}")

    since = datetime.now(timezone.utc) - timedelta(hours=since_hours)
    window = f"{since_hours:g}h"

    prs, reported_total = fetch_merged_prs(org, since, github_token)
    if reported_total > len(prs):
        print(
            f"::warning::search reported {reported_total} merged PRs but the API caps "
            f"paging at {SEARCH_PAGE_SIZE * SEARCH_MAX_PAGES}; {len(prs)} included",
            file=sys.stderr,
        )

    excluded = {
        name.strip().lower()
        for name in os.environ.get("DIGEST_EXCLUDE_AUTHORS", "").split(",")
        if name.strip()
    }
    kept = [
        pr
        for pr in prs
        # GitHub App authors always carry the [bot] suffix; named machine users
        # (release bumpers, sync accounts) have to be listed explicitly.
        if not pr["author"].endswith("[bot]") and pr["author"].lower() not in excluded
    ]
    if len(kept) != len(prs):
        print(f"Excluded {len(prs) - len(kept)} PRs by bot or listed author", file=sys.stderr)
    prs = kept

    print(f"{len(prs)} merged PRs in the last {window} across {org}", file=sys.stderr)

    if not prs and _env_flag("DIGEST_SKIP_IF_EMPTY", default=True):
        print("Nothing merged in the window; skipping the post", file=sys.stderr)
        return 0

    summary = ""
    if mode == "summarize" and prs:
        api_key = os.environ.get("ANTHROPIC_API_KEY", "").strip()
        if not api_key:
            raise DigestError("DIGEST_MODE=summarize requires ANTHROPIC_API_KEY")
        summary = summarize(
            prs,
            api_key=api_key,
            model=os.environ.get("DIGEST_MODEL", "claude-opus-5").strip(),
            effort=os.environ.get("DIGEST_EFFORT", "low").strip(),
        )

    grouped = group_by_repo(prs)
    blocks = build_blocks(grouped, total=len(prs), window=window, summary=summary)
    fallback = f"{len(prs)} PRs merged across {org} in the last {window}"

    if dry_run:
        print(json.dumps(blocks, indent=2))
        return 0

    slack_token = os.environ.get("SLACK_BOT_TOKEN", "").strip()
    target = os.environ.get("SLACK_TARGET", "").strip()
    if not slack_token or not target:
        raise DigestError("SLACK_BOT_TOKEN and SLACK_TARGET are required unless DIGEST_DRY_RUN=true")

    post_message(resolve_dm_channel(target, slack_token), blocks, fallback, slack_token)
    print(f"Posted digest of {len(prs)} PRs", file=sys.stderr)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except DigestError as err:
        print(f"::error::{err}", file=sys.stderr)
        sys.exit(1)
