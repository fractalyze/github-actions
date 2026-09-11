#!/usr/bin/env bash
# Copyright 2026 Fractalyze Inc. All rights reserved.
#
# Functional test for digest.py. Stubs the single HTTP chokepoint (_request) so
# the GitHub, Anthropic, and Slack paths are all exercised without network or
# credentials, then asserts on the request payloads and rendered Slack blocks.
#
# Requires: python3.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="${here}/../digest.py"

python3 - "${script}" <<'PY'
import importlib.util
import io
import json
import sys
from contextlib import redirect_stdout

spec = importlib.util.spec_from_file_location("digest", sys.argv[1])
d = importlib.util.module_from_spec(spec)
spec.loader.exec_module(d)

failures = []


def check(label, cond):
    print(f"{'ok  ' if cond else 'FAIL'} {label}")
    if not cond:
        failures.append(label)


def pr(repo, number, author="alice", title="t"):
    return {
        "repo": repo, "number": number, "title": title,
        "url": f"https://github.com/o/{repo}/pull/{number}",
        "author": author, "merged_at": "", "body": "",
    }


def fake_transport(responses):
    """Replace _request with a scripted stub; returns the captured call log."""
    calls = []

    def _request(url, *, headers=None, data=None):
        calls.append({"url": url, "headers": headers or {}, "data": data})
        for match, payload in responses:
            if match in url:
                return payload
        raise AssertionError(f"unstubbed request to {url}")

    d._request = _request
    return calls


# --- grouping -----------------------------------------------------------------
grouped = d.group_by_repo([pr("beta", 1), pr("alpha", 2), pr("alpha", 3), pr("gamma", 4)])
check("busiest repo first", list(grouped) == ["alpha", "beta", "gamma"])
check("PRs kept per repo", [p["number"] for p in grouped["alpha"]] == [2, 3])

# --- Slack block limits -------------------------------------------------------
wide = d.build_blocks(d.group_by_repo([pr(f"r{i:02d}", i) for i in range(60)]),
                      total=60, window="24h", summary="")
shown = sum(1 for b in wide if b["type"] == "section")
check("respects Slack 50-block cap", len(wide) <= d.SLACK_MAX_BLOCKS)
check("reports the omitted repo count", f"{60 - shown} more repositories" in json.dumps(wide))

long_title = [pr("big", i, title="x" * 200) for i in range(100)]
clamped = d.build_blocks(d.group_by_repo(long_title), total=100, window="24h", summary="y" * 9000)
check("clamps summary to 3000 chars", len(clamped[1]["text"]["text"]) <= d.SLACK_MAX_TEXT)
check("clamps section to 3000 chars", len(clamped[3]["text"]["text"]) <= d.SLACK_MAX_TEXT)

plain = d.build_blocks(d.group_by_repo([pr("solo", 1)]), total=1, window="24h", summary="")
check("no divider without a summary", not any(b["type"] == "divider" for b in plain))
check("divider follows a summary", clamped[2]["type"] == "divider")

# --- Claude summarize ---------------------------------------------------------
calls = fake_transport([("anthropic", {
    "stop_reason": "end_turn", "model": "claude-opus-5",
    "usage": {"input_tokens": 10, "output_tokens": 20},
    "content": [{"type": "thinking", "thinking": ""}, {"type": "text", "text": "*Shipped*"}],
})])
text = d.summarize([pr("a", 1)], api_key="k", model="claude-opus-5", effort="low")
sent = calls[0]["data"]
check("extracts only text blocks", text == "*Shipped*")
check("sends the configured model", sent["model"] == "claude-opus-5")
check("sends effort inside output_config", sent["output_config"] == {"effort": "low"})
check("leaves thinking adaptive", sent["thinking"] == {"type": "adaptive"})
check("sets a max_tokens ceiling", sent["max_tokens"] == 16000)
check("sends the anthropic-version header", calls[0]["headers"]["anthropic-version"] == "2023-06-01")
check("tells Claude to avoid ** for Slack", "**double" in sent["messages"][0]["content"])

