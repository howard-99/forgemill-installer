"""Sandboxed installer flow tests. No Docker, apt, systemd or network changes.
Run with Python 3, Bash and jq. On Windows, install Git Bash and either
put official jq.exe in .validation-tools or set FORGEMILL_TEST_JQ.
All host paths in a disposable script copy are redirected into a test fixture.
"""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import sys

ROOT = Path(__file__).resolve().parents[1]
BASH = Path(os.environ.get("FORGEMILL_TEST_BASH") or shutil.which("bash") or r"C:\Program Files\Git\bin\bash.exe")
JQ = Path(os.environ.get("FORGEMILL_TEST_JQ") or shutil.which("jq") or str(ROOT / ".validation-tools" / "jq.exe"))
SOURCE = (ROOT / "install-forgemill.bash").read_text(encoding="utf-8")
REPO = "ghcr.io/blink-zero/forgemill"


def posix(p):
    s = str(Path(p).resolve()).replace("\\", "/")
    return "/" + s[0].lower() + s[2:] if len(s) > 1 and s[1] == ":" else s


MOCK = r'''
import hashlib, json, os, sys, shutil
from pathlib import Path
root = Path(os.environ["FIXTURE"])
cmd, args = sys.argv[1], sys.argv[2:]
repo = "ghcr.io/blink-zero/forgemill"
statefile = root / "container.json"
def native(s):
    return s[1].upper() + ":" + s[2:] if len(s) > 2 and s[0] == "/" and s[2] == "/" else s
def write(p, s):
    p = Path(native(p)); p.parent.mkdir(parents=True, exist_ok=True); p.write_text(s)
def fail(): sys.exit(1)
def state():
    if not statefile.exists(): fail()
    return json.loads(statefile.read_text())
with (root / "calls.jsonl").open("a") as out:
    out.write(json.dumps([cmd] + args) + "\n")
release = os.environ.get("RELEASE", "v1.2.3")
hashval = hashlib.sha256(release.encode()).hexdigest()
imageid = "sha256:" + hashval
if cmd == "docker":
    if args[:1] == ["--host"]: args = args[2:]
    if args[0] == "info": sys.exit(0)
    if args[:2] == ["container", "inspect"]:
        print(json.dumps([state()])); sys.exit(0)
    if args[0] == "inspect":
        s = state()
        if "index .Config.Labels" in args[2]:
            print(s["Config"]["Labels"].get("io.forgemill.installer", ""), s["State"]["Status"], s["State"]["Health"]["Status"])
        else: print(s["State"]["Status"], s["State"]["Health"]["Status"])
        sys.exit(0)
    if args[:2] == ["image", "inspect"]:
        fmt = args[3]
        print(imageid if ".Id" in fmt else repo + "@" + imageid if ".RepoDigests" in fmt else "amd64")
        sys.exit(0)
    if args[0] == "pull":
        if os.environ.get("PULL_FAIL"): fail()
        sys.exit(0)
    if args[0] == "run":
        pub = args[args.index("--publish") + 1].split(":")
        s = {"Config":{"Labels":{"io.forgemill.installer":"v1"}, "Image":args[-1]},
             "HostConfig":{"PortBindings":{"8080/tcp":[{"HostIp":pub[0],"HostPort":pub[1]}]}},
             "State":{"Status":"running","Health":{"Status":"unhealthy" if os.environ.get("HEALTH_FAIL") else "healthy"}}}
        statefile.write_text(json.dumps(s))
        write(str(root / "app" / "data" / "forgemill.db"), "simulated persistent database")
        sys.exit(0)
    if args[0] in ("stop", "restart"):
        s = state(); s["State"]["Status"] = "exited" if args[0] == "stop" else "running"
        s["State"]["Health"]["Status"] = "healthy"
        statefile.write_text(json.dumps(s)); sys.exit(0)
    if args[0] == "rm": statefile.unlink(); sys.exit(0)
    if args[:2] == ["image", "rm"]: sys.exit(0)
    fail()
elif cmd == "curl":
    output = None
    for flag in ("-o", "--output"):
        if flag in args: output = args[args.index(flag)+1]
    if any("releases/latest" in a for a in args):
        if os.environ.get("API_FAIL"): sys.exit(22)
        write(output, json.dumps({"tag_name":release,"draft":False,"prerelease":bool(os.environ.get("PRERELEASE"))}))
    elif any(a.endswith("/api/version") for a in args):
        if os.environ.get("HEALTH_FAIL"): sys.exit(22)
        write(output, json.dumps({"version":release}))
    elif any(a.endswith("/api/auth/login") for a in args):
        payload = json.loads(Path(native(args[args.index("--data-binary")+1][1:])).read_text())
        assert payload["username"] == "admin" and len(payload["password"]) == 64
        print(os.environ.get("LOGIN_CODE", "200"), end="")
    elif any("download.docker.com" in a for a in args): write(output, "dummy GPG key for mocked apt")
    else: fail()
elif cmd == "dpkg": print(os.environ.get("ARCH", "amd64"))
elif cmd == "dpkg-query": fail()
elif cmd == "ss":
    if os.environ.get("PORT_BUSY"): print("LISTEN 0 128 0.0.0.0:8443 0.0.0.0:*")
elif cmd == "ip":
    print("1.1.1.1 via 192.0.2.1 dev eth0 src 192.0.2.10" if "route" in args else "2: eth0 inet 192.0.2.10/24 brd 192.0.2.255 scope global eth0")
elif cmd == "install":
    paths = []; i = 0
    while i < len(args):
        if args[i] in ("-m", "-o", "-g"): i += 2; continue
        if args[i] not in ("-d", "--"): paths.append(Path(native(args[i])))
        i += 1
    if "-d" in args:
        for p in paths: p.mkdir(parents=True, exist_ok=True)
    else: shutil.copyfile(paths[0], paths[1])
elif cmd == "flock":
    if os.environ.get("LOCK_BUSY"): fail()
elif cmd in ("apt-get", "systemctl", "chown", "chmod", "sleep"): pass
else: fail()
'''


