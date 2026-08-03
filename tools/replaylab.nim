## Replay analyzer: re-simulates a league .replay file and prints
## per-seat behavior stats — score/death events, wall crossings and
## whether they were boosted off a teammate's head, and time spent
## per map region. Used to study how league bots play.

import
  std/[json, os, strformat, strutils, tables],
  jumper, jumper/replays

const
  TileSize = 32
  BoxH = 23
  BoxW = 20
  # Choke walls: x tile of the wall column and the feet y (px) of its top.
  Walls = [
    (name: "wall1_x23", left: 23 * TileSize, topFeet: 12 * TileSize),
    (name: "wall2_x38", left: 38 * TileSize, topFeet: 10 * TileSize),
    (name: "wall3_x57", left: 57 * TileSize, topFeet: 10 * TileSize),
  ]

type
  SeatStats = object
    name: string
    scores: seq[int]        ## ticks of flag touches
    deaths: seq[int]        ## ticks of deaths
    stationaryTicks: int
    boostedTicks: int       ## ticks standing on another player
    ladderTicks: int        ## ticks somebody stood on us
    wallZoneTicks: array[Walls.len, int]
    crossTicks: array[Walls.len, seq[int]]
    lastX, lastY: int

proc standingOn(a, b: Actor): bool =
  ## True when a's feet rest on b's head.
  let
    dx = abs((a.x + BoxW div 2) - (b.x + BoxW div 2))
    gap = b.y - (a.y + BoxH)
  dx <= BoxW and gap >= -2 and gap <= 3

proc main() =
  if paramCount() < 1:
    quit "usage: replaylab <file.replay> [--traj]"
  let
    path = paramStr(1)
    wantTraj = paramCount() >= 2 and paramStr(2) == "--traj"
    data = loadReplay(path)
    config = parseJson(data.configJson)
    seed = config{"seed"}.getInt(0xB1770)
  echo &"config: {data.configJson}"
  var
    sim = initSimServer(seed)
    replay = initReplayPlayer(data)
    stats: Table[int, SeatStats]
    prevScores: Table[int, int]
    prevDead: Table[int, bool]
    prevY: Table[int, int]
  replay.playing = true
  let maxTick = replay.replayMaxTick()
  echo &"joins: {data.joins.len} leaves: {data.leaves.len}"
  echo &"maxTick: {maxTick}"

  while sim.tickCount < maxTick:
    replay.stepReplay(sim)
    for i in 0 ..< sim.players.len:
      let slot = sim.players[i].slot
      if slot notin stats:
        stats[slot] = SeatStats(name: sim.players[i].name)
        prevScores[slot] = 0
        prevDead[slot] = false
        prevY[slot] = 0
    for i in 0 ..< sim.players.len:
      let p = sim.players[i]
      let slot = p.slot
      template st: untyped = stats[slot]
      if p.score > prevScores[slot]:
        st.scores.add sim.tickCount
        prevScores[slot] = p.score
      if p.dead and not prevDead[slot]:
        st.deaths.add sim.tickCount
      prevDead[slot] = p.dead
      if p.dead:
        continue
      if p.x == st.lastX and p.y == st.lastY:
        inc st.stationaryTicks
      # Boost bookkeeping.
      for j in 0 ..< sim.players.len:
        if i == j or sim.players[j].dead:
          continue
        if standingOn(p, sim.players[j]):
          inc st.boostedTicks
          inc stats[sim.players[j].slot].ladderTicks
          break
      # Wall zones and crossings.
      let feet = p.y + BoxH
      for w in 0 ..< Walls.len:
        if abs(p.x + BoxW - Walls[w].left) <= 3 * TileSize and
            feet > Walls[w].topFeet:
          inc st.wallZoneTicks[w]
        # Crossing: feet moved above wall top while near the wall column.
        if prevY[slot] + BoxH > Walls[w].topFeet and
            feet <= Walls[w].topFeet and
            abs(p.x + BoxW div 2 - Walls[w].left) <= 3 * TileSize:
          st.crossTicks[w].add sim.tickCount
      prevY[slot] = p.y
      st.lastX = p.x
      st.lastY = p.y
      if wantTraj:
        echo &"traj {sim.tickCount} {slot} {p.x} {p.y} {p.score}"

  echo ""
  echo &"final tick {sim.tickCount}"
  for slot in 0 ..< 8:
    if slot notin stats:
      continue
    let st = stats[slot]
    var line = &"slot {slot} {st.name:24s} score={st.scores.len}"
    line.add &" deaths={st.deaths.len}"
    line.add &" stationary={st.stationaryTicks}"
    line.add &" boosted={st.boostedTicks} ladder={st.ladderTicks}"
    echo line
    if st.scores.len > 0:
      echo &"   flags at: {st.scores}"
    if st.deaths.len > 0 and st.deaths.len <= 20:
      echo &"   deaths at: {st.deaths}"
    for w in 0 ..< Walls.len:
      if st.crossTicks[w].len > 0 or st.wallZoneTicks[w] > 0:
        echo &"   {Walls[w].name}: zoneTicks={st.wallZoneTicks[w]} " &
          &"crossings={st.crossTicks[w]}"

when isMainModule:
  main()
