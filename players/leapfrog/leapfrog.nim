## Leapfrog: our Jumper bot, driven by the shared brain module.
## The websocket layer decodes the sprite protocol into a WorldView
## (own box, grounded flag, other players with names) and sends back
## the brain's input mask.
##
## League integration:
## - The seat slot is discovered by probing ?slot=N on connect; the
##   server only accepts the slot whose token matches ours.
## - We join as "jl<slot>" so teammates can recognize each other.
## - Every seat runs the scoring route; see brain.nim for why no seat
##   is allowed to park as a dedicated ladder.

import
  std/[options, os, parseopt, strutils, tables],
  whisky,
  bitworld/spriteprotocol,
  ./brain,
  ./reporter

const
  DefaultAddress = "localhost"
  DefaultPort = 8080
  EngineWsEnv = "COGAMES_ENGINE_WS_URL"
  MaxDrainMessages = 64
  ReconnectDelayMs = 250

  # World geometry (mirrors src/jumper.nim).
  WorldTileSize = 32
  ViewportWidth = 320
  ViewportHeight = 200
  PlayerSpriteOffsetX = 6
  PlayerSpriteOffsetY = 9
  TileObjectBase = 1000
  PlayerObjectBase = 5000
  NameObjectBase = 10000
  TiledSpriteBase = 300
  SelfTrackRadius = 48

type
  ObjectState = object
    x, y: int
    spriteId: int

  Sight = object
    found: bool
    worldX, worldY: int       ## top-left of the player collision box

  Bot = object
    name: string
    slot: int
    frameTick: int
    frameWidth: int
    frameHeight: int
    cameraKnown: bool
    cameraX, cameraY: int
    objects: Table[int, ObjectState]
    spriteLabels: Table[int, string]
    lastMask: uint8
    selfKnown: bool
    selfObjectId: int
    prevWorldX, prevWorldY: int
    brain: Brain

proc readU16(data: string, offset: int): int =
  int(uint16(data[offset].uint8) or
    (uint16(data[offset + 1].uint8) shl 8))

proc readI16(data: string, offset: int): int =
  let value = uint16(data[offset].uint8) or
    (uint16(data[offset + 1].uint8) shl 8)
  int(cast[int16](value))

proc readU32(data: string, offset: int): int =
  int(uint32(data[offset].uint8) or
    (uint32(data[offset + 1].uint8) shl 8) or
    (uint32(data[offset + 2].uint8) shl 16) or
    (uint32(data[offset + 3].uint8) shl 24))

proc queryEscape(value: string): string =
  ## Escapes one query string component.
  const Hex = "0123456789ABCDEF"
  for ch in value:
    if ch.isAlphaNumeric() or ch in {'-', '_', '.', '~'}:
      result.add(ch)
    else:
      let byte = ord(ch)
      result.add('%')
      result.add(Hex[(byte shr 4) and 0x0f])
      result.add(Hex[byte and 0x0f])

proc appendQueryParam(url: var string, first: var bool, key, value: string) =
  if value.len == 0:
    return
  if first:
    url.add('?')
    first = false
  else:
    url.add('&')
  url.add(key.queryEscape())
  url.add('=')
  url.add(value.queryEscape())

proc addQuery(url, name, token: string, slot: int): string =
  result = url
  var first = not result.contains('?')
  result.appendQueryParam(first, "name", name)
  result.appendQueryParam(first, "token", token)
  if slot >= 0:
    result.appendQueryParam(first, "slot", $slot)

proc playerUrl(address: string, port: int, url, name, token: string,
    slot: int): string =
  ## Builds the Jumper player websocket URL.
  if url.len > 0:
    return url.addQuery(name, token, slot)
  if address.startsWith("ws://") or address.startsWith("wss://"):
    return address.addQuery(name, token, slot)
  let host =
    if address.len == 0:
      DefaultAddress
    else:
      address
  ("ws://" & host & ":" & $port & "/player").addQuery(name, token, slot)

