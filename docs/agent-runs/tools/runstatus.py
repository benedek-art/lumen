import json, subprocess, sys
for sha in sys.argv[1:]:
    url = f"https://api.github.com/repos/benedek-art/lumen/actions/runs?head_sha={sha}"
    out = subprocess.run(["curl", "-s", url], capture_output=True, text=True).stdout
    for r in json.loads(out).get("workflow_runs", []):
        print(sha[:8], r["id"], r["name"], r["status"], r["conclusion"])