class Fixture:
    def __init__(self, version="24.04"):
        (ROOT / ".validation-tools").mkdir(exist_ok=True)
        self.dir = Path(tempfile.mkdtemp(prefix="forgemill-test-", dir=ROOT / ".validation-tools"))
        for name in ("bin", "app", "systemd", "apt/keyrings", "apt/sources.list.d", "lock", "systemd-running", "tmp"):
            (self.dir / name).mkdir(parents=True, exist_ok=True)
        codename = {"22.04":"jammy", "24.04":"noble", "26.04":"resolute"}[version]
        (self.dir / "os-release").write_text(f'ID=ubuntu\nVERSION_ID="{version}"\nVERSION_CODENAME={codename}\n')
        (self.dir / "mock.py").write_text(MOCK)
        for command in ("docker", "curl", "dpkg", "dpkg-query", "ss", "ip", "apt-get", "systemctl", "flock", "chown", "chmod", "install", "sleep"):
            wrapper = f'#!/usr/bin/env bash\nexec "{posix(sys.executable)}" "{posix(self.dir / "mock.py")}" "{command}" "$@"\n'
            (self.dir / "bin" / command).write_text(wrapper, newline="\n")
            (self.dir / "bin" / command).chmod(0o755)
        script = SOURCE.replace("export PATH=/usr/sbin:/usr/bin:/sbin:/bin", f'export PATH="{posix(self.dir / "bin")}:{posix(JQ.parent)}:$PATH"')
        script = script.replace("(( EUID == 0 ))", "(( 1 == 1 ))")
        for original, replacement in (
            ("/opt/forgemill", self.dir / "app"),
            ("/etc/os-release", self.dir / "os-release"),
            ("/run/systemd/system", self.dir / "systemd-running"),
            ("/run/lock/forgemill-installer.lock", self.dir / "lock" / "installer.lock"),
            ("/etc/systemd/system", self.dir / "systemd"),
            ("/etc/apt", self.dir / "apt"),
            ("/tmp/forgemill-install.", str(self.dir / "tmp" / "forgemill-install.")),
        ):
            script = script.replace(original, posix(replacement))
        # Exercise the engine installation branch on demand, without invoking apt.
        insert = '\ncommand() { if [[ ${INSTALL_ENGINE:-} == 1 && $* == "-v docker" ]]; then return 1; fi; builtin command "$@"; }\n'
        script = script.replace("readonly APP_DIR=", insert + "readonly APP_DIR=", 1)
        (self.dir / "installer.bash").write_text(script, newline="\n")

    def run(self, expected=0, flags=(), **env):
        merged = dict(os.environ, FIXTURE=str(self.dir), MSYS2_ARG_CONV_EXCL="/CN=", **env)
        r = subprocess.run([str(BASH), posix(self.dir / "installer.bash"), *flags], env=merged, capture_output=True, text=True, timeout=90)
        assert (r.returncode == 0) == (expected == 0), (r.returncode, r.stdout, r.stderr)
        return r.stdout + r.stderr

    def calls(self):
        return [json.loads(x) for x in (self.dir / "calls.jsonl").read_text().splitlines()]

    def clear_calls(self):
        (self.dir / "calls.jsonl").write_text("")

    def close(self):
        shutil.rmtree(self.dir)


