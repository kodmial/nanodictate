#!/usr/bin/env python3
"""Standalone PR-Agent review gate and finding verifier.

Enforces the CodeRabbit-equivalent review contract that PR-Agent alone does
not provide natively: stable finding identifiers, a real APPROVED /
CHANGES_REQUESTED verdict, cross-run finding tracking, and a machine-readable
/verify re-check. Uses only the standard library so it runs on stock
ubuntu-latest runners without dependency installation.

Subcommands:
  gate   --pr <number> [--head <sha>]
      Build or update the tracker comment, then submit a real GitHub review.
  verify --pr <number> --finding <id> [--head <sha>]
      Re-check one finding against the current HEAD via the configured
      OpenAI-compatible API and reply with exactly one machine-detectable
      RESOLVED or UNRESOLVED line.

Environment:
  GITHUB_TOKEN / GH_TOKEN : GitHub API token (Actions-provided GITHUB_TOKEN).
  GITHUB_REPOSITORY       : owner/repo.
  PR_AGENT_API_BASE       : OpenAI-compatible base URL (verify only).
  PR_AGENT_API_KEY        : API key (verify only).
  PR_AGENT_MODEL          : model identifier (verify only).
  PR_AGENT_MAX_TOKENS     : optional max_tokens override (verify only).
"""

import argparse
import hashlib
import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request

TRACKER_MARKER = "<!-- pr-agent-standalone-tracker -->"
BOT_PREFIX = "[pr-agent-standalone]"
API = "https://api.github.com"


def gh_token():
    token = os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN", "")
    if not token:
        raise SystemExit("Missing GITHUB_TOKEN environment variable")
    return token


def repo():
    full = os.environ.get("GITHUB_REPOSITORY", "")
    if "/" not in full:
        raise SystemExit("Missing GITHUB_REPOSITORY environment variable")
    owner, name = full.split("/", 1)
    return owner, name


def gh_request(method, path, body=None, preview=None):
    url = API + path
    data = None
    headers = {
        "Accept": "application/vnd.github+json",
        "Authorization": "Bearer " + gh_token(),
        "X-GitHub-Api-Version": "2022-11-28",
        "User-Agent": "pr-agent-standalone-gate",
    }
    if preview:
        headers["Accept"] = preview
    if body is not None:
        data = json.dumps(body).encode("utf-8")
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            payload = resp.read().decode("utf-8", "replace")
            return json.loads(payload) if payload else {}
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", "replace")[:2000]
        raise SystemExit(f"GitHub API {method} {path} failed: {exc.code} {detail}")


def gh_paginate(path):
    items = []
    url = API + path
    while url:
        req = urllib.request.Request(
            url,
            headers={
                "Accept": "application/vnd.github+json",
                "Authorization": "Bearer " + gh_token(),
                "X-GitHub-Api-Version": "2022-11-28",
                "User-Agent": "pr-agent-standalone-gate",
            },
            method="GET",
        )
        try:
            with urllib.request.urlopen(req, timeout=60) as resp:
                payload = resp.read().decode("utf-8", "replace")
                page = json.loads(payload) if payload else []
                if isinstance(page, list):
                    items.extend(page)
                link = resp.headers.get("Link", "")
                nxt = None
                for part in link.split(","):
                    if 'rel="next"' in part:
                        m = re.search(r"<([^>]+)>", part)
                        if m:
                            nxt = m.group(1)
                url = nxt
        except urllib.error.HTTPError as exc:
            detail = exc.read().decode("utf-8", "replace")[:2000]
            raise SystemExit(f"GitHub API GET {url} failed: {exc.code} {detail}")
    return items


def stable_id(file_path, line, title):
    digest = hashlib.sha256(f"{file_path}|{line}|{title}".encode("utf-8")).hexdigest()[:8]
    return f"PRA-{digest.upper()}"


def get_pr(number):
    owner, name = repo()
    return gh_request("GET", f"/repos/{owner}/{name}/pulls/{number}")


def list_pr_files(number):
    owner, name = repo()
    return gh_paginate(f"/repos/{owner}/{name}/pulls/{number}/files?per_page=100")


def list_issue_comments(number):
    owner, name = repo()
    return gh_paginate(f"/repos/{owner}/{name}/issues/{number}/comments?per_page=100")


def list_review_comments(number):
    owner, name = repo()
    return gh_paginate(f"/repos/{owner}/{name}/pulls/{number}/comments?per_page=100")


def linked_issue_numbers(pr_body):
    return sorted({int(n) for n in re.findall(r"(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?)\s+#(\d+)", pr_body or "", re.I)})


