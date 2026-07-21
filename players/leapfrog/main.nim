## Leapfrog: our Jumper bot.
## Runs right, jumps pits and walls, and breaks too-tall ledges with
## leapfrog rotation: stand as a stable step, and once climbed on (and
## still stuck 10s later) hop back one body width so the next teammate
## takes the wall spot, then take a running jump at the ledge.
## - Pits: jump ahead of the edge; while rising hold forward; while
##   falling release forward if a pit lip is close and ground is below.
## - Walls up to solo jump reach: jump forward.
## - Ledges above jump reach: stand still as a step for teammates,
##   retreat-and-retry cycle described above.

import
  std/[options, os, parseopt, strutils, tables],
  whisky,
  bitworld/spriteprotocol

const
  DefaultAddress = "localhost"
  DefaultPort = 8080
  EngineWsEnv = "COGAMES_ENGINE_WS_URL"
  MaxDrainMessages = 64
  ReconnectDelayMs = 250

  # World geometry (mirrors src/jumper.nim).
  WorldTileSize = 32
  LevelWidthTiles = 64
  LevelHeightTiles = 16
  ViewportWidth = 320
  ViewportHeight = 200
  PlayerBoxWidth = 20
  PlayerBoxHeight = 23
  PlayerSpriteOffsetX = 6
  PlayerSpriteOffsetY = 9
  TileObjectBase = 1000
  PlayerObjectBase = 5000
  TiledSpriteBase = 300
  FlagGid = 15
  SeesawGid = 54
  SignGid = 60

  # Pit policy tuning.
  PitLookAheadPixels = 96     ## how far ahead we scan for missing ground
  PitScanStepPixels = 2       ## horizontal scan resolution
  PitDropPixels = 56          ## ground deeper than this reads as a pit
  JumpTriggerPixels = 40      ## jump when the pit edge is this close
  FallGuardPixels = 24        ## while falling, stop forward if pit this close
  JumpCooldownTicks = 10      ## re-press spacing for the jump button
  SelfTrackRadius = 48        ## own-player continuity radius between frames

  # Wall policy tuning.
  WallLookAheadPixels = 28    ## a solid column this close counts as a wall

  # Ledge retreat policy: when stuck at a ledge for a while right after
  # carrying someone, step back to give the next climber the wall spot.
  TicksPerSecond = 24
  LedgeStuckTicks = 10 * TicksPerSecond   ## facing ledge + grounded this long
  CarrierRecentTicks = 2 * TicksPerSecond ## carrier seen within this window
  RetreatDistancePixels = PlayerBoxWidth  ## how far back to step
  RetreatMaxTicks = 3 * TicksPerSecond    ## safety cap if pinned
  CarrierSideTolerance = 24               ## x overlap for on-top detection
  CarrierGapMin = -6                      ## feet-to-head gap window
  CarrierGapMax = 12
  ClimbWindowTicks = 5 * TicksPerSecond   ## post-retreat jump-at-ledge window

type
  ObjectState = object
    x, y: int
    spriteId: int

  Sight = object
    found: bool
    worldX, worldY: int       ## top-left of the player collision box

  Bot = object
    name: string
    frameTick: int
    frameWidth: int
    frameHeight: int
    cameraKnown: bool
    cameraX, cameraY: int
    objects: Table[int, ObjectState]
    jumpCooldown: int
    lastMask: uint8
    selfKnown: bool
    selfObjectId: int         ## sticky own-player object id
    prevWorldX, prevWorldY: int
    velY: int                 ## positive = falling, negative = rising
    ledgeStuckSince: int      ## first tick of the current ledge+floor stretch
    ledgeLastMetTick: int     ## last tick the ledge+floor condition held
    lastCarrierTick: int      ## last tick another player stood on us
    retreating: bool
    retreatStartX: int
    retreatDeadline: int
    climbUntilTick: int       ## after a retreat, jump at ledges until here

proc readU16(data: string, offset: int): int =
  ## Reads one little endian unsigned 16 bit value.
  int(uint16(data[offset].uint8) or
    (uint16(data[offset + 1].uint8) shl 8))

proc readI16(data: string, offset: int): int =
  ## Reads one little endian signed 16 bit value.
  let value = uint16(data[offset].uint8) or
    (uint16(data[offset + 1].uint8) shl 8)
  int(cast[int16](value))

