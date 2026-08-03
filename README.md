# Jumper

Cooperative Coworld platformer where players cross pits, stack on each
other, and reach the flag.

## Coworld package

This repository owns the Coworld manifest template and every image build declared by it:

```bash
coworld build --version 0.1.3
coworld certify dist/coworld_manifest.json
coworld upload-coworld dist/coworld_manifest.json
```

## Running

```bash
nimble build
./jumper --host:0.0.0.0 --port:8080
```

Open `http://localhost:8080/client/global` to spectate.

## Bot

The bundled Nim bot is `dalli`.

```bash
nim c --path:src --outdir:out players/dalli/dalli.nim
./out/dalli --address:localhost --port:8080
```

Dalli plays a fixed route: the forest map never changes, so takeoff
points for every pit are compiled in from `data/forest.tmx` rather than
rediscovered by scanning each frame. The interesting part is the three
walls at tiles x23, x38 and x57, which are taller than the 91 px solo
jump and can only be passed by standing on somebody. At a wall the bot
backs off to a staging spot, jumps into the wall face, slides down onto
whoever holds the pocket, and jumps off their head once the apex clears
the lip. With nobody there it holds the pocket itself and becomes the
ladder, then climbs as soon as another body arrives.

The decision logic lives in `players/dalli/brain.nim` and is written
against an abstract `WorldView`, so it can be driven either by the
websocket client or, in `tools/simlab.nim`, straight from the real
`SimServer` for experiments. `tools/replaylab.nim` re-simulates a
recorded `.bitreplay` and reports per-seat flags, deaths, time spent
riding another player, and wall crossings; every fix in this bot came
from reading those numbers on a hosted game.

`players/dalli/dalli_classic.nim` is the previous purely reactive bot,
kept for comparison.
