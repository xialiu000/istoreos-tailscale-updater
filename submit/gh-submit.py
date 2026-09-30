#!/usr/bin/env python3
"""Submit luci-app-tailscale-updater to the iStore repos by opening PRs.

Forks the upstream repos, creates a temporary branch, uploads the files and
opens the pull requests through the GitHub REST API.

IMPORTANT: needs a CLASSIC personal access token with the 'public_repo' scope.
Fine-grained tokens (github_pat_...) cannot fork or open PRs against arbitrary
public repositories and will fail with HTTP 403.

Usage:
    GH_TOKEN=... python3 submit/gh-submit.py
    # or, to keep the token out of the command line:
    sh submit/run-submit.sh            # reads ~/.gh_token
    DRY_RUN=1 sh submit/run-submit.sh  # print the plan only
"""
import base64
import json
import os
import sys
import time
import urllib.error
import urllib.request

TOKEN = os.environ.get("GH_TOKEN", "").strip()
API = "https://api.github.com"
REPO_URL = "https://github.com/xialiu000/istoreos-tailscale-updater"
DRY = os.environ.get("DRY_RUN") == "1"
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
LOGIN = ""


def bail(msg):
    print("error:", msg, file=sys.stderr)
    sys.exit(1)


def req(method, path, payload=None):
    url = path if path.startswith("http") else API + path
    data = json.dumps(payload).encode() if payload is not None else None
    r = urllib.request.Request(url, data=data, method=method)
    r.add_header("Authorization", "Bearer " + TOKEN)
    r.add_header("Accept", "application/vnd.github+json")
    r.add_header("X-GitHub-Api-Version", "2022-11-28")
    if data is not None:
        r.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(r, timeout=60) as resp:
            body = resp.read()
            return json.loads(body) if body else {}
    except urllib.error.HTTPError as e:
        detail = e.read().decode(errors="replace")
        raise RuntimeError(f"{method} {url} -> {e.code}: {detail[:280]}") from None


def wait_repo(full):
    for _ in range(45):
        try:
            return req("GET", f"/repos/{full}")
        except RuntimeError:
            time.sleep(2)
    raise RuntimeError(f"fork {full} not ready after ~90s")


def ensure_fork(upstream, fork):
    try:
        req("GET", f"/repos/{fork}")
        print(f"  fork already exists: {fork}")
        return
    except RuntimeError:
        pass
    try:
        fk = req("POST", f"/repos/{upstream}/forks")
        print(f"  forked -> {fk.get('full_name', fork)}")
    except RuntimeError as e:
        if "403" in str(e):
            raise RuntimeError(
                "cannot fork via API (403). Use a CLASSIC token with 'public_repo', "
                f"or fork {upstream} manually in the browser and re-run."
            ) from None
        raise
    wait_repo(fork)


def get_sha(full, branch="main"):
    ref = req("GET", f"/repos/{full}/git/ref/heads/{branch}")
    return ref["object"]["sha"]


def ensure_branch(fork, branch, base_sha):
    try:
        req("GET", f"/repos/{fork}/git/ref/heads/{branch}")
        print(f"  branch exists: {branch}")
    except RuntimeError:
        req("POST", f"/repos/{fork}/git/refs",
            {"ref": f"refs/heads/{branch}", "sha": base_sha})
        print(f"  created branch {branch}")


def put_file(fork, branch, repo_path, local_path, message):
    content = base64.b64encode(open(local_path, "rb").read()).decode()
    url = f"/repos/{fork}/contents/{repo_path}"
    sha = None
    try:
        sha = req("GET", f"{url}?ref={branch}").get("sha")
    except RuntimeError:
        pass
    payload = {"message": message, "content": content, "branch": branch}
    if sha:
        payload["sha"] = sha
    res = req("PUT", url, payload)
    print(f"  uploaded {repo_path} ({res.get('commit', {}).get('sha', '')[:8]})")


def open_pr(upstream, head_branch, base, title, body):
    pr = req("POST", f"/repos/{upstream}/pulls",
             {"title": title, "head": f"{LOGIN}:{head_branch}", "base": base,
              "body": body, "maintainer_can_modify": True})
    print(f"  PR: {pr['html_url']}")
    return pr["html_url"]


JOBS = [
    {
        "upstream": "linkease/istore-repo",
        "branch": "add_tailscale_updater",
        "base": "pending",
        "files": [
            ("bin/packages/all/nas_luci/luci-app-tailscale-updater_1.0.0-1_all.ipk",
             os.path.join(ROOT, "dist/luci-app-tailscale-updater_1.0.0-1_all.ipk")),
        ],
        "title": "Add luci-app-tailscale-updater (iStoreOS Tailscale 更新工具)",
        "body": (
            "新增 LuCI 应用包 luci-app-tailscale-updater。\n\n"
            "用途：iStore 安装的 Tailscale 被固件源冻结在 1.80.3-1，本工具把 "
            "tailscale/tailscaled 两个二进制替换为官方最新稳定版，保留启动脚本、"
            "UCI 配置与登录状态；带 sha256 校验、自动备份与回滚。\n\n"
            f"源码仓库：{REPO_URL}\n"
            "架构：Architecture: all（架构无关），故放在 bin/packages/all/nas_luci/。\n"
        ),
    },
    {
        "upstream": "linkease/openwrt-app-meta",
        "branch": "add_app_tailscale_updater",
        "base": "main",
        "files": [
            ("applications/app-meta-tailscale-updater/Makefile",
             os.path.join(HERE, "openwrt-app-meta/applications/app-meta-tailscale-updater/Makefile")),
            ("applications/app-meta-tailscale-updater/logo.png",
             os.path.join(HERE, "openwrt-app-meta/applications/app-meta-tailscale-updater/logo.png")),
        ],
        "title": "Add app-meta-tailscale-updater (Tailscale 更新)",
        "body": (
            "新增 iStore 上架元数据 app-meta-tailscale-updater。\n\n"
            f"源码/教程仓库：{REPO_URL}\n"
            "依赖主包：+luci-app-tailscale-updater\n"
        ),
    },
]


def main():
    global LOGIN
    if not TOKEN:
        bail("set GH_TOKEN, or use: sh submit/run-submit.sh")
    if not TOKEN.isascii():
        bail("token contains non-ASCII characters (copy/paste artifact) — re-copy it")
    if TOKEN.startswith("github_pat_"):
        print("warning: fine-grained token detected; it usually cannot fork/PR "
              "arbitrary public repos (needs a CLASSIC token with 'public_repo').")

    if DRY:
        LOGIN = "<your-user>"
    else:
        LOGIN = req("GET", "/user")["login"]
        print("login:", LOGIN, "\n")

    failed = False
    prs = []
    for job in JOBS:
        up = job["upstream"]
        fork = f"{LOGIN}/{up.split('/')[1]}"
        print(f"== {up} ==")
        if DRY:
            print("  would fork/branch", job["branch"], "->", [f[0] for f in job["files"]])
            print()
            continue
        try:
            ensure_fork(up, fork)
            ensure_branch(fork, job["branch"], get_sha(fork))
            for repo_path, local_path in job["files"]:
                if not os.path.exists(local_path):
                    raise RuntimeError(f"missing local file: {local_path}")
                put_file(fork, job["branch"], repo_path, local_path,
                         f"add {os.path.basename(repo_path)}")
            prs.append(open_pr(up, job["branch"], job["base"], job["title"], job["body"]))
        except RuntimeError as e:
            failed = True
            print(f"  FAILED: {e}")
        print()

    print("done." + ("  PRs: " + ", ".join(prs) if prs else ""))
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
