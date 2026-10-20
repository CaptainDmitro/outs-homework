"""Запуск скриптов на VM без публичного IP: скрипт уходит в метаданные сервера,
агент на VM (cloud-init/user-data.yaml) выполняет его и пишет вывод в серийную консоль.

  python3 vkcmd.py send  <server_id> <cmd_id> <script.sh> [файлы...]   файлы кладутся в /opt/bench
  python3 vkcmd.py fetch <server_id> <cmd_id> <out.log>                 достать вывод из консоли
  python3 vkcmd.py tail  <server_id> [N]                                хвост консоли без base64
Учётка берётся из OS_* переменных openrc.
"""
import base64
import gzip
import json
import os
import re
import sys
import urllib.request

COMPUTE = "https://infra.mail.ru:8774/v2.1"


def token():
    body = {"auth": {
        "identity": {"methods": ["password"], "password": {"user": {
            "name": os.environ["OS_USERNAME"],
            "domain": {"name": os.environ["OS_USER_DOMAIN_NAME"]},
            "password": os.environ["OS_PASSWORD"]}}},
        "scope": {"project": {"id": os.environ["OS_PROJECT_ID"]}}}}
    req = urllib.request.Request(os.environ["OS_AUTH_URL"] + "auth/tokens",
                                 json.dumps(body).encode(), {"Content-Type": "application/json"})
    return urllib.request.urlopen(req).headers["X-Subject-Token"]


def call(url, data):
    req = urllib.request.Request(url, json.dumps(data).encode(),
                                 {"X-Auth-Token": token(), "Content-Type": "application/json"})
    return urllib.request.urlopen(req).read().decode()


def send(server, cid, script, files):
    prelude = "mkdir -p /opt/bench\n"
    for path in files:
        prelude += f"cat > /opt/bench/{os.path.basename(path)} <<'EOF_BENCH'\n{open(path).read()}EOF_BENCH\n"
    prelude += "[ -f /opt/bench/env.sh ] && . /opt/bench/env.sh\n"
    data = base64.b64encode(gzip.compress((prelude + open(script).read()).encode())).decode()
    chunks = [data[i:i + 255] for i in range(0, len(data), 255)]
    assert len(chunks) <= 120, f"скрипт слишком большой: {len(chunks)} кусков"
    meta = {"cmd_id": cid, "cmd_n": str(len(chunks))}
    meta.update({f"c{i:03d}": c for i, c in enumerate(chunks)})
    call(f"{COMPUTE}/servers/{server}/metadata", {"metadata": meta})
    print(f"sent {cid}: {len(chunks)} chunks")


def console(server):
    out = call(f"{COMPUTE}/servers/{server}/action", {"os-getConsoleOutput": {}})
    return json.loads(out)["output"].replace("\r", "")


def fetch(server, cid, out):
    text = console(server)
    m = re.search(rf"=== OUT {re.escape(cid)} BEGIN\n(.*?)=== OUT {re.escape(cid)} END rc=(\d+)", text, re.S)
    if not m:
        sys.exit(f"{cid}: вывода в консоли нет")
    b64 = "".join(line[4:] for line in m.group(1).splitlines() if line.startswith("B64:"))
    with open(out, "wb") as f:
        f.write(gzip.decompress(base64.b64decode(b64)))
    print(f"{cid}: rc={m.group(2)} -> {out}")


def tail(server, n):
    lines = [line for line in console(server).splitlines() if not line.startswith("B64:")]
    print("\n".join(lines[-n:]))


if __name__ == "__main__":
    cmd, server, *rest = sys.argv[1:]
    if cmd == "send":
        send(server, rest[0], rest[1], rest[2:])
    elif cmd == "fetch":
        fetch(server, rest[0], rest[1])
    else:
        tail(server, int(rest[0]) if rest else 40)
