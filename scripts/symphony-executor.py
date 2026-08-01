#!/usr/bin/env python3
"""
Symphony Executor (Backend HTTP Service)
This service runs in a long-lived Docker container. It receives webhook calls
from n8n to execute code modifications via Hermes, in an isolated git worktree
of its own dedicated clone (never the host's live ops checkout).
"""

import hmac
import json
import os
import subprocess
import threading
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = 5000
LITELLM_URL = os.getenv("LITELLM_BASE_URL", "http://litellm:4000/v1/chat/completions")
WORKER_KEY = os.getenv("LITELLM_KEY_AGENT_WORKER", "")
REVIEW_B_KEY = os.getenv("LITELLM_KEY_AGENT_REVIEW_B", "")
EXECUTOR_SECRET = os.getenv("SYMPHONY_EXECUTOR_SECRET", "")
REPO_URL = os.getenv("SYMPHONY_REPO_URL", "https://github.com/Exawyll/agent-infra.git")
REPO_DIR = os.getcwd()


def run_cmd(cmd, cwd=None, check=True):
    print(f"Running: {' '.join(cmd)}")
    result = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True)
    if check and result.returncode != 0:
        raise Exception(f"Command failed ({result.returncode}): {' '.join(cmd)}\n{result.stderr}\n{result.stdout}")
    return result


def review_code(diff, model, api_key):
    print(f"Requesting review from {model}...")
    headers = {
        "Content-Type": "application/json",
        "Authorization": f"Bearer {api_key}"
    }
    payload = {
        "model": model,
        "messages": [
            {
                "role": "system",
                "content": "You are a strict code reviewer. Review the following diff. If there are critical architecture flaws, security vulnerabilities, or major bugs, reply with 'BLOCK' and explain why. If there are only minor nits or it's good, reply with 'APPROVE'."
            },
            {
                "role": "user",
                "content": f"Git Diff:\n```diff\n{diff}\n```"
            }
        ]
    }

    req = urllib.request.Request(LITELLM_URL, data=json.dumps(payload).encode(), headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=120) as response:
            data = json.loads(response.read().decode())
            return data["choices"][0]["message"]["content"]
    except Exception as e:
        print(f"Review API error for {model}: {e}")
        return "BLOCK: Review API failed."


def ensure_repo():
    """Clone (once) or refresh the executor's own dedicated checkout.

    Deliberately never reuses the host's live ops checkout: the worker runs
    with a terminal toolset over LLM-generated code, so its blast radius must
    stay confined to a clone the executor owns — not the same working
    directory deploy.sh and the human operator use.
    """
    if not os.path.isdir(os.path.join(REPO_DIR, ".git")):
        print(f"Cloning {REPO_URL} into {REPO_DIR}...")
        run_cmd(["git", "clone", REPO_URL, REPO_DIR])
    else:
        print("Refreshing existing clone...")
        run_cmd(["git", "fetch", "origin"], cwd=REPO_DIR)
        run_cmd(["git", "checkout", "main"], cwd=REPO_DIR)
        run_cmd(["git", "reset", "--hard", "origin/main"], cwd=REPO_DIR)


class RequestHandler(BaseHTTPRequestHandler):
    def do_POST(self):
        if self.path != '/execute':
            self.send_response(404)
            self.end_headers()
            return

        provided_secret = self.headers.get('X-Symphony-Secret', '')
        if not EXECUTOR_SECRET or not hmac.compare_digest(provided_secret, EXECUTOR_SECRET):
            print("Rejected /execute call: missing or invalid X-Symphony-Secret")
            self.send_response(401)
            self.end_headers()
            self.wfile.write(b"Unauthorized")
            return

        content_length = int(self.headers['Content-Length'])
        post_data = self.rfile.read(content_length)
        payload = json.loads(post_data)

        ticket_id = payload.get("ticket_id")
        description = payload.get("description")

        if not ticket_id or not description:
            self.send_response(400)
            self.end_headers()
            self.wfile.write(b"Missing ticket_id or description")
            return

        self.send_response(202)
        self.end_headers()
        self.wfile.write(b"Execution started")

        # Hand off to a background thread so the HTTP response returns immediately.
        threading.Thread(target=execute_task, args=(ticket_id, description), daemon=True).start()

    def log_message(self, format, *args):
        print(f"{self.address_string()} - {format % args}")


