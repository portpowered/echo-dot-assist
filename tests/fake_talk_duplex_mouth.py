#!/usr/bin/env python3
"""-D (duplex) over Wyoming against build/hassmic-host-screen with a stand-in UI: the face's level ("lv", the mouth while
it talks) is the reply's, never the talker's.  A client such as a realtime bridge keeps one reply open across a whole
call, its silences too, while the microphone streams on; a loud talker then must not move the mouth.
  - listening (no reply yet): the level follows the microphone, as before (the eyes)
  - reply open, no reply audio: the level drops to 0 and stays there however loud the talker
  - reply audio: the level follows it
  - reply open again without audio: back to 0 within a moment"""
import asyncio, contextlib, math, os, shutil, signal, struct, subprocess, sys, tempfile, time

if len(sys.argv) > 1 and sys.argv[1] == "--ui":           # the stand-in UI, as hassmic runs it: each text line it gets, timed
    with open(os.environ["FAKE_UI_LOG"], "a", buffering=1) as f:
        sys.stdout.write("ready 960 470\n"); sys.stdout.flush()
        while line := sys.stdin.buffer.readline():
            text = line.decode(errors="replace").rstrip()
            words = text.split()
            if len(words) == 2 and words[0] in ("band", "art") and words[1].isdigit():   # bytes right after the line
                sys.stdin.buffer.read(int(words[1]) * (4 if words[0] == "band" else 1))
            if text.startswith("ping "): sys.stdout.write("pong " + text[5:] + "\n"); sys.stdout.flush()   # alive
            f.write(f"{time.time():.3f} {text}\n")
    sys.exit(0)

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from webclient import wait_port
from wyoming.audio import AudioChunk, AudioStart, AudioStop
from wyoming.client import AsyncTcpClient
from wyoming.pipeline import RunPipeline
from wyoming.satellite import RunSatellite

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PORT = 16799
RATE = 24000


def tone(rate, secs, dbfs):
    """A sine at 440 Hz, s16le mono"""
    a = 32767 * 10 ** (dbfs / 20)
    return b"".join(struct.pack("<h", int(a * math.sin(2 * math.pi * 440 * i / rate))) for i in range(int(rate * secs)))


@contextlib.contextmanager
def echo():
    """build/hassmic-host-screen -P wyoming -D with a loud talker on the microphone and the stand-in UI"""
    tmp = tempfile.mkdtemp()
    state = os.path.join(tmp, "state"); os.mkdir(state)
    with open(os.path.join(state, "config"), "w") as f: f.write("even_volume=off\n")
    cap, ui = os.path.join(tmp, "cap.raw"), os.path.join(tmp, "ui.log")
    with open(cap, "wb") as f: f.write(tone(16000, 2, -10))            # (looped: a talker who never stops)
    runner = os.path.join(tmp, "ui"); open(runner, "w").write(f"#!/bin/sh\nexec {sys.executable} {os.path.abspath(__file__)} --ui\n")
    os.chmod(runner, 0o755)
    env = dict(os.environ, HASSMIC_PLAY=os.path.join(tmp, "play.raw"), HASSMIC_FAKE_LED=os.path.join(tmp, "led"),
               HASSMIC_STATE=state, HASSMIC_CAP=cap, HASSMIC_SCREEN=runner, HASSMIC_SCREEN_WAIT_MS="20", FAKE_UI_LOG=ui)
    with open(os.path.join(tmp, "stderr.log"), "w") as err:
        proc = subprocess.Popen([f"{ROOT}/build/hassmic-host-screen", "-p", str(PORT), "-n", "Test Dot", "-P", "wyoming", "-D",
                                 "-L", "-W", "0", "-o", "0", "-a", "0", "-i", "0"], env=env, start_new_session=True, stderr=err)
    try:
        wait_port(PORT, secs=20)
        assert proc.poll() is None, f"hassmic did not start ({proc.returncode})"
        yield proc, ui
    finally:
        try:
            proc.send_signal(signal.SIGTERM)
            try: proc.wait(timeout=5)
            except subprocess.TimeoutExpired: proc.kill(); proc.wait()
        finally: shutil.rmtree(tmp, ignore_errors=True)


def levels(ui):
    """(time, lv) for each level the UI got"""
    out = []
    with open(ui) as f:
        for line in f:
            t, _, rest = line.partition(" ")
            if rest.startswith("lv "): out.append((float(t), int(rest.split()[1])))
    return out


def level_at(ui, t):
    """The level the UI shows at time t: the last one it got before then (0 before any)"""
    seen = [lv for at, lv in levels(ui) if at <= t]
    return seen[-1] if seen else 0


def changes(ui, t0, t1):
    return [lv for at, lv in levels(ui) if t0 <= at <= t1]


async def drain(client, secs):
    """What the Echo sends for secs (the microphone streams on: a deadline, not a pause)"""
    end = time.monotonic() + secs
    try:
        while (left := end - time.monotonic()) > 0:
            assert await asyncio.wait_for(client.read_event(), left) is not None, "connection closed"
    except asyncio.TimeoutError: pass


async def until_level(client, ui, secs):
    """The first level above 0 the UI gets within secs (it comes up, then the talker shows), else 0"""
    end = time.monotonic() + secs
    while time.monotonic() < end:
        if (now := level_at(ui, time.time())) > 0: return now
        await drain(client, 0.05)
    return 0


async def main():
    with echo() as (proc, ui):
        async with AsyncTcpClient("127.0.0.1", PORT) as client:
            await client.write_event(RunSatellite().event())
            await asyncio.sleep(0.5)
            proc.send_signal(signal.SIGUSR1)                    # the wake word
            while not RunPipeline.is_type((await asyncio.wait_for(client.read_event(), 5)).type): pass
            await drain(client, 0.5)
            listening = await until_level(client, ui, 5)
            assert listening > 0, f"listening: the level does not follow a loud talker ({listening}): the test proves nothing"

            await client.write_event(AudioStart(rate=RATE, width=2, channels=1).event())
            t_open = time.time()
            await drain(client, 1.2)                             # the reply open, nothing in it yet, the talker loud
            t_end = time.time()
            quiet = changes(ui, t_open + 0.4, t_end)
            assert level_at(ui, t_end) == 0 and all(lv == 0 for lv in quiet), \
                f"reply open without audio: the talker moved the mouth (levels {quiet}, now {level_at(ui, t_end)})"

            loud = AudioChunk(rate=RATE, width=2, channels=1, audio=tone(RATE, 0.02, -10)).event()
            t_talk = time.time()
            for _ in range(50):                                  # one second of reply in 20 ms frames, as it plays
                await client.write_event(loud)
                await asyncio.sleep(0.02)
            talking = changes(ui, t_talk, time.time())
            assert any(lv > 0 for lv in talking), f"reply audio: the mouth did not follow it ({talking})"

            t_gap = time.time()
            await drain(client, 1.2)                             # the reply open again, silent between two answers
            t_end = time.time()
            gap = changes(ui, t_gap + 0.5, t_end)
            assert level_at(ui, t_end) == 0 and all(lv == 0 for lv in gap), \
                f"between answers: the mouth did not close or the talker moved it (levels {gap}, now {level_at(ui, t_end)})"

            await client.write_event(AudioStop().event())
            await drain(client, 1.0)
            print(f"ok   -D mouth: listening {listening}, reply open and silent 0, reply audio up to {max(talking)}, between answers 0")


if __name__ == "__main__":
    asyncio.run(main())
