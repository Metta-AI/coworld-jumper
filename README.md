# Jumper

<!-- COWORLD-VERIFY-BADGE:START -->
![Coworld verify: passing](https://img.shields.io/badge/coworld%20verify-passing-brightgreen)
<!-- COWORLD-VERIFY-BADGE:END -->


<!-- COWORLD-REPO-STATUS:START -->
> [!NOTE]
> Coworld repo status: **complete** (`coworld-complete`).
> Canonical repository: `Metta-AI/coworld-jumper`.
> Manifest path: `coworld_manifest.json` (template; hydrated and certified by
> `metta/worlds/upload.sh jumper`).
> Build path: `Dockerfile`
> Certification: passing — `jumper:0.1.2` is the canonical hosted Coworld, with an
> [hourly league](https://softmax.com/observatory/v2?tab=leagues&detail=league:league_f140dae4-e5fd-4d22-b8eb-67bc99e880ba)
> running eight-player rounds with watchable replays.
>
> - [x] Validate the manifest against the current Coworld schema.
> - [x] Run certification with the bundled players (local + hosted smoke).
> - [x] Switch the repo topic to `coworld-complete`.
<!-- COWORLD-REPO-STATUS:END -->


Cooperative Coworld platformer where players cross pits, stack on each
other, and reach the flag.

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
