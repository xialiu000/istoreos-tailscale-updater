#!/usr/bin/env python3
"""Submit luci-app-tailscale-updater to the iStore repos by opening PRs.

It forks the upstream repos, creates a temporary branch, uploads the files and
opens the pull requests — all through the GitHub REST API.

Usage (run on YOUR machine; token never leaves it):

    GH_TOKEN=<classic PAT with 'public_repo'/'repo' scope> python3 submit/gh-submit.py

Optional:
    DRY_RUN=1  GH_TOKEN=... python3 submit/gh-submit.py     # only print the plan
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


def die(msg):
    print("error:", msg, file=sys.stderr)
    sys.exit(1)


def req(method, path, payload=None, raw_body=None, ctype="application/json"):
    url = path if path.startswith("http") else API + path
    data = None
    if raw_body is not None:
        data = raw_body
    elif payload is not None:
        data = json.dumps(payload).encode()
    r = urllib.request.Request(url, data=data, method=method)
    r.add_header("Authorization", "Bearer " + TOKEN)
    r.add_header("Accept", "application/vnd.github+json")
    r.add_header("X-GitHub-Api-Version", "2022-11-28")
    if data is not None:
        r.add_header("Content-Type", ctype)
    try:
        with urllib.request.urlopen(r, timeout=60) as resp:
            body = resp.read()
            return json.loads(body) if body else {}
    except urllib.error.HTTPError as e:
        detail = e.read().decode(errors="replace")
        raise RuntimeError(f"{method} {url} -> {e.code}: {detail[:300]}") from None


def wait_repo(full):
    for _ in range(45):
        try:
            return req("GET", f"/repos/{full}")
        except RuntimeError:
            time.sleep(2)
    die(f"fork {full} not ready after ~90s")


def get_sha(full, branch):
    ref = req("GET", f"/repos/{full}/git/ref/heads/{branch}")
    return ref["object"]["sha"]


def ensure_branch(fork, branch, base_sha):
    try:
        req("GET", f"/repos/{fork}/git/ref/heads/{branch}")
        print(f"  branch {branch} already exists, reusing")
    except RuntimeError:
        req("POST", f"/repos/{fork}/git/refs",
            {"ref": f"refs/heads/{branch}", "sha": base_sha})
        print(f"  created branch {branch}")


def put_file(fork, branch, repo_path, local_path, message):
    content = base64.b64encode(open(local_path, "rb").read()).decode()
    url = f"/repos/{fork}/contents/{repo_path}"
    sha = None
    try:
        cur = req("GET", f"{url}?ref={branch}")
        sha = cur.get("sha")
    except RuntimeError:
        pass
    payload = {"message": message, "content": content, "branch": branch}
    if sha:
        payload["sha"] = sha
    res = req("PUT", url, payload)
    print(f"  uploaded {repo_path} ({res.get('commit', {}).get('sha', '')[:8]})")


def open_pr(upstream, head_branch, base, title, body):
    try:
        pr = req("POST", f"/repos/{upstream}/pulls",
                 {"title": title, "head": f"{LOGIN}:{head_branch}",
                  "base": base, "body": body, "maintainer_can_modify": True})
        print(f"  PR: {pr['html_url']}")
        return pr["html_url"]
    except RuntimeError as e:
        print(f"  PR failed: {e}")
        return None


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
            "tailscale/tailscaled 两个二进制替换为官方最新稳定版本，保留启动脚本、"
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
        die("请先设置环境变量 GH_TOKEN（classic PAT，需 public_repo 权限）")
    if DRY:
        LOGIN = "<your-user>"
    else:
        me = req("GET", "/user")
        LOGIN = me["login"]
        print("login:", LOGIN, "\n")

    for job in JOBS:
        up = job["upstream"]
        name = up.split("/")[1]
        fork = f"{LOGIN}/{name}"
        print(f"== {up} ==")
        if DRY:
            print("  would fork, branch", job["branch"], "files:", [f[0] for f in job["files"]])
            continue
        req("POST", f"/repos/{up}/forks")
        wait_repo(fork)
        base_sha = get_sha(fork, "main")
        ensure_branch(fork, job["branch"], base_sha)
        for repo_path, local_path in job["files"]:
            if not os.path.exists(local_path):
                die(f"missing local file: {local_path}")
            put_file(fork, job["branch"], repo_path, local_path,
                     f"add {os.path.basename(repo_path)}")
        open_pr(up, job["branch"], job["base"], job["title"], job["body"])
        print()


if __name__ == "__main__":
    main()
