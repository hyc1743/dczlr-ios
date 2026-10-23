"""Noninteractive GitHub transport. Tokens stay in memory and child environments."""
import argparse
import base64
import json
import os
from pathlib import Path
import re
import subprocess
import urllib.error
import urllib.parse
import urllib.request


def credential(directory, username=None):
    token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")
    if token:
        return token.strip()
    if username and not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9-]{0,63}", username):
        raise ValueError("Invalid GitHub credential username")
    query = "protocol=https\nhost=github.com\n"
    if username:
        query += "username=" + username + "\n"
    result = subprocess.run(
        ["git", "-c", "credential.interactive=false", "credential", "fill"],
        cwd=directory, input=query + "\n",
        capture_output=True, text=True, timeout=30,
        env=dict(os.environ, GCM_INTERACTIVE="Never", GIT_TERMINAL_PROMPT="0"))
    values = dict(line.split("=", 1) for line in result.stdout.splitlines() if "=" in line)
    if result.returncode or not values.get("password"):
        raise ValueError("No existing noninteractive GitHub credential")
    return values["password"]


class Redirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, *args):
        redirected = super().redirect_request(request, *args)
        if redirected:
            if not redirected.full_url.startswith("https://"):
                raise ValueError("Refusing insecure redirect")
            if urllib.parse.urlsplit(request.full_url).netloc != urllib.parse.urlsplit(redirected.full_url).netloc:
                redirected.remove_header("Authorization")
        return redirected


def request(token, method, path, body=None, binary=False):
    if not path.startswith("/") or path.startswith("//"):
        raise ValueError("Invalid GitHub API path")
    req = urllib.request.Request(
        "https://api.github.com" + path, method=method,
        data=json.dumps(body).encode() if body is not None else None,
        headers={"Authorization": "Bearer " + token, "Accept": "application/vnd.github+json",
                 "User-Agent": "PortLab-build", "Content-Type": "application/json",
                 "X-GitHub-Api-Version": "2022-11-28"})
    with urllib.request.build_opener(Redirect()).open(req, timeout=60) as response:
        data = response.read()
    return data if binary else (json.loads(data) if data else None)


def push(token, repository, root):
    auth = base64.b64encode(("x-access-token:" + token).encode()).decode()
    env = dict(os.environ, GCM_INTERACTIVE="Never", GIT_TERMINAL_PROMPT="0",
               GIT_CONFIG_COUNT="2", GIT_CONFIG_KEY_0="credential.helper", GIT_CONFIG_VALUE_0="",
               GIT_CONFIG_KEY_1="http.https://github.com/.extraheader",
               GIT_CONFIG_VALUE_1="Authorization: Basic " + auth)
    result = subprocess.run(
        ["git", "push", "https://github.com/" + repository + ".git", "HEAD:refs/heads/main"],
        cwd=root, env=env, capture_output=True, text=True, timeout=180)
    if result.returncode:
        raise ValueError("Noninteractive git push failed (exit " + str(result.returncode) + ")")
    return {"repository": repository, "pushed": True}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--credential-dir", type=Path)
    parser.add_argument("--credential-user", help="Select an existing account when the credential store has multiple GitHub accounts")
    parser.add_argument("action", choices=["identity", "ensure-public", "push", "runs", "jobs", "artifacts", "job-log", "artifact"])
    parser.add_argument("--repo", default="hyc1743/dczlr-ios")
    parser.add_argument("--id", type=int)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", args.repo):
        raise ValueError("Expected owner/repository")
    token = credential(args.credential_dir, args.credential_user)
    prefix = "/repos/" + args.repo
    if args.action == "identity":
        user = request(token, "GET", "/user")
        result = {"login": user["login"], "id": user["id"]}
    elif args.action == "ensure-public":
        user = request(token, "GET", "/user")
        owner, name = args.repo.split("/")
        if owner != user["login"]:
            raise ValueError("Refusing repository creation under a different account")
        try:
            repo = request(token, "GET", prefix)
        except urllib.error.HTTPError as error:
            if error.code != 404:
                raise
            repo = request(token, "POST", "/user/repos", {
                "name": name, "private": False, "auto_init": False,
                "description": "Experimental iOS platform host. Windows game execution is not implemented."})
        if repo["private"]:
            raise ValueError("Existing repository is private; visibility was not changed")
        result = {key: repo[key] for key in ("full_name", "html_url", "private")}
    elif args.action == "push":
        result = push(token, args.repo, Path.cwd())
    elif args.action == "runs":
        runs = request(token, "GET", prefix + "/actions/runs?per_page=5")["workflow_runs"]
        result = [{key: run[key] for key in ("id", "head_sha", "name", "status", "conclusion", "html_url")} for run in runs]
    elif args.action == "jobs":
        if args.id is None:
            raise ValueError("--id is required")
        jobs = request(token, "GET", prefix + f"/actions/runs/{args.id}/jobs")["jobs"]
        result = [{key: job[key] for key in ("id", "name", "status", "conclusion", "steps")} for job in jobs]
    elif args.action == "artifacts":
        if args.id is None:
            raise ValueError("--id is required")
        values = request(token, "GET", prefix + f"/actions/runs/{args.id}/artifacts")["artifacts"]
        result = [{key: value[key] for key in ("id", "name", "size_in_bytes", "expired")} for value in values]
    else:
        if args.id is None or args.output is None:
            raise ValueError("--id and --output are required")
        path = prefix + (f"/actions/jobs/{args.id}/logs" if args.action == "job-log" else f"/actions/artifacts/{args.id}/zip")
        data = request(token, "GET", path, binary=True)
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_bytes(data)
        result = {"saved": str(args.output), "bytes": len(data)}
    print(json.dumps(result, ensure_ascii=True, indent=2))


if __name__ == "__main__":
    try:
        main()
    except urllib.error.HTTPError as error:
        raise SystemExit("GitHub HTTP " + str(error.code))
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        raise SystemExit(str(error) if isinstance(error, ValueError) else type(error).__name__)