proc readU32(data: string, offset: int): int =
  ## Reads one little endian unsigned 32 bit value.
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
  ## Appends one optional query parameter to a URL.
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
  ## Appends player query fields to a websocket URL.
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
  ## Returns true when an object id belongs to a Tiled map cell.
  id >= TileObjectBase and
    id < TileObjectBase + LevelWidthTiles * LevelHeightTiles

proc isPlayerObjectId(id: int): bool =
  ## Returns true when an object id belongs to a player sprite.
  id >= PlayerObjectBase and id < PlayerObjectBase + 256

proc tileFromObjectId(id: int): tuple[tx, ty: int] =
  ## Returns the Tiled cell coordinate for one tile object id.
  let index = id - TileObjectBase
  (tx: index mod LevelWidthTiles, ty: index div LevelWidthTiles)

proc gidFromSprite(spriteId: int): int =
  ## Returns the Tiled gid encoded by one tile sprite id.
  if spriteId < TiledSpriteBase:
    return 0
  spriteId - TiledSpriteBase

proc isSolidGid(gid: int): bool =
  ## Returns true when a Tiled gid blocks players.
  gid != 0 and gid != FlagGid and gid != SeesawGid and gid != SignGid

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
  ## Applies one or more sprite protocol messages. Pixel data is skipped;
  ## the bot only needs object placement and sprite ids.
  var offset = 0
  while offset < packet.len:
    let messageType = packet[offset].uint8
    inc offset
    case messageType
    of 0x01:
      if offset + 10 > packet.len:
        return false
      let compressedLen = packet.readU32(offset + 6)
      offset += 10
      if compressedLen < 0 or offset + compressedLen + 2 > packet.len:
        return false
      offset += compressedLen
      let labelLen = packet.readU16(offset)
      offset += 2
      if offset + labelLen > packet.len:
        return false
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

# ---- world queries ----------------------------------------------------------

proc solidTile(bot: Bot, tx, ty: int): bool =
  ## Returns true when a visible map cell is solid.
  if tx < 0 or ty < 0 or tx >= LevelWidthTiles or ty >= LevelHeightTiles:
    return false
  let id = TileObjectBase + ty * LevelWidthTiles + tx
  if id notin bot.objects:
    return false
  bot.objects[id].spriteId.gidFromSprite().isSolidGid()

proc solidAt(bot: Bot, worldX, worldY: int): bool =
  ## Returns true when a world pixel is inside solid terrain.
  if worldX < 0 or worldY < 0:
    return false
  bot.solidTile(worldX div WorldTileSize, worldY div WorldTileSize)

proc sightFor(bot: Bot, item: ObjectState): Sight =
  ## Converts one player object into a world-space sight.
  Sight(
    found: true,
    worldX: bot.cameraX + item.x + PlayerSpriteOffsetX,
    worldY: bot.cameraY + item.y + PlayerSpriteOffsetY
  )

proc ownPlayer(bot: var Bot): Sight =
  ## Returns our own player box. The server centers the camera on us, but
  ## other players near the center can win a naive closest-to-center pick.
  ## So the id is made sticky: once identified, keep following that object
  ## while it stays near our last known position.
  if bot.selfKnown and bot.selfObjectId in bot.objects:
    let sight = bot.sightFor(bot.objects[bot.selfObjectId])
    if abs(sight.worldX - bot.prevWorldX) <= SelfTrackRadius and
        abs(sight.worldY - bot.prevWorldY) <= SelfTrackRadius:
      return sight
    # Object teleported (respawn) or we mis-tracked: re-acquire below.
  bot.selfKnown = false
  var bestScore = high(int)
  var bestId = -1
  for id, item in bot.objects.pairs:
    if not id.isPlayerObjectId():
      continue
    let
      boxScreenX = item.x + PlayerSpriteOffsetX
      boxScreenY = item.y + PlayerSpriteOffsetY
      dx = boxScreenX + PlayerBoxWidth div 2 - bot.frameWidth div 2
      dy = boxScreenY + PlayerBoxHeight div 2 - bot.frameHeight div 2
      score = dx * dx + dy * dy
    if score < bestScore:
      bestScore = score
      bestId = id
  if bestId < 0:
    return
  bot.selfKnown = true
  bot.selfObjectId = bestId
  bot.sightFor(bot.objects[bestId])

