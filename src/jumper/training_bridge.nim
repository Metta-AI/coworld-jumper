## Finite, headless Jumper sessions for Metta's numeric Coworld trainers.
## Stdout is one JSON response per command; diagnostics belong on stderr.

import std/[hashes, json, os]
import bitworld/spriteprotocol
import jumper

const
  MaxTicks = 512
  Masks = [
    0'u8,
    ButtonLeft,
    ButtonRight,
    ButtonA,
    ButtonLeft or ButtonA,
    ButtonRight or ButtonA,
  ]

var
  sim: SimServer
  seats: int
  actingSeat: int
  decisionId: int
  lastMasks: seq[uint8]
  pendingMasks: seq[uint8]
  furthestX: seq[int]

proc decision(): JsonNode =
  let values = sim.trainingVisibleValues(actingSeat)
  result = %*{
    "kind": "decision",
    "game": "jumper",
    "decision_id": decisionId,
    "seat": actingSeat,
    "engine_seat": actingSeat,
    "turn": sim.tickCount,
    "semantic_view": {"values": values},
    "inbox": [],
    "messages": [{
      "role": "user",
      "content": $(%*{"values": values, "actions": Masks}),
    }],
    "speech_messages": [],
    "action_schema": {"type": "object", "mask": "one of the listed input masks"},
  }
  result["typed_question"] = newJNull()

proc encoding(): JsonNode =
  var actions = newJArray()
  for mask in Masks:
    actions.add(%*{"mask": int(mask)})
  %*{
    "decision_id": decisionId,
    "values": sim.trainingVisibleValues(actingSeat),
    "actions": actions,
  }

proc teacher(): JsonNode =
  ## Weak, deterministic movement baseline; all choices use legal input masks.
  let mask = if sim.tickCount mod 24 < 12: ButtonRight or ButtonA else: ButtonRight
  %*{"response": $(%*{"mask": int(mask)})}

proc reset(command: JsonNode): JsonNode =
  seats = command["players"].getInt()
  if seats < 2 or seats > 8:
    raise newException(ValueError, "Jumper training needs 2..8 players")
  sim = initSimServer(int(hash(command["seed"].getStr())))
  for seat in 0 ..< seats:
    discard sim.addPlayer("seat-" & $seat, seat)
  actingSeat = 0
  decisionId = 0
  lastMasks = newSeq[uint8](seats)
  pendingMasks = newSeq[uint8](seats)
  furthestX = newSeq[int](seats)
  for seat in 0 ..< seats:
    furthestX[seat] = sim.trainingProgress(seat)
  decision()

proc step(command: JsonNode): JsonNode =
  if command["decision_id"].getInt() != decisionId:
    return %*{"kind": "rejected", "reason": "stale decision"}
  let action = parseJson(command["response"].getStr())
  let mask = action["mask"].getInt()
  if mask < 0 or mask > 255 or uint8(mask) notin Masks:
    return %*{"kind": "rejected", "reason": "illegal mask"}
  pendingMasks[actingSeat] = uint8(mask)
  let accepted = %*{"mask": mask}
  inc decisionId
  inc actingSeat
  if actingSeat == seats:
    var inputs = newSeq[InputState](seats)
    for seat in 0 ..< seats:
      inputs[seat] = inputStateFromMasks(pendingMasks[seat], lastMasks[seat])
      lastMasks[seat] = pendingMasks[seat]
    sim.step(inputs)
    for seat in 0 ..< seats:
      furthestX[seat] = max(furthestX[seat], sim.trainingProgress(seat))
    actingSeat = 0
  if sim.tickCount >= MaxTicks:
    var scores = newJObject()
    for seat in 0 ..< seats:
      # Reaching the flag dominates distance. Progress resolves scoreless runs.
      scores[$seat] = %(sim.players[seat].score * 10000 + furthestX[seat])
    return %*{
      "kind": "accepted",
      "action": accepted,
      "observation": {"kind": "terminal", "scores": scores},
    }
  %*{"kind": "accepted", "action": accepted, "observation": decision()}

when isMainModule:
  if paramCount() != 1:
    raise newException(ValueError, "Pass the Jumper checkout as the bridge argument")
  setCurrentDir(paramStr(1))
  for line in stdin.lines:
    let command = parseJson(line)
    let response = case command["kind"].getStr()
      of "reset": reset(command)
      of "encode": encoding()
      of "teacher": teacher()
      of "step": step(command)
      else: raise newException(ValueError, "Unknown bridge command")
    stdout.writeLine($response)
    stdout.flushFile()
