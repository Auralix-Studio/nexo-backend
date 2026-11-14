"""Builds the backend image without Docker and pushes it to the Azure registry.

Azure for Students blocks ACR Tasks, and Docker may not be available, so:

1. `mix release` is built locally with RELEASE_INCLUDE_ERTS=false (the code
   has no native dependencies, so the BEAM files run on Linux as they are);
2. the release becomes one extra layer on top of the official Erlang image
   (same OTP version as the local one), copied from Docker Hub to the
   registry;
3. a new image config and manifest are written and pushed.

Usage (run by deploy.sh):
    python deploy/azure/push_image.py <registry> <user> <password> <tag> [<tag>...]

Only the standard library is used.
"""

import base64
import gzip
import hashlib
import io
import json
import os
import sys
import tarfile
import time
import urllib.error
import urllib.parse
import urllib.request

BASE_REPO = "hexpm/erlang"
BASE_TAG = "28.5-debian-trixie-20260610-slim"
REPO = "nexo-backend"
RELEASE_DIR = os.path.join("_build", "prod", "rel", "nexo")

INDEX_TYPES = [
    "application/vnd.oci.image.index.v1+json",
    "application/vnd.docker.distribution.manifest.list.v2+json",
]
MANIFEST_TYPES = [
    "application/vnd.oci.image.manifest.v1+json",
    "application/vnd.docker.distribution.manifest.v2+json",
]
LAYER_TYPE = {
    "application/vnd.oci.image.manifest.v1+json": "application/vnd.oci.image.layer.v1.tar+gzip",
    "application/vnd.docker.distribution.manifest.v2+json": "application/vnd.docker.image.rootfs.diff.tar.gzip",
}
CONFIG_TYPE = {
    "application/vnd.oci.image.manifest.v1+json": "application/vnd.oci.image.config.v1+json",
    "application/vnd.docker.distribution.manifest.v2+json": "application/vnd.docker.container.image.v1+json",
}

# Text files Windows checked out or generated with CRLF; Linux needs LF.
TEXT_FILES = {
    "bin/nexo",
    "bin/server",
    "releases/start_erl.data",
    "releases/0.1.0/env.sh",
    "releases/0.1.0/vm.args",
    "releases/0.1.0/remote.vm.args",
    "releases/0.1.0/elixir",
    "releases/0.1.0/iex",
}
EXECUTABLES = {"bin/nexo", "bin/server", "releases/0.1.0/elixir", "releases/0.1.0/iex"}


def log(msg):
    print(f"   {msg}", flush=True)


def request(method, url, headers=None, data=None, ok=(200, 201, 202, 204, 307)):
    req = urllib.request.Request(url, data=data, method=method, headers=headers or {})
    try:
        resp = urllib.request.urlopen(req, timeout=300)
        return resp.status, dict(resp.headers), resp.read()
    except urllib.error.HTTPError as e:
        if e.code in ok:
            return e.code, dict(e.headers), e.read()
        raise SystemExit(f"{method} {url} -> {e.code}: {e.read()[:300]!r}")


class Registry:
    def __init__(self, host, user=None, password=None):
        self.host = host
        self.base = f"https://{host}"
        self.basic = (
            "Basic " + base64.b64encode(f"{user}:{password}".encode()).decode()
            if user
            else None
        )
        self.tokens = {}

    def token(self, scope):
        if scope in self.tokens:
            return self.tokens[scope]
        req = urllib.request.Request(f"{self.base}/v2/", method="GET")
        try:
            urllib.request.urlopen(req, timeout=60)
            self.tokens[scope] = None
            return None
        except urllib.error.HTTPError as e:
            challenge = e.headers.get("WWW-Authenticate", "")
        params = dict(
            part.split("=", 1) for part in challenge.split(" ", 1)[1].replace('"', "").split(",")
        )
        query = {"service": params.get("service", ""), "scope": scope}
        headers = {"Authorization": self.basic} if self.basic else {}
        _, _, body = request("GET", params["realm"] + "?" + urllib.parse.urlencode(query), headers)
        data = json.loads(body)
        self.tokens[scope] = data.get("token") or data.get("access_token")
        return self.tokens[scope]

    def headers(self, repo, actions, extra=None):
        tok = self.token(f"repository:{repo}:{actions}")
        h = {"Authorization": f"Bearer {tok}"} if tok else {}
        h.update(extra or {})
        return h

    def manifest(self, repo, ref, accept):
        _, hdrs, body = request(
            "GET",
            f"{self.base}/v2/{repo}/manifests/{ref}",
            self.headers(repo, "pull", {"Accept": ", ".join(accept)}),
        )
        return hdrs.get("Content-Type", "").split(";")[0], body

    def blob(self, repo, digest):
        _, _, body = request("GET", f"{self.base}/v2/{repo}/blobs/{digest}", self.headers(repo, "pull"))
        return body

    def has_blob(self, repo, digest):
        status, _, _ = request(
            "HEAD", f"{self.base}/v2/{repo}/blobs/{digest}", self.headers(repo, "pull,push"), ok=(200, 404)
        )
        return status == 200

    def push_blob(self, repo, digest, data):
        if self.has_blob(repo, digest):
            return
        _, hdrs, _ = request(
            "POST", f"{self.base}/v2/{repo}/blobs/uploads/", self.headers(repo, "pull,push")
        )
        location = hdrs.get("Location") or hdrs.get("location")
        if location.startswith("/"):
            location = self.base + location
        sep = "&" if "?" in location else "?"
        request(
            "PUT",
            f"{location}{sep}digest={urllib.parse.quote(digest)}",
            self.headers(repo, "pull,push", {"Content-Type": "application/octet-stream"}),
            data,
        )

    def push_manifest(self, repo, tag, media_type, body):
        request(
            "PUT",
            f"{self.base}/v2/{repo}/manifests/{tag}",
            self.headers(repo, "pull,push", {"Content-Type": media_type}),
            body,
        )