proc groundWithin(bot: Bot, x, footY, drop: int): bool =
  ## Returns true when solid ground exists under one x within `drop` pixels.
  var dy = 0
  while dy <= drop:
    if bot.solidAt(x, footY + dy):
      return true
    dy += PitScanStepPixels
  false

proc groundedOnTiles(bot: Bot, own: Sight): bool =
  ## Returns true when the player is standing on terrain.
  let footY = own.worldY + PlayerBoxHeight + 1
  var x = own.worldX + 2
  while x <= own.worldX + PlayerBoxWidth - 2:
    if bot.solidAt(x, footY) or bot.solidAt(x, footY + 2):
      return true
    x += PitScanStepPixels
  false

proc pitStartDistance(bot: Bot, own: Sight): int =
  ## Returns pixels from our front edge to the first pit column ahead,
  ## or -1 when no pit is visible within the look-ahead window.
  ## A pit column has no ground within PitDropPixels below foot level.
  let
    frontX = own.worldX + PlayerBoxWidth
    footY = own.worldY + PlayerBoxHeight + 1
  var dx = 0
  while dx <= PitLookAheadPixels:
    if not bot.groundWithin(frontX + dx, footY, PitDropPixels):
      return dx
    dx += PitScanStepPixels
  -1

proc landingBelow(bot: Bot, own: Sight): bool =
  ## Returns true when solid ground lies below our body within a fall
  ## guard's reach (we would land, not keep falling into a pit).
  let footY = own.worldY + PlayerBoxHeight + 1
  var x = own.worldX + 2
  while x <= own.worldX + PlayerBoxWidth - 2:
    if bot.groundWithin(x, footY, PitDropPixels):
      return true
    x += PitScanStepPixels
  false

proc wallAhead(bot: Bot, own: Sight): bool =
  ## Returns true when a solid column blocks our body within a short
  ## distance ahead (anything that stops horizontal motion).
  let frontX = own.worldX + PlayerBoxWidth
  var dx = 2
  while dx <= WallLookAheadPixels:
    var y = own.worldY + 4
    while y <= own.worldY + PlayerBoxHeight - 2:
      if bot.solidAt(frontX + dx, y):
        return true
      y += PitScanStepPixels
    dx += PitScanStepPixels
  false

proc facingLedge(bot: Bot, own: Sight): bool =
  ## Returns true when the first blocking wall ahead is taller than a solo
  ## jump can clear. Only the continuous solid column that actually blocks
  ## our body counts: a higher step further along (staircase) is NOT a
  ## ledge, we can climb stairs one jump at a time.
  let
    frontX = own.worldX + PlayerBoxWidth
    footY = own.worldY + PlayerBoxHeight
  var dx = 2
  while dx <= WallLookAheadPixels:
    let x = frontX + dx
    # Is this column blocking our body?
    var blockingY = -1
    var y = own.worldY + 4
    while y <= own.worldY + PlayerBoxHeight - 2:
      if bot.solidAt(x, y):
        blockingY = y
        break
      y += PitScanStepPixels
    if blockingY >= 0:
      # Walk up the continuous solid column to find its top.
      var topY = blockingY
      while topY > 0 and bot.solidAt(x, topY - PitScanStepPixels):
        topY -= PitScanStepPixels
      # Jump reach: ~3 tiles of rise; keep half a tile of safety margin.
      return footY - topY > WorldTileSize * 5 div 2
    dx += PitScanStepPixels
  false

proc allPlayers(bot: Bot): seq[Sight] =
  ## Returns all visible player boxes in world coordinates.
  for id, item in bot.objects.pairs:
    if id.isPlayerObjectId():
      result.add(bot.sightFor(item))

proc someoneOnTop(bot: Bot, own: Sight): bool =
  ## Returns true when another player is standing on our head.
  for other in bot.allPlayers():
    if other.worldX == own.worldX and other.worldY == own.worldY:
      continue  # ourselves
    let
      dx = abs((other.worldX + PlayerBoxWidth div 2) -
        (own.worldX + PlayerBoxWidth div 2))
      gap = own.worldY - (other.worldY + PlayerBoxHeight)
    if dx <= CarrierSideTolerance and
        gap >= CarrierGapMin and gap <= CarrierGapMax:
      return true

