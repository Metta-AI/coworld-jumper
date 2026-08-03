## Headless experiment lab for Jumper policies.
## Drives the real SimServer tick by tick with scripted controllers that
## have full world access. Used to measure physics limits, verify the
## shared brain's route, and estimate flags-per-game before shipping.

import
  std/[os, strformat, strutils],
  bitworld/spriteprotocol,
  jumper,
  ../players/leapfrog/brain

const
  TileSize = 32

type
  Kind = enum
    KindRunner
    KindSupport
    KindWallCamper   ## proxy for daf/jumper-bot: parks + bounces at a wall
    KindIdle

  Seat = object
    kind: Kind
    brain: Brain
    campWall: int

proc viewFor(sim: SimServer, i: int): WorldView =
  ## Builds the full-information world view for one player.
  let p = sim.players[i]
  result.ownX = p.x
  result.ownY = p.y
  result.grounded = p.onGround
  for j in 0 ..< sim.players.len:
    if j == i or sim.players[j].dead:
      continue
    result.players.add SeenPlayer(
      x: sim.players[j].x,
      y: sim.players[j].y,
      name: sim.players[j].name
    )

proc inputFromMask(mask: uint8): InputState =
  result.left = (mask and MaskLeft) != 0
  result.right = (mask and MaskRight) != 0
  result.attack = (mask and MaskJump) != 0

proc camperMask(sim: SimServer, seat: var Seat, i: int): uint8 =
  ## Wall camper: proxy for resident league bots that park at a wall
  ## bouncing forever (daf at wall1, jumper-bot at wall2).
  seat.brain.supportWall = seat.campWall
  seat.brain.decide(sim.viewFor(i), RoleSupport)

proc runScenario(seats: var seq[Seat], ticks, seed: int, trace: bool) =
  var sim = initSimServer(seed)
  for i in 0 ..< seats.len:
    let name =
      case seats[i].kind
      of KindRunner, KindSupport: TeamPrefix & $i
      of KindWallCamper: "camp" & $i
      of KindIdle: "idle" & $i
    discard sim.addPlayer(name)
    seats[i].brain.slot = i
  var inputs = newSeq[InputState](seats.len)
  for tick in 0 ..< ticks:
    for i in 0 ..< seats.len:
      if sim.players[i].dead:
        inputs[i] = InputState()
        continue
      let view = sim.viewFor(i)
      var mask = 0'u8
      case seats[i].kind
      of KindRunner:
        mask = seats[i].brain.decide(view, RoleRunner)
      of KindSupport:
        mask = seats[i].brain.decide(view, RoleSupport)
      of KindWallCamper:
        mask = camperMask(sim, seats[i], i)
      of KindIdle:
        mask = 0
      inputs[i] = inputFromMask(mask)
    sim.step(inputs)
    if trace and tick mod 12 == 0:
      let p = sim.players[0]
      echo &"t={tick:4d} runner x={p.x:4d} feet={p.y + BoxH:3d} " &
        &"score={p.score} dead={p.dead} tile={p.x div 32}"
    let dbgLo = getEnv("SIMLAB_DBG_LO", "0").parseInt()
    let dbgHi = getEnv("SIMLAB_DBG_HI", "0").parseInt()
    if tick >= dbgLo and tick < dbgHi:
      var line = &"D t={tick}"
      let showAll = getEnv("SIMLAB_DBG_ALL", "") != ""
      for i in 0 ..< min(seats.len, 8):
        let p = sim.players[i]
        if showAll or p.x > 1600 or i == 0:
          line.add &" | {i} x={p.x} f={p.y + BoxH} g={p.onGround}" &
            &" m={inputs[i].attack.int}{inputs[i].right.int}" &
            &"{inputs[i].left.int}"
      echo line
  echo "--- scores:"
  for i in 0 ..< seats.len:
    echo &"  {sim.players[i].name} ({seats[i].kind}): " &
      &"score={sim.players[i].score}"