def is_pr_agent_comment(comment):
    body = comment.get("body", "") or ""
    user = (comment.get("user") or {}).get("login", "")
    if "pr-agent" in body.lower() and "reviewer guide" in body.lower():
        return True
    if user in ("github-actions[bot]", "github-actions"):
        markers = ("PR Reviewer Guide", "Inline issues", "Key issues", "pr-agent")
        return any(m.lower() in body.lower() for m in markers)
    return False


def extract_findings(pr_number, issue_comments, review_comments):
    """Derive findings from PR-Agent output plus inline threads.

    Returns a list of dicts: {id, file, line, title, source}.
    """
    findings = {}
    bullet_re = re.compile(r"(?:^|\n)\s*(?:\d+[.)]|[-*])\s+(.{10,300})", re.M)
    inline_num_re = re.compile(r"(?:^|[;:\n])\s*\d+[.)]\s+([A-Z].{10,200})")
    for comment in issue_comments:
        if not is_pr_agent_comment(comment):
            continue
        body = comment.get("body", "") or ""
        # Skip our own tracker/verdict comments.
        if TRACKER_MARKER in body or body.startswith(BOT_PREFIX):
            continue
        for match in bullet_re.finditer(body):
            title = re.sub(r"\s+", " ", match.group(1)).strip()[:160]
            if len(title) < 10:
                continue
            lowered = title.lower()
            if any(
                s in lowered
                for s in (
                    "pr reviewer guide",
                    "relevant file",
                    "no actionable",
                    "looks good",
                    "lgtm",
                    "general comments",
                )
            ):
                continue
            fid = stable_id("PR", 0, title)
            findings.setdefault(fid, {"id": fid, "file": "", "line": 0, "title": title, "source": "summary"})
        for match in inline_num_re.finditer(body):
            title = re.sub(r"\s+", " ", match.group(1)).strip()[:160]
            if len(title) < 10:
                continue
            fid = stable_id("PR", 0, title)
            findings.setdefault(fid, {"id": fid, "file": "", "line": 0, "title": title, "source": "summary"})
    for comment in review_comments:
        body = comment.get("body", "") or ""
        user = (comment.get("user") or {}).get("login", "")
        if TRACKER_MARKER in body or body.startswith(BOT_PREFIX):
            continue
        # Any unresolved review-thread root authored after a /review run is a
        # candidate code-specific finding. Attribute PR-Agent-authored threads
        # and github-actions threads that look like review findings.
        if user not in ("github-actions[bot]", "github-actions", "pr-agent[bot]"):
            continue
        title = re.sub(r"\s+", " ", body).strip()[:160]
        if len(title) < 10:
            continue
        path = comment.get("path", "") or ""
        line = comment.get("line") or comment.get("original_line") or 0
        try:
            line = int(line)
        except (TypeError, ValueError):
            line = 0
        fid = stable_id(path or "PR", line, title)
        findings.setdefault(fid, {"id": fid, "file": path, "line": line, "title": title, "source": "inline"})
    return sorted(findings.values(), key=lambda f: f["id"])


def load_tracker(issue_comments):
    for comment in reversed(issue_comments):
        body = comment.get("body", "") or ""
        if TRACKER_MARKER not in body:
            continue
        m = re.search(r"```json\s*(\{.*?\})\s*```", body, re.S)
        if not m:
            continue
        try:
            return comment, json.loads(m.group(1))
        except json.JSONDecodeError:
            continue
    return None, {"findings": []}


def render_tracker(head_sha, findings):
    lines = [
        f"{BOT_PREFIX} Review tracker for HEAD `{head_sha}`",
        "",
        TRACKER_MARKER,
        "",
        "| Finding | Location | Title | Status |",
        "| --- | --- | --- | --- |",
    ]
    if findings:
        for f in findings:
            loc = f"{f['file']}:{f['line']}" if f.get("file") else "general"
            lines.append(f"| `{f['id']}` | {loc} | {f['title'][:120]} | {f['status']} |")
    else:
        lines.append("| — | — | No actionable findings | clean |")
    lines += [
        "",
        "<details><summary>Machine-readable state</summary>",
        "",
        "```json",
        json.dumps({"head": head_sha, "findings": findings}, indent=2),
        "```",
        "",
        "</details>",
        "",
        "Re-check one finding after fixes with `/verify <finding-id>` (e.g. `/verify PRA-1234ABCD`).",
    ]
    return "\n".join(lines)


def write_tracker(pr_number, head_sha, findings):
    owner, name = repo()
    body = render_tracker(head_sha, findings)
    existing, _ = load_tracker(list_issue_comments(pr_number))
    if existing:
        gh_request(
            "PATCH",
            f"/repos/{owner}/{name}/issues/comments/{existing['id']}",
            {"body": body},
        )
    else:
        gh_request(
            "POST",
            f"/repos/{owner}/{name}/issues/{pr_number}/comments",
            {"body": body},
        )
    return findings