proc standingOnPlayer(bot: Bot, own: Sight): bool =
  ## Returns true when we are standing on another player's head.
  for other in bot.allPlayers():
    if other.worldX == own.worldX and other.worldY == own.worldY:
      continue  # ourselves
    let
      dx = abs((other.worldX + PlayerBoxWidth div 2) -
        (own.worldX + PlayerBoxWidth div 2))
      gap = other.worldY - (own.worldY + PlayerBoxHeight)
    if dx <= CarrierSideTolerance and
        gap >= CarrierGapMin and gap <= CarrierGapMax:
      return true

proc grounded(bot: Bot, own: Sight): bool =
  ## Returns true when the player is supported by terrain or a teammate.
  bot.groundedOnTiles(own) or bot.standingOnPlayer(own)

# ---- decision ---------------------------------------------------------------

proc jumpButton(bot: var Bot): uint8 =
  ## Returns a one-frame jump press honoring the cooldown.
  if bot.jumpCooldown > 0:
    return 0
  if (bot.lastMask and ButtonA) != 0:
    return 0
  bot.jumpCooldown = JumpCooldownTicks
  ButtonA

proc decideMask(bot: var Bot): uint8 =
  ## Runs right; jumps pits and walls; releases forward when falling near
  ## a pit edge.
  let own = bot.ownPlayer()
  if not own.found or not bot.cameraKnown:
    return 0

  # Vertical velocity from position delta (positive = falling).
  bot.velY = own.worldY - bot.prevWorldY
  bot.prevWorldX = own.worldX
  bot.prevWorldY = own.worldY
  if bot.jumpCooldown > 0:
    dec bot.jumpCooldown

  let
    isGrounded = bot.grounded(own)
    pitDistance = bot.pitStartDistance(own)
    pitNear = pitDistance >= 0 and pitDistance <= JumpTriggerPixels
    pitGuard = pitDistance >= 0 and pitDistance <= FallGuardPixels
    blocked = bot.wallAhead(own)
    ledge = bot.facingLedge(own)

  # -- Ledge retreat bookkeeping --------------------------------------------
  # Track how long we've been pinned at a too-tall ledge. The condition
  # naturally flickers (we hop against the wall, briefly airborne), so the
  # streak only resets after a full second away from the ledge, not on
  # every hop frame.
  if ledge and isGrounded:
    if bot.ledgeStuckSince == 0 or
        bot.frameTick - bot.ledgeLastMetTick > TicksPerSecond:
      bot.ledgeStuckSince = bot.frameTick
    bot.ledgeLastMetTick = bot.frameTick
  if bot.someoneOnTop(own):
    bot.lastCarrierTick = bot.frameTick

  # Debug: report condition state once a second while near a wall.
  if bot.frameTick mod TicksPerSecond == 0 and (blocked or ledge):
    let stuckFor =
      if bot.ledgeStuckSince > 0:
        bot.frameTick - bot.ledgeStuckSince
      else:
        -1
    let carrierAge =
      if bot.lastCarrierTick > 0:
        bot.frameTick - bot.lastCarrierTick
      else:
        -1
    echo bot.name, " dbg tick=", bot.frameTick,
      " x=", own.worldX,
      " grounded=", isGrounded,
      " blocked=", blocked,
      " ledge=", ledge,
      " stuckFor=", stuckFor,
      " carrierAge=", carrierAge
    flushFile(stdout)

  # Active retreat runs to completion before any other behavior.
  # Retreat = hop backward: while grounded, jump-and-left (mid-air movement
  # escapes the pile shove of teammates pressing right into our back);
  # while airborne, hold left.
  if bot.retreating:
    let travelled = bot.retreatStartX - own.worldX
    if travelled >= RetreatDistancePixels or
        bot.frameTick >= bot.retreatDeadline:
      bot.retreating = false
      bot.ledgeStuckSince = 0
      bot.ledgeLastMetTick = 0
      # Resume normal ledge attempts for a while: with the retreat gap and
      # possibly a teammate now at the wall, a running jump may make it.
      bot.climbUntilTick = bot.frameTick + ClimbWindowTicks
      echo bot.name, " retreat done travelled=", travelled
      flushFile(stdout)
    else:
      return ButtonLeft

  # Start a retreat: pinned at the ledge for 10s, and someone stood on us
  # within the last 2s (they likely just climbed off our head and over).
  if bot.ledgeStuckSince > 0 and
      bot.frameTick - bot.ledgeLastMetTick <= TicksPerSecond and
      bot.frameTick - bot.ledgeStuckSince >= LedgeStuckTicks and
      bot.lastCarrierTick > 0 and
      bot.frameTick - bot.lastCarrierTick <= CarrierRecentTicks:
    bot.retreating = true
    bot.retreatStartX = own.worldX
    bot.retreatDeadline = bot.frameTick + RetreatMaxTicks
    echo bot.name, " retreat start x=", own.worldX
    flushFile(stdout)
    return ButtonLeft
  # --------------------------------------------------------------------------

  if isGrounded:
    # Run right; jump the moment a pit edge or a wall is close.
    # A too-tall ledge is the exception: jumping is futile and the constant
    # hopping prevents ever being a stable step for teammates. Press into
    # the wall and stand still instead -- unless we just finished a retreat,
    # in which case attempt ledge jumps as usual for a short window (there
    # may be a teammate at the wall to climb, or a running start helps).
    result = ButtonRight
    if ledge and bot.frameTick >= bot.climbUntilTick:
      discard
    elif pitNear or blocked:
      result = result or bot.jumpButton()
  elif bot.velY < 0:
    # Rising in a jump: hold forward to carry across the pit or onto
    # the wall top.
    result = ButtonRight
  else:
    # Falling. Two very different situations:
    # - Ground below us and a pit just ahead: release forward so we land
    #   on the near edge instead of drifting in.
    # - No ground below (we are already over the pit): hold forward, the
    #   far edge is the only way out.
    if pitGuard and bot.landingBelow(own):
      result = 0
    else:
      result = ButtonRight

