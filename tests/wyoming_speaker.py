#!/usr/bin/env python3
"""The speaker over Wyoming (proto_wyoming.c) against build/hassmic-host: Wyoming has no volume or speaker mute, so
hassmic sends its own "hassmic-speaker" {"volume": 0..100, "muted": bool} on connecting and on every change, and takes
"hassmic-set-volume" {"volume": 0..100} and "hassmic-set-output-mute" {"mute": bool} from the client, each answered by
one hassmic-speaker even when nothing changed.  muted is the output mute: replies play silent while it is on, the
volume is kept (and may move) meanwhile, and the microphones' mute (hassmic-mute, the latch) is another thing."""
import json, os, select, socket, struct, subprocess, sys, tempfile, time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PORT, KEY_MUTE = 16798, 113
failed = False
def check(cond, what):
    global failed
    print(("ok   " if cond else "FAIL ") + what)
    failed |= not cond

class Client:
    """Wyoming over a plain socket and a buffer of our own: a read can time out and the connection still be read after"""
    def __init__(self):
        for _ in range(100):
            try: self.s = socket.create_connection(("127.0.0.1", PORT), timeout=5); break
            except OSError: time.sleep(0.1)
        else: raise RuntimeError("no connection")
        self.buf, self.end = b"", time.time() + 5
    def fill(self):
        left = self.end - time.time()
        if left <= 0 or not select.select([self.s], [], [], left)[0]: raise TimeoutError
        more = self.s.recv(65536)
        if not more: raise EOFError
        self.buf += more
    def line(self):
        while b"\n" not in self.buf: self.fill()
        l, self.buf = self.buf.split(b"\n", 1); return l
    def take(self, n):
        while len(self.buf) < n: self.fill()
        b, self.buf = self.buf[:n], self.buf[n:]; return b
    def send(self, t, data=None, payload=b""):
        head = {"type": t}
        body = json.dumps(data).encode() if data is not None else b""
        if body: head["data_length"] = len(body)
        if payload: head["payload_length"] = len(payload)
        self.s.sendall((json.dumps(head) + "\n").encode() + body + payload)
    def recv(self, timeout=5):
        self.end = time.time() + timeout
        h = json.loads(self.line()); d = h.get("data") or {}
        if h.get("data_length"): d = json.loads(self.take(h["data_length"]))
        if h.get("payload_length"): self.take(h["payload_length"])
        return h["type"], d
    def events(self, types, timeout=5, n=1):
        """the next n events of these types within timeout, (type, data) each, skipping everything else"""
        got, end = [], time.time() + timeout
        while len(got) < n:
            try: t, d = self.recv(max(0.0, end - time.time()))
            except TimeoutError: break
            if t in types: got.append((t, d))
        return got
    def speaker(self, timeout=5, n=1):
        return [d for _, d in self.events({"hassmic-speaker"}, timeout, n)]
    def close(self): self.s.close()

tmp = tempfile.mkdtemp(); state = os.path.join(tmp, "state"); os.makedirs(state)
keys = os.path.join(tmp, "keypad"); os.mkfifo(keys); keypad = os.open(keys, os.O_RDWR)
cap = os.path.join(tmp, "capture"); open(cap, "wb").write(b"\0" * 32000 * 30)
play = os.path.join(tmp, "play.raw")
env = dict(os.environ, HASSMIC_STATE=state, HASSMIC_CAP=cap, HASSMIC_PLAY=play,
           HASSMIC_FAKE_LED=os.path.join(tmp, "led"), HASSMIC_ARB_ADDR="127.255.255.255", HASSMIC_ARB_RIVALS="0",
           HASSMIC_FAKE_ADDRS=os.path.join(tmp, "addrs"), HASSMIC_MDNS_FILE=os.path.join(tmp, "mdns"))
open(env["HASSMIC_FAKE_ADDRS"], "w").write("127.0.0.1\n")
log = open(os.path.join(tmp, "log"), "w+")
proc = subprocess.Popen([f"{ROOT}/build/hassmic-host", "-P", "wyoming", "-p", str(PORT), "-n", "Lab", "-b", keys],
                        env=env, stderr=log)
def key(code):
    for v in (1, 0): os.write(keypad, struct.pack("llHHi", 0, 0, 1, code, v))     # struct input_event, EV_KEY
def logged():
    log.flush(); log.seek(0); return log.read()