proc redactedUrl(url: string): string =
  ## Hides the token query value in a URL for logs.
  const Key = "token="
  let start = url.find(Key)
  if start < 0:
    return url
  let valueStart = start + Key.len
  var valueEnd = valueStart
  while valueEnd < url.len and url[valueEnd] notin {'&', '#'}:
    inc valueEnd
  result = url[0 ..< valueStart] & "<redacted>"
  if valueEnd < url.len:
    result.add(url[valueEnd .. ^1])

# ---- sprite protocol decoding ----------------------------------------------

proc isTileObjectId(id: int): bool =
  id >= TileObjectBase and
    id < TileObjectBase + LevelWidthTiles * LevelHeightTiles

proc isPlayerObjectId(id: int): bool =
  id >= PlayerObjectBase and id < PlayerObjectBase + 256

proc isNameObjectId(id: int): bool =
  id >= NameObjectBase and id < NameObjectBase + 256

proc tileFromObjectId(id: int): tuple[tx, ty: int] =
  let index = id - TileObjectBase
  (tx: index mod LevelWidthTiles, ty: index div LevelWidthTiles)

proc updateCamera(bot: var Bot) =
  ## Infers the camera offset from any visible tile object.
  bot.cameraKnown = false
  for id, item in bot.objects.pairs:
    if not id.isTileObjectId():
      continue
    let tile = id.tileFromObjectId()
    bot.cameraX = tile.tx * WorldTileSize - item.x
    bot.cameraY = tile.ty * WorldTileSize - item.y
    bot.cameraKnown = true
    return

proc applySpritePacket(bot: var Bot, packet: string): bool =
  ## Applies one or more sprite protocol messages. Pixel data is
  ## skipped, but static sprite labels are kept: name tag sprites are
  ## labeled "name <player>" and let us recognize teammates.
  var offset = 0
  while offset < packet.len:
    let messageType = packet[offset].uint8
    inc offset
    case messageType
    of 0x01:
      if offset + 10 > packet.len:
        return false
      let spriteId = packet.readU16(offset)
      let compressedLen = packet.readU32(offset + 6)
      offset += 10
      if compressedLen < 0 or offset + compressedLen + 2 > packet.len:
        return false
      offset += compressedLen
      let labelLen = packet.readU16(offset)
      offset += 2
      if offset + labelLen > packet.len:
        return false
      bot.spriteLabels[spriteId] = packet[offset ..< offset + labelLen]
      offset += labelLen
    of 0x02:
      if offset + 11 > packet.len:
        return false
      let id = packet.readU16(offset)
      bot.objects[id] = ObjectState(
        x: packet.readI16(offset + 2),
        y: packet.readI16(offset + 4),
        spriteId: packet.readU16(offset + 9)
      )
      offset += 11
    of 0x03:
      if offset + 2 > packet.len:
        return false
      bot.objects.del(packet.readU16(offset))
      offset += 2
    of 0x04:
      bot.objects.clear()
    of 0x05:
      if offset + 5 > packet.len:
        return false
      bot.frameWidth = packet.readU16(offset + 1)
      bot.frameHeight = packet.readU16(offset + 3)
      offset += 5
    of 0x06:
      if offset + 3 > packet.len:
        return false
      offset += 3
    else:
      return false
  bot.updateCamera()
  true

# ---- world view -------------------------------------------------------------

proc sightFor(bot: Bot, item: ObjectState): Sight =
  Sight(
    found: true,
    worldX: bot.cameraX + item.x + PlayerSpriteOffsetX,
    worldY: bot.cameraY + item.y + PlayerSpriteOffsetY
  )

proc playerName(bot: Bot, playerIndex: int): string =
  ## Name tag text for one player index, if its tag is visible.
  let nameId = NameObjectBase + playerIndex
  if nameId notin bot.objects:
    return ""
  let spriteId = bot.objects[nameId].spriteId
  if spriteId notin bot.spriteLabels:
    return ""
  let label = bot.spriteLabels[spriteId]
  const Prefix = "name "
  if label.startsWith(Prefix):
    return label[Prefix.len .. ^1]
  ""

