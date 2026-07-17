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