proc measureJumpHeight() =
  var sim = initSimServer(7)
  discard sim.addPlayer("solo")
  var inputs = @[InputState()]
  for tick in 0 ..< 100:
    sim.step(inputs)
  let startY = sim.players[0].y
  echo &"standing y={startY}"
  inputs[0] = InputState(attack: true)
  var minY = startY
  for tick in 0 ..< 60:
    sim.step(inputs)
    inputs[0] = InputState()
    minY = min(minY, sim.players[0].y)
  echo &"max rise = {startY - minY} px (tiles: {(startY - minY) / TileSize})"

proc measureBoostedJump() =
  var sim = initSimServer(7)
  discard sim.addPlayer("base")
  discard sim.addPlayer("climber")
  var inputs = @[InputState(), InputState()]
  for tick in 0 ..< 100:
    sim.step(inputs)
  sim.players[1].x = sim.players[0].x
  sim.players[1].y = sim.players[0].y - BoxH
  let groundY = sim.players[0].y
  for tick in 0 ..< 10:
    sim.step(inputs)
  let startY = sim.players[1].y
  echo &"base y={groundY} climber standing on head y={startY}"
  inputs[1] = InputState(attack: true)
  var minY = startY
  for tick in 0 ..< 60:
    sim.step(inputs)
    inputs[1] = InputState()
    minY = min(minY, sim.players[1].y)
  echo &"boosted rise from ground = {groundY - minY} px " &
    &"(tiles: {(groundY - minY) / TileSize})"

when isMainModule:
  let mode = if paramCount() >= 1: paramStr(1) else: "physics"
  let seed = if paramCount() >= 2: parseInt(paramStr(2)) else: 1
  let trace = paramCount() >= 3 and paramStr(3) == "--trace"
  case mode
  of "physics":
    measureJumpHeight()
    measureBoostedJump()
  of "team":
    # Our full team: runner + 2 supports at wall3/wall2, campers at
    # walls 1 and 2 as resident league ladders, rest idle.
    var seats = @[
      Seat(kind: KindRunner),
      Seat(kind: KindSupport, brain: Brain(supportWall: 2)),
      Seat(kind: KindSupport, brain: Brain(supportWall: 1)),
      Seat(kind: KindWallCamper, campWall: 0),
      Seat(kind: KindWallCamper, campWall: 1),
      Seat(kind: KindIdle),
      Seat(kind: KindIdle),
      Seat(kind: KindIdle),
    ]
    runScenario(seats, 4320, seed, trace)
  of "pair", "pair2", "pair3":
    # Minimal: one runner plus campers at walls up to N. Debug mounts.
    var seats = @[Seat(kind: KindRunner)]
    let upTo = if mode == "pair": 0 elif mode == "pair2": 1 else: 2
    for w in 0 .. upTo:
      seats.add Seat(kind: KindWallCamper, campWall: w)
    runScenario(seats, 2400, seed, trace)
  of "endleg":
    # Verify the wall3-top -> flag leg: teleport the runner onto x57.
    var sim = initSimServer(seed)
    discard sim.addPlayer("jl0")
    var seat = Seat(kind: KindRunner)
    var inputs = newSeq[InputState](1)
    for tick in 0 ..< 300:
      if tick == 10:
        sim.players[0].x = 57 * 32 + 6
        sim.players[0].y = 10 * 32 - BoxH
        sim.players[0].velX = 0
        sim.players[0].velY = 0
      let view = sim.viewFor(0)
      inputs[0] = inputFromMask(seat.brain.decide(view, RoleRunner))
      sim.step(inputs)
      if tick mod 10 == 0:
        let p = sim.players[0]
        echo &"t={tick} x={p.x} feet={p.y + BoxH} score={p.score} " &
          &"dead={p.dead}"
    echo &"final score={sim.players[0].score}"
  of "solorun":
    # Runner alone with resident campers only: measures the no-filler
    # case where strangers make the wall3 ladder.
    var seats = @[
      Seat(kind: KindRunner),
      Seat(kind: KindWallCamper, campWall: 0),
      Seat(kind: KindWallCamper, campWall: 1),
      Seat(kind: KindWallCamper, campWall: 2),
      Seat(kind: KindIdle),
      Seat(kind: KindIdle),
      Seat(kind: KindIdle),
      Seat(kind: KindIdle),
    ]
    runScenario(seats, 4320, seed, trace)
  else:
    quit "unknown mode: " & mode
