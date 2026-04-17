#!/usr/bin/env python3
"""
Type4Me GitHub Monitor
每 2 小时检查新 Issue 和 PR，有动态就发飞书
"""
import json
import os
import sys
from datetime import datetime, timezone, timedelta
from pathlib import Path
from urllib.request import urlopen, Request


def _load_secrets():
    p = Path.home() / ".config" / "secrets.env"
    if not p.exists():
        return
    for line in p.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, v = line.split("=", 1)
        os.environ.setdefault(k.strip(), v.strip().strip('"').strip("'"))


_load_secrets()

GITHUB_TOKEN = os.environ["GITHUB_TOKEN"]
REPO = "joewongjc/type4me"
FEISHU_APP_ID = os.environ["FEISHU_APP_ID"]
FEISHU_APP_SECRET = os.environ["FEISHU_APP_SECRET"]
OPEN_ID = os.environ["FEISHU_OPEN_ID"]

# 多取 10 分钟，防止 cron 抖动漏掉
LOOKBACK = timedelta(hours=2, minutes=10)


def gh_get(path):
    req = Request(
        f"https://api.github.com/repos/{REPO}/{path}",
        headers={
            "Authorization": f"token {GITHUB_TOKEN}",
            "Accept": "application/vnd.github.v3+json",
        },
    )
    with urlopen(req) as r:
        return json.loads(r.read())


def feishu_send(text):
    body = json.dumps({"app_id": FEISHU_APP_ID, "app_secret": FEISHU_APP_SECRET}).encode()
    req = Request(
        "https://open.feishu.cn/open-apis/auth/v3/tenant_access_token/internal",
        data=body,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urlopen(req) as r:
        token = json.loads(r.read())["tenant_access_token"]

    msg_body = json.dumps({
        "receive_id": OPEN_ID,
        "msg_type": "text",
        "content": json.dumps({"text": text}),
    }).encode()
    req2 = Request(
        "https://open.feishu.cn/open-apis/im/v1/messages?receive_id_type=open_id",
        data=msg_body,
        headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"},
        method="POST",
    )
    with urlopen(req2) as r:
        return json.loads(r.read())


def main():
    threshold = datetime.now(timezone.utc) - LOOKBACK
    items = gh_get("issues?state=open&sort=created&direction=desc&per_page=30")

    new_issues, new_prs = [], []
    for item in items:
        created_at = datetime.fromisoformat(item["created_at"].replace("Z", "+00:00"))
        if created_at < threshold:
            continue
        if "pull_request" in item:
            new_prs.append(item)
        else:
            new_issues.append(item)

    if not new_issues and not new_prs:
        print("No new items, skipping.")
        return

    lines = ["[Type4Me GitHub 新动态]"]
    if new_issues:
        lines.append(f"\nIssue x{len(new_issues)}")
        for i in new_issues:
            lines.append(f"  #{i['number']} {i['title']}")
            lines.append(f"  by {i['user']['login']}")
            lines.append(f"  {i['html_url']}")
    if new_prs:
        lines.append(f"\nPR x{len(new_prs)}")
        for p in new_prs:
            lines.append(f"  #{p['number']} {p['title']}")
            lines.append(f"  by {p['user']['login']}")
            lines.append(f"  {p['html_url']}")
    lines.append("\n需要我处理哪个？回复 issue/PR 编号告诉我修还是合。")

    result = feishu_send("\n".join(lines))
    print("Sent:", result.get("code"), result.get("msg"))


if __name__ == "__main__":
    main()
