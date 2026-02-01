#!/usr/bin/env python3
"""Collect reactions from pr-reviewer-bot comments and update trust scores."""

import json
import os
import subprocess
import sys
from datetime import date
from pathlib import Path


BOT_SIGNATURE = "<!-- pr-reviewer-bot -->"


def gh_api(endpoint: str) -> list | dict:
    """Call GitHub API via gh CLI. Raises on failure."""
    result = subprocess.run(
        ["gh", "api", endpoint],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        raise RuntimeError(f"GitHub API failed for {endpoint}: {result.stderr.strip()}")

    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError as e:
        raise RuntimeError(f"Invalid JSON from {endpoint}: {e}")


def get_bot_comments(repo: str, pr_number: int) -> list[dict]:
    """Get all comments with pr-reviewer-bot signature. Raises on API failure."""
    comments = []

    # PR review comments (inline on diff)
    pr_comments = gh_api(f"repos/{repo}/pulls/{pr_number}/comments")
    for c in pr_comments:
        if BOT_SIGNATURE in c.get("body", ""):
            comments.append({"id": c["id"], "type": "pr"})

    # Issue comments (general PR conversation)
    issue_comments = gh_api(f"repos/{repo}/issues/{pr_number}/comments")
    for c in issue_comments:
        if BOT_SIGNATURE in c.get("body", ""):
            comments.append({"id": c["id"], "type": "issue"})

    return comments


def get_reactions(repo: str, comment_id: int, comment_type: str) -> dict[str, int]:
    """Get reaction counts for a comment. Raises on API failure."""
    if comment_type == "pr":
        endpoint = f"repos/{repo}/pulls/comments/{comment_id}/reactions"
    else:
        endpoint = f"repos/{repo}/issues/comments/{comment_id}/reactions"

    reactions = gh_api(endpoint)

    counts = {"hooray": 0, "+1": 0, "-1": 0}
    for r in reactions:
        content = r.get("content", "")
        if content in counts:
            counts[content] += 1

    return counts


def calculate_score(hooray: int, minus: int, comment_count: int) -> float:
    """Calculate PR score: (hooray - 2*minus) / comments, clamped to [-2, +1]."""
    if comment_count == 0:
        return 0.0
    raw = (hooray - 2 * minus) / comment_count
    return max(-2.0, min(1.0, raw))


def update_metrics(
    metrics_dir: Path, repo: str, pr_number: int, reactions: dict, score: float
):
    """Update history and summary files."""
    today = date.today()
    month = today.strftime("%Y-%m")

    # Update history
    history_dir = metrics_dir / "history"
    history_dir.mkdir(parents=True, exist_ok=True)
    history_file = history_dir / f"{month}.json"

    if history_file.exists():
        history = json.loads(history_file.read_text())
    else:
        history = {"month": month, "prs": []}

    # Check if PR already recorded
    existing = [p for p in history["prs"] if p["repo"] == repo and p["pr"] == pr_number]
    if existing:
        print(f"PR {repo}#{pr_number} already recorded. Skipping.")
        return

    history["prs"].append(
        {
            "repo": repo,
            "pr": pr_number,
            "date": today.isoformat(),
            "comments": reactions["comments"],
            "reactions": {
                "🎉": reactions["hooray"],
                "👍": reactions["+1"],
                "👎": reactions["-1"],
            },
            "score": round(score, 2),
        }
    )

    history_file.write_text(json.dumps(history, indent=2, ensure_ascii=False) + "\n")

    # Recalculate overall score
    total_prs = 0
    total_score = 0.0

    for f in history_dir.glob("*.json"):
        data = json.loads(f.read_text())
        for pr in data.get("prs", []):
            total_prs += 1
            total_score += pr.get("score", 0)

    if total_prs > 0:
        avg_score = total_score / total_prs
        overall = 5 + (avg_score * 5)
    else:
        overall = 5.0

    # Update summary
    summary = {
        "overall_score": round(overall, 1),
        "total_prs": total_prs,
        "last_updated": today.isoformat(),
    }
    (metrics_dir / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")

    print(
        f"Updated: score={round(score, 2)}, overall={round(overall, 1)} ({total_prs} PRs)"
    )


def main() -> int:
    repo = os.environ.get("REPO")
    pr_number_str = os.environ.get("PR_NUMBER", "")
    metrics_dir = Path(
        os.environ.get("METRICS_DIR", "dot-claude/agents/pr-reviewer/metrics")
    )

    # Validate inputs
    if not repo:
        print("Error: REPO environment variable required", file=sys.stderr)
        return 1

    if not pr_number_str:
        print("Error: PR_NUMBER environment variable required", file=sys.stderr)
        return 1

    try:
        pr_number = int(pr_number_str)
    except ValueError:
        print(
            f"Error: PR_NUMBER must be an integer, got: {pr_number_str}",
            file=sys.stderr,
        )
        return 1

    print(f"Collecting reactions for {repo}#{pr_number}...")

    # Get bot comments (will raise on API failure)
    try:
        comments = get_bot_comments(repo, pr_number)
    except RuntimeError as e:
        print(f"Error: Failed to fetch comments: {e}", file=sys.stderr)
        return 1

    if not comments:
        print("No pr-reviewer-bot comments found. Nothing to collect.")
        return 0  # This is expected when review didn't run - not an error

    print(f"Found {len(comments)} bot comments")

    # Collect reactions
    try:
        total = {"hooray": 0, "+1": 0, "-1": 0, "comments": len(comments)}
        for c in comments:
            r = get_reactions(repo, c["id"], c["type"])
            total["hooray"] += r["hooray"]
            total["+1"] += r["+1"]
            total["-1"] += r["-1"]
    except RuntimeError as e:
        print(f"Error: Failed to fetch reactions: {e}", file=sys.stderr)
        return 1

    print(f"Reactions: 🎉={total['hooray']} 👍={total['+1']} 👎={total['-1']}")

    # Calculate score
    score = calculate_score(total["hooray"], total["-1"], len(comments))
    print(f"PR Score: {score:.2f}")

    # Update metrics
    try:
        update_metrics(metrics_dir, repo, pr_number, total, score)
    except Exception as e:
        print(f"Error: Failed to update metrics: {e}", file=sys.stderr)
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
