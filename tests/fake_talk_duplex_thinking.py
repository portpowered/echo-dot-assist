#!/usr/bin/env python3
"""-D (duplex) over Wyoming against build/hassmic-host-screen with a stand-in UI: hassmic-thinking shows that the
client's agent works on the answer, and changes nothing else.
  - listening: {"thinking": true} puts the thinking pattern on the face in place of the listening one
  - a reply opens and plays under it: thinking stays (the client takes it back when its audio is heard)
  - {"thinking": false}: the face talks
  - thinking again, the reply ends: the run listens on (-D) and the face still thinks
  - the run ends: thinking goes with it; the next run starts listening
  - without a run: ignored"""
import asyncio, os, signal, sys, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from fake_talk_duplex_mouth import RATE, drain, echo, tone
from wyoming.audio import AudioChunk, AudioStart, AudioStop
from wyoming.client import AsyncTcpClient
from wyoming.event import Event
from wyoming.pipeline import RunPipeline
from wyoming.satellite import RunSatellite

LISTEN, THINK, TALK = "active-start", "active-thinking", "active-talking"


def shown(ui):
    """The core's patterns the UI has on now: "p+ name ago" puts one on, "p- name" takes it off"""
    on = set()
    with open(ui) as f:
        for line in f:
            words = line.split()
            if len(words) >= 3 and words[1] == "p+": on.add(words[2])
            elif len(words) >= 3 and words[1] == "p-": on.discard(words[2])
    return on & {LISTEN, THINK, TALK}


async def until(client, ui, want, what, secs=5):
    """The face's patterns become `want` within secs, the microphone streaming on meanwhile"""
    end = time.monotonic() + secs
    while shown(ui) != want:
        assert time.monotonic() < end, f"{what}: the face shows {sorted(shown(ui))}, not {sorted(want)}"
        await drain(client, 0.05)
    await drain(client, 0.3)                                    # and it stays so
    assert shown(ui) == want, f"{what}: the face went on to {sorted(shown(ui))}"
    print(f"ok   {what}: {sorted(want)}")


async def thinking(client, on): await client.write_event(Event(type="hassmic-thinking", data={"thinking": on}))


async def wake(client, proc):
    proc.send_signal(signal.SIGUSR1)                            # the wake word
    while not RunPipeline.is_type((await asyncio.wait_for(client.read_event(), 5)).type): pass


async def main():
    with echo() as (proc, ui):
        async with AsyncTcpClient("127.0.0.1", 16799) as client:
            await client.write_event(RunSatellite().event())
            await asyncio.sleep(0.5)
            await thinking(client, True)
            await drain(client, 0.5)
            assert not shown(ui), f"no run: hassmic-thinking showed {sorted(shown(ui))}"
            print("ok   no run: ignored")

            await wake(client, proc)
            await until(client, ui, {LISTEN}, "listening")
            await thinking(client, True)
            await until(client, ui, {THINK}, "thinking over listening")

            await client.write_event(AudioStart(rate=RATE, width=2, channels=1).event())
            loud = AudioChunk(rate=RATE, width=2, channels=1, audio=tone(RATE, 0.02, -10)).event()
            for _ in range(25):
                await client.write_event(loud)
                await asyncio.sleep(0.02)
            await until(client, ui, {THINK, TALK}, "a reply under thinking")
            await thinking(client, False)
            await until(client, ui, {TALK}, "thinking taken back")

            await thinking(client, True)
            await until(client, ui, {THINK, TALK}, "thinking over the open reply")
            await client.write_event(AudioStop().event())
            await until(client, ui, {THINK}, "the reply ended, the run listens on")

            await client.write_event(Event(type="hassmic-end"))
            await until(client, ui, set(), "the run ended")
            await wake(client, proc)
            await until(client, ui, {LISTEN}, "the next run")


if __name__ == "__main__":
    asyncio.run(main())