proc ownPlayer(bot: var Bot): Sight =
  ## Returns our own player box, identified by our unique name tag.
  ## Falls back to the closest-to-viewport-center heuristic (the
  ## server centers the camera on us) with a sticky id.
  for id, item in bot.objects.pairs:
    if not id.isPlayerObjectId():
      continue
    if bot.playerName(id - PlayerObjectBase) == bot.name:
      bot.selfKnown = true
      bot.selfObjectId = id
      return bot.sightFor(item)
  if bot.selfKnown and bot.selfObjectId in bot.objects:
    let sight = bot.sightFor(bot.objects[bot.selfObjectId])
    if abs(sight.worldX - bot.prevWorldX) <= SelfTrackRadius and
        abs(sight.worldY - bot.prevWorldY) <= SelfTrackRadius:
      return sight
  bot.selfKnown = false
  var bestScore = high(int)
  var bestId = -1
  for id, item in bot.objects.pairs:
    if not id.isPlayerObjectId():
      continue
    let
      boxScreenX = item.x + PlayerSpriteOffsetX
      boxScreenY = item.y + PlayerSpriteOffsetY
      dx = boxScreenX + BoxW div 2 - bot.frameWidth div 2
      dy = boxScreenY + BoxH div 2 - bot.frameHeight div 2
      score = dx * dx + dy * dy
    if score < bestScore:
      bestScore = score
      bestId = id
  if bestId < 0:
    return
  bot.selfKnown = true
  bot.selfObjectId = bestId
  bot.sightFor(bot.objects[bestId])

proc groundedOnTiles(view: WorldView): bool =
  ## True when the static map supports our feet.
  let footY = view.ownY + BoxH + 1
  var x = view.ownX + 1
  while x <= view.ownX + BoxW - 1:
    if solidTile(x div WorldTileSize, footY div WorldTileSize):
      return true
    x += 2
  false

proc buildView(bot: var Bot): Option[WorldView] =
  ## Builds the brain's world view from decoded sprite state.
  let own = bot.ownPlayer()
  if not own.found or not bot.cameraKnown:
    return none(WorldView)
  bot.prevWorldX = own.worldX
  bot.prevWorldY = own.worldY
  var view = WorldView(ownX: own.worldX, ownY: own.worldY)
  for id, item in bot.objects.pairs:
    if not id.isPlayerObjectId() or id == bot.selfObjectId:
      continue
    let sight = bot.sightFor(item)
    view.players.add SeenPlayer(
      x: sight.worldX,
      y: sight.worldY,
      name: bot.playerName(id - PlayerObjectBase)
    )
  view.grounded = view.groundedOnTiles() or view.standingOnPlayer()
  some(view)

# ---- websocket loop ---------------------------------------------------------

proc acceptServerMessage(
  ws: WebSocket,
  message: Message,
  bot: var Bot,
  rep: var Reporter
): bool =
  case message.kind
  of BinaryMessage:
    rep.consume(message.data)
    result = bot.applySpritePacket(message.data)
    if result:
      inc bot.frameTick
  of Ping:
    ws.send(message.data, Pong)
  of TextMessage, Pong:
    discard

proc receiveUpdates(ws: WebSocket, bot: var Bot, rep: var Reporter): bool =
  let firstMessage = ws.receiveMessage(-1)
  if firstMessage.isNone:
    return false
  if ws.acceptServerMessage(firstMessage.get, bot, rep):
    result = true
  var drained = 0
  while drained < MaxDrainMessages:
    let message = ws.receiveMessage(0)
    if message.isNone:
      break
    if ws.acceptServerMessage(message.get, bot, rep):
      result = true
    inc drained