# ---- websocket loop ---------------------------------------------------------

proc acceptServerMessage(ws: WebSocket, message: Message, bot: var Bot): bool =
  ## Handles one websocket message from the Jumper server.
  case message.kind
  of BinaryMessage:
    result = bot.applySpritePacket(message.data)
    if result:
      inc bot.frameTick
  of Ping:
    ws.send(message.data, Pong)
  of TextMessage, Pong:
    discard

proc receiveUpdates(ws: WebSocket, bot: var Bot): bool =
  ## Receives and applies queued sprite protocol updates.
  let firstMessage = ws.receiveMessage(-1)
  if firstMessage.isNone:
    return false
  if ws.acceptServerMessage(firstMessage.get, bot):
    result = true
  var drained = 0
  while drained < MaxDrainMessages:
    let message = ws.receiveMessage(0)
    if message.isNone:
      break
    if ws.acceptServerMessage(message.get, bot):
      result = true
    inc drained

proc runBot(address: string, port: int, url, name, token: string,
    slot, maxSteps: int, exitOnDisconnect: bool) =
  ## Connects the bot to the Jumper player websocket.
  let endpoint = playerUrl(address, port, url, name, token, slot)
  var connected = false
  while true:
    try:
      var bot = Bot(
        name: if name.len > 0: name else: "leapfrog",
        frameWidth: ViewportWidth,
        frameHeight: ViewportHeight
      )
      echo bot.name, " connecting to ", endpoint.redactedUrl()
      flushFile(stdout)
      let ws = newWebSocket(endpoint)
      connected = true
      echo bot.name, " connected"
      flushFile(stdout)
      var lastMask = 0xff'u8
      while true:
        if not ws.receiveUpdates(bot):
          continue
        let nextMask = bot.decideMask()
        bot.lastMask = nextMask
        if nextMask != lastMask:
          ws.send(blobFromMask(nextMask), BinaryMessage)
          lastMask = nextMask
        if maxSteps > 0 and bot.frameTick >= maxSteps:
          ws.close()
          return
    except CatchableError as e:
      if connected:
        echo name, " disconnected: ", e.msg
        flushFile(stdout)
        if exitOnDisconnect:
          return
        connected = false
      else:
        echo name, " reconnecting: ", e.msg
        flushFile(stdout)
      sleep(ReconnectDelayMs)

when isMainModule:
  var
    address = DefaultAddress
    port = DefaultPort
    url = getEnv(EngineWsEnv)
    name = if getEnv(EngineWsEnv).len > 0: "" else: "leapfrog"
    token = ""
    slot = -1
    maxSteps = 0
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
      of "name":
        name = val
      of "token":
        token = val
      of "slot":
        slot = parseInt(val)
      of "max-steps":
        maxSteps = parseInt(val)
      else:
        discard
    else:
      discard
  runBot(address, port, url, name, token, slot, maxSteps, url.len > 0)
