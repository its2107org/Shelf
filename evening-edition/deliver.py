"""Links to Ian's reMarkable account with a one-time code and uploads a PDF,
using the same simple upload the reMarkable web library uses.

Usage: RM_CODE=xxxxxxxx python deliver.py link
       python deliver.py put <file.pdf>
"""
import base64, json, os, sys, urllib.error, urllib.request, uuid

AUTH = "https://webapp-prod.cloud.remarkable.engineering"
HOSTS = ["https://internal.cloud.remarkable.com", "https://web.eu.tectonic.remarkable.com"]
STATE = os.path.join(os.environ.get("RUNNER_TEMP", "/tmp"), "rm.json")


def post(url, body, headers):
    req = urllib.request.Request(url, data=body, headers=headers, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            return r.status, r.read()
    except urllib.error.HTTPError as e:
        print("HTTP", e.code, "from", url.split("?")[0], e.read()[:300])
        raise


def link():
    code = os.environ["RM_CODE"].strip()
    _, token = post(f"{AUTH}/token/json/2/device/new",
                    json.dumps({"code": code, "deviceDesc": "browser-chrome", "deviceID": str(uuid.uuid4())}).encode(),
                    {"Content-Type": "application/json"})
    token = token.decode().strip()
    if not token:
        sys.exit("No token returned; the code may have expired")
    print("::add-mask::" + token)
    json.dump({"device": token}, open(STATE, "w"))
    print("Linked to the reMarkable account")


def put(path):
    device = json.load(open(STATE))["device"]
    _, user = post(f"{AUTH}/token/json/2/user/new", b"", {"Authorization": f"Bearer {device}"})
    user = user.decode().strip()
    print("::add-mask::" + user)
    name = os.path.splitext(os.path.basename(path))[0]
    meta = base64.b64encode(json.dumps({"file_name": name}).encode()).decode()
    data = open(path, "rb").read()
    last = None
    for host in HOSTS:
        try:
            status, body = post(f"{host}/doc/v2/files", data, {
                "Authorization": f"Bearer {user}", "rm-meta": meta, "rm-source": "WebLibrary",
                "Content-Type": "application/pdf"})
            print("Uploaded", name, "via", host, status, body[:200])
            return
        except Exception as e:  # noqa: BLE001
            last = e
            print("upload via", host, "failed:", e, getattr(e, "read", lambda: b"")()[:300])
    sys.exit(f"Upload failed: {last}")


if __name__ == "__main__":
    link() if sys.argv[1] == "link" else put(sys.argv[2])
