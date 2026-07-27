# Writing a game reporter

You are going to write a **reporter** for a BitWorld/Coworld game: a
module that receives the game's render stream (sprite protocol packets)
and prints text lines that narrate the game so an LLM — or a human
tailing a log — can "see" what is happening.

## Architecture

```
Server <--(websocket, sprite protocol)--> Bot
                                           └── Reporter (passive tap)
```

The reporter lives inside the bot process, in its **own file**, with a
single entry point (`consume(packet)`) called on every inbound binary
message before the bot's own decoding. It keeps its own state and never
influences the bot's decisions. Output goes to a file or stdout, one
line at a time, flushed once per frame. Gate it behind a CLI flag
(`--report:<path>`, `--report-mode:<mode>`) so it costs nothing when
off.

The reporter sees only what the bot sees. Do not read server memory,
results files, or the map from disk to generate lines: if the bot
couldn't know it, the reporter must not say it. (Reading game data
files to *verify* the reporter's output is encouraged — see
Verification.)

## Input: the sprite protocol

Server-to-client packets are a sequence of messages
(`bitworld/spriteprotocol.nim`):

| type | message | payload |
|------|---------|---------|
| 0x01 | sprite definition | id, width, height, snappy-compressed pixels, **label** |
| 0x02 | object placement | id, x, y (screen px), z, layer, spriteId |
| 0x03 | delete object | id |
| 0x04 | clear all objects | — (this marks a new frame) |
| 0x05 | viewport | layer, width, height |
| 0x06 | layer definition | layer, kind, flags |

Key facts, learned the hard way:

- **Skip the pixels; read the labels.** Sprite definitions carry a text
  label ("tile 9", "name lf0", "chat help", a score digit string).
  Labels are the semantic channel — never decode pixel data.
- **Object ids are namespaced by range** (e.g. tiles 1000+, players
  5000+, chat 9000+, name tags 10000+). Read the server source
  (`src/<game>.nim`, the constants block) for the exact bases. Object
  ids encode identity: `PlayerObjectBase + i` IS player i;
  `TileObjectBase + index` IS map cell (index % W, index / W).
- **The object list is rebuilt every frame** (clear-objects, then adds).
  Treat 0x04 as the frame boundary: parse everything, then derive and
  narrate once per frame.
- **The server viewport-culls.** Only objects inside the camera window
  are sent. Absence of a culled thing means "not visible", not "not
  there" — except for things the server never culls (find out which by
  reading the server's packet-builder proc; e.g. jumper renders ALL
  living players regardless of camera).
- **Text sprites are redefined when their content changes.** A chat
  bubble, name tag, or score HUD re-sends its sprite definition with a
  new label. The label change IS the event; the per-frame object
  placements of it are noise.

## What to build, in order

Work incrementally; run the game and read your output after each step.

**1. Raw pass-through with static/dynamic split.**
Parse the packet stream. Classify sprites/objects as *static*
(environment: terrain art, map cells, decorations — report once, on
first sight) or *dynamic* (players, text, HUD — report per frame).
This will be noisy (~10-15 lines/frame). That's fine; it validates your
parsing and shows you what's in the stream.

**2. Camera inference and world space.**
Find any object whose world position is knowable (a map tile: its id
encodes its cell). `camera = cell_world_pos - screen_pos`. Convert
every reported position to world space. This is the single biggest
denoiser: a standing player stops producing lines just because the
camera scrolls.

**3. Entity naming.**
Map indices to names from name-tag sprite labels (or join events,
score panels — whatever the game provides). "d2 on top of lf0" is
worth ten "obj=5003 near obj=5000".

**4. State-transition narration (the `events` mode — the payoff).**
Track per-entity state; emit one line only when a state CHANGES:

- motion: direction of horizontal / vertical movement
  ("moving right", "stopped", "jumping", "falling")
- support/contact: what the entity rests on or touches
  ("on ground", "on top of <name>", "at wall on right", "off wall")
- lifecycle: "died", "respawned at (x,y)", "reached the goal"
- game text: chat, score changes (from text-sprite redefinitions)

**5. Environment features (game-specific semantics).**
Accumulate a persistent world model from static objects as they scroll
into view (tiles: solid/empty/unknown). Detect and narrate features in
the game's own vocabulary, each exactly once, with sizes and distances:
for a platformer — steps, walls, holes, drops, bottomless pits, the
goal; for other games — whatever the bot must reason about.

## Denoising principles

- **Once, ever, for static things.** Key each feature (by cell/column/
  id) and report it on first confirmation only.
- **On change only, for dynamic things.** Store last state per entity;
  compare; emit on difference. Never emit "still true".
- **Confirm before speaking.** If a feature is only partially visible
  (a gap whose bottom hasn't been seen), stay SILENT until the stream
  confirms it. A wrong line ("pit!" that is actually a shallow hole) is
  worse than a late line. Model unknowns explicitly
  (solid/empty/**unknown**) — viewport culling means most of the world
  starts unknown.
- **Guard against discontinuities.** A teleport/respawn makes position
  deltas garbage. If an entity moves more than physics allows in one
  frame, reset its motion state and report the discontinuity itself
  ("teleported to", "respawned at") instead of a bogus "moving left".
- **Suppress derived flicker.** One-frame states (a jump apex, a brief
  airborne frame during a hop) are not states. Either skip them or
  require persistence before narrating.
- **Infer invisible events from render absence.** Servers often don't
  render deaths or scoring overlaps — they show up as an entity
  vanishing, or an instant move home. Read the server's update loop to
  learn what each looks like, then narrate the CAUSE ("died", "reached
  the flag! scored") not the symptom. Keep an "unexplained" fallback
  ("teleported") for moves you can't attribute.

## Output conventions

- One event per line: `f=<frame> <subject>: <what>` — e.g.
  `f=240 d2: on top of lf0`. Static lines: `static tile cell=(2,15) ...`.
  Environment lines: `f=90 terrain: wall 3 tiles (96px) tall at x=736,
  59px to the right`.
- Subjects are names, not ids. Positions in world coordinates. Sizes in
  the game's natural unit plus pixels: `2 tiles (64px)`.
- Distances relative to the observing player, at the moment of the
  line: `, 96px to the right`.
- Plain, correct English, present tense, no abbreviations an outsider
  wouldn't know. The reader has NOT seen the code.
- Line budget in events mode: a few hundred lines per game minute. If
  you're over, your states are too fine-grained; if a whole minute
  passes silently, too coarse.

## Verification — do not skip

1. **Run a real game** with the reporter on (add a `--report` passthrough
   to the repo's `run_local.sh`) and read the whole log. Every line
   should be true, human-readable in isolation, and non-repeating.
2. **Cross-check against ground truth.** Parse the map file / server
   config with a throwaway script and diff: are all reported walls/pits
   real, correct size, correct position? Is anything real missing that
   the bot HAS seen? (Missing-because-never-visited is correct
   behavior.)
3. **Cross-check events against outcomes.** Final scores must match the
   goal events you narrated; death counts should match respawn counts.
4. **Watch for the known trap:** `whisky`'s `receiveMessage(timeout=0)`
   can return nothing on macOS — if the reporter taps a secondary
   socket, poll with timeout ≥ 1.

## Modes

Ship three, sharing one code path:
- `all` — every dynamic object every frame (debugging the reporter)
- `changes` — object-level dedup (debugging state tracking)
- `events` — transitions + environment features only (the real product;
  what an LLM consumes)