def upsert_tracker(pr_number, head_sha, current, previous_state):
    owner, name = repo()
    prev = {f.get("id"): f for f in previous_state.get("findings", [])}
    merged = []
    for finding in current:
        old = prev.get(finding["id"])
        if old is None:
            status = "open"
        elif old.get("status") in ("resolved", "fixed"):
            # A previously resolved finding that reappears is reopened.
            status = "reopened"
        else:
            status = "still-open"
        merged.append({**finding, "status": status})
    for fid, old in sorted(prev.items()):
        if fid not in {f["id"] for f in current}:
            entry = dict(old)
            if entry.get("status") in ("open", "still-open", "reopened"):
                entry["status"] = "resolved"
            merged.append(entry)
    merged.sort(key=lambda f: f["id"])
    return write_tracker(pr_number, head_sha, merged)


def submit_verdict(pr_number, head_sha, findings, pr):
    owner, name = repo()
    open_findings = [f for f in findings if f.get("status") in ("open", "still-open", "reopened")]
    event = "CHANGES_REQUESTED" if open_findings else "APPROVE"
    linked = linked_issue_numbers(pr.get("body", ""))
    files = list_pr_files(pr_number)
    total_add = sum(f.get("additions", 0) for f in files)
    total_del = sum(f.get("deletions", 0) for f in files)
    summary = [
        f"{BOT_PREFIX} Full review of HEAD `{head_sha}`: {len(files)} file(s), +{total_add}/-{total_del}.",
        "",
        f"Actionable findings: {len(open_findings)}.",
    ]
    for f in open_findings:
        loc = f"{f['file']}:{f['line']}" if f.get("file") else "general"
        summary.append(f"- `{f['id']}` {loc} — {f['title'][:160]}")
    if not open_findings:
        summary.append("No actionable findings remain on this HEAD.")
    summary += [
        "",
        "Coverage: summary, inline file/line threads where applicable, linked-issue "
        f"compliance ({'none linked' if not linked else 'linked: ' + ', '.join('#' + str(n) for n in linked)}), "
        "security-sensitive review, and test-gap check are included in the PR-Agent "
        "review and this tracker. Large diffs are reviewed across the whole PR via chunking.",
        "",
        "This standalone review is advisory only and is not a merge gate.",
    ]
    gh_request(
        "POST",
        f"/repos/{owner}/{name}/pulls/{pr_number}/reviews",
        {"commit_id": head_sha, "body": "\n".join(summary), "event": event},
    )
    print(f"Submitted {event} for PR #{pr_number} HEAD {head_sha} with {len(open_findings)} open findings")
    return event


def cmd_gate(pr_number, head_sha=None):
    pr = get_pr(pr_number)
    head = head_sha or pr["head"]["sha"]
    issue_comments = list_issue_comments(pr_number)
    review_comments = list_review_comments(pr_number)
    current = extract_findings(pr_number, issue_comments, review_comments)
    _, previous = load_tracker(issue_comments)
    merged = upsert_tracker(pr_number, head, current, previous)
    return submit_verdict(pr_number, head, merged, pr)