# A safety classifier declines with HTTP 200 and no content; the digest must
# fall back to the plain listing rather than crash or post an empty summary.
fake_transport([("anthropic", {"stop_reason": "refusal", "content": [], "usage": {}})])
check("refusal degrades to no summary",
      d.summarize([pr("a", 1)], api_key="k", model="m", effort="low") == "")

# --- Slack delivery -----------------------------------------------------------
calls = fake_transport([("conversations.open", {"ok": True, "channel": {"id": "D123"}})])
check("opens a DM for a user ID", d.resolve_dm_channel("U555", "tok") == "D123")
check("passes the user in the body", calls[0]["data"] == {"users": "U555"})
calls = fake_transport([])
check("passes channel IDs through", d.resolve_dm_channel("C777", "tok") == "C777")
check("no API call for a channel ID", calls == [])

calls = fake_transport([("chat.postMessage", {"ok": True})])
d.post_message("D123", [{"type": "divider"}], "fallback", "tok")
check("posts blocks and fallback text",
      calls[0]["data"]["channel"] == "D123" and calls[0]["data"]["text"] == "fallback")
check("authorizes with the bot token",
      calls[0]["headers"]["Authorization"] == "Bearer tok")

# Slack reports application errors in a 200 body, so ok:false must still raise.
fake_transport([("chat.postMessage", {"ok": False, "error": "not_in_channel"})])
try:
    d.post_message("D1", [], "f", "tok")
    check("raises on Slack ok:false", False)
except d.DigestError as err:
    check("raises on Slack ok:false", "not_in_channel" in str(err))

# --- end-to-end via main() ----------------------------------------------------
search = {"total_count": 3, "items": [
    {"repository_url": "https://api.github.com/repos/o/keep", "number": 1, "title": "real",
     "html_url": "u1", "user": {"login": "alice"}, "pull_request": {"merged_at": "x"}, "body": ""},
    {"repository_url": "https://api.github.com/repos/o/keep", "number": 2, "title": "botpr",
     "html_url": "u2", "user": {"login": "dependabot[bot]"}, "pull_request": {"merged_at": "x"}, "body": ""},
    {"repository_url": "https://api.github.com/repos/o/keep", "number": 3, "title": "machine",
     "html_url": "u3", "user": {"login": "fractalyze-dev"}, "pull_request": {"merged_at": "x"}, "body": ""},
]}

import os
os.environ.update({"DIGEST_ORG": "o", "GITHUB_TOKEN": "gh", "DIGEST_DRY_RUN": "true",
                   "DIGEST_EXCLUDE_AUTHORS": "fractalyze-dev", "DIGEST_MODE": "list"})
fake_transport([("search/issues", search)])
buf = io.StringIO()
with redirect_stdout(buf):
    rc = d.main()
rendered = json.dumps(json.loads(buf.getvalue()))
check("dry run exits 0", rc == 0)
check("keeps human-authored PRs", "real" in rendered)
check("always drops [bot] authors", "botpr" not in rendered)
check("drops listed machine users", "machine" not in rendered)
check("counts only kept PRs in the header", "1 PRs" in rendered)

# Empty window with skip_if_empty must succeed and post nothing.
fake_transport([("search/issues", {"total_count": 0, "items": []})])
buf = io.StringIO()
with redirect_stdout(buf):
    rc = d.main()
check("empty window exits 0", rc == 0)
check("empty window posts nothing", buf.getvalue().strip() == "")

# A missing Slack target must fail loudly rather than silently no-op.
os.environ["DIGEST_DRY_RUN"] = "false"
os.environ.pop("SLACK_BOT_TOKEN", None)
os.environ.pop("SLACK_TARGET", None)
fake_transport([("search/issues", search)])
try:
    d.main()
    check("missing Slack config raises", False)
except d.DigestError as err:
    check("missing Slack config raises", "SLACK_BOT_TOKEN" in str(err))

print()
if failures:
    print(f"{len(failures)} check(s) failed:")
    for f in failures:
        print(f"  - {f}")
    sys.exit(1)
print("all checks passed")
PY