def sha256(data):
    return "sha256:" + hashlib.sha256(data).hexdigest()


def release_layer():
    """The release under /app as a tar layer: (gzipped bytes, diff_id)."""
    if not os.path.isfile(os.path.join(RELEASE_DIR, "bin", "nexo")):
        raise SystemExit(f"No release in {RELEASE_DIR}. Run MIX_ENV=prod RELEASE_INCLUDE_ERTS=false mix release.")
    raw = io.BytesIO()
    now = int(time.time())
    with tarfile.open(fileobj=raw, mode="w", format=tarfile.PAX_FORMAT) as tar:
        def add_dir(name):
            info = tarfile.TarInfo(name)
            info.type, info.mode, info.mtime = tarfile.DIRTYPE, 0o755, now
            tar.addfile(info)

        add_dir("app")
        for root, dirs, files in os.walk(RELEASE_DIR):
            dirs.sort()
            rel_root = os.path.relpath(root, RELEASE_DIR).replace("\\", "/")
            if rel_root != ".":
                add_dir(f"app/{rel_root}")
            for name in sorted(files):
                if name.endswith(".bat"):
                    continue
                rel = name if rel_root == "." else f"{rel_root}/{name}"
                with open(os.path.join(root, name), "rb") as fh:
                    content = fh.read()
                if rel in TEXT_FILES:
                    content = content.replace(b"\r\n", b"\n")
                info = tarfile.TarInfo(f"app/{rel}")
                info.size, info.mtime = len(content), now
                info.mode = 0o755 if rel in EXECUTABLES else 0o644
                tar.addfile(info, io.BytesIO(content))
    tar_bytes = raw.getvalue()
    return gzip.compress(tar_bytes, mtime=0), sha256(tar_bytes)


def main():
    if len(sys.argv) < 5:
        raise SystemExit(__doc__)
    host, user, password, *tags = sys.argv[1:]
    hub = Registry("registry-1.docker.io")
    acr = Registry(host, user, password)

    print(f"==> Base image {BASE_REPO}:{BASE_TAG}", flush=True)
    media, body = hub.manifest(BASE_REPO, BASE_TAG, INDEX_TYPES + MANIFEST_TYPES)
    if media in INDEX_TYPES:
        index = json.loads(body)
        entry = next(
            m for m in index["manifests"]
            if m.get("platform", {}).get("os") == "linux"
            and m.get("platform", {}).get("architecture") == "amd64"
        )
        media, body = hub.manifest(BASE_REPO, entry["digest"], MANIFEST_TYPES)
    base = json.loads(body)
    config = json.loads(hub.blob(BASE_REPO, base["config"]["digest"]))

    print(f"==> Copying {len(base['layers'])} base layers to {host}", flush=True)
    for layer in base["layers"]:
        if acr.has_blob(REPO, layer["digest"]):
            log(f"{layer['digest'][:19]} already there")
            continue
        log(f"{layer['digest'][:19]} {layer['size'] // 1_000_000} MB")
        acr.push_blob(REPO, layer["digest"], hub.blob(BASE_REPO, layer["digest"]))

    print("==> Release layer", flush=True)
    layer, diff_id = release_layer()
    layer_digest = sha256(layer)
    log(f"{layer_digest[:19]} {len(layer) // 1000} KB")
    acr.push_blob(REPO, layer_digest, layer)

    cfg = config.setdefault("config", {})
    env = [e for e in cfg.get("Env") or [] if not e.startswith(("LANG=", "MIX_ENV=", "HOME="))]
    cfg["Env"] = env + ["LANG=C.UTF-8", "LC_ALL=C.UTF-8", "MIX_ENV=prod", "HOME=/app"]
    cfg["WorkingDir"] = "/app"
    cfg["Entrypoint"] = None
    cfg["Cmd"] = ["/app/bin/server"]
    cfg["ExposedPorts"] = {"4000/tcp": {}}
    config["rootfs"]["diff_ids"].append(diff_id)
    config.setdefault("history", []).append(
        {"created": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "created_by": "nexo release layer"}
    )
    config.pop("container_config", None)
    config_bytes = json.dumps(config, separators=(",", ":")).encode()
    config_digest = sha256(config_bytes)
    acr.push_blob(REPO, config_digest, config_bytes)

    manifest = {
        "schemaVersion": 2,
        "mediaType": media,
        "config": {"mediaType": CONFIG_TYPE[media], "digest": config_digest, "size": len(config_bytes)},
        "layers": base["layers"]
        + [{"mediaType": LAYER_TYPE[media], "digest": layer_digest, "size": len(layer)}],
    }
    manifest_bytes = json.dumps(manifest, separators=(",", ":")).encode()
    for tag in tags:
        acr.push_manifest(REPO, tag, media, manifest_bytes)
        print(f"==> Pushed {host}/{REPO}:{tag}", flush=True)


if __name__ == "__main__":
    main()