def execute_task(ticket_id, description):
    print(f"=== Starting execution for {ticket_id} ===")

    try:
        ensure_repo()
    except Exception as e:
        print(f"Task {ticket_id} failed: could not prepare repo clone: {e}")
        return

    # Git Identity + credentials. `gh` picks up GH_TOKEN from the environment
    # automatically for its own API calls, but plain `git push` does not —
    # without `gh auth setup-git`, git has no credential helper configured
    # and the push below fails.
    run_cmd(["git", "config", "--global", "user.name", "Symphony Executor"])
    run_cmd(["git", "config", "--global", "user.email", "bot@symphony"])
    run_cmd(["gh", "auth", "setup-git"])

    branch_name = f"symphony/linear-{ticket_id}"
    worktree_path = f"/tmp/sandbox-{ticket_id}"

    # Cleanup any stale state
    subprocess.run(["git", "worktree", "remove", "--force", worktree_path], capture_output=True, cwd=REPO_DIR)
    subprocess.run(["git", "branch", "-D", branch_name], capture_output=True, cwd=REPO_DIR)

    # Create isolation branch & worktree, off the freshly-synced main
    run_cmd(["git", "branch", branch_name, "origin/main"], cwd=REPO_DIR)
    run_cmd(["git", "worktree", "add", worktree_path, branch_name], cwd=REPO_DIR)

    try:
        max_tries = 3
        success = False

        prompt_file = os.path.join(worktree_path, ".task_brief")
        with open(prompt_file, "w") as f:
            f.write(description)

        for attempt in range(1, max_tries + 1):
            print(f"--- Attempt {attempt}/{max_tries} ---")

            # Hermes Worker Execution
            try:
                run_cmd([
                    "hermes", "chat", "-q",
                    "--profile", "worker",
                    "--prompt-file", ".task_brief"
                ], cwd=worktree_path)
            except Exception as e:
                print(f"Hermes execution failed: {e}")
                # We can choose to block or retry, but let's let the review gate handle empty diffs

            # Check diff
            run_cmd(["git", "add", "-A"], cwd=worktree_path)
            diff = run_cmd(["git", "diff", "--staged"], cwd=worktree_path).stdout.strip()

            if not diff:
                print("No changes made by Hermes.")
                with open(prompt_file, "a") as f:
                    f.write("\n\n[SYSTEM]: You made no changes to the code. Please implement the requested feature.\n")
                continue

            # Gate 1: Automated Tests
            tests_passed = True
            test_output = ""
            if os.path.exists(os.path.join(worktree_path, "package.json")):
                print("Running npm test...")
                test_result = subprocess.run(["npm", "test"], cwd=worktree_path, capture_output=True, text=True)
                if test_result.returncode != 0:
                    tests_passed = False
                    test_output = test_result.stderr + "\n" + test_result.stdout
                    print("Tests failed!")

            if not tests_passed:
                with open(prompt_file, "a") as f:
                    f.write(f"\n\n[SYSTEM TEST FAILURE]: Your code failed the tests:\n```\n{test_output}\n```\nPlease fix the issues.\n")
                # Reset staged changes for next attempt
                run_cmd(["git", "reset", "HEAD"], cwd=worktree_path)
                continue

            # Gate 2: Multi-Model Review
            print("Gate 1 passed. Requesting multi-model review...")
            with ThreadPoolExecutor(max_workers=2) as executor:
                f1 = executor.submit(review_code, diff, "review", WORKER_KEY)
                f2 = executor.submit(review_code, diff, "review-b", REVIEW_B_KEY)

                rev1 = f1.result()
                rev2 = f2.result()

            block1 = "BLOCK" in rev1.upper()
            block2 = "BLOCK" in rev2.upper()

            if block1 or block2:
                print(f"Review failed. Model A Blocked: {block1}. Model B Blocked: {block2}")
                with open(prompt_file, "a") as f:
                    f.write("\n\n[SYSTEM REVIEW FAILURE]: The code review rejected your changes. Please fix:\n")
                    if block1: f.write(f"\nReviewer A (GLM-5.2):\n{rev1}\n")
                    if block2: f.write(f"\nReviewer B (Claude):\n{rev2}\n")
                run_cmd(["git", "reset", "HEAD"], cwd=worktree_path)
                continue

            print("Gate 2 passed. Reviews are green!")
            success = True
            break

        # Delivery (PR)
        if success:
            print("Delivering PR...")
            run_cmd(["git", "commit", "-m", f"Agent execution for {ticket_id}"], cwd=worktree_path)
            run_cmd(["git", "push", "-u", "origin", branch_name], cwd=worktree_path)

            pr_title = f"[AGENT] Resolve {ticket_id}"
            pr_body = f"This PR was generated by Symphony Executor for ticket {ticket_id}."
            run_cmd(["gh", "pr", "create", "--title", pr_title, "--body", pr_body], cwd=worktree_path)
            print("PR Created Successfully!")
        else:
            print("Failed to pass gates after 3 attempts.")

    finally:
        print("Cleaning up worktree...")
        subprocess.run(["git", "worktree", "remove", "--force", worktree_path], capture_output=True, cwd=REPO_DIR)
        # We leave the branch behind, but if it failed, maybe we should delete it.
        # For now, it stays as forensic evidence if it pushed, or just local if not pushed.


if __name__ == "__main__":
    if not EXECUTOR_SECRET:
        print("WARNING: SYMPHONY_EXECUTOR_SECRET is not set — /execute will reject every request.")
    ensure_repo()
    server_address = ('', PORT)
    httpd = ThreadingHTTPServer(server_address, RequestHandler)
    print(f"Symphony Executor listening on port {PORT}...")
    httpd.serve_forever()
