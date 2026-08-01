#!/usr/bin/env python3
"""
Symphony Executor (Backend HTTP Service)
This service runs in a Docker container with the repository mounted.
It receives Webhook calls from n8n to execute code modifications via Hermes.
"""

import os
import json
import subprocess
import shutil
from http.server import HTTPServer, BaseHTTPRequestHandler
import urllib.request
from concurrent.futures import ThreadPoolExecutor

PORT = 5000
LITELLM_URL = os.getenv("LITELLM_BASE_URL", "http://litellm:4000/v1/chat/completions")
WORKER_KEY = os.getenv("LITELLM_KEY_AGENT_WORKER", "")
REVIEW_B_KEY = os.getenv("LITELLM_KEY_AGENT_REVIEW_B", "")

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

class RequestHandler(BaseHTTPRequestHandler):
    def do_POST(self):
        if self.path != '/execute':
            self.send_response(404)
            self.end_headers()
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
        
        # Fork processing to avoid blocking the HTTP response
        pid = os.fork()
        if pid == 0:
            try:
                execute_task(ticket_id, description)
            except Exception as e:
                print(f"Task {ticket_id} failed completely: {e}")
            finally:
                os._exit(0)

def execute_task(ticket_id, description):
    print(f"=== Starting execution for {ticket_id} ===")
    
    # 1. Verification & Git Identity
    run_cmd(["git", "config", "--global", "user.name", "Symphony Executor"])
    run_cmd(["git", "config", "--global", "user.email", "bot@symphony"])
    # `gh` picks up GH_TOKEN from the environment automatically for its own API
    # calls, but plain `git push` does not — without this, git has no
    # credential helper configured and the push below fails.
    run_cmd(["gh", "auth", "setup-git"])
    
    repo_root = os.getcwd()
    branch_name = f"symphony/linear-{ticket_id}"
    worktree_path = f"/tmp/sandbox-{ticket_id}"
    
    # Cleanup any stale state
    subprocess.run(["git", "worktree", "remove", "--force", worktree_path], capture_output=True)
    subprocess.run(["git", "branch", "-D", branch_name], capture_output=True)
    
    # 2. Create isolation branch & worktree
    run_cmd(["git", "branch", branch_name, "main"])
    run_cmd(["git", "worktree", "add", worktree_path, branch_name])
    
    try:
        max_tries = 3
        success = False
        
        prompt_file = os.path.join(worktree_path, ".task_brief")
        with open(prompt_file, "w") as f:
            f.write(description)
            
        for attempt in range(1, max_tries + 1):
            print(f"--- Attempt {attempt}/{max_tries} ---")
            
            # 3. Hermes Worker Execution
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
                
            # 4. Gate 1: Automated Tests
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
                
            # 5. Gate 2: Multi-Model Review
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
            
        # 6. Delivery (PR)
        if success:
            print("Delivering PR...")
            run_cmd(["git", "commit", "-m", f"Agent execution for {ticket_id}"], cwd=worktree_path)
            run_cmd(["git", "push", "-u", "origin", branch_name], cwd=worktree_path)
            
            pr_title = f"[AGENT] Resolve {ticket_id}"
            pr_body = f"This PR was generated by Symphony Executor for ticket {ticket_id}."
            # Ensure GH_TOKEN is present
            run_cmd(["gh", "pr", "create", "--title", pr_title, "--body", pr_body], cwd=worktree_path)
            print("PR Created Successfully!")
        else:
            print("Failed to pass gates after 3 attempts.")
            
    finally:
        print("Cleaning up worktree...")
        subprocess.run(["git", "worktree", "remove", "--force", worktree_path], capture_output=True)
        # We leave the branch behind, but if it failed, maybe we should delete it. 
        # For now, it stays as forensic evidence if it pushed, or just local if not pushed.

if __name__ == "__main__":
    server_address = ('', PORT)
    httpd = HTTPServer(server_address, RequestHandler)
    print(f"Symphony Executor listening on port {PORT}...")
    httpd.serve_forever()
