# Jumper

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