def docker_actions(f):
    return [x[3:] for x in f.calls() if x[0] == "docker"]


def fresh_and_upgrade():
    for version in ("22.04", "24.04", "26.04"):
        f = Fixture(version)
        try:
            out = f.run(INSTALL_ENGINE="1")
            assert "Login verified successfully" in out and "https://192.0.2.10:8443" in out
            secrets = {p.name: p.read_bytes() for p in (f.dir / "app/secrets").iterdir()}
            assert all(len(v.strip()) == 64 for v in secrets.values())
            assert not list((f.dir / "tmp").iterdir()), "temporary files leaked"
            assert "Suites: " + {"22.04":"jammy", "24.04":"noble", "26.04":"resolute"}[version] in (f.dir / "apt/sources.list.d/docker.sources").read_text()
            calls = docker_actions(f)
            run = next(x for x in calls if x[0] == "run")
            for flag in ("--read-only", "--init", "--restart", "--health-cmd", "--log-opt"):
                assert flag in run
            assert "https://127.0.0.1:8080/api/version" in run[run.index("--health-cmd")+1]
            assert not any("prune" in x for x in calls)
            f.clear_calls()
            out = f.run(RELEASE="v1.2.4")
            assert secrets == {p.name: p.read_bytes() for p in (f.dir / "app/secrets").iterdir()}
            actions = docker_actions(f)
            pull = next(i for i,x in enumerate(actions) if x[0] == "pull")
            stop = next(i for i,x in enumerate(actions) if x[0] == "stop")
            assert pull < stop, "running service stopped before successful pull"
            assert any(x[:2] == ["image", "rm"] and x[2].endswith(":1.2.3") for x in actions)
            assert not list((f.dir / "tmp").iterdir())
            f.clear_calls()
            out = f.run(LOGIN_CODE="401", RELEASE="v1.2.4")
            assert "use your existing password" in out and "Password: " + secrets["admin_password"].decode().strip() not in out
            print(f"PASS Ubuntu {version}: fresh Docker path, HTTPS/login, update/key preservation, changed password")
        finally: f.close()


