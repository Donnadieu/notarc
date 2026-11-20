#!/usr/bin/env python3
"""Release check on the FINAL app: NotArc as the default browser (Omar, Nov 19 2026: "How can I make NotArc my
default browser?").

1. Info.plist: macOS lists an app as a web browser when it takes http and https links; HTML and XHTML files open in
   it too.
2. Links handed over by Launch Services, the path Mail, Slack, One and `open https://...` use, to a hidden copy in a
   throwaway home (NOTARC_SELFTEST_ONLY=openlinks):
   - cold: the first link is sent while NotArc is still starting, and must end up as the shown tab with no lost URL,
     no Little window and no second window;
   - warm: a link to the running copy, a link with a second window in front (lands there), two links at once, and a
     local .html file.
   scripts/lsopen.m only ever sends to the copy this script started, never to another NotArc.
Usage: scripts/test-open-links.py <NotArc.app>
"""
import os
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import time
from urllib.parse import unquote

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
COLD = "https://links-cold.example/from-mail?id=42#top"
REQUIRED = ["OPENLINKS-COLD", "OPENLINKS-WARM", "OPENLINKS-FRONT", "OPENLINKS-MULTI", "OPENLINKS-FILE", "REALPROFILE"]


def copies(app):
    """Process ids running this app's own binary (libproc; /bin/ps may be unavailable)."""
    import ctypes
    lib = ctypes.CDLL("/usr/lib/libproc.dylib")
    n = lib.proc_listallpids(None, 0)
    pids = (ctypes.c_int * (n * 2))()
    n = lib.proc_listallpids(pids, ctypes.sizeof(pids))
    buf = ctypes.create_string_buffer(4096)
    want = os.path.realpath(os.path.join(app, "Contents", "MacOS", "NotArc")).encode()
    return [pids[i] for i in range(n) if lib.proc_pidpath(pids[i], buf, 4096) > 0 and os.path.realpath(buf.value) == want]


def plist_checks(app):
    with open(os.path.join(app, "Contents", "Info.plist"), "rb") as f:
        info = plistlib.load(f)
    schemes = {s for t in info.get("CFBundleURLTypes", []) for s in t.get("CFBundleURLSchemes", [])}
    docs = {u for d in info.get("CFBundleDocumentTypes", []) if d.get("CFBundleTypeRole") == "Viewer"
            for u in d.get("LSItemContentTypes", [])}
    checks = {"http": "http" in schemes, "https": "https" in schemes, "html": "public.html" in docs,
              "xhtml": "public.xhtml" in docs}
    print("SELFTEST-OPENLINKS-PLIST " + " ".join("%s=%d" % (k, v) for k, v in checks.items()))
    return all(checks.values())


def main():
    if len(sys.argv) != 2:
        print(__doc__)
        return 2
    app = os.path.abspath(sys.argv[1].rstrip("/"))
    ok = plist_checks(app)
    work = os.path.realpath(tempfile.mkdtemp(prefix="notarc-openlinks-"))  # no /var -> /private/var link in file URLs
    lsopen = os.path.join(work, "lsopen")
    subprocess.run(["clang", "-fobjc-arc", "-framework", "Cocoa", os.path.join(ROOT, "scripts", "lsopen.m"), "-o", lsopen],
                   check=True)
    home = os.path.join(work, "home")
    subprocess.run([sys.executable, os.path.join(ROOT, "scripts", "make-test-home.py"), home], check=True,
                   stdout=subprocess.DEVNULL)
    log = os.path.join(work, "openlinks.log")
    env = dict(os.environ, CFFIXED_USER_HOME=home, NOTARC_SELFTEST_ONLY="openlinks", NOTARC_OPENLINKS_COLD=COLD)
    with open(log, "w") as out:
        proc = subprocess.Popen([os.path.join(app, "Contents", "MacOS", "NotArc"), "--selftest"], env=env, stdout=out,
                                stderr=subprocess.STDOUT)
    pid = str(proc.pid)

    def send(urls, quiet=False):
        r = subprocess.run([lsopen, "send", app, pid] + urls, capture_output=True, text=True)
        if not quiet or r.returncode == 0:
            print("sent %s rc=%d %s" % (" ".join(urls), r.returncode, r.stderr.strip()))
        return r.returncode == 0

    # Cold: hand the link over while the copy is still starting. Launch Services refuses (and starts nothing else) until
    # the app's event loop runs, so keep offering it; the copy reports whether it came before its window existed.
    cold_ok = subprocess.run([lsopen, "wait", app, pid, "30"]).returncode == 0
    tries, until = 0, time.time() + 30
    while cold_ok and proc.poll() is None and time.time() < until:
        tries += 1
        if send([COLD], quiet=True):
            break
        if len(copies(app)) > 1:  # never: Launch Services must not start a second copy outside the throwaway home
            print("OPEN-LINKS FAIL: a second copy started: %s" % copies(app))
            for other in copies(app):
                if other != proc.pid:
                    os.kill(other, 9)
            cold_ok = False
        time.sleep(0.1)
    else:
        cold_ok = False
    print("cold link offered %d times" % tries)
    if not cold_ok:
        print("OPEN-LINKS FAIL: couldn't hand the first link to the starting copy")
        ok = False
    sent, deadline = 0, time.time() + 150
    while proc.poll() is None and time.time() < deadline:
        with open(log, errors="replace") as f:
            asks = [l.split()[1:] for l in f if l.startswith("OPENLINKS-SEND ")]
        for urls in asks[sent:]:
            ok = send([unquote(u[len("file://"):]) if u.startswith("file://") else u for u in urls]) and ok
        sent = len(asks)
        time.sleep(0.2)
    if proc.poll() is None:
        proc.kill()
        print("OPEN-LINKS FAIL: the copy didn't finish in time")
        ok = False
    proc.wait()
    with open(log, errors="replace") as f:
        lines = [l.rstrip("\n") for l in f if l.startswith("SELFTEST-")]
    for l in lines:
        print(l)
    for name in REQUIRED:
        if not any(l.startswith("SELFTEST-%s " % name) for l in lines):
            print("OPEN-LINKS FAIL: no SELFTEST-%s line" % name)
            ok = False
    if any(re.search(r"=0( |$)", l) for l in lines):
        print("OPEN-LINKS FAIL: a check failed")
        ok = False
    if not any(re.match(r"SELFTEST-REALPROFILE .*prefsUntouched=1 dataUntouched=1", l) for l in lines):
        print("OPEN-LINKS FAIL: the run didn't finish cleanly")
        ok = False
    if ok:
        shutil.rmtree(work, ignore_errors=True)
        print("OPEN-LINKS OK")
    else:
        print("log: %s" % log)
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
