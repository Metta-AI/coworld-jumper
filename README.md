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
nim c --path:src players/dalli.nim
./players/dalli --address:localhost --port:8080
```

## Training

Build the finite, headless bridge with the pinned Nimby dependencies:

```bash
nimby sync nimby.lock -g
mkdir -p out
nim c -d:release --path:src --out:out/jumper-training-bridge src/jumper/training_bridge.nim
```

Set `JUMPER_ROOT` to this checkout's absolute path. Pass the compiled bridge and root directory as one command to the
Metta recipes. Both recipes use the same 100-value player-view encoding, six input masks, and 512-tick episodes.

```bash
export JUMPER_ROOT=/absolute/path/to/coworld-jumper
cd /absolute/path/to/metta
uv run ./tools/run.py recipes.external.coworld.train --dry-run \
  command="[\"$JUMPER_ROOT/out/jumper-training-bridge\",\"$JUMPER_ROOT\"]" \
  assets="[\"$JUMPER_ROOT/nimby.lock\",\"$JUMPER_ROOT/data/forest.tmx\",\"$JUMPER_ROOT/data/forest.tiled-project\",\"$JUMPER_ROOT/data/forest.tiled-session\",\"$JUMPER_ROOT/data/spritesheet.aseprite\"]" \
  players=3 teacher=true total_timesteps=1024
uv run --group cortex ./tools/run.py recipes.external.coworld_metta_rl.train --dry-run \
  command="[\"$JUMPER_ROOT/out/jumper-training-bridge\",\"$JUMPER_ROOT\"]" \
  players=3 total_timesteps=1024
```

The same bridge feeds Metta post-training. Collect complete games, export seed-separated teacher examples, then train
with a bounded optimizer-step count:

```bash
uv run --package metta-posttrain metta-posttrain collect-teacher \
  --bridge "$JUMPER_ROOT/out/jumper-training-bridge" \
  --bridge-command "$JUMPER_ROOT/out/jumper-training-bridge" --bridge-command "$JUMPER_ROOT" \
  --output /tmp/jumper-trajectories.jsonl --source-revision "$(git -C "$JUMPER_ROOT" rev-parse HEAD)" \
  --episodes 2 --seed-prefix jumper --players 3 --game jumper \
  --action-schema-revision jumper-input-v1 --max-decisions 1536
uv run --package metta-posttrain metta-posttrain export \
  --trajectory /tmp/jumper-trajectories.jsonl --output /tmp/jumper-dataset
uv run --package metta-posttrain --extra train metta-posttrain train \
  --dataset /tmp/jumper-dataset --output /tmp/jumper-model --max-steps 10
```

The teacher moves right and jumps on a fixed cycle. It is a protocol baseline, not a strong platformer policy. For
scoreless episodes, training ranks players by furthest horizontal progress; reaching the flag always dominates that
progress score. League scoring and the hosted player protocol are unchanged. Native Puffer updates need a CUDA host.