def failure_paths():
    f = Fixture()
    try:
        f.run()
        for env in ({"API_FAIL":"1"}, {"PULL_FAIL":"1"}, {"PRERELEASE":"1"}, {"RELEASE":"bad/tag"}):
            f.clear_calls(); f.run(expected=1, **env)
            assert not any(x[0] in ("stop", "rm", "run") for x in docker_actions(f))
            assert not list((f.dir / "tmp").iterdir())
        (f.dir / "app/secrets/encryption_key").unlink()
        f.clear_calls(); out = f.run(expected=1)
        assert "must never be regenerated" in out
        assert not any(x[0] in ("stop", "rm", "run") for x in docker_actions(f))
        print("PASS release/API/pull failures preserve running app; missing encryption key refuses regeneration")
    finally: f.close()
    for env, message in (({"PORT_BUSY":"1"}, "already in use"), ({"ARCH":"arm64"}, "only linux/amd64"), ({"HEALTH_FAIL":"1"}, "did not become healthy"), ({"LOGIN_CODE":"401"}, "login verification failed")):
        f = Fixture()
        try:
            out = f.run(expected=1, **env)
            assert message in out, out
            assert "ForgeMill is ready" not in out
            assert not list((f.dir / "tmp").iterdir())
        finally: f.close()
    f = Fixture()
    try:
        (f.dir / "app/foreign.txt").write_text("keep me")
        assert "unmanaged" in f.run(expected=1)
        assert (f.dir / "app/foreign.txt").read_text() == "keep me"
    finally: f.close()
    f = Fixture()
    try:
        # An interrupted install with a marker but no DB may finish generating secrets.
        (f.dir / "app/.managed-by-installer").write_text("forgemill-installer-v1\n")
        assert "Login verified successfully" in f.run()
        print("PASS port/architecture/health/login failures, unmanaged directory, interrupted install recovery")
    finally: f.close()



def health_and_bind():
    f = Fixture()
    try:
        f.run()
        f.clear_calls()
        out = f.run(flags=("--bind", "192.0.2.10"), PORT_BUSY="1")
        assert "https://192.0.2.10:8443" in out
        assert json.loads((f.dir / "app/settings.json").read_text())["bind"] == "192.0.2.10"
        helper = f.dir / "app/check-health.bash"
        for status, label, locked, restart in (
            ("running", "v1", False, True),
            ("exited", "v1", False, False),
            ("running", "foreign", False, False),
            ("running", "v1", True, False),
        ):
            s = json.loads((f.dir / "container.json").read_text())
            s["State"]["Status"] = status
            s["State"]["Health"]["Status"] = "unhealthy"
            s["Config"]["Labels"]["io.forgemill.installer"] = label
            (f.dir / "container.json").write_text(json.dumps(s))
            f.clear_calls()
            r = subprocess.run([str(BASH), posix(helper)], env=dict(os.environ, FIXTURE=str(f.dir), LOCK_BUSY="1" if locked else ""), capture_output=True, text=True, timeout=20)
            assert r.returncode == 0, (r.stdout, r.stderr)
            assert any(x[0] == "restart" for x in docker_actions(f)) == restart
        print("PASS bind-address update, unhealthy recovery, intentional stop, foreign container, installer lock")
    finally: f.close()

def cli_and_format():
    assert "\r" not in SOURCE and not SOURCE.startswith("\ufeff")
    r = subprocess.run([str(BASH), "-n", str(ROOT / "install-forgemill.bash")], capture_output=True)
    assert r.returncode == 0
    for flags in (("--port","0"), ("--port","65536"), ("--port","999999"), ("--bind","999.1.1.1"), ("--bind","010.1.1.1"), ("--port",), ("--bogus",)):
        r = subprocess.run([str(BASH), str(ROOT / "install-forgemill.bash"), *flags], capture_output=True)
        assert r.returncode == 1, flags
    print("PASS Bash syntax, LF/no BOM, invalid arguments")


if __name__ == "__main__":
    if not BASH.is_file() or not JQ.is_file():
        raise SystemExit("Tests require Bash and jq. Set FORGEMILL_TEST_BASH / FORGEMILL_TEST_JQ to their binary paths.")
    cli_and_format()
    fresh_and_upgrade()
    failure_paths()
    health_and_bind()
    print("All sandboxed flow tests passed. These do not replace real Ubuntu VM testing.")
