#!/usr/bin/env python3
"""T3: client-controlled duplex device through real Wyoming and the prebuilt host-screen file sink."""
import asyncio
import contextlib
import os
import re
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time

from wyoming.audio import AudioChunk, AudioStart, AudioStop
from wyoming.client import AsyncTcpClient
from wyoming.event import Event
from fake_talk_duplex import logged
from webclient import wait_port

ROOT = Path(__file__).resolve().parents[1]
PORT = 16797
RATE = 24000
PCM = b"\x01\x00" * (RATE // 50)


@contextlib.contextmanager
def echo():
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        state = root / "state"
        state.mkdir()
        (state / "config").write_text("even_volume=off\n")
        play, log = root / "play.raw", root / "stderr.log"
        env = dict(os.environ, HASSMIC_PLAY=str(play), HASSMIC_STATE=str(state),
                   HASSMIC_FAKE_LED=str(root / "led"), HASSMIC_SCREEN="/bin/false")
        with log.open("w") as err:
            proc = subprocess.Popen([str(ROOT / "build/hassmic-host-screen"), "-P", "wyoming", "-D", "-L",
                                     "-W", "0", "-o", "0", "-a", "0", "-i", "0", "-p", str(PORT)],
                                    env=env, stderr=err, start_new_session=True)
        try:
            wait_port(PORT, secs=20)
            yield proc, play, log
        finally:
            proc.terminate()
            try: proc.wait(timeout=5)
            except subprocess.TimeoutExpired: proc.kill(); proc.wait()


class Peer:
    def __init__(self, client):
        self.client = client
        self.mic = self.played = self.runs = 0

    async def send(self, kind, data=None):
        await self.client.write_event(Event(type=kind, data=data))

    async def until(self, predicate, seconds=5):
        async def read():
            while not predicate():
                ev = await self.client.read_event()
                assert ev is not None, "connection closed"
                self.mic += ev.type == "audio-chunk"
                self.played += ev.type == "played"
                self.runs += ev.type == "run-pipeline"
                if ev.type == "pong": self.pong = True
        await asyncio.wait_for(read(), seconds)

    async def barrier(self):
        self.pong = False
        await self.send("ping")
        await self.until(lambda: self.pong)

    async def observe(self, seconds):
        try: await self.until(lambda: False, seconds)
        except asyncio.TimeoutError: pass

    async def wake(self, proc):
        n = self.runs
        proc.send_signal(signal.SIGUSR1)
        await self.until(lambda: self.runs == n + 1)
        n = self.mic
        await self.until(lambda: self.mic >= n + 3)

    async def begin(self):
        await self.client.write_event(AudioStart(rate=RATE, width=2, channels=1).event())

    async def chunk(self, pcm):
        await self.client.write_event(AudioChunk(rate=RATE, width=2, channels=1, audio=pcm).event())

    async def ack(self, expected, seconds=5):
        await self.until(lambda: self.played >= expected, seconds)
        assert self.played == expected

    async def capture(self):
        n, runs = self.mic, self.runs
        await self.until(lambda: self.mic >= n + 3)
        assert self.runs == runs, "unexpected new run"

    async def ended(self):
        await self.barrier()
        n = self.mic
        await self.observe(0.25)
        assert self.mic == n, "capture continued after explicit end"


async def controls(mode="all"):
    with echo() as (proc, play, log):
        async with AsyncTcpClient("127.0.0.1", PORT) as client:
            p = Peer(client)
            await p.send("run-satellite")
            await p.barrier()
            await p.send("hassmic-flush")
            await p.send("hassmic-end")
            await p.barrier()
            assert p.runs == p.played == 0, "idle controls invented a run or acknowledgement"
            await p.wake(proc)
            if mode != "flush":
                await lifecycle(p)
                if mode == "lifecycle": return
            # An oversized chunk is already dequeued and writing when flush arrives.
            await p.begin()
            await p.chunk(PCM * 200)
            await p.chunk(PCM * 10)                 # an independent queued item must also be discarded
            while not play.exists() or play.stat().st_size < 960:
                await p.capture()
            before = play.stat().st_size
            t0 = time.monotonic()
            await p.send("hassmic-flush")
            await p.ack(1)
            cut = play.stat().st_size
            assert 0 <= cut - before <= 960, f"post-flush growth {cut - before}, ceiling 960"
            record = re.search(r"duplex flush: receipt_ms=(\d+) closed_ms=(\d+) before=(\d+) written=(\d+) discarded=(\d+)", log.read_text())
            assert record, "missing native discard observation"
            receipt, closed, committed, written, discarded = map(int, record.groups())
            assert closed - receipt <= 40 and 0 <= written - committed <= 960
            assert written == cut and written + discarded == len(PCM) * 210
            elapsed = (time.monotonic() - t0) * 1000
            await p.capture()
            assert play.stat().st_size == cut, "old PCM resumed after played"
            print(f"ok   large-chunk flush: growth={cut-before} bytes, played=1, acknowledgement={elapsed:.1f}ms")
            await p.send("hassmic-flush")
            await p.send("audio-stop")
            await p.barrier()
            await p.capture()
            assert p.played == 1, "duplicate flush/stale stop acknowledged twice"
            # Empty reply must wake the idle playback worker, then be acknowledged exactly once.
            await p.begin()
            await p.send("hassmic-flush")
            await p.ack(2)
            assert play.stat().st_size == cut
            await p.begin()
            await p.chunk(PCM * 10)
            await client.write_event(AudioStop().event())
            await p.ack(3)
            assert play.stat().st_size - cut == 9600, "replacement PCM changed"
            await p.capture()
            print("ok   empty flush, duplicate/stale controls, replacement=9600 bytes, natural stop keeps capture")
            await p.send("hassmic-end")
            await p.send("hassmic-end")
            await p.ended()
            assert p.played == 3
            await p.wake(proc)
            await p.begin()
            await p.chunk(PCM * 200)
            await p.barrier()
            await p.send("hassmic-end")
            await p.ack(4)
            await p.ended()
            await p.wake(proc)
            assert p.runs == 3
            await p.begin()
            await p.chunk(PCM * 200)               # disconnect while capture and output are active
            await p.barrier()
            print("ok   explicit end aborts active reply once; duplicate end idle; next wake starts fresh")
        async with AsyncTcpClient("127.0.0.1", PORT) as client:
            p = Peer(client)
            await p.send("run-satellite")
            await p.ended()
            assert p.played == p.runs == 0, "stale reply/run crossed reconnect"
            await p.wake(proc)
            await p.begin()
            await client.write_event(AudioStop().event())
            await p.ack(1)
            await p.send("hassmic-end")
            print("ok   disconnect aborts active output; reconnect replays no run or acknowledgement")


async def lifecycle(p):
    await p.send("transcript", {"text": "synthetic question"})
    await p.send("voice-stopped")
    await p.barrier()
    await p.capture()
    print("ok   transcript/voice-stopped keep capture in the same run")

async def watchdog():
    with echo() as (proc, play, log):
        async with AsyncTcpClient("127.0.0.1", PORT) as client:
            p = Peer(client)
            await p.send("run-satellite", {"hassmic_failsafe_seconds": 1})
            await p.barrier()
            await p.wake(proc)
            await p.begin()
            await p.chunk(PCM * 200)
            # Invalid registration must retain the last valid one-second watchdog.
            await p.send("run-satellite", {"hassmic_failsafe_seconds": 0})
            started = time.monotonic()
            while not p.played and time.monotonic() - started < 3:
                await p.send("ping")
                await p.send("describe")
                await p.observe(0.2)
            assert p.played == 1, "ping/describe postponed the watchdog"
            assert p.mic > 3, "no microphone traffic during watchdog observation"
            assert logged(log, "duplex failsafe expired"), "watchdog did not expire"
            assert logged(log, "invalid hassmic_failsafe_seconds, ignored")
            await p.ended()
            await p.wake(proc)
            await p.send("hassmic-end")
            print("ok   configured 1s failsafe aborts stalled reply despite microphone traffic; invalid value retained; next wake")
        # Reconnect with omission: default must be restored, and fire, not just be parsed.
        async with AsyncTcpClient("127.0.0.1", PORT) as client:
            p = Peer(client)
            await p.send("run-satellite")
            await p.barrier()
            await p.wake(proc)
            await p.begin()
            t0 = time.monotonic()
            await p.ack(1, 34)                     # empty but active reply: default watchdog still aborts it
            elapsed = time.monotonic() - t0
            assert 29 <= elapsed < 33, f"default watchdog expired at {elapsed}s"
            await p.ended()
            await p.wake(proc)
            await p.send("hassmic-end")
            print(f"ok   reconnect resets 30s default; actual expiry={elapsed:.3f}s; next wake")


async def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else "all"
    if mode != "watchdog": await controls(mode)
    if mode in ("all", "watchdog"): await watchdog()


if __name__ == "__main__":
    asyncio.run(main())
