# Jumper

<!-- COWORLD-VERIFY-BADGE:START -->
![Coworld verify: failed](https://img.shields.io/badge/coworld%20verify-failed-red)
<!-- COWORLD-VERIFY-BADGE:END -->


<!-- COWORLD-REPO-STATUS:START -->
> [!NOTE]
> Coworld repo status: **incomplete** (`coworld-incomplete`).
> Canonical repository: `Metta-AI/coworld-jumper`.
> Manifest path: `coworld_manifest.json`.
> Build path: `Dockerfile`
> Certification: blocked until `uv run coworld certify coworld_manifest.json` passes and the result is recorded.
>
> Missing pieces:
> - [ ] Validate the root concrete manifest against the current Coworld schema.
> - [ ] Run `uv run coworld certify coworld_manifest.json` with the bundled players.
> - [ ] Switch the repo topic to `coworld-complete` after certification passes.
<!-- COWORLD-REPO-STATUS:END -->


Cooperative Coworld platformer where players cross pits, stack on each
other, and reach the flag.

## Running

```bash
nimble build
./jumper --address:0.0.0.0 --port:8080
```

Open `http://localhost:8080/client/global` to spectate.

## Bot

The bundled Nim bot is `dalli`.

```bash
nim c --path:src players/dalli.nim
./players/dalli --address:localhost --port:8080
```
