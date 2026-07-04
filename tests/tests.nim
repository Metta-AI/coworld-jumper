import std/os

{.warning[UnusedImport]: off.}
import jumper
{.warning[UnusedImport]: on.}

echo "Testing Jumper"
doAssert fileExists("coworld_manifest.json"), "manifest should exist"
doAssert fileExists("data/forest.tmx"), "map should exist"
doAssert fileExists("data/spritesheet.png"), "spritesheet should exist"
doAssert fileExists("players/dalli.nim"), "dalli bot should exist"

import std/json
import bitworld/spriteprotocol
import jumper/replays

echo "Testing replay round trip"
block:
  const
    TestSeed = 4242
    TestTicks = 200
  let replayPath = getTempDir() / "jumper-test-replay.bitreplay"

  # Record: drive a live-style sim with scripted inputs and a chat.
  var
    recSim = initSimServer(TestSeed)
    writer = openReplayWriter(replayPath, $(%*{"seed": TestSeed}))
  doAssert recSim.addPlayer("alice", -1) == 0, "alice should join first"
  writer.writeJoin(tickTime(0), 0, "alice", recSim.players[0].slot, "")
  writer.lastMasks.add(0)
  doAssert recSim.addPlayer("bob", 3) == 1, "bob should join second"
  writer.writeJoin(tickTime(0), 1, "bob", recSim.players[1].slot, "")
  writer.lastMasks.add(0)

  var
    masks = [0'u8, 0'u8]
    lastApplied = [0'u8, 0'u8]
  for tick in 0 ..< TestTicks:
    masks[0] =
      if tick < 40:
        ButtonRight
      elif tick < 90:
        ButtonRight or ButtonUp
      elif tick < 120:
        ButtonA
      else:
        ButtonUp or ButtonLeft
    masks[1] =
      if tick mod 30 < 15:
        ButtonLeft
      else:
        ButtonRight or ButtonUp
    for playerIndex in 0 ..< 2:
      writer.writeInputMaskChange(
        tickTime(recSim.tickCount),
        playerIndex,
        masks[playerIndex]
      )
    if tick == 100:
      recSim.players[0].message = "hello bob"
      recSim.players[0].messageTicks = ChatLifetimeTicks
      writer.writeChat(tickTime(recSim.tickCount), 0, "hello bob")
    let inputs = @[
      inputStateFromMasks(masks[0], lastApplied[0]),
      inputStateFromMasks(masks[1], lastApplied[1])
    ]
    lastApplied = masks
    recSim.step(inputs)
    writer.writeHash(uint32(recSim.tickCount), recSim.gameHash())
  let recordedHash = recSim.gameHash()
  writer.closeReplayWriter()

  # Play back against a fresh sim and validate every recorded hash.
  let data = loadReplay(replayPath)
  doAssert data.configJson == $(%*{"seed": TestSeed}),
    "replay config should round trip"
  doAssert data.joins.len == 2, "replay should keep both joins"
  doAssert data.chats.len == 1, "replay should keep the chat"
  doAssert data.hashes.len == TestTicks, "replay should hash every tick"
  var
    playSim = initSimServer(TestSeed)
    replay = initReplayPlayer(data)
  doAssert replay.replayMaxTick() == TestTicks, "max tick should match"
  while replay.playing and replay.hashIndex < data.hashes.len:
    replay.stepReplay(playSim)
  doAssert playSim.tickCount == TestTicks, "playback should reach the end"
  doAssert not replay.hashValidationFailed, "replay hashes should validate"
  doAssert playSim.gameHash() == recordedHash,
    "playback should reproduce the final game hash"
  doAssert playSim.gameHash() == data.hashes[^1].hash,
    "final hash should match the recorded stream"

  echo "Testing replay keyframe seeking"
  var
    seekSim = initSimServer(TestSeed)
    seeker = initReplayPlayer(data)
  seeker.buildReplayKeyframes(initSimServer(TestSeed))
  doAssert seeker.keyframes.len == TestTicks div ReplayKeyframeTicks + 1,
    "keyframes should be saved every " & $ReplayKeyframeTicks & " ticks"
  for target in [150, 42, 200, 0, 137]:
    seeker.seekReplay(seekSim, TestSeed, target)
    doAssert seekSim.tickCount == target,
      "seek should land on tick " & $target
    var linearSim = initSimServer(TestSeed)
    var linear = initReplayPlayer(data)
    while linearSim.tickCount < target and
        linear.hashIndex < data.hashes.len:
      linear.stepReplay(linearSim)
    doAssert seekSim.gameHash() == linearSim.gameHash(),
      "seeked state should match linear playback at tick " & $target
  removeFile(replayPath)