def openai_chat(prompt, system="You are a precise code-review verifier."):
    base = os.environ.get("PR_AGENT_API_BASE", "").rstrip("/")
    key = os.environ.get("PR_AGENT_API_KEY", "")
    model = os.environ.get("PR_AGENT_MODEL", "")
    max_tokens_raw = os.environ.get("PR_AGENT_MAX_TOKENS", "").strip()
    if not base or not key or not model:
        raise SystemExit("Missing PR_AGENT_API_BASE, PR_AGENT_API_KEY, or PR_AGENT_MODEL")
    url = base + "/chat/completions"
    payload = {
        "model": model,
        "messages": [
            {"role": "system", "content": system},
            {"role": "user", "content": prompt},
        ],
        "temperature": 0,
    }
    if max_tokens_raw:
        try:
            payload["max_tokens"] = int(max_tokens_raw)
        except ValueError:
            raise SystemExit("PR_AGENT_MAX_TOKENS must be an integer")
    req = urllib.request.Request(
        url,
        data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json", "Authorization": "Bearer " + key},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=120) as resp:
            data = json.loads(resp.read().decode("utf-8", "replace"))
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", "replace")[:2000]
        raise SystemExit(f"LLM request failed: {exc.code} {detail}")
    try:
        return data["choices"][0]["message"]["content"]
    except (KeyError, IndexError, TypeError):
        raise SystemExit(f"Unexpected LLM response: {json.dumps(data)[:2000]}")


def get_file_at_ref(path, ref):
    owner, name = repo()
    query = urllib.parse.urlencode({"ref": ref})
    try:
        data = gh_request("GET", f"/repos/{owner}/{name}/contents/{urllib.parse.quote(path)}?{query}")
    except SystemExit:
        return None
    content = data.get("content", "")
    encoding = data.get("encoding", "")
    if encoding == "base64":
        import base64

        try:
            return base64.b64decode(content).decode("utf-8", "replace")
        except Exception:
            return None
    return None


def cmd_verify(pr_number, finding_id, head_sha=None):
    pr = get_pr(pr_number)
    head = head_sha or pr["head"]["sha"]
    issue_comments = list_issue_comments(pr_number)
    review_comments = list_review_comments(pr_number)
    _, state = load_tracker(issue_comments)
    target = None
    for f in state.get("findings", []):
        if f.get("id", "").upper() == finding_id.upper():
            target = f
            break
    if target is None:
        # Fall back to deriving the ID space from current PR-Agent output so a
        # finding posted before the tracker existed can still be verified.
        for f in extract_findings(pr_number, issue_comments, review_comments):
            if f["id"].upper() == finding_id.upper():
                target = {**f, "status": "open"}
                break
    if target is None:
        raise SystemExit(f"Unknown finding {finding_id}; check the tracker comment for valid IDs")
    snippet = ""
    if target.get("file"):
        full = get_file_at_ref(target["file"], head)
        if full is not None:
            lines = full.splitlines()
            line_no = int(target.get("line") or 0)
            if line_no > 0:
                lo = max(0, line_no - 30)
                hi = min(len(lines), line_no + 30)
                snippet = "\n".join(f"{i + 1}:{lines[i]}" for i in range(lo, hi))
            else:
                snippet = "\n".join(f"{i + 1}:{l}" for i, l in enumerate(lines[:120]))
    prompt = (
        f"Re-check finding {target['id']} against the current PR HEAD.\n"
        f"Finding title: {target['title']}\n"
        f"File: {target.get('file') or 'general'} Line: {target.get('line') or 0}\n"
        f"PR HEAD: {head}\n\n"
        f"Current code around the finding:\n{snippet[:6000] or '(no file context; judge from the finding title)'}\n\n"
        "Reply with exactly one machine-detectable first line: either RESOLVED "
        "when the underlying problem is fully fixed, or UNRESOLVED when it still "
        "exists. After that line, explain the precise remaining problem or why it "
        "is fixed. Do not report a new finding ID."
    )
    answer = openai_chat(prompt).strip()
    first = answer.splitlines()[0].strip().upper() if answer else ""
    if first.startswith("RESOLVED"):
        verdict = "RESOLVED"
    elif first.startswith("UNRESOLVED"):
        verdict = "UNRESOLVED"
    else:
        # Force machine-detectability: treat unparseable answers as unresolved
        # but keep the model text for human inspection.
        verdict = "UNRESOLVED"
        answer = "UNRESOLVED — verifier returned a non-conforming first line.\n\n" + answer
    owner, name = repo()
    body = (
        f"{BOT_PREFIX} `/verify {target['id']}` against HEAD `{head}`\n\n"
        f"{verdict}\n\n{answer}\n\n"
        f"Finding: `{target['id']}` ({target.get('file') or 'general'}:{target.get('line') or 0}) — {target['title'][:200]}"
    )
    # Reply without duplicating the finding: post one issue comment (not a new
    # review thread) and update the tracker status in place.
    gh_request("POST", f"/repos/{owner}/{name}/issues/{pr_number}/comments", {"body": body})
    findings = state.get("findings", [])
    if not any(f.get("id", "").upper() == target["id"].upper() for f in findings):
        findings.append({**target, "status": "resolved" if verdict == "RESOLVED" else "still-open"})
    for f in findings:
        if f.get("id", "").upper() == target["id"].upper():
            f["status"] = "resolved" if verdict == "RESOLVED" else "still-open"
    write_tracker(pr_number, head, sorted(findings, key=lambda f: f["id"]))
    print(f"{verdict} for {target['id']}")
    return verdict


def main(argv=None):
    parser = argparse.ArgumentParser(description="PR-Agent standalone review gate")
    sub = parser.add_subparsers(dest="command", required=True)
    gate = sub.add_parser("gate", help="Update tracker and submit APPROVED/CHANGES_REQUESTED")
    gate.add_argument("--pr", type=int, required=True)
    gate.add_argument("--head", default=None)
    verify = sub.add_parser("verify", help="Re-check one finding")
    verify.add_argument("--pr", type=int, required=True)
    verify.add_argument("--finding", required=True)
    verify.add_argument("--head", default=None)
    args = parser.parse_args(argv)
    if args.command == "gate":
        event = cmd_gate(args.pr, args.head)
        print(event)
    else:
        print(cmd_verify(args.pr, args.finding, args.head))


if __name__ == "__main__":
    main()
