"""Sets the container app's scale-to-zero cooldown (seconds without traffic
before it scales to zero). The CLI has no flag for it and a generic update
fails because Azure never returns secret values, so this reads them with
listSecrets and sends the app back unchanged except for the cooldown.
Nothing is printed or written to disk.

Usage: python deploy/azure/set_cooldown.py <resource-id> <seconds>
"""
import json
import subprocess
import sys
import urllib.error
import urllib.request

API = "2025-01-01"


def token():
    out = subprocess.run(
        ["az", "account", "get-access-token", "--resource", "https://management.azure.com/",
         "--query", "accessToken", "-o", "tsv"],
        capture_output=True, text=True, check=True, shell=sys.platform == "win32")
    return out.stdout.strip()


def call(method, url, tok, body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method, headers={
        "Authorization": f"Bearer {tok}", "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=120) as resp:
            raw = resp.read()
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as e:
        # Azure's error explains which field it rejected; it never echoes secrets.
        raw = (e.read() or b"").decode(errors="replace")
        raise SystemExit(f"{method} failed {e.code}: {raw[:600]}")


def main():
    resource_id, seconds = sys.argv[1], int(sys.argv[2])
    base = f"https://management.azure.com{resource_id}"
    tok = token()
    app = call("GET", f"{base}?api-version={API}", tok)
    if app["properties"]["template"]["scale"].get("cooldownPeriod") == seconds:
        print(f"cooldown already {seconds}s")
        return
    secrets = call("POST", f"{base}/listSecrets?api-version={API}", tok).get("value", [])
    body = {
        "location": app["location"],
        "identity": app.get("identity"),
        "properties": {
            "managedEnvironmentId": app["properties"]["managedEnvironmentId"],
            "configuration": {**app["properties"]["configuration"], "secrets": secrets},
            "template": app["properties"]["template"],
        },
    }
    body["properties"]["template"]["scale"]["cooldownPeriod"] = seconds
    if body["identity"] is None:
        body.pop("identity")
    call("PUT", f"{base}?api-version={API}", tok, body)
    print(f"cooldown set to {seconds}s")


if __name__ == "__main__":
    main()