proc connectWithSlot(address: string, port: int, url, token: string,
    requestedSlot: int): tuple[ws: WebSocket, slot: int] =
  ## Connects to the player socket. With no requested slot, probes
  ## slots 0..7: the server accepts only the slot whose token matches,
  ## which tells us which league seat we hold.
  if requestedSlot >= 0:
    let name = TeamPrefix & $requestedSlot
    let endpoint = playerUrl(address, port, url, name, token, requestedSlot)
    echo name, " connecting to ", endpoint.redactedUrl()
    flushFile(stdout)
    return (newWebSocket(endpoint), requestedSlot)
  for slot in 0 .. 7:
    let name = TeamPrefix & $slot
    let endpoint = playerUrl(address, port, url, name, token, slot)
    try:
      let ws = newWebSocket(endpoint)
      echo name, " connected (slot probe hit ", slot, ")"
      flushFile(stdout)
      return (ws, slot)
    except CatchableError:
      continue
  # Every explicit slot refused: join with automatic assignment.
  let endpoint = playerUrl(address, port, url, TeamPrefix, token, -1)
  echo "slot probe exhausted; connecting with auto slot"
  flushFile(stdout)
  (newWebSocket(endpoint), -1)

proc runBot(address: string, port: int, url, token: string,
    slot, maxSteps: int, exitOnDisconnect: bool,
    reportTarget: string, reportMode: ReportMode) =
  var
    connected = false
    rep = initReporter(reportTarget, reportMode)
  defer: rep.close()
  while true:
    try:
      let (ws, mySlot) = connectWithSlot(address, port, url, token, slot)
      connected = true
      let effectiveSlot = max(mySlot, 0)
      var bot = Bot(
        name: TeamPrefix & $effectiveSlot,
        slot: effectiveSlot,
        frameWidth: ViewportWidth,
        frameHeight: ViewportHeight,
        brain: Brain(slot: effectiveSlot, supportWall: 2)
      )
      # Every seat runs for the flag: a policy holding several seats is
      # scored by the mean over them, so a parked support seat would
      # halve our result.
      const role = RoleRunner
      echo bot.name, " playing role ", role
      flushFile(stdout)
      var lastMask = 0xff'u8
      while true:
        if not ws.receiveUpdates(bot, rep):
          continue
        let viewOpt = bot.buildView()
        var nextMask = 0'u8
        if viewOpt.isSome:
          nextMask = bot.brain.decide(viewOpt.get, role)
        if getEnv("LEAPFROG_DEBUG").len > 0 and
            bot.frameTick mod 24 == 0:
          if viewOpt.isSome:
            let v = viewOpt.get
            var line = "dbg t=" & $bot.frameTick & " x=" & $v.ownX &
              " y=" & $v.ownY & " g=" & $v.grounded &
              " mask=" & $nextMask & " others="
            for p in v.players:
              line.add "(" & $p.x & "," & $p.y & "," & p.name & ")"
            echo line
          else:
            echo "dbg t=", bot.frameTick, " no view (cameraKnown=",
              bot.cameraKnown, " objects=", bot.objects.len, ")"
          flushFile(stdout)
        bot.lastMask = nextMask
        if nextMask != lastMask:
          ws.send(blobFromMask(nextMask), BinaryMessage)
          lastMask = nextMask
        if maxSteps > 0 and bot.frameTick >= maxSteps:
          ws.close()
          return
    except CatchableError as e:
      if connected:
        echo "disconnected: ", e.msg
        flushFile(stdout)
        if exitOnDisconnect:
          return
        connected = false
      else:
        echo "reconnecting: ", e.msg
        flushFile(stdout)
      sleep(ReconnectDelayMs)

when isMainModule:
  var
    address = DefaultAddress
    port = DefaultPort
    url = getEnv(EngineWsEnv)
    token = ""
    slot = -1
    maxSteps = 0
    reportTarget = ""
    reportMode = rmAll
  for kind, key, val in getopt():
    case kind
    of cmdLongOption:
      case key
      of "address":
        address = val
      of "url", "player-url", "socket":
        url = val
      of "port":
        port = parseInt(val)
      of "token":
        token = val
      of "slot":
        slot = parseInt(val)
      of "max-steps":
        maxSteps = parseInt(val)
      of "report":
        reportTarget = val
      of "report-mode":
        case val
        of "all": reportMode = rmAll
        of "changes": reportMode = rmChanges
        of "events": reportMode = rmEvents
        else: quit("unknown --report-mode: " & val)
      else:
        discard
    else:
      discard
  runBot(address, port, url, token, slot, maxSteps, url.len > 0,
    reportTarget, reportMode)
