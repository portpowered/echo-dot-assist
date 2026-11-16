#!/usr/bin/env python3
"""The effective mute over Wyoming (proto_wyoming.c) against build/hassmic-host: Wyoming has no mute event, so hassmic
sends its own "hassmic-mute" {"muted": bool}, once when a client connects and again on every change.  The mute key
(KEY_MUTE on the keypad, the host's stand-in for the privacy latch) toggles it; a client connecting while muted is told
so straight away."""
import json, os, socket, struct, subprocess, sys, tempfile, time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PORT, KEY_MUTE = 16797, 113
failed = False
def check(cond, what):
    global failed
    print(("ok   " if cond else "FAIL ") + what)
    failed |= not cond

class Client:
    def __init__(self):
        for _ in range(100):
            try: self.s = socket.create_connection(("127.0.0.1", PORT), timeout=5); break
            except OSError: time.sleep(0.1)
        else: raise RuntimeError("no connection")
        self.f = self.s.makefile("rb")
    def send(self, t): self.s.sendall((json.dumps({"type": t}) + "\n").encode())
    def recv(self):
        h = json.loads(self.f.readline()); d = h.get("data") or {}
        if h.get("data_length"): d = json.loads(self.f.read(h["data_length"]))
        if h.get("payload_length"): self.f.read(h["payload_length"])
        return h["type"], d
    def mutes(self, n, timeout=5):
        """the next n hassmic-mute values, skipping everything else"""
        got, end = [], time.time() + timeout
        self.s.settimeout(timeout)
        while len(got) < n and time.time() < end:
            t, d = self.recv()
            if t == "hassmic-mute": got.append(d.get("muted"))
        return got
    def close(self): self.s.close()

tmp = tempfile.mkdtemp(); state = os.path.join(tmp, "state"); os.makedirs(state)
keys = os.path.join(tmp, "keypad"); os.mkfifo(keys); keypad = os.open(keys, os.O_RDWR)
cap = os.path.join(tmp, "capture"); open(cap, "wb").write(b"\0" * 32000 * 30)
env = dict(os.environ, HASSMIC_STATE=state, HASSMIC_CAP=cap, HASSMIC_PLAY=os.path.join(tmp, "play.raw"),
           HASSMIC_FAKE_LED=os.path.join(tmp, "led"), HASSMIC_ARB_ADDR="127.255.255.255", HASSMIC_ARB_RIVALS="0",
           HASSMIC_FAKE_ADDRS=os.path.join(tmp, "addrs"), HASSMIC_MDNS_FILE=os.path.join(tmp, "mdns"))
open(env["HASSMIC_FAKE_ADDRS"], "w").write("127.0.0.1\n")
log = open(os.path.join(tmp, "log"), "w+")
proc = subprocess.Popen([f"{ROOT}/build/hassmic-host", "-P", "wyoming", "-p", str(PORT), "-n", "Lab", "-b", keys],
                        env=env, stderr=log)
def key(code):
    for v in (1, 0): os.write(keypad, struct.pack("llHHi", 0, 0, 1, code, v))     # struct input_event, EV_KEY
try:
    c = Client()
    check(c.mutes(1) == [False], "a client connecting is told the microphones are on")
    c.send("run-satellite"); time.sleep(0.3)
    key(KEY_MUTE)
    check(c.mutes(1) == [True], "the mute key: muted")
    c.close(); time.sleep(0.5)
    c = Client()
    check(c.mutes(1) == [True], "a client connecting while muted is told so")
    c.send("run-satellite"); time.sleep(0.3)
    key(KEY_MUTE)
    check(c.mutes(1) == [False], "the mute key again: unmuted")
    c.close()
finally:
    proc.terminate(); proc.wait(5); os.close(keypad)
    if failed: log.seek(0); sys.stderr.write(log.read()[-3000:])
sys.exit(1 if failed else 0)