def reply(c):
    """a short reply, 0.3 s of a loud square wave at 16 kHz; what reached the speaker (the host's play file) back"""
    before = os.path.getsize(play) if os.path.exists(play) else 0
    pcm = struct.pack("<h", 12000) * 40 + struct.pack("<h", -12000) * 40
    c.send("audio-start", {"rate": 16000, "width": 2, "channels": 1})
    c.send("audio-chunk", {"rate": 16000, "width": 2, "channels": 1}, pcm * 60)
    c.send("audio-stop", {})
    played = c.events({"played"}, timeout=5)
    data = open(play, "rb").read()[before:] if os.path.exists(play) else b""
    return played != [], max((abs(s) for (s,) in struct.iter_unpack("<h", data[:len(data) // 2 * 2])), default=-1)
try:
    c = Client()
    first = c.recv()
    check(first[0] == "hassmic-speaker" and set(first[1]) == {"volume", "muted"} and first[1]["muted"] is False
          and isinstance(first[1]["volume"], int) and 0 <= first[1]["volume"] <= 100,
          f"on connecting: hassmic-speaker first, the volume and not muted ({first})")
    c.send("describe")
    got = c.events({"info", "hassmic-speaker"})
    check([t for t, _ in got] == ["info"], "describe is answered by info, no second speaker state")
    c.send("run-satellite"); time.sleep(0.3)

    c.send("hassmic-set-volume", {"volume": 30})
    check(c.speaker() == [{"volume": 30, "muted": False}], "hassmic-set-volume 30: answered with the volume 30")
    c.send("hassmic-set-volume", {"volume": 30})
    check(c.speaker() == [{"volume": 30, "muted": False}], "the same volume again: answered all the same")
    for bad in ({"volume": 101}, {"volume": -1}, {"volume": 30.5}, {"volume": "40"}, {"volume": True}, {}):
        c.send("hassmic-set-volume", bad)
    check(c.speaker(timeout=1) == [], "a volume out of range or no whole number: ignored, no answer")
    played, peak = reply(c)
    check(played and peak > 1000, f"unmuted: a reply is heard (peak {peak})")

    c.send("hassmic-set-output-mute", {"mute": True})
    got = c.events({"hassmic-speaker", "hassmic-mute"})
    check(got == [("hassmic-speaker", {"volume": 30, "muted": True})], f"output mute: muted, the volume kept ({got})")
    check("volume: output muted" in logged() and "audio: tts gain 0.000" in logged(), "output mute: replies at gain 0")
    played, peak = reply(c)
    check(played and peak == 0, f"output muted: a reply still plays to its end (played), silent (peak {peak})")
    c.send("hassmic-set-volume", {"volume": 50})
    check(c.speaker() == [{"volume": 50, "muted": True}], "a volume set while muted: kept, still muted")
    played, peak = reply(c)
    check(played and peak == 0, f"still silent after the volume moved (peak {peak})")
    c.send("hassmic-set-output-mute", {"mute": True})
    check(c.speaker() == [{"volume": 50, "muted": True}], "output mute again: answered all the same")
    for bad in ({"mute": 1}, {"mute": "false"}, {"mute": None}, {}):
        c.send("hassmic-set-output-mute", bad)
    check(c.speaker(timeout=1) == [], "a mute that is no true or false: ignored, no answer")

    c.close(); time.sleep(0.5)
    c = Client()
    t, d = c.recv()
    check((t, d) == ("hassmic-speaker", {"volume": 50, "muted": True}), f"a new connection is told the speaker as it is ({t} {d})")
    c.send("run-satellite"); time.sleep(0.3)
    c.send("hassmic-set-output-mute", {"mute": False})
    check(c.speaker() == [{"volume": 50, "muted": False}], "output unmuted: the volume as it was")
    played, peak = reply(c)
    check(played and peak > 1000, f"unmuted again: the reply is heard (peak {peak})")

    key(KEY_MUTE)
    got = c.events({"hassmic-speaker", "hassmic-mute"}, timeout=2, n=2)
    check(got == [("hassmic-mute", {"muted": True})], f"the microphones' mute: hassmic-mute alone, the speaker untouched ({got})")
    key(KEY_MUTE)
    check(c.events({"hassmic-mute"}) == [("hassmic-mute", {"muted": False})], "the microphones back on")
    c.close()
finally:
    proc.terminate(); proc.wait(5); os.close(keypad)
    if failed: sys.stderr.write(logged()[-3000:])
sys.exit(1 if failed else 0)
