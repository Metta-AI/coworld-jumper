import
  std/[algorithm, json, locks, monotimes, os, random, strutils,
    tables, times],
  curly, flatty, jsony, mummy, pixie,
  bitworld/aseprite, bitworld/client, bitworld/runtime, bitworld/tiled,
  bitworld/pixelfonts, bitworld/spriteprotocol, bitworld/server,
  bitworld/sprites,
  jumper/replays

const
  DefaultSeed = 0xB1770
  DefaultMaxTicks = 0
  DefaultMaxGames = 0
  UnassignedPlayerIndex = 0x7fffffff
  SheetTileSize = 32
  SheetColumns = 8
  WorldTileSize = 32
  PlayerSpriteSize = 32
  PlayerBoxWidth = 20
  PlayerBoxHeight = 23
  PlayerSpriteOffsetX = (PlayerSpriteSize - PlayerBoxWidth) div 2
  PlayerSpriteOffsetY = PlayerSpriteSize - PlayerBoxHeight
  PlayerFrameCount = 4
  PlayerDirectionCount = 2
  PlayerSpritesPerColor = PlayerFrameCount * PlayerDirectionCount
  LevelWidthTiles = 64
  LevelHeightTiles = 16
  LevelWidthPixels = LevelWidthTiles * WorldTileSize
  LevelHeightPixels = LevelHeightTiles * WorldTileSize
  ViewportWidth = 320
  ViewportHeight = 200
  MotionScale = 256
  AccelX = 171
  FrictionNum = 200
  FrictionDen = 256
  MaxSpeedX = 1707
  StopThreshold = 43
  Gravity = 256
  JumpVel = -3594
  MaxFallSpeed = 5333
  TargetFps = 24.0
  HealthzPath = "/healthz"
  WebSocketPath = "/player"
  GlobalWebSocketPath = "/global"
  AdminWebSocketPath = "/admin"
  ReplayWebSocketPath = "/replay"
  SkyColor = 14'u8
  PlayerColors = [3'u8, 7, 8, 14, 4, 11, 13, 15]
  DeathY = LevelHeightPixels + WorldTileSize * 2
  SpawnWidthTiles = 9
  SpawnAirTiles = 4
  TiledLayerName = "Tile Layer 1"
  FlagGid = 15
  SeesawGid = 54
  SignGid = 60
  MapLayerId = 0
  MapLayerKind = 0
  MapLayerFlags = 1
  TopLeftLayerId = 1
  TopLeftLayerKind = 1
  TopLeftLayerFlags = 2
  TopLeftViewportWidth = 128
  TopLeftViewportHeight = 128
  SkySpriteId = 1
  PlayerSpriteBase = 100
  RadarSpriteBase = 200
  TiledSpriteBase = 300
  SkyObjectId = 1
  TileObjectBase = 1000
  PlayerObjectBase = 5000
  RadarObjectBase = 6000
  HudObjectBase = 7000
  HudSpriteBase = 7000
  TextObjectBase = 7100
  TextSpriteBase = 7100
  ScorePanelDigitSpriteBase = 7200
  ScorePanelChipSpriteBase = 7300
  ScorePanelNameSpriteBase = 7600
  ChatSpriteBase = 9000
  ChatObjectBase = 9000
  NameSpriteBase = 10000
  NameObjectBase = 10000
  DebugPlayerBoxSpriteId = 900
  DebugPlayerBoxObjectBase = 8000
  DebugPlayerBounds = false
  OverlapResolvePasses = 4
  ChatMaxChars = 24
  NameMaxChars = 14
  ChatPad = 3
  ChatPointerHeight = 3
  ChatGapY = 4
  NamePadX = 2
  NamePadY = 1
  NameGapY = 2
  TextBackR = 0x33'u8
  TextBackG = 0x31'u8
  TextBackB = 0x36'u8
  ScorePanelChipObjectBase = 11000
  ScorePanelDigitObjectBase = 12000
  ScorePanelNameObjectBase = 20000
  ScorePanelChipSize = 3
  ScorePanelChipGapX = 2
  ScorePanelNameGapX = 2
  ScorePanelMaxScoreChars = 16
  ChatLifetimeTicks* = 5 * 24
  ScorePanelSelectedR = 255'u8
  ScorePanelSelectedG = 226'u8
  ScorePanelSelectedB = 92'u8
  ReplayCenterBottomLayerId = 8
  ReplayCenterBottomLayerKind = 8
  ReplayBottomLeftLayerId = 9
  ReplayBottomLeftLayerKind = 4
  UiLayerFlags = 2
  ReplayPanelHeight = 20
  ReplayScrubberSpriteId = 4004
  ReplayScrubberObjectId = 4004
  ReplayScrubberWidth = 84
  ReplayScrubberHeight = 5
  ReplayScrubberTrackY = 2
  ReplayScrubberY = 8
  ReplayControlsSpriteId = 4005
  ReplayControlsObjectId = 4005
  TransportIconSize = 6
  TransportIconHeight = 6
  TransportIconCount = 5
  TransportButtonGap = 2
  TransportButtonStride = TransportIconSize + TransportButtonGap
  TransportSpeedX = 0
  TransportSpeedY = 8
  TransportWidth = 108
  TransportHeight = 18
  TransportSpeedGap = 16
  TransportX = 2
  TransportY = 1

type
  HsvColor = object
    h, s, v: float

  Rect = object
    x, y, w, h: int

  Actor* = object
    x, y: int
    velX, velY: int
    carryX, carryY: int
    onGround: bool
    score*: int
    slot*: int
    dead: bool
    respawnTimer: int
    facingRight: bool
    color: uint8
    name*: string
    message*: string
    messageTicks*: int

  ScorePanelPlayer = object
    index: int
    score: int
    color: uint8
    name: string

  SpriteCacheEntry = object
    spriteId: int
    width: int
    height: int
    pixels: seq[uint8]

  TileKind = enum
    TileAir
    TileDecoration
    TileGround
    TileWall
    TileGoal

  PlayerFrame = enum
    PlayerStand
    PlayerWalkA
    PlayerWalkB
    PlayerJump

  SimServer* = object
    players*: seq[Actor]
    tiles: seq[TileKind]
    tileGids: seq[int]
    tileSprites: Table[int, RgbaSprite]
    playerFrames: array[PlayerFrame, RgbaSprite]
    textFont: PixelFont
    rng: Rand
    tickCount*: int
    nextColorIndex: int

  PlayerViewerState = object
    initialized: bool
    selectedPlayerIndex: int
    mouseX, mouseY, mouseLayer: int
    mouseDown, clickPending: bool
    povInitialized: bool
    spriteCache: seq[SpriteCacheEntry]
    povSpriteCache: seq[SpriteCacheEntry]

  WebSocketAppState = object
    lock: Lock
    inputMasks: Table[WebSocket, uint8]
    lastAppliedMasks: Table[WebSocket, uint8]
    playerIndices: Table[WebSocket, int]
    playerViewers: Table[WebSocket, PlayerViewerState]
    globalViewers: Table[WebSocket, PlayerViewerState]
    replayViewers: Table[WebSocket, PlayerViewerState]
    playerNames: Table[WebSocket, string]
    playerSlots: Table[WebSocket, int]
    chatMessages: Table[WebSocket, string]
    closedSockets: seq[WebSocket]
    tokens: seq[string]
    replayServerMode: bool
    replayLoaded: bool
    pendingReplayUri: string
    replayMaxTick: int
    replayCommands: seq[char]
    replaySeekTicks: seq[int]
    viewerMice: Table[WebSocket, tuple[x, y, layer: int]]
    scrubbingViewers: Table[WebSocket, bool]

  SimSnapshot = object
    tickCount: int
    nextColorIndex: int
    rng: Rand
    players: seq[Actor]

  ServerThreadArgs = object
    server: ptr Server
    address: string
    port: int

  RunConfig = object
    address: string
    port: int
    seed: int
    maxTicks: int
    maxGames: int
    tokens: seq[string]

proc dataDir(): string =
  getCurrentDir() / "data"

proc clientDataDir(): string =
  clientDir() / "data"

proc sheetPath(): string =
  dataDir() / "spritesheet.aseprite"

proc tiledProjectPath(): string =
  dataDir() / "forest.tiled-project"

proc tiledSessionPath(): string =
  dataDir() / "forest.tiled-session"

proc tiledMapPath(): string =
  dataDir() / "forest.tmx"

proc loadClientPalette() =
  loadPalette(clientDataDir() / "pallete.png")

proc loadTiny5Font(): PixelFont =
  ## Loads the shared Tiny5 variable-width pixel font.
  readTiny5Font()

proc rgbaColor(color: uint8): ColorRGBA =
  ## Converts one palette index to an RGBA color.
  if color == TransparentColorIndex:
    return ColorRGBA(r: 0, g: 0, b: 0, a: 0)
  Palette[int(color)]

proc sheetRgbaSprite(sheet: Image, cellX, cellY: int): RgbaSprite =
  ## Slices one 32 pixel cell from the sprite sheet as RGBA.
  sheet.cellRgbaSprite(cellX, cellY, SheetTileSize)

proc sheetGidSprite(sheet: Image, gid: int): RgbaSprite =
  ## Slices one Tiled gid cell from the sprite sheet as RGBA.
  if gid <= 0:
    raise newException(TiledError, "Tiled gid must be positive: " & $gid)
  let
    index = gid - 1
    cellX = index mod SheetColumns
    cellY = index div SheetColumns
  if (cellX + 1) * SheetTileSize > sheet.width or
      (cellY + 1) * SheetTileSize > sheet.height:
    raise newException(
      TiledError,
      "Tiled gid " & $gid & " is outside the sprite sheet"
    )
  sheet.sheetRgbaSprite(cellX, cellY)

proc rgbToHsv(color: ColorRGBA): HsvColor =
  ## Converts one RGBA color to HSV while ignoring alpha.
  let
    r = color.r.float / 255.0
    g = color.g.float / 255.0
    b = color.b.float / 255.0
    maxValue = max(r, max(g, b))
    minValue = min(r, min(g, b))
    delta = maxValue - minValue
  result.v = maxValue
  if maxValue <= 0.0:
    result.s = 0.0
  else:
    result.s = delta / maxValue

  if delta <= 0.0:
    result.h = 0.0
  elif maxValue == r:
    result.h = (g - b) / delta
    if result.h < 0.0:
      result.h += 6.0
    result.h /= 6.0
  elif maxValue == g:
    result.h = ((b - r) / delta + 2.0) / 6.0
  else:
    result.h = ((r - g) / delta + 4.0) / 6.0

proc toColor(hsv: HsvColor, alpha: uint8): ColorRGBA =
  ## Converts HSV plus alpha to an RGBA color.
  if hsv.s <= 0.0:
    let gray = uint8(clamp(int(hsv.v * 255.0 + 0.5), 0, 255))
    return rgba(gray, gray, gray, alpha)

  var h = hsv.h
  while h < 0.0:
    h += 1.0
  while h >= 1.0:
    h -= 1.0
  let
    scaled = h * 6.0
    sector = min(5, int(scaled))
    f = scaled - sector.float
    p = hsv.v * (1.0 - hsv.s)
    q = hsv.v * (1.0 - hsv.s * f)
    t = hsv.v * (1.0 - hsv.s * (1.0 - f))

  proc channel(value: float): uint8 =
    uint8(clamp(int(value * 255.0 + 0.5), 0, 255))

  case sector
  of 0:
    rgba(channel(hsv.v), channel(t), channel(p), alpha)
  of 1:
    rgba(channel(q), channel(hsv.v), channel(p), alpha)
  of 2:
    rgba(channel(p), channel(hsv.v), channel(t), alpha)
  of 3:
    rgba(channel(p), channel(q), channel(hsv.v), alpha)
  of 4:
    rgba(channel(t), channel(p), channel(hsv.v), alpha)
  else:
    rgba(channel(hsv.v), channel(p), channel(q), alpha)

proc isProtectedPlayerPixel(color: ColorRGBA): bool =
  ## Returns true for player colors that must keep their source hue.
  color.r == 0xee'u8 and
    color.g == 0xb8'u8 and
    color.b == 0x85'u8

proc isPlayerTintPixel(color: ColorRGBA): bool =
  ## Returns true for red player pixels that should be hue shifted.
  if color.a == 0 or color.isProtectedPlayerPixel():
    return false

  let hsv = color.rgbToHsv()
  hsv.s >= 0.35 and
    hsv.v >= 0.25 and
    (hsv.h <= 0.04 or hsv.h >= 0.94)

proc tintPlayerPixel(color: ColorRGBA, targetHue: float): ColorRGBA =
  ## Hue shifts one saturated red player pixel.
  if not color.isPlayerTintPixel():
    return color
  var hsv = color.rgbToHsv()
  hsv.h = targetHue
  hsv.toColor(color.a)

proc tintPlayerSprite(
  sprite: RgbaSprite,
  color: uint8,
  flipX: bool
): RgbaSprite =
  ## HSV-tints and optionally flips one player frame.
  result = newRgbaSprite(sprite.width, sprite.height)
  let targetHue = rgbaColor(color).rgbToHsv().h
  for y in 0 ..< sprite.height:
    for x in 0 ..< sprite.width:
      let
        dx =
          if flipX:
            sprite.width - 1 - x
          else:
            x
        source = sprite.rgbaPixel(x, y)
      result.putRgbaPixel(dx, y, source.tintPlayerPixel(targetHue))

proc solidRgbaSprite(width, height: int, color: uint8): RgbaSprite =
  ## Builds one solid RGBA sprite from a palette index.
  solidRgbaSprite(width, height, rgbaColor(color))

proc chatCharSupported(ch: char): bool =
  ## Returns true when Jumper can draw one chat character.
  ch >= ' ' and ch <= '~'

proc cleanDisplayText(text: string, maxChars: int): string =
  ## Normalizes one printable Tiny5 text field.
  for ch in text.strip():
    if result.len >= maxChars:
      return
    if ch.chatCharSupported():
      result.add(ch)

proc cleanChatMessage(message: string): string =
  ## Normalizes one submitted player chat message.
  cleanDisplayText(message, ChatMaxChars)

proc cleanPlayerName(name: string): string =
  ## Normalizes one submitted player display name.
  cleanDisplayText(name, NameMaxChars)

proc chatTextWidth(sim: SimServer, text: string): int =
  ## Returns the rendered width of one chat line.
  sim.textFont.textWidth(text)

proc blitChatGlyph(
  target: var RgbaSprite,
  glyph: PixelGlyph,
  x, y: int,
  color: ColorRGBA
) =
  ## Blits one Tiny5 glyph into a chat bubble.
  for gy in 0 ..< glyph.height:
    for gx in 0 ..< glyph.width:
      if glyph.glyphPixel(gx, gy):
        target.putRgbaPixel(x + gx, y + gy, color)

proc blitTinyText(
  sim: SimServer,
  target: var RgbaSprite,
  text: string,
  x, y: int,
  color: ColorRGBA
) =
  ## Blits one Tiny5 text line into a sprite.
  var dx = x
  for ch in text:
    let glyph = sim.textFont.glyphAt(ch)
    target.blitChatGlyph(glyph, dx, y, color)
    dx += sim.textFont.glyphAdvance(ch)

proc blitChatText(
  sim: SimServer,
  target: var RgbaSprite,
  text: string,
  x, y: int,
  alpha: uint8
) =
  ## Blits one chat line into a chat bubble.
  sim.blitTinyText(target, text, x, y, rgba(255, 255, 255, alpha))

proc speechBubbleSprite(
  sim: SimServer,
  text: string
): RgbaSprite =
  ## Builds one speech bubble sprite for a player message.
  let
    textWidth = max(6, sim.chatTextWidth(text))
    lineHeight = sim.textFont.height
    bodyWidth = textWidth + ChatPad * 2
    bodyHeight = lineHeight + ChatPad * 2
    fill = rgba(TextBackR, TextBackG, TextBackB, 255)
    border = rgba(TextBackR, TextBackG, TextBackB, 255)
  result = newRgbaSprite(bodyWidth, bodyHeight + ChatPointerHeight)
  for y in 0 ..< bodyHeight:
    for x in 0 ..< bodyWidth:
      result.putRgbaPixel(x, y, fill)
  for x in 0 ..< bodyWidth:
    result.putRgbaPixel(x, 0, border)
    result.putRgbaPixel(x, bodyHeight - 1, border)
  for y in 0 ..< bodyHeight:
    result.putRgbaPixel(0, y, border)
    result.putRgbaPixel(bodyWidth - 1, y, border)
  let pointerX = bodyWidth div 2
  for y in 0 ..< ChatPointerHeight:
    let span = ChatPointerHeight - y - 1
    for x in pointerX - span .. pointerX + span:
      result.putRgbaPixel(x, bodyHeight + y, border)
  sim.blitChatText(result, text, ChatPad, ChatPad, 255)

proc addRgbaSprite(
  packet: var seq[uint8],
  spriteId: int,
  sprite: RgbaSprite,
  label: string
) =
  ## Appends one RGBA sprite definition.
  packet.addSprite(spriteId, sprite.width, sprite.height, sprite.pixels, label)

proc addRgbaSpriteCached(
  packet: var seq[uint8],
  cache: var seq[SpriteCacheEntry],
  spriteId: int,
  sprite: RgbaSprite,
  label: string
) =
  ## Appends one RGBA sprite only when its pixels changed.
  for item in cache.mitems:
    if item.spriteId != spriteId:
      continue
    let unchanged =
      item.width == sprite.width and
      item.height == sprite.height and
      item.pixels == sprite.pixels
    if unchanged:
      return
    packet.addRgbaSprite(spriteId, sprite, label)
    item.width = sprite.width
    item.height = sprite.height
    item.pixels = sprite.pixels
    return
  packet.addRgbaSprite(spriteId, sprite, label)
  cache.add(SpriteCacheEntry(
    spriteId: spriteId,
    width: sprite.width,
    height: sprite.height,
    pixels: sprite.pixels
  ))

proc tileIndex(tx, ty: int): int =
  ty * LevelWidthTiles + tx

proc inBounds(tx, ty: int): bool =
  tx >= 0 and ty >= 0 and tx < LevelWidthTiles and ty < LevelHeightTiles

proc getTile(sim: SimServer, tx, ty: int): TileKind =
  if not inBounds(tx, ty):
    return TileAir
  sim.tiles[tileIndex(tx, ty)]

proc isSolid(kind: TileKind): bool =
  kind == TileGround or kind == TileWall

proc isPassThroughGid(gid: int): bool =
  ## Returns true when a rendered tile should not collide.
  case gid
  of SignGid, SeesawGid:
    true
  else:
    false

proc worldClampPixel(x, maxValue: int): int =
  x.clamp(0, maxValue)

proc rectsOverlap(ax, ay, aw, ah, bx, by, bw, bh: int): bool =
  ax < bx + bw and
  ax + aw > bx and
  ay < by + bh and
  ay + ah > by

proc collidesWithTiles(sim: SimServer, x, y, w, h: int): bool =
  let
    startTx = x div WorldTileSize
    startTy = y div WorldTileSize
    endTx = (x + w - 1) div WorldTileSize
    endTy = (y + h - 1) div WorldTileSize
  for ty in startTy .. endTy:
    for tx in startTx .. endTx:
      if sim.getTile(tx, ty).isSolid:
        return true
  false

proc tileKindForGid(gid: int): TileKind =
  ## Returns the Jumper tile kind for one Tiled gid.
  case gid
  of 0:
    TileAir
  of FlagGid:
    TileGoal
  else:
    if gid.isPassThroughGid():
      TileDecoration
    else:
      TileGround

proc buildLevel(sim: var SimServer) =
  ## Loads the Jumper level from the Tiled forest map.
  let
    workspace = loadTiledWorkspace(
      tiledProjectPath(),
      tiledSessionPath(),
      tiledMapPath()
    )
    map = workspace.map
    layer = map.layerByName(TiledLayerName)

  if map.width != LevelWidthTiles or map.height != LevelHeightTiles:
    raise newException(
      TiledError,
      "Forest map size must be " & $LevelWidthTiles & "x" &
        $LevelHeightTiles & ", got " & $map.width & "x" & $map.height
    )
  if map.tileWidth != WorldTileSize or map.tileHeight != WorldTileSize:
    raise newException(
      TiledError,
      "Forest map tile size must be " & $WorldTileSize & "x" &
        $WorldTileSize
    )

  sim.tiles = newSeq[TileKind](LevelWidthTiles * LevelHeightTiles)
  sim.tileGids = newSeq[int](sim.tiles.len)
  for ty in 0 ..< LevelHeightTiles:
    for tx in 0 ..< LevelWidthTiles:
      let
        index = tileIndex(tx, ty)
        gid = layer.gidAt(tx, ty)
      sim.tiles[index] = gid.tileKindForGid()
      sim.tileGids[index] = gid

proc loadTileSprites(sim: var SimServer, sheet: Image) =
  ## Loads each Tiled gid sprite used by the map.
  sim.tileSprites = initTable[int, RgbaSprite]()
  for gid in sim.tileGids:
    if gid == 0 or gid in sim.tileSprites:
      continue
    sim.tileSprites[gid] = sheet.sheetGidSprite(gid)

proc colorSlot(color: uint8): int =
  ## Returns the compact sprite slot for one player color.
  for i in 0 ..< PlayerColors.len:
    if PlayerColors[i] == color:
      return i
  0

proc playerSpriteId(
  color: uint8,
  facingRight: bool,
  frame: PlayerFrame
): int =
  ## Returns the sprite id for one colored player animation frame.
  let directionOffset =
    if facingRight:
      PlayerFrameCount
    else:
      0
  PlayerSpriteBase +
    color.colorSlot() * PlayerSpritesPerColor +
    directionOffset +
    ord(frame)

proc radarSpriteId(color: uint8): int =
  ## Returns the radar dot sprite id for one player color.
  RadarSpriteBase + color.colorSlot()

proc tileSpriteId(gid: int): int =
  ## Returns the sprite id for one Tiled gid.
  TiledSpriteBase + gid

proc playerCollisionBounds(sim: SimServer, player: Actor): Rect =
  ## Returns the fixed player collision box.
  Rect(x: 0, y: 0, w: PlayerBoxWidth, h: PlayerBoxHeight)

proc playerCollisionRectAt(
  sim: SimServer,
  player: Actor,
  x, y: int
): Rect =
  ## Returns the world collision rectangle for one player position.
  let bounds = sim.playerCollisionBounds(player)
  Rect(
    x: x + bounds.x,
    y: y + bounds.y,
    w: bounds.w,
    h: bounds.h
  )

proc playerCollisionRect(sim: SimServer, player: Actor): Rect =
  ## Returns the current world collision rectangle for one player.
  sim.playerCollisionRectAt(player, player.x, player.y)

proc playerCenterX(sim: SimServer, player: Actor): int =
  ## Returns the center x coordinate of the visible player body.
  let rect = sim.playerCollisionRect(player)
  rect.x + rect.w div 2

proc playerCenterY(sim: SimServer, player: Actor): int =
  ## Returns the center y coordinate of the visible player body.
  let rect = sim.playerCollisionRect(player)
  rect.y + rect.h div 2

proc playersOverlapAt(
  sim: SimServer,
  a: Actor,
  ax, ay: int,
  b: Actor,
  bx, by: int
): bool =
  ## Returns true when two player collision boxes overlap.
  let
    ar = sim.playerCollisionRectAt(a, ax, ay)
    br = sim.playerCollisionRectAt(b, bx, by)
  rectsOverlap(ar.x, ar.y, ar.w, ar.h, br.x, br.y, br.w, br.h)

proc randomSpawn(sim: var SimServer): tuple[x, y: int] =
  ## Returns a random spawn in the first tiles, above the ground.
  let
    widthPixels = SpawnWidthTiles * WorldTileSize
    maxBodyX = max(0, widthPixels - PlayerBoxWidth)
    bodyX = sim.rng.rand(maxBodyX)
    bodyY = SpawnAirTiles * WorldTileSize
  (bodyX, bodyY)

proc resolveOverlaps(sim: var SimServer) =
  for _ in 0 ..< OverlapResolvePasses:
    var moved = false
    for i in 0 ..< sim.players.len:
      if sim.players[i].dead:
        continue
      for j in i + 1 ..< sim.players.len:
        if sim.players[j].dead:
          continue
        if sim.playersOverlapAt(
          sim.players[i],
          sim.players[i].x,
          sim.players[i].y,
          sim.players[j],
          sim.players[j].x,
          sim.players[j].y
        ):
          let
            ri = sim.playerCollisionRect(sim.players[i])
            rj = sim.playerCollisionRect(sim.players[j])
          if ri.y <= rj.y:
            sim.players[i].y += rj.y - ri.y - ri.h
            sim.players[i].carryY = 0
            sim.players[i].velY = 0
          else:
            sim.players[j].y += ri.y - rj.y - rj.h
            sim.players[j].carryY = 0
            sim.players[j].velY = 0
          moved = true
    if not moved:
      break

proc freeSlot(sim: SimServer, requestedSlot: int): int =
  ## Returns the requested seat slot or the first unoccupied one.
  var used: seq[int] = @[]
  for player in sim.players:
    used.add(player.slot)
  if requestedSlot >= 0 and requestedSlot notin used:
    return requestedSlot
  result = 0
  while result in used:
    inc result

proc addPlayer*(sim: var SimServer, name: string, requestedSlot = -1): int =
  ## Adds one player at a random spawn point.
  let
    spawn = sim.randomSpawn()
    color = PlayerColors[sim.nextColorIndex mod PlayerColors.len]
    requestedName = name.cleanPlayerName()
    cleanName =
      if requestedName.len > 0:
        requestedName
      else:
        "player " & $(sim.players.len + 1)
  inc sim.nextColorIndex
  sim.players.add Actor(
    x: spawn.x,
    y: spawn.y,
    facingRight: true,
    color: color,
    name: cleanName,
    slot: sim.freeSlot(requestedSlot),
  )
  result = sim.players.high
  sim.resolveOverlaps()

proc resultsJson*(sim: SimServer, seatCount: int): string =
  ## Returns end-of-game per-seat player results as JSON.
  var seats = seatCount
  for player in sim.players:
    seats = max(seats, player.slot + 1)
  var
    names = newJArray()
    scores = newJArray()
  for slot in 0 ..< seats:
    var seated = false
    for player in sim.players:
      if player.slot == slot:
        names.add(%player.name)
        scores.add(%player.score)
        seated = true
        break
    if not seated:
      names.add(%"")
      scores.add(%0)
  var results = newJObject()
  results["names"] = names
  results["scores"] = scores
  $results

proc respawnPlayer(sim: var SimServer, i: int) =
  let spawn = sim.randomSpawn()
  sim.players[i].x = spawn.x
  sim.players[i].y = spawn.y
  sim.players[i].velX = 0
  sim.players[i].velY = 0
  sim.players[i].carryX = 0
  sim.players[i].carryY = 0
  sim.players[i].onGround = false
  sim.players[i].dead = false
  sim.players[i].respawnTimer = 0
  sim.players[i].message = ""
  sim.players[i].messageTicks = 0
  sim.resolveOverlaps()

proc initSimServer*(seed = DefaultSeed): SimServer =
  result.rng = initRand(seed)
  loadClientPalette()
  let sheet = readAsepriteImage(sheetPath())
  result.playerFrames[PlayerStand] = sheet.sheetRgbaSprite(0, 0)
  result.playerFrames[PlayerWalkA] = sheet.sheetRgbaSprite(1, 0)
  result.playerFrames[PlayerWalkB] = sheet.sheetRgbaSprite(2, 0)
  result.playerFrames[PlayerJump] = sheet.sheetRgbaSprite(3, 0)
  result.textFont = loadTiny5Font()
  result.players = @[]
  result.buildLevel()
  result.loadTileSprites(sheet)

proc addSpriteProtocolInit(
  packet: var seq[uint8],
  sim: SimServer,
  viewportWidth = ViewportWidth,
  viewportHeight = ViewportHeight
) =
  ## Appends the static sprite protocol setup for one sprite viewer.
  packet.addLayer(MapLayerId, MapLayerKind, MapLayerFlags)
  packet.addViewport(MapLayerId, viewportWidth, viewportHeight)
  packet.addLayer(TopLeftLayerId, TopLeftLayerKind, TopLeftLayerFlags)
  packet.addViewport(
    TopLeftLayerId,
    TopLeftViewportWidth,
    TopLeftViewportHeight
  )
  packet.addRgbaSprite(
    SkySpriteId,
    solidRgbaSprite(viewportWidth, viewportHeight, SkyColor),
    "sky"
  )
  when DebugPlayerBounds:
    packet.addRgbaSprite(
      DebugPlayerBoxSpriteId,
      outlineRgbaSprite(
        PlayerBoxWidth,
        PlayerBoxHeight,
        rgba(255, 255, 255, 255)
      ),
      "debug player box"
    )
  var emittedTileSprites = initTable[int, bool]()
  for gid in sim.tileGids:
    if gid == 0 or gid in emittedTileSprites:
      continue
    packet.addRgbaSprite(
      gid.tileSpriteId(),
      sim.tileSprites[gid],
      "tile " & $gid
    )
    emittedTileSprites[gid] = true

  for i in 0 ..< PlayerColors.len:
    let color = PlayerColors[i]
    for frame in PlayerFrame:
      packet.addRgbaSprite(
        playerSpriteId(color, false, frame),
        sim.playerFrames[frame].tintPlayerSprite(color, true),
        "player " & $i & " left " & $frame
      )
      packet.addRgbaSprite(
        playerSpriteId(color, true, frame),
        sim.playerFrames[frame].tintPlayerSprite(color, false),
        "player " & $i & " right " & $frame
      )
    packet.addRgbaSprite(
      RadarSpriteBase + i,
      solidRgbaSprite(1, 1, color),
      "radar " & $i
    )

proc tiny5Sprite(
  sim: SimServer,
  text: string,
  color: ColorRGBA
): RgbaSprite =
  ## Builds one transparent Tiny5 text sprite.
  result = newRgbaSprite(
    max(1, sim.textFont.textWidth(text)),
    sim.textFont.height
  )
  var x = 0
  for ch in text:
    let glyph = sim.textFont.glyphAt(ch)
    result.blitChatGlyph(glyph, x, 0, color)
    x += sim.textFont.glyphAdvance(ch)

proc nameTagSprite(sim: SimServer, text: string): RgbaSprite =
  ## Builds one compact player name tag sprite.
  let
    width = max(1, sim.textFont.textWidth(text) + NamePadX * 2)
    height = sim.textFont.height + NamePadY * 2
  result = newRgbaSprite(width, height)
  for y in 0 ..< height:
    for x in 0 ..< width:
      result.putRgbaPixel(x, y, rgba(TextBackR, TextBackG, TextBackB, 255))
  sim.blitChatText(result, text, NamePadX, NamePadY, 255)

proc scorePanelPlayers(sim: SimServer): seq[ScorePanelPlayer] =
  ## Returns the players to display in the global score panel.
  for i, player in sim.players:
    result.add(ScorePanelPlayer(
      index: i,
      score: player.score,
      color: player.color,
      name: player.name
    ))

proc compareScorePanelPlayers(a, b: ScorePanelPlayer): int =
  ## Sorts score panel players by descending score.
  result = cmp(b.score, a.score)
  if result == 0:
    result = cmp(a.index, b.index)

proc scorePanelScoreText(score: int): string =
  ## Returns one non-negative score panel text value.
  result = $max(0, score)
  if result.len > ScorePanelMaxScoreChars:
    result = result[0 ..< ScorePanelMaxScoreChars]

proc scorePanelScoreWidth(
  sim: SimServer,
  players: openArray[ScorePanelPlayer]
): int =
  ## Returns the widest score label for one score panel.
  for player in players:
    let scoreText = scorePanelScoreText(player.score)
    result = max(result, sim.textFont.textWidth(scoreText))

proc scorePanelDigitSpriteId(ch: char): int =
  ## Returns the sprite id for one score panel digit.
  ScorePanelDigitSpriteBase + ord(ch) - ord('0')

proc scorePanelChipSpriteId(playerIndex: int): int =
  ## Returns the score panel chip sprite id for one player.
  ScorePanelChipSpriteBase + playerIndex

proc scorePanelNameSpriteId(playerIndex: int): int =
  ## Returns the score panel name sprite id for one player.
  ScorePanelNameSpriteBase + playerIndex

proc scorePanelChipObjectId(playerIndex: int): int =
  ## Returns the score panel chip object id for one player.
  ScorePanelChipObjectBase + playerIndex

proc scorePanelDigitObjectId(playerIndex, digitIndex: int): int =
  ## Returns the score panel digit object id for one player digit.
  ScorePanelDigitObjectBase +
    playerIndex * ScorePanelMaxScoreChars + digitIndex

proc scorePanelNameObjectId(playerIndex: int): int =
  ## Returns the score panel name object id for one player.
  ScorePanelNameObjectBase + playerIndex

proc scorePanelDigitSprite(sim: SimServer, ch: char): RgbaSprite =
  ## Builds one white score panel digit sprite.
  sim.tiny5Sprite($ch, rgba(255, 255, 255, 255))

proc scorePanelChipSprite(color: uint8): RgbaSprite =
  ## Builds one solid score panel color chip.
  result = newRgbaSprite(ScorePanelChipSize, ScorePanelChipSize)
  result.fillRect(
    0,
    0,
    ScorePanelChipSize,
    ScorePanelChipSize,
    rgbaColor(color)
  )

proc scorePanelNameSprite(
  sim: SimServer,
  player: ScorePanelPlayer,
  selected: bool
): RgbaSprite =
  ## Builds one score panel player name sprite.
  let color =
    if selected:
      rgba(
        ScorePanelSelectedR,
        ScorePanelSelectedG,
        ScorePanelSelectedB,
        255
      )
    else:
      rgbaColor(player.color)
  sim.tiny5Sprite(player.name, color)

proc addScorePanelDigitSprites(
  packet: var seq[uint8],
  sim: SimServer,
  cache: var seq[SpriteCacheEntry]
) =
  ## Adds stable score panel digit sprites when pixels changed.
  for ch in '0' .. '9':
    packet.addRgbaSpriteCached(
      cache,
      scorePanelDigitSpriteId(ch),
      sim.scorePanelDigitSprite(ch),
      "score digit " & $ch
    )

proc addScorePanelPlayerSprites(
  packet: var seq[uint8],
  sim: SimServer,
  cache: var seq[SpriteCacheEntry],
  player: ScorePanelPlayer,
  selectedIndex: int
) =
  ## Adds one player's score panel sprites when pixels changed.
  let
    chip = scorePanelChipSprite(player.color)
    selected = player.index == selectedIndex
    name = sim.scorePanelNameSprite(player, selected)
  packet.addRgbaSpriteCached(
    cache,
    scorePanelChipSpriteId(player.index),
    chip,
    "score chip " & $player.index
  )
  packet.addRgbaSpriteCached(
    cache,
    scorePanelNameSpriteId(player.index),
    name,
    "score name " & player.name
  )

proc selectedGlobalPlayerIndex(state: PlayerViewerState, sim: SimServer): int =
  ## Returns the selected global player index clamped to connected players.
  if sim.players.len == 0:
    return -1
  result = state.selectedPlayerIndex
  if result < 0 or result >= sim.players.len:
    return -1

proc toggleSelectedPlayer(state: var PlayerViewerState, playerIndex: int) =
  ## Selects or clears the current global point-of-view player.
  let previous = state.selectedPlayerIndex
  if playerIndex >= 0:
    state.selectedPlayerIndex =
      if state.selectedPlayerIndex == playerIndex:
        -1
      else:
        playerIndex
  if state.selectedPlayerIndex != previous:
    state.povInitialized = false
    state.povSpriteCache.setLen(0)

proc scorePanelPlayerAt(
  sim: SimServer,
  layer,
  mouseX,
  mouseY: int
): int =
  ## Returns the score-panel player index at one mouse point.
  if layer != TopLeftLayerId or sim.players.len == 0:
    return -1
  var players = sim.scorePanelPlayers()
  players.sort(compareScorePanelPlayers)
  let
    rowHeight = max(sim.textFont.lineHeight(), ScorePanelChipSize)
    scoreColumnWidth = sim.scorePanelScoreWidth(players)
    scoreXBase = ScorePanelChipSize + ScorePanelChipGapX
    nameX = scoreXBase + scoreColumnWidth + ScorePanelNameGapX
    row = mouseY div rowHeight
  if mouseY < 0 or row < 0 or row >= players.len:
    return -1
  if mouseX < nameX or mouseX >= TopLeftViewportWidth:
    return -1
  players[row].index

proc addTiny5Object(
  packet: var seq[uint8],
  sim: SimServer,
  text: string,
  objectId,
  spriteId,
  x,
  y,
  z: int
) =
  ## Appends one Tiny5 text sprite and object.
  let sprite = sim.tiny5Sprite(text, rgba(255, 255, 255, 255))
  packet.addRgbaSprite(spriteId, sprite, text)
  packet.addObject(objectId, x, y, z, MapLayerId, spriteId)

proc addNameTag(
  packet: var seq[uint8],
  sim: SimServer,
  cache: var seq[SpriteCacheEntry],
  player: Actor,
  playerIndex,
  screenX,
  screenY,
  z: int
): int =
  ## Appends a player name tag and returns its top y coordinate.
  let
    tag = sim.nameTagSprite(player.name)
    x = screenX + PlayerBoxWidth div 2 - tag.width div 2
    y = screenY - PlayerSpriteOffsetY - tag.height - NameGapY
    spriteId = NameSpriteBase + playerIndex
  packet.addRgbaSpriteCached(cache, spriteId, tag, "name " & player.name)
  packet.addObject(
    NameObjectBase + playerIndex,
    x,
    y,
    z,
    MapLayerId,
    spriteId
  )
  y

proc addSpeechBubble(
  packet: var seq[uint8],
  sim: SimServer,
  cache: var seq[SpriteCacheEntry],
  player: Actor,
  playerIndex,
  screenX,
  anchorY,
  z: int
) =
  ## Appends a speech bubble object above one player name.
  if player.message.len == 0 or player.messageTicks <= 0:
    return
  let
    bubble = sim.speechBubbleSprite(player.message)
    x = screenX + PlayerBoxWidth div 2 - bubble.width div 2
    y = anchorY - bubble.height - ChatGapY
    spriteId = ChatSpriteBase + playerIndex
  packet.addRgbaSpriteCached(cache, spriteId, bubble, "chat " & player.message)
  packet.addObject(
    ChatObjectBase + playerIndex,
    x,
    y,
    z,
    MapLayerId,
    spriteId
  )

proc addGlobalScorePanel(
  packet: var seq[uint8],
  sim: SimServer,
  cache: var seq[SpriteCacheEntry],
  selectedIndex: int
) =
  ## Appends the global score panel.
  if sim.players.len == 0:
    return
  var players = sim.scorePanelPlayers()
  players.sort(compareScorePanelPlayers)
  packet.addScorePanelDigitSprites(sim, cache)
  let
    rowHeight = max(sim.textFont.lineHeight(), ScorePanelChipSize)
    scoreColumnWidth = sim.scorePanelScoreWidth(players)
    scoreXBase = ScorePanelChipSize + ScorePanelChipGapX
    nameX = scoreXBase + scoreColumnWidth + ScorePanelNameGapX
  for i, player in players:
    packet.addScorePanelPlayerSprites(sim, cache, player, selectedIndex)
    let
      rowY = i * rowHeight
      chipY = rowY + (rowHeight - ScorePanelChipSize) div 2
      scoreText = scorePanelScoreText(player.score)
      scoreWidth = sim.textFont.textWidth(scoreText)
      scoreX = scoreXBase + max(0, scoreColumnWidth - scoreWidth)
    packet.addObject(
      scorePanelChipObjectId(player.index),
      0,
      chipY,
      int(high(int16)),
      TopLeftLayerId,
      scorePanelChipSpriteId(player.index)
    )
    packet.addObject(
      scorePanelNameObjectId(player.index),
      nameX,
      rowY,
      int(high(int16)),
      TopLeftLayerId,
      scorePanelNameSpriteId(player.index)
    )
    var digitX = scoreX
    for digitIndex, ch in scoreText:
      packet.addObject(
        scorePanelDigitObjectId(player.index, digitIndex),
        digitX,
        rowY,
        int(high(int16)),
        TopLeftLayerId,
        scorePanelDigitSpriteId(ch)
      )
      digitX += sim.textFont.glyphAdvance(ch)

proc cameraXFor(sim: SimServer, player: Actor): int =
  ## Returns the player camera x coordinate.
  worldClampPixel(
    sim.playerCenterX(player) - ViewportWidth div 2,
    LevelWidthPixels - ViewportWidth
  )

proc cameraYFor(sim: SimServer, player: Actor): int =
  ## Returns the player camera y coordinate.
  worldClampPixel(
    sim.playerCenterY(player) - ViewportHeight div 2,
    LevelHeightPixels - ViewportHeight
  )

proc animationFrame(sim: SimServer, player: Actor): PlayerFrame =
  ## Returns the current animation frame for one player.
  if not player.onGround:
    return PlayerJump
  if abs(player.velX) >= StopThreshold:
    if (sim.tickCount div 6) mod 2 == 0:
      return PlayerWalkA
    return PlayerWalkB
  PlayerStand

proc hasTileSupport(sim: SimServer, player: Actor): bool =
  ## Returns true when solid tiles touch the player collision box.
  let
    rect = sim.playerCollisionRect(player)
    startTx = rect.x div WorldTileSize
    endTx = (rect.x + rect.w - 1) div WorldTileSize
    ty = (rect.y + rect.h) div WorldTileSize
  for tx in startTx .. endTx:
    if sim.getTile(tx, ty).isSolid:
      return true
  false

proc hasPlayerSupport(sim: SimServer, playerIndex: int): bool =
  ## Returns true when another player's box supports this player's box.
  let
    player = sim.players[playerIndex]
    rect = sim.playerCollisionRect(player)
    footY = rect.y + rect.h
  for i in 0 ..< sim.players.len:
    if i == playerIndex or sim.players[i].dead:
      continue
    let otherRect = sim.playerCollisionRect(sim.players[i])
    if footY >= otherRect.y and footY < otherRect.y + otherRect.h and
        rect.x < otherRect.x + otherRect.w and
        rect.x + rect.w > otherRect.x:
      return true
  false

proc hasGroundSupport(sim: SimServer, playerIndex: int): bool =
  ## Returns true when a player can still stand on current support.
  if sim.players[playerIndex].dead:
    return false
  sim.hasTileSupport(sim.players[playerIndex]) or
    sim.hasPlayerSupport(playerIndex)

proc validateGroundSupport(sim: var SimServer) =
  ## Clears grounded state when moving support no longer lines up.
  for i in 0 ..< sim.players.len:
    if sim.players[i].onGround and not sim.hasGroundSupport(i):
      sim.players[i].onGround = false

proc playerBlockedByTilesAt(
  sim: SimServer,
  player: Actor,
  x, y: int
): bool =
  ## Returns true when one player position overlaps world tiles.
  let rect = sim.playerCollisionRectAt(player, x, y)
  rect.x < 0 or
    rect.x + rect.w > LevelWidthPixels or
    sim.collidesWithTiles(rect.x, rect.y, rect.w, rect.h)

proc applyTurnCandidate(
  sim: var SimServer,
  playerIndex: int,
  turned: Actor,
  x, y: int,
  facingRight: bool
): bool =
  ## Applies a turn at one candidate position when it is tile-safe.
  if sim.playerBlockedByTilesAt(turned, x, y):
    return false
  sim.players[playerIndex].x = x
  sim.players[playerIndex].facingRight = facingRight
  true

proc tryTurnPlayer(
  sim: var SimServer,
  playerIndex: int,
  facingRight: bool
) =
  ## Turns a player and nudges horizontally out of tiles if needed.
  if sim.players[playerIndex].facingRight == facingRight:
    return

  let
    currentX = sim.players[playerIndex].x
    currentY = sim.players[playerIndex].y
    oldBounds = sim.playerCollisionBounds(sim.players[playerIndex])
  var turned = sim.players[playerIndex]
  turned.facingRight = facingRight

  if not sim.playerBlockedByTilesAt(turned, currentX, currentY):
    sim.players[playerIndex].facingRight = facingRight
    return

  let
    newBounds = sim.playerCollisionBounds(turned)
    preferredX = currentX + oldBounds.x - newBounds.x
    preferPositive = preferredX >= currentX

  if sim.applyTurnCandidate(
    playerIndex,
    turned,
    preferredX,
    currentY,
    facingRight
  ):
    return

  for distance in 1 .. PlayerSpriteSize:
    let firstX =
      if preferPositive:
        currentX + distance
      else:
        currentX - distance
    if sim.applyTurnCandidate(
      playerIndex,
      turned,
      firstX,
      currentY,
      facingRight
    ):
      return

    let secondX =
      if preferPositive:
        currentX - distance
      else:
        currentX + distance
    if sim.applyTurnCandidate(
      playerIndex,
      turned,
      secondX,
      currentY,
      facingRight
    ):
      return

proc buildSpriteProtocolPlayerUpdates(
  sim: SimServer,
  playerIndex: int,
  state: PlayerViewerState,
  nextState: var PlayerViewerState
): seq[uint8] =
  ## Builds one sprite protocol update packet for a player viewer.
  nextState = state
  if not nextState.initialized:
    result.addSpriteProtocolInit(sim)
    nextState.initialized = true

  result.addClearObjects()
  result.addObject(
    SkyObjectId,
    0,
    0,
    int(low(int16)),
    MapLayerId,
    SkySpriteId
  )

  if playerIndex < 0 or playerIndex >= sim.players.len:
    return

  let
    player = sim.players[playerIndex]
    cameraX = sim.cameraXFor(player)
    cameraY = sim.cameraYFor(player)
    startTx = max(0, cameraX div WorldTileSize)
    startTy = max(0, cameraY div WorldTileSize)
    endTx = min(
      LevelWidthTiles - 1,
      (cameraX + ViewportWidth - 1) div WorldTileSize
    )
    endTy = min(
      LevelHeightTiles - 1,
      (cameraY + ViewportHeight - 1) div WorldTileSize
    )

  for ty in startTy .. endTy:
    for tx in startTx .. endTx:
      let
        index = tileIndex(tx, ty)
        gid = sim.tileGids[index]
        spriteId =
          if gid == 0:
            0
          else:
            gid.tileSpriteId()
      if spriteId == 0:
        continue
      result.addObject(
        TileObjectBase + index,
        tx * WorldTileSize - cameraX,
        ty * WorldTileSize - cameraY,
        0,
        MapLayerId,
        spriteId
      )

  for i in 0 ..< sim.players.len:
    let other = sim.players[i]
    if other.dead:
      continue
    let
      boxX = other.x - cameraX
      boxY = other.y - cameraY
      spriteX = boxX - PlayerSpriteOffsetX
      spriteY = boxY - PlayerSpriteOffsetY
    result.addObject(
      PlayerObjectBase + i,
      spriteX,
      spriteY,
      boxY + 100,
      MapLayerId,
      other.color.playerSpriteId(
        other.facingRight,
        sim.animationFrame(other)
      )
    )
    when DebugPlayerBounds:
      result.addObject(
        DebugPlayerBoxObjectBase + i,
        boxX,
        boxY,
        boxY + 101,
        MapLayerId,
        DebugPlayerBoxSpriteId
      )
    let nameY = result.addNameTag(
      sim,
      nextState.spriteCache,
      other,
      i,
      boxX,
      boxY,
      boxY + 200
    )
    result.addSpeechBubble(
      sim,
      nextState.spriteCache,
      other,
      i,
      boxX,
      nameY,
      boxY + 201
    )

  let pcx = sim.playerCenterX(player)
  for i in 0 ..< sim.players.len:
    if i == playerIndex or sim.players[i].dead:
      continue
    let
      other = sim.players[i]
      ocx = sim.playerCenterX(other)
      sx = ocx - cameraX
    if sx >= 0 and sx < ViewportWidth:
      continue
    let
      edgeX =
        if ocx < pcx:
          0
        else:
          ViewportWidth - 1
      osy = clamp(
        sim.playerCenterY(other) - cameraY,
        0,
        ViewportHeight - 1
      )
    result.addObject(
      RadarObjectBase + i,
      edgeX,
      osy,
      int(high(int16)) - 2,
      MapLayerId,
      other.color.radarSpriteId()
    )

  result.addTiny5Object(
    sim,
    $max(0, player.score),
    HudObjectBase,
    HudSpriteBase,
    0,
    0,
    int(high(int16))
  )
  if player.dead:
    result.addTiny5Object(
      sim,
      "OOPS!",
      TextObjectBase,
      TextSpriteBase,
      17,
      20,
      int(high(int16)) - 1
    )

proc buildSpriteProtocolGlobalUpdates(
  sim: SimServer,
  state: PlayerViewerState,
  nextState: var PlayerViewerState
): seq[uint8] =
  ## Builds one sprite protocol update packet for a global viewer.
  nextState = state
  if nextState.clickPending:
    let playerIndex = sim.scorePanelPlayerAt(
      nextState.mouseLayer,
      nextState.mouseX,
      nextState.mouseY
    )
    if playerIndex >= 0:
      nextState.toggleSelectedPlayer(playerIndex)
    nextState.clickPending = false

  let selectedIndex = nextState.selectedGlobalPlayerIndex(sim)
  nextState.selectedPlayerIndex = selectedIndex
  if selectedIndex >= 0:
    var
      povState = PlayerViewerState(
        initialized: nextState.povInitialized,
        spriteCache: nextState.povSpriteCache
      )
      nextPovState: PlayerViewerState
    result = sim.buildSpriteProtocolPlayerUpdates(
      selectedIndex,
      povState,
      nextPovState
    )
    nextState.initialized = false
    nextState.povInitialized = nextPovState.initialized
    nextState.povSpriteCache = nextPovState.spriteCache
    result.addGlobalScorePanel(
      sim,
      nextState.spriteCache,
      selectedIndex
    )
    return

  if not nextState.initialized:
    result.addSpriteProtocolInit(
      sim,
      LevelWidthPixels,
      LevelHeightPixels
    )
    nextState.initialized = true

  result.addClearObjects()
  result.addObject(
    SkyObjectId,
    0,
    0,
    int(low(int16)),
    MapLayerId,
    SkySpriteId
  )

  for ty in 0 ..< LevelHeightTiles:
    for tx in 0 ..< LevelWidthTiles:
      let
        index = tileIndex(tx, ty)
        gid = sim.tileGids[index]
        spriteId =
          if gid == 0:
            0
          else:
            gid.tileSpriteId()
      if spriteId == 0:
        continue
      result.addObject(
        TileObjectBase + index,
        tx * WorldTileSize,
        ty * WorldTileSize,
        0,
        MapLayerId,
        spriteId
      )

  for i in 0 ..< sim.players.len:
    let player = sim.players[i]
    if player.dead:
      continue
    result.addObject(
      PlayerObjectBase + i,
      player.x - PlayerSpriteOffsetX,
      player.y - PlayerSpriteOffsetY,
      player.y + 100,
      MapLayerId,
      player.color.playerSpriteId(
        player.facingRight,
        sim.animationFrame(player)
      )
    )
    when DebugPlayerBounds:
      result.addObject(
        DebugPlayerBoxObjectBase + i,
        player.x,
        player.y,
        player.y + 101,
        MapLayerId,
        DebugPlayerBoxSpriteId
      )
    let nameY = result.addNameTag(
      sim,
      nextState.spriteCache,
      player,
      i,
      player.x,
      player.y,
      player.y + 200
    )
    result.addSpeechBubble(
      sim,
      nextState.spriteCache,
      player,
      i,
      player.x,
      nameY,
      player.y + 201
    )

  result.addGlobalScorePanel(sim, nextState.spriteCache, selectedIndex)

proc applyInput(sim: var SimServer, playerIndex: int, input: InputState) =
  if playerIndex < 0 or playerIndex >= sim.players.len:
    return

  template p: untyped = sim.players[playerIndex]

  if p.dead:
    return

  var inputX = 0
  if input.left:
    inputX -= 1
  if input.right:
    inputX += 1

  if inputX != 0:
    p.velX = clamp(p.velX + inputX * AccelX, -MaxSpeedX, MaxSpeedX)
    sim.tryTurnPlayer(playerIndex, inputX > 0)
  else:
    p.velX = (p.velX * FrictionNum) div FrictionDen
    if abs(p.velX) < StopThreshold:
      p.velX = 0

  if not p.onGround and sim.hasGroundSupport(playerIndex):
    p.onGround = true

  if input.attack and p.onGround:
    p.velY = JumpVel
    p.onGround = false

proc collidesWithPlayerAt(
  sim: SimServer,
  pi: int,
  player: Actor,
  x, y: int
): int =
  ## Returns the first player with overlapping collision boxes.
  let rect = sim.playerCollisionRectAt(player, x, y)
  for j in 0 ..< sim.players.len:
    if j == pi or sim.players[j].dead:
      continue
    let otherRect = sim.playerCollisionRect(sim.players[j])
    if rectsOverlap(
      rect.x,
      rect.y,
      rect.w,
      rect.h,
      otherRect.x,
      otherRect.y,
      otherRect.w,
      otherRect.h
    ):
      return j
  -1

proc tryPushX(
  sim: var SimServer,
  playerIndex: int,
  step: int,
  depth = 0
): bool =
  ## Tries to push one horizontal chain of player boxes by one pixel.
  if depth > sim.players.len or sim.players[playerIndex].dead:
    return false
  let nx = sim.players[playerIndex].x + step
  if sim.playerBlockedByTilesAt(
    sim.players[playerIndex],
    nx,
    sim.players[playerIndex].y
  ):
    return false

  var checked = 0
  while checked <= sim.players.len:
    let hitPlayer = sim.collidesWithPlayerAt(
      playerIndex,
      sim.players[playerIndex],
      nx,
      sim.players[playerIndex].y
    )
    if hitPlayer < 0:
      sim.players[playerIndex].x = nx
      return true
    if not sim.tryPushX(hitPlayer, step, depth + 1):
      return false
    inc checked
  false

proc tryPushY(
  sim: var SimServer,
  playerIndex: int,
  step: int,
  depth = 0
): bool =
  ## Tries to push one vertical chain of player boxes by one pixel.
  if depth > sim.players.len or sim.players[playerIndex].dead:
    return false
  let ny = sim.players[playerIndex].y + step
  if sim.playerBlockedByTilesAt(
    sim.players[playerIndex],
    sim.players[playerIndex].x,
    ny
  ):
    return false

  var checked = 0
  while checked <= sim.players.len:
    let hitPlayer = sim.collidesWithPlayerAt(
      playerIndex,
      sim.players[playerIndex],
      sim.players[playerIndex].x,
      ny
    )
    if hitPlayer < 0:
      sim.players[playerIndex].y = ny
      return true
    if not sim.tryPushY(hitPlayer, step, depth + 1):
      return false
    inc checked
  false

proc movePlayerY(
  sim: var SimServer,
  p: var Actor,
  pi: int,
  step: int
): bool =
  ## Moves a player vertically by one pixel when the box path is clear.
  let ny = p.y + step
  if sim.playerBlockedByTilesAt(p, p.x, ny):
    return false
  let hitPlayer = sim.collidesWithPlayerAt(pi, p, p.x, ny)
  if hitPlayer >= 0:
    if step > 0:
      return false
    if not sim.tryPushY(hitPlayer, step):
      return false
  p.y = ny
  true

proc moveX(sim: var SimServer, p: var Actor, pi: int) =
  p.carryX += p.velX
  while abs(p.carryX) >= MotionScale:
    let step = (if p.carryX < 0: -1 else: 1)
    let nx = p.x + step
    let rect = sim.playerCollisionRectAt(p, nx, p.y)
    if rect.x < 0 or
      rect.x + rect.w > LevelWidthPixels or
      sim.collidesWithTiles(rect.x, rect.y, rect.w, rect.h):
        p.carryX = 0
        p.velX = 0
        break
    let hitPlayer = sim.collidesWithPlayerAt(
      pi,
      p,
      nx,
      p.y
    )
    if hitPlayer >= 0:
      if sim.tryPushX(hitPlayer, step):
        p.x = nx
        p.carryX -= step * MotionScale
      else:
        p.carryX = 0
      break
    p.x = nx
    p.carryX -= step * MotionScale

proc moveY(sim: var SimServer, p: var Actor, pi: int) =
  p.carryY += p.velY
  while abs(p.carryY) >= MotionScale:
    let step = (if p.carryY < 0: -1 else: 1)
    if not sim.movePlayerY(p, pi, step):
      p.carryY = 0
      if p.velY > 0:
        p.onGround = true
      p.velY = 0
      break
    p.carryY -= step * MotionScale

proc applyPhysics(sim: var SimServer, p: var Actor, pi: int) =
  p.velY = min(p.velY + Gravity, MaxFallSpeed)
  sim.moveX(p, pi)
  sim.moveY(p, pi)

  if p.onGround:
    if not sim.hasGroundSupport(pi):
      p.onGround = false

proc checkDeath(sim: var SimServer) =
  for i in 0 ..< sim.players.len:
    if sim.players[i].dead:
      continue
    let rect = sim.playerCollisionRect(sim.players[i])
    if rect.y > DeathY:
      sim.players[i].dead = true
      sim.players[i].respawnTimer = 48

proc checkGoal(sim: var SimServer) =
  for i in 0 ..< sim.players.len:
    if sim.players[i].dead:
      continue
    let rect = sim.playerCollisionRect(sim.players[i])
    var scored = false
    for ty in 0 ..< LevelHeightTiles:
      for tx in 0 ..< LevelWidthTiles:
        if sim.tiles[tileIndex(tx, ty)] != TileGoal:
          continue
        if rectsOverlap(
          rect.x,
          rect.y,
          rect.w,
          rect.h,
          tx * WorldTileSize,
          ty * WorldTileSize,
          WorldTileSize,
          WorldTileSize
        ):
          inc sim.players[i].score
          sim.respawnPlayer(i)
          scored = true
          break
      if scored:
        break

proc updateRespawns(sim: var SimServer) =
  for i in 0 ..< sim.players.len:
    if not sim.players[i].dead:
      continue
    dec sim.players[i].respawnTimer
    if sim.players[i].respawnTimer <= 0:
      sim.respawnPlayer(i)

proc updateMessages(sim: var SimServer) =
  ## Clears player speech bubbles when their lifetime expires.
  for i in 0 ..< sim.players.len:
    if sim.players[i].messageTicks <= 0:
      if sim.players[i].message.len > 0:
        sim.players[i].message = ""
      continue
    dec sim.players[i].messageTicks
    if sim.players[i].messageTicks <= 0:
      sim.players[i].message = ""

proc step*(sim: var SimServer, inputs: openArray[InputState]) =
  inc sim.tickCount
  for i in 0 ..< sim.players.len:
    let input =
      if i < inputs.len: inputs[i]
      else: InputState()
    sim.applyInput(i, input)
  for i in 0 ..< sim.players.len:
    if not sim.players[i].dead:
      sim.applyPhysics(sim.players[i], i)
  sim.resolveOverlaps()
  sim.validateGroundSupport()
  sim.checkDeath()
  sim.checkGoal()
  sim.updateRespawns()
  sim.updateMessages()

var appState: WebSocketAppState

proc initAppState() =
  initLock(appState.lock)
  appState.inputMasks = initTable[WebSocket, uint8]()
  appState.lastAppliedMasks = initTable[WebSocket, uint8]()
  appState.playerIndices = initTable[WebSocket, int]()
  appState.playerViewers = initTable[WebSocket, PlayerViewerState]()
  appState.globalViewers = initTable[WebSocket, PlayerViewerState]()
  appState.playerNames = initTable[WebSocket, string]()
  appState.playerSlots = initTable[WebSocket, int]()
  appState.chatMessages = initTable[WebSocket, string]()
  appState.replayViewers = initTable[WebSocket, PlayerViewerState]()
  appState.viewerMice = initTable[WebSocket, tuple[x, y, layer: int]]()
  appState.scrubbingViewers = initTable[WebSocket, bool]()
  appState.closedSockets = @[]
  appState.tokens = @[]
  appState.replayServerMode = false
  appState.replayLoaded = false
  appState.pendingReplayUri = ""
  appState.replayMaxTick = 0
  appState.replayCommands = @[]
  appState.replaySeekTicks = @[]

proc initGlobalViewerState(): PlayerViewerState =
  ## Returns the default state for one global viewer.
  result.selectedPlayerIndex = -1
  result.mouseLayer = MapLayerId

proc inputStateFromMasks*(currentMask, previousMask: uint8): InputState =
  result = decodeInputMask(currentMask)
  result.attack =
    (currentMask and ButtonA) != 0 and
    (previousMask and ButtonA) == 0

proc mixHash(hash: var uint64, value: uint64) =
  ## Mixes one value into a running FNV-1a hash.
  hash = (hash xor value) * 1099511628211'u64

proc mixHashInt(hash: var uint64, value: int) =
  ## Mixes one integer into a running hash.
  hash.mixHash(cast[uint64](int64(value)))

proc gameHash*(sim: SimServer): uint64 =
  ## Returns a deterministic hash of gameplay state.
  result = 14695981039346656037'u64
  result.mixHashInt(sim.tickCount)
  result.mixHashInt(sim.nextColorIndex)
  result.mixHashInt(sim.players.len)
  for player in sim.players:
    result.mixHashInt(player.x)
    result.mixHashInt(player.y)
    result.mixHashInt(player.velX)
    result.mixHashInt(player.velY)
    result.mixHashInt(player.carryX)
    result.mixHashInt(player.carryY)
    result.mixHashInt(ord(player.onGround))
    result.mixHashInt(player.score)
    result.mixHashInt(player.slot)
    result.mixHashInt(ord(player.dead))
    result.mixHashInt(player.respawnTimer)
    result.mixHashInt(ord(player.facingRight))
    result.mixHashInt(int(player.color))
    result.mixHashInt(player.name.len)
    result.mixHashInt(player.message.len)
    result.mixHashInt(player.messageTicks)

proc snapshotSim(sim: SimServer): string =
  ## Serializes the dynamic simulation state for replay keyframes.
  SimSnapshot(
    tickCount: sim.tickCount,
    nextColorIndex: sim.nextColorIndex,
    rng: sim.rng,
    players: sim.players
  ).toFlatty()

proc restoreSim(sim: var SimServer, bytes: string) =
  ## Restores the dynamic simulation state from a replay keyframe.
  let snapshot = bytes.fromFlatty(SimSnapshot)
  sim.tickCount = snapshot.tickCount
  sim.nextColorIndex = snapshot.nextColorIndex
  sim.rng = snapshot.rng
  sim.players = snapshot.players

proc applyReplayEvents(replay: var ReplayPlayer, sim: var SimServer) =
  ## Applies replay leaves, joins, inputs, and chats for the current tick.
  let time = tickTime(sim.tickCount)
  while replay.leaveIndex < replay.data.leaves.len and
      replay.data.leaves[replay.leaveIndex].time <= time:
    let leave = replay.data.leaves[replay.leaveIndex]
    if int(leave.player) < 0 or int(leave.player) >= sim.players.len:
      raise newException(ReplayError, "Replay player leave is invalid")
    sim.players.delete(int(leave.player))
    if int(leave.player) < replay.masks.len:
      replay.masks.delete(int(leave.player))
    if int(leave.player) < replay.lastAppliedMasks.len:
      replay.lastAppliedMasks.delete(int(leave.player))
    inc replay.leaveIndex

  while replay.joinIndex < replay.data.joins.len and
      replay.data.joins[replay.joinIndex].time <= time:
    let join = replay.data.joins[replay.joinIndex]
    if int(join.player) != sim.players.len:
      raise newException(ReplayError, "Replay player join order is invalid")
    discard sim.addPlayer(join.name, join.slot)
    replay.ensureReplayPlayer(int(join.player))
    inc replay.joinIndex

  while replay.inputIndex < replay.data.inputs.len and
      replay.data.inputs[replay.inputIndex].time <= time:
    let input = replay.data.inputs[replay.inputIndex]
    replay.ensureReplayPlayer(int(input.player))
    replay.masks[int(input.player)] = input.keys
    inc replay.inputIndex

  while replay.chatIndex < replay.data.chats.len and
      replay.data.chats[replay.chatIndex].time <= time:
    let chat = replay.data.chats[replay.chatIndex]
    if int(chat.player) >= 0 and int(chat.player) < sim.players.len:
      sim.players[int(chat.player)].message = chat.message
      sim.players[int(chat.player)].messageTicks = ChatLifetimeTicks
    inc replay.chatIndex

proc checkReplayHash(replay: var ReplayPlayer, sim: SimServer) =
  ## Checks the recorded hash for the current tick.
  if replay.hashValidationFailed:
    if sim.tickCount >= replay.replayMaxTick():
      replay.playing = false
    return
  if replay.hashIndex >= replay.data.hashes.len:
    replay.playing = false
    return
  let expected = replay.data.hashes[replay.hashIndex]
  if int(expected.tick) < sim.tickCount:
    let message = "Replay hash tick is missing at tick " & $sim.tickCount & "."
    if replay.mismatchQuit:
      raise newException(ReplayError, message)
    echo message
    replay.hashValidationFailed = true
    replay.hashMismatchTick = sim.tickCount
    return
  if int(expected.tick) > sim.tickCount:
    return
  let hash = sim.gameHash()
  if hash != expected.hash:
    let message =
      "Replay hash mismatch at tick " & $sim.tickCount &
        "; expected " & $expected.hash & ", got " & $hash & "."
    if replay.mismatchQuit:
      raise newException(ReplayError, message)
    echo message
    replay.hashValidationFailed = true
    replay.hashMismatchTick = sim.tickCount
    return
  inc replay.hashIndex

proc stepReplay*(replay: var ReplayPlayer, sim: var SimServer) =
  ## Advances replay by one simulation tick.
  replay.applyReplayEvents(sim)
  var inputs = newSeq[InputState](sim.players.len)
  for i in 0 ..< sim.players.len:
    replay.ensureReplayPlayer(i)
    inputs[i] = inputStateFromMasks(
      replay.masks[i],
      replay.lastAppliedMasks[i]
    )
    replay.lastAppliedMasks[i] = replay.masks[i]
  sim.step(inputs)
  replay.checkReplayHash(sim)

proc saveReplayKeyframe(
  replay: ReplayPlayer,
  sim: SimServer
): ReplayKeyframe =
  ## Builds one replay keyframe from the current playback state.
  ReplayKeyframe(
    tick: sim.tickCount,
    simBytes: sim.snapshotSim(),
    joinIndex: replay.joinIndex,
    leaveIndex: replay.leaveIndex,
    chatIndex: replay.chatIndex,
    inputIndex: replay.inputIndex,
    hashIndex: replay.hashIndex,
    masks: replay.masks,
    lastAppliedMasks: replay.lastAppliedMasks,
    hashValidationFailed: replay.hashValidationFailed,
    hashMismatchTick: replay.hashMismatchTick
  )

proc restoreReplayKeyframe(
  replay: var ReplayPlayer,
  sim: var SimServer,
  keyframe: ReplayKeyframe
) =
  ## Restores playback state from one replay keyframe.
  sim.restoreSim(keyframe.simBytes)
  replay.joinIndex = keyframe.joinIndex
  replay.leaveIndex = keyframe.leaveIndex
  replay.chatIndex = keyframe.chatIndex
  replay.inputIndex = keyframe.inputIndex
  replay.hashIndex = keyframe.hashIndex
  replay.masks = keyframe.masks
  replay.lastAppliedMasks = keyframe.lastAppliedMasks
  replay.hashValidationFailed = keyframe.hashValidationFailed
  replay.hashMismatchTick = keyframe.hashMismatchTick

proc buildReplayKeyframes*(
  replay: var ReplayPlayer,
  initialSim: SimServer,
  interval = ReplayKeyframeTicks
) =
  ## Builds serialized replay seek keyframes every interval ticks.
  replay.keyframes = @[]
  var
    sim = initialSim
    builder = initReplayPlayer(replay.data)
  builder.looping = false
  builder.mismatchQuit = replay.mismatchQuit
  replay.keyframes.add(builder.saveReplayKeyframe(sim))
  let maxTick = builder.replayMaxTick()
  while builder.playing and sim.tickCount < maxTick:
    builder.stepReplay(sim)
    if sim.tickCount mod max(interval, 1) == 0 or sim.tickCount == maxTick:
      replay.keyframes.add(builder.saveReplayKeyframe(sim))

proc seekReplay*(
  replay: var ReplayPlayer,
  sim: var SimServer,
  seed: int,
  tick: int
) =
  ## Seeks replay playback to a target tick.
  if replay.keyframes.len > 0:
    replay.restoreReplayKeyframe(
      sim,
      replay.keyframes[replay.replayKeyframeIndex(tick)]
    )
  else:
    sim = initSimServer(seed)
    replay.resetReplay()
  while sim.tickCount < tick and replay.hashIndex < replay.data.hashes.len:
    replay.stepReplay(sim)

proc applyReplaySeek(
  replay: var ReplayPlayer,
  sim: var SimServer,
  seed: int,
  tick: int
) =
  ## Seeks replay playback and pauses on the target tick.
  replay.playing = false
  replay.seekReplay(sim, seed, clamp(tick, 0, replay.replayMaxTick()))

proc applyReplayCommand(
  replay: var ReplayPlayer,
  sim: var SimServer,
  seed: int,
  command: char
) =
  ## Applies one global viewer replay transport command.
  case command
  of ' ':
    replay.playing = not replay.playing
  of 'p':
    replay.playing = true
  of 'P':
    replay.playing = false
  of '+', '=':
    replay.speedIndex = min(replay.speedIndex + 1, PlaybackSpeeds.high)
  of '-', '_':
    replay.speedIndex = max(replay.speedIndex - 1, 0)
  of '1':
    replay.speedIndex = 0
  of '2':
    replay.speedIndex = 1
  of '3':
    replay.speedIndex = 2
  of '4':
    replay.speedIndex = 3
  of '8':
    replay.speedIndex = 4
  of '6':
    replay.speedIndex = 5
  of ',', '<':
    replay.playing = false
    replay.seekReplay(sim, seed, 0)
  of 'b':
    replay.playing = false
    replay.seekReplay(sim, seed, max(0, sim.tickCount - 1))
  of 'e':
    replay.playing = false
    replay.seekReplay(sim, seed, replay.replayMaxTick())
  of 'r':
    replay.looping = not replay.looping
  of '.', '>':
    replay.playing = false
    replay.seekReplay(
      sim,
      seed,
      min(sim.tickCount + ReplayFps * 5, replay.replayMaxTick())
    )
  else:
    discard

proc replayCommandAt(layer, x, y: int): char =
  ## Returns the replay transport command under a UI coordinate.
  if layer != ReplayBottomLeftLayerId:
    return '\0'
  let
    localX = x - TransportX
    localY = y - TransportY
  if localY >= 0 and localY < TransportIconHeight:
    let index = localX div TransportButtonStride
    if index < 0 or index >= TransportIconCount:
      return '\0'
    if localX - index * TransportButtonStride >= TransportIconSize:
      return '\0'
    case index
    of 0: return '<'
    of 1: return ' '
    of 2: return 'e'
    of 3: return 'r'
    of 4: return 'b'
    else: return '\0'
  if localY >= TransportSpeedY and localY < TransportSpeedY + 6:
    let speedX = localX - TransportSpeedX
    if speedX >= 0 and speedX < 12:
      return '1'
    if speedX >= 16 and speedX < 28:
      return '2'
    if speedX >= 32 and speedX < 44:
      return '3'
    if speedX >= 48 and speedX < 60:
      return '4'
    if speedX >= 64 and speedX < 76:
      return '8'
    if speedX >= 80 and speedX < 100:
      return '6'
  '\0'

proc replayScrubTickAt(
  layer, x, y, maxTick: int,
  requireInside = true
): int =
  ## Returns the replay tick under the scrubber pointer.
  if layer != ReplayCenterBottomLayerId or maxTick < 0:
    return -1
  let
    scrubberX = max(0, (ViewportWidth - ReplayScrubberWidth) div 2)
    localX = x - scrubberX
    localY = y - ReplayScrubberY
  if requireInside and (
      localX < 0 or localX >= ReplayScrubberWidth or
      localY < 0 or localY >= ReplayScrubberHeight
    ):
    return -1
  if ReplayScrubberWidth <= 1:
    return 0
  let clampedX = clamp(localX, 0, ReplayScrubberWidth - 1)
  clamp((clampedX * maxTick) div (ReplayScrubberWidth - 1), 0, maxTick)

var TransportSheetSprite: Sprite

proc transportSheet(): Sprite =
  ## Returns the shared transport icon sheet.
  if TransportSheetSprite.width == 0:
    TransportSheetSprite = readRequiredSprite(
      clientDataDir() / "transport.png"
    )
  TransportSheetSprite

proc buildReplayScrubberSprite(tick, maxTick: int): RgbaSprite =
  ## Builds a compact replay scrubber sprite.
  result = newRgbaSprite(ReplayScrubberWidth, ReplayScrubberHeight)
  let knobX =
    if maxTick > 0:
      clamp(
        (tick * (ReplayScrubberWidth - 1)) div maxTick,
        0,
        ReplayScrubberWidth - 1
      )
    else:
      0
  for x in 0 ..< ReplayScrubberWidth:
    result.putRgbaPixel(x, ReplayScrubberTrackY, rgbaColor(1'u8))
  for x in 0 .. knobX:
    result.putRgbaPixel(x, ReplayScrubberTrackY, rgbaColor(10'u8))
  for y in 0 ..< ReplayScrubberHeight:
    result.putRgbaPixel(knobX, y, rgbaColor(2'u8))

proc blitTransportIcon(
  target: var RgbaSprite,
  sheet: Sprite,
  cell, baseX, baseY: int,
  tint: uint8
) =
  ## Blits one transport icon cell into an RGBA sprite.
  let sourceX = cell * TransportIconSize
  for y in 0 ..< TransportIconHeight:
    for x in 0 ..< TransportIconSize:
      let colorIndex = sheet.pixels[sheet.spriteIndex(sourceX + x, y)]
      if colorIndex == TransparentColorIndex:
        continue
      target.putRgbaPixel(baseX + x, baseY + y, rgbaColor(tint))

proc buildReplayControlsSprite(
  sim: SimServer,
  replayPlaying: bool,
  replaySpeed: int,
  replayLooping: bool
): RgbaSprite =
  ## Builds the replay transport controls sprite.
  result = newRgbaSprite(TransportWidth, TransportHeight)
  let
    sheet = transportSheet()
    iconCells = [
      0,
      if replayPlaying: 2 else: 1,
      3,
      4,
      5
    ]
  for i in 0 ..< iconCells.len:
    let tint =
      if i == 3:
        if replayLooping: 10'u8 else: 1'u8
      else:
        2'u8
    result.blitTransportIcon(
      sheet,
      iconCells[i],
      i * TransportButtonStride,
      0,
      tint
    )
  let speedTexts = ["1X", "2X", "3X", "4X", "8X", "16X"]
  var x = TransportSpeedX
  for i in 0 ..< speedTexts.len:
    let color =
      if PlaybackSpeeds[i] == replaySpeed:
        rgbaColor(10'u8)
      else:
        rgbaColor(1'u8)
    var glyphX = x
    for ch in speedTexts[i]:
      let glyph = sim.textFont.glyphAt(ch)
      result.blitChatGlyph(glyph, glyphX, TransportSpeedY, color)
      glyphX += sim.textFont.glyphAdvance(ch)
    x += TransportSpeedGap

proc addReplayControls(
  packet: var seq[uint8],
  sim: SimServer,
  cache: var seq[SpriteCacheEntry],
  replay: ReplayPlayer
) =
  ## Adds the replay scrubber and transport controls to one packet.
  packet.addLayer(
    ReplayCenterBottomLayerId,
    ReplayCenterBottomLayerKind,
    UiLayerFlags
  )
  packet.addViewport(
    ReplayCenterBottomLayerId,
    ViewportWidth,
    ReplayPanelHeight
  )
  packet.addLayer(
    ReplayBottomLeftLayerId,
    ReplayBottomLeftLayerKind,
    UiLayerFlags
  )
  packet.addViewport(
    ReplayBottomLeftLayerId,
    TransportWidth + TransportX,
    TransportHeight + TransportY
  )
  packet.addRgbaSpriteCached(
    cache,
    ReplayScrubberSpriteId,
    buildReplayScrubberSprite(sim.tickCount, replay.replayMaxTick()),
    "replay scrubber"
  )
  packet.addObject(
    ReplayScrubberObjectId,
    max(0, (ViewportWidth - ReplayScrubberWidth) div 2),
    ReplayScrubberY,
    30000,
    ReplayCenterBottomLayerId,
    ReplayScrubberSpriteId
  )
  packet.addRgbaSpriteCached(
    cache,
    ReplayControlsSpriteId,
    sim.buildReplayControlsSprite(
      replay.playing,
      replay.replaySpeed(),
      replay.looping
    ),
    "replay controls"
  )
  packet.addObject(
    ReplayControlsObjectId,
    TransportX,
    TransportY,
    30001,
    ReplayBottomLeftLayerId,
    ReplayControlsSpriteId
  )

proc applyGlobalViewerMessage(
  state: var PlayerViewerState,
  message: string
) =
  ## Applies one or more global viewer client messages.
  for item in message.parseSpriteClientMessages():
    case item.kind
    of SpriteClientChatMessage, SpriteClientInputMessage,
        SpriteClientReadyMessage, SpriteClientDebugSpriteMessage:
      discard
    of SpriteClientMouseMoveMessage:
      state.mouseX = item.x
      state.mouseY = item.y
      state.mouseLayer =
        if item.hasLayer:
          item.layer
        else:
          MapLayerId
    of SpriteClientMouseButtonMessage:
      if item.button == 1'u8:
        state.mouseDown = item.down
        if item.down:
          state.clickPending = true

proc playerChatFromMessage(message: Message): string =
  ## Reads player chat from text or binary websocket messages.
  case message.kind
  of TextMessage:
    message.data
  of BinaryMessage:
    if message.data.isChatPacket():
      return message.data.blobToChat()
    message.data.readSpriteInputText()
  of Ping, Pong:
    ""

proc applyReplayViewerMessage(websocket: WebSocket, message: string) =
  ## Applies replay transport input from one replay-mode viewer.
  for item in message.parseSpriteClientMessages():
    case item.kind
    of SpriteClientChatMessage:
      for ch in item.text:
        appState.replayCommands.add(ch)
    of SpriteClientMouseMoveMessage:
      let layer =
        if item.hasLayer:
          item.layer
        else:
          MapLayerId
      appState.viewerMice[websocket] = (x: item.x, y: item.y, layer: layer)
      if appState.scrubbingViewers.getOrDefault(websocket, false):
        let tick = replayScrubTickAt(
          layer,
          item.x,
          item.y,
          appState.replayMaxTick,
          requireInside = false
        )
        if tick >= 0:
          appState.replaySeekTicks.add(tick)
    of SpriteClientMouseButtonMessage:
      if item.button != 1'u8:
        continue
      if not item.down:
        appState.scrubbingViewers[websocket] = false
        continue
      let mouse = appState.viewerMice.getOrDefault(
        websocket,
        (x: 0, y: 0, layer: MapLayerId)
      )
      let command = replayCommandAt(mouse.layer, mouse.x, mouse.y)
      if command != '\0':
        appState.replayCommands.add(command)
        continue
      let tick = replayScrubTickAt(
        mouse.layer,
        mouse.x,
        mouse.y,
        appState.replayMaxTick
      )
      if tick >= 0:
        appState.replaySeekTicks.add(tick)
        appState.scrubbingViewers[websocket] = true
    else:
      discard

proc removePlayer(sim: var SimServer, websocket: WebSocket) =
  if websocket in appState.globalViewers:
    appState.globalViewers.del(websocket)
  if websocket in appState.replayViewers:
    appState.replayViewers.del(websocket)
  if websocket in appState.viewerMice:
    appState.viewerMice.del(websocket)
  if websocket in appState.scrubbingViewers:
    appState.scrubbingViewers.del(websocket)
  if websocket in appState.playerViewers:
    appState.playerViewers.del(websocket)
  if websocket in appState.playerNames:
    appState.playerNames.del(websocket)
  if websocket in appState.playerSlots:
    appState.playerSlots.del(websocket)
  if websocket in appState.chatMessages:
    appState.chatMessages.del(websocket)
  if websocket notin appState.playerIndices:
    appState.inputMasks.del(websocket)
    appState.lastAppliedMasks.del(websocket)
    return
  let removedIndex = appState.playerIndices[websocket]
  appState.playerIndices.del(websocket)
  appState.inputMasks.del(websocket)
  appState.lastAppliedMasks.del(websocket)
  if removedIndex >= 0 and removedIndex < sim.players.len:
    sim.players.delete(removedIndex)
    for ws, value in appState.playerIndices.mpairs:
      if value > removedIndex:
        dec value

proc resetConnectedPlayers() =
  ## Marks every connected player socket for a fresh simulation join.
  var sockets: seq[WebSocket] = @[]
  for websocket in appState.playerIndices.keys:
    sockets.add(websocket)
  for websocket in sockets:
    appState.playerIndices[websocket] = UnassignedPlayerIndex
    appState.playerViewers[websocket] = PlayerViewerState()
    appState.inputMasks[websocket] = 0
    appState.lastAppliedMasks[websocket] = 0
  appState.chatMessages.clear()

proc isWebSocketUpgrade(request: Request): bool =
  ## Returns true when the request is a WebSocket upgrade.
  request.headers["Sec-WebSocket-Key"].len > 0

proc respondPlain(request: Request, status: int, body: string) =
  ## Sends a no-cache plain text response.
  var headers: HttpHeaders
  headers["Content-Type"] = "text/plain; charset=utf-8"
  headers["Cache-Control"] = "no-cache"
  request.respond(status, headers, body)

proc serveHealthz(request: Request): bool =
  ## Serves the container health check endpoint.
  if request.path != HealthzPath or request.httpMethod notin ["GET", "HEAD"]:
    return false
  request.respondPlain(200, "healthy")
  true

proc isGlobalSocketPath(path: string): bool =
  ## Returns true for global viewer websocket endpoints.
  path == GlobalWebSocketPath or
    path == AdminWebSocketPath

proc replayFilePath(uri: string): string =
  ## Resolves one local replay URI to a host path.
  const FilePrefix = "file://"
  if uri.startsWith(FilePrefix):
    return uri[FilePrefix.len .. ^1]
  if "://" in uri:
    return ""
  uri

let replayDownloadPool = newCurlPool(1)

proc loadReplayUri(uri: string): ReplayData =
  ## Loads a replay from a local file URI or HTTP(S) URL.
  parseReplayBytes(readCogameUri(uri, CogameLoadReplayUriEnv))

proc readableReplayUri(uri: string): bool =
  ## Returns true when a replay URI can be opened by this server.
  if uri.len == 0:
    return false
  if uri.startsWith("http://") or uri.startsWith("https://"):
    return replayDownloadPool.head(uri).code == 200
  let path = replayFilePath(uri)
  path.len > 0 and fileExists(path)

proc replayRequestUri(request: Request): string =
  ## Returns the replay artifact URI requested by a Coworld replay client.
  request.queryParams.getOrDefault("uri", "").strip()

proc playerSlot(request: Request): int =
  ## Returns the requested zero-based slot or -1 for automatic assignment.
  let text = request.queryParams.getOrDefault("slot", "").strip()
  if text.len == 0:
    return -1
  try:
    result = parseInt(text)
  except ValueError:
    return int.high
  if result < 0:
    return int.high

proc playerToken(request: Request): string =
  ## Returns the player join token.
  request.queryParams.getOrDefault("token", "").strip()

proc playerName(request: Request): string =
  ## Returns the player display name.
  request.queryParams.getOrDefault("name", "").cleanPlayerName()

proc playerJoinAllowed(slot: int, token: string): bool =
  ## Returns true when the configured token list accepts the join request.
  if appState.tokens.len == 0:
    return true
  if slot >= 0 and slot < appState.tokens.len:
    return token == appState.tokens[slot]
  if slot == -1:
    return token in appState.tokens
  false

proc resolveJoinSlot(slot: int, token: string): int =
  ## Returns the seat slot for one accepted join request.
  if slot >= 0:
    return slot
  if appState.tokens.len == 0:
    return -1
  var claimed: seq[int] = @[]
  for _, claimedSlot in appState.playerSlots.pairs:
    claimed.add(claimedSlot)
  result = -1
  for i in 0 ..< appState.tokens.len:
    if appState.tokens[i] == token:
      if i notin claimed:
        return i
      if result == -1:
        result = i

proc checkReplayRequest(request: Request): bool =
  ## Validates one replay page or websocket request, capturing the
  ## requested replay URI for the playback loop. Returns false after
  ## responding with an error.
  result = true
  var
    replayServerMode = false
    replayLoaded = false
  {.gcsafe.}:
    withLock appState.lock:
      replayServerMode = appState.replayServerMode
      replayLoaded = appState.replayLoaded
  if not replayServerMode:
    return true
  let uri = request.replayRequestUri()
  if uri.len == 0:
    if replayLoaded:
      return true
    request.respondPlain(400, "missing replay uri\n")
    return false
  var readable = false
  {.gcsafe.}:
    readable = uri.readableReplayUri()
  if not readable:
    request.respondPlain(404, "replay uri is not readable\n")
    return false
  {.gcsafe.}:
    withLock appState.lock:
      appState.pendingReplayUri = uri
  return true

proc httpHandler(request: Request) =
  if request.serveHealthz():
    discard
  elif request.path == WebSocketPath and request.httpMethod == "GET" and
      not request.isWebSocketUpgrade():
    discard request.serveClientFile(GlobalClientRoute, GlobalClientRoute)
  elif request.path.isGlobalSocketPath() and
      request.httpMethod == "GET" and not request.isWebSocketUpgrade():
    discard request.serveClientFile(GlobalClientRoute, GlobalClientRoute)
  elif request.path == ReplayWebSocketPath and request.httpMethod == "GET" and
      not request.isWebSocketUpgrade():
    if not request.checkReplayRequest():
      return
    discard request.serveClientFile(ReplayClientRoute, GlobalClientRoute)
  elif request.path == ReplayWebSocketPath and request.httpMethod == "GET" and
      request.isWebSocketUpgrade():
    if not request.checkReplayRequest():
      return
    let websocket = request.upgradeToWebSocket()
    {.gcsafe.}:
      withLock appState.lock:
        if appState.replayServerMode:
          appState.replayViewers[websocket] = initGlobalViewerState()
        else:
          appState.globalViewers[websocket] = initGlobalViewerState()
  elif request.path in [ReplayClientRoute, CoworldReplayClientRoute] and
      request.httpMethod == "GET":
    if not request.checkReplayRequest():
      return
    discard request.serveClientFile(request.path, GlobalClientRoute)
  elif request.path == WebSocketPath and request.httpMethod == "GET" and
      request.isWebSocketUpgrade():
    let
      slot = request.playerSlot()
      token = request.playerToken()
      name = request.playerName()
    var allowed = false
    {.gcsafe.}:
      withLock appState.lock:
        allowed = playerJoinAllowed(slot, token)
    if not allowed:
      request.respondPlain(403, "player token rejected\n")
      return
    let websocket = request.upgradeToWebSocket()
    {.gcsafe.}:
      withLock appState.lock:
        appState.playerViewers[websocket] = PlayerViewerState()
        appState.playerIndices[websocket] = UnassignedPlayerIndex
        appState.playerNames[websocket] = name
        appState.playerSlots[websocket] = resolveJoinSlot(slot, token)
        appState.inputMasks[websocket] = 0
        appState.lastAppliedMasks[websocket] = 0
  elif request.path.isGlobalSocketPath() and
      request.httpMethod == "GET" and request.isWebSocketUpgrade():
    let websocket = request.upgradeToWebSocket()
    {.gcsafe.}:
      withLock appState.lock:
        appState.globalViewers[websocket] = initGlobalViewerState()
  elif request.serveClientRoute(GlobalClientRoute):
    discard
  else:
    request.respondPlain(200, "Jumper sprite protocol server")

proc websocketHandler(
  websocket: WebSocket,
  event: WebSocketEvent,
  message: Message
) =
  case event
  of OpenEvent:
    discard
  of MessageEvent:
    if message.kind == BinaryMessage:
      {.gcsafe.}:
        withLock appState.lock:
          if websocket in appState.globalViewers:
            var state = appState.globalViewers[websocket]
            state.applyGlobalViewerMessage(message.data)
            appState.globalViewers[websocket] = state
          if websocket in appState.replayViewers:
            var state = appState.replayViewers[websocket]
            state.applyGlobalViewerMessage(message.data)
            appState.replayViewers[websocket] = state
          if appState.replayServerMode and (
              websocket in appState.replayViewers or
              websocket in appState.globalViewers
            ):
            websocket.applyReplayViewerMessage(message.data)
    if message.kind == BinaryMessage and message.data.len == 2 and
        (
          message.data[0].uint8 == PacketInput or
          message.data[0].uint8 == 0x84'u8
        ):
      {.gcsafe.}:
        withLock appState.lock:
          if websocket in appState.playerViewers:
            appState.inputMasks[websocket] = message.data[1].uint8 and 0x7f'u8
    let chatText = message.playerChatFromMessage().cleanChatMessage()
    if chatText.len > 0:
      {.gcsafe.}:
        withLock appState.lock:
          if websocket in appState.playerViewers:
            appState.chatMessages[websocket] = chatText
  of ErrorEvent:
    discard
  of CloseEvent:
    {.gcsafe.}:
      withLock appState.lock:
        appState.closedSockets.add(websocket)

proc serverThreadProc(args: ServerThreadArgs) {.thread.} =
  args.server[].serve(Port(args.port), args.address)

proc runFrameLimiter(previousTick: var MonoTime) =
  let frameDuration = initDuration(milliseconds = int(1000.0 / TargetFps))
  let elapsed = getMonoTime() - previousTick
  if elapsed < frameDuration:
    sleep(int((frameDuration - elapsed).inMilliseconds))
  previousTick = getMonoTime()

proc runServerLoop*(
  host = DefaultHost,
  port = DefaultPort,
  seed = DefaultSeed,
  maxTicks = DefaultMaxTicks,
  maxGames = DefaultMaxGames,
  tokens: seq[string] = @[],
  saveReplayPath = "",
  runtimeConfig = RuntimeConfig()
) =
  initAppState()
  appState.tokens = tokens
  var replayWriter = openReplayWriter(
    saveReplayPath,
    $(%*{
      "seed": seed,
      "maxTicks": maxTicks,
      "maxGames": maxGames,
      "tokenCount": tokens.len
    })
  )
  let httpServer = newServer(
    httpHandler,
    websocketHandler,
    workerThreads = 4,
    tcpNoDelay = true
  )
  var serverThread: Thread[ServerThreadArgs]
  var serverPtr = cast[ptr Server](unsafeAddr httpServer)
  createThread(
    serverThread,
    serverThreadProc,
    ServerThreadArgs(server: serverPtr, address: host, port: port)
  )
  httpServer.waitUntilReady()

  var
    sim = initSimServer(seed)
    lastTick = getMonoTime()
    runTicks = 0
    gamesFinished = 0

  while true:
    var
      sockets: seq[WebSocket] = @[]
      playerIndices: seq[int] = @[]
      playerStates: seq[PlayerViewerState] = @[]
      globalSockets: seq[WebSocket] = @[]
      globalStates: seq[PlayerViewerState] = @[]
      inputs: seq[InputState]

    {.gcsafe.}:
      withLock appState.lock:
        for websocket in appState.closedSockets:
          if replayWriter.enabled and websocket in appState.playerIndices:
            let playerIndex = appState.playerIndices[websocket]
            if playerIndex >= 0 and playerIndex < sim.players.len:
              replayWriter.writeLeave(tickTime(sim.tickCount), playerIndex)
              if playerIndex < replayWriter.lastMasks.len:
                replayWriter.lastMasks.delete(playerIndex)
          sim.removePlayer(websocket)
        appState.closedSockets.setLen(0)

        for websocket in appState.playerIndices.keys:
          if appState.playerIndices[websocket] == UnassignedPlayerIndex:
            let playerIndex = sim.addPlayer(
              appState.playerNames.getOrDefault(websocket, ""),
              appState.playerSlots.getOrDefault(websocket, -1)
            )
            appState.playerIndices[websocket] = playerIndex
            if replayWriter.enabled:
              replayWriter.writeJoin(
                tickTime(sim.tickCount),
                playerIndex,
                appState.playerNames.getOrDefault(websocket, ""),
                sim.players[playerIndex].slot,
                ""
              )
              while replayWriter.lastMasks.len < sim.players.len:
                replayWriter.lastMasks.add(0)

        inputs = newSeq[InputState](sim.players.len)
        for websocket, playerIndex in appState.playerIndices.pairs:
          sockets.add(websocket)
          playerIndices.add(playerIndex)
          playerStates.add(
            appState.playerViewers.getOrDefault(
              websocket,
              PlayerViewerState()
            )
          )
          if playerIndex < 0 or playerIndex >= inputs.len:
            continue
          let currentMask = appState.inputMasks.getOrDefault(websocket, 0)
          let previousMask = appState.lastAppliedMasks.getOrDefault(
            websocket,
            0
          )
          inputs[playerIndex] = inputStateFromMasks(currentMask, previousMask)
          appState.lastAppliedMasks[websocket] = currentMask
          replayWriter.writeInputMaskChange(
            tickTime(sim.tickCount),
            playerIndex,
            currentMask
          )
          let chatText = appState.chatMessages.getOrDefault(websocket, "")
          if chatText.len > 0:
            sim.players[playerIndex].message = chatText
            sim.players[playerIndex].messageTicks = ChatLifetimeTicks
            replayWriter.writeChat(
              tickTime(sim.tickCount),
              playerIndex,
              chatText
            )
            appState.chatMessages.del(websocket)

        for websocket, state in appState.globalViewers.pairs:
          globalSockets.add(websocket)
          globalStates.add(state)

    sim.step(inputs)
    replayWriter.writeHash(uint32(sim.tickCount), sim.gameHash())
    inc runTicks

    for i in 0 ..< sockets.len:
      var nextState: PlayerViewerState
      let packet = sim.buildSpriteProtocolPlayerUpdates(
        playerIndices[i],
        playerStates[i],
        nextState
      )
      try:
        sockets[i].send(blobFromBytes(packet), BinaryMessage)
        {.gcsafe.}:
          withLock appState.lock:
            if sockets[i] in appState.playerViewers:
              appState.playerViewers[sockets[i]] = nextState
      except:
        {.gcsafe.}:
          withLock appState.lock:
            sim.removePlayer(sockets[i])

    for i in 0 ..< globalSockets.len:
      var nextState: PlayerViewerState
      let packet = sim.buildSpriteProtocolGlobalUpdates(
        globalStates[i],
        nextState
      )
      try:
        globalSockets[i].send(blobFromBytes(packet), BinaryMessage)
        {.gcsafe.}:
          withLock appState.lock:
            if globalSockets[i] in appState.globalViewers:
              appState.globalViewers[globalSockets[i]] = nextState
      except:
        {.gcsafe.}:
          withLock appState.lock:
            sim.removePlayer(globalSockets[i])

    if maxTicks > 0 and runTicks >= maxTicks:
      if replayWriter.enabled:
        # Only the first game of a run is recorded and uploaded.
        replayWriter.closeReplayWriter()
        if fileExists(saveReplayPath):
          echo "Replay written: ", saveReplayPath,
            " (", getFileSize(saveReplayPath), " bytes)"
          runtimeConfig.writeReplay(readFile(saveReplayPath))
      inc gamesFinished
      if maxGames > 0 and gamesFinished >= maxGames:
        runtimeConfig.writeResults(sim.resultsJson(tokens.len) & "\n")
        quit(0)
      sim = initSimServer(seed + gamesFinished)
      runTicks = 0
      {.gcsafe.}:
        withLock appState.lock:
          resetConnectedPlayers()

    runFrameLimiter(lastTick)

proc readConfigInt(node: JsonNode, name: string, value: var int) =
  ## Reads one optional integer config field.
  if not node.hasKey(name):
    return
  let item = node[name]
  if item.kind != JInt:
    raise newException(
      ValueError,
      "Config field " & name & " must be an integer."
    )
  value = item.getInt()

proc readConfigStrings(node: JsonNode, name: string, value: var seq[string]) =
  ## Reads one optional string array config field.
  if not node.hasKey(name):
    return
  let item = node[name]
  if item.kind != JArray:
    raise newException(
      ValueError,
      "Config field " & name & " must be an array."
    )
  value.setLen(0)
  for child in item.items:
    if child.kind != JString:
      raise newException(
        ValueError,
        "Config field " & name & " items must be strings."
      )
    value.add(child.getStr())

proc update(config: var RunConfig, jsonText: string) =
  ## Updates the run config from a JSON object.
  if jsonText.len == 0:
    return
  var node: JsonNode
  try:
    node = fromJson(jsonText)
  except jsony.JsonError as e:
    raise newException(ValueError, "Could not parse config JSON: " & e.msg)
  if node.kind != JObject:
    raise newException(ValueError, "Config must be a JSON object.")
  node.readConfigInt("seed", config.seed)
  node.readConfigInt("maxTicks", config.maxTicks)
  node.readConfigInt("max-ticks", config.maxTicks)
  node.readConfigInt("maxGames", config.maxGames)
  node.readConfigInt("max-games", config.maxGames)
  node.readConfigStrings("tokens", config.tokens)

proc replayRunSeed(data: ReplayData): int =
  ## Returns the recorded game seed for one replay.
  result = DefaultSeed
  if data.configJson.len == 0:
    return
  var node: JsonNode
  try:
    node = fromJson(data.configJson)
  except jsony.JsonError:
    return
  if node.kind == JObject and node.hasKey("seed") and
      node["seed"].kind == JInt:
    result = node["seed"].getInt()

proc runReplayServerLoop*(
  host = DefaultHost,
  port = DefaultPort,
  runtimeConfig = RuntimeConfig()
) =
  ## Serves recorded Jumper replays to replay and global viewers.
  initAppState()
  appState.replayServerMode = true

  var
    replayData = ReplayData()
    replaySeed = DefaultSeed
    replayLoaded = false
  if runtimeConfig.replay.len > 0:
    replayData = parseReplayBytes(runtimeConfig.replay)
    replaySeed = replayData.replayRunSeed()
    replayLoaded = true
  appState.replayLoaded = replayLoaded

  let httpServer = newServer(
    httpHandler,
    websocketHandler,
    workerThreads = 4,
    tcpNoDelay = true
  )
  var serverThread: Thread[ServerThreadArgs]
  var serverPtr = cast[ptr Server](unsafeAddr httpServer)
  createThread(
    serverThread,
    serverThreadProc,
    ServerThreadArgs(server: serverPtr, address: host, port: port)
  )
  httpServer.waitUntilReady()

  var
    sim = initSimServer(replaySeed)
    replay =
      if replayLoaded:
        initReplayPlayer(replayData)
      else:
        ReplayPlayer()
    lastTick = getMonoTime()
  if replayLoaded:
    replay.buildReplayKeyframes(initSimServer(replaySeed))
    {.gcsafe.}:
      withLock appState.lock:
        appState.replayMaxTick = replay.replayMaxTick()

  while true:
    var
      pendingReplayUri = ""
      commands: seq[char] = @[]
      seekTicks: seq[int] = @[]
      viewerSockets: seq[WebSocket] = @[]
      viewerStates: seq[PlayerViewerState] = @[]
      viewerIsReplay: seq[bool] = @[]

    {.gcsafe.}:
      withLock appState.lock:
        pendingReplayUri = appState.pendingReplayUri
        appState.pendingReplayUri = ""
        for websocket in appState.closedSockets:
          sim.removePlayer(websocket)
        appState.closedSockets.setLen(0)
        commands = appState.replayCommands
        appState.replayCommands.setLen(0)
        seekTicks = appState.replaySeekTicks
        appState.replaySeekTicks.setLen(0)

    if pendingReplayUri.len > 0:
      try:
        replayData = loadReplayUri(pendingReplayUri)
        replaySeed = replayData.replayRunSeed()
        sim = initSimServer(replaySeed)
        replay = initReplayPlayer(replayData)
        replay.buildReplayKeyframes(initSimServer(replaySeed))
        replayLoaded = true
        {.gcsafe.}:
          withLock appState.lock:
            appState.replayLoaded = true
            appState.replayMaxTick = replay.replayMaxTick()
      except CatchableError as e:
        echo "Could not load replay uri: ", e.msg

    {.gcsafe.}:
      withLock appState.lock:
        for websocket, state in appState.replayViewers.pairs:
          viewerSockets.add(websocket)
          viewerStates.add(state)
          viewerIsReplay.add(true)
        for websocket, state in appState.globalViewers.pairs:
          viewerSockets.add(websocket)
          viewerStates.add(state)
          viewerIsReplay.add(false)

    if replayLoaded:
      for tick in seekTicks:
        replay.applyReplaySeek(sim, replaySeed, tick)
      for command in commands:
        replay.applyReplayCommand(sim, replaySeed, command)
      if replay.playing:
        for _ in 0 ..< replay.replaySpeed():
          if replay.playing:
            replay.stepReplay(sim)
        if not replay.playing and replay.looping and
            replay.replayMaxTick() > 0:
          sim = initSimServer(replaySeed)
          replay.resetReplay()
          replay.playing = true

    for i in 0 ..< viewerSockets.len:
      var nextState: PlayerViewerState
      var packet = sim.buildSpriteProtocolGlobalUpdates(
        viewerStates[i],
        nextState
      )
      if replayLoaded:
        packet.addReplayControls(sim, nextState.spriteCache, replay)
      try:
        viewerSockets[i].send(blobFromBytes(packet), BinaryMessage)
        {.gcsafe.}:
          withLock appState.lock:
            if viewerIsReplay[i]:
              if viewerSockets[i] in appState.replayViewers:
                appState.replayViewers[viewerSockets[i]] = nextState
            elif viewerSockets[i] in appState.globalViewers:
              appState.globalViewers[viewerSockets[i]] = nextState
      except CatchableError:
        {.gcsafe.}:
          withLock appState.lock:
            sim.removePlayer(viewerSockets[i])

    runFrameLimiter(lastTick)

proc limitText(value: int): string =
  ## Returns a readable text value for a numeric limit.
  if value > 0:
    $value
  else:
    "infinite"

proc echoStartupConfig(config: RunConfig) =
  ## Prints the effective startup config without token secrets.
  echo "Jumper config: host=", config.address,
    " port=", config.port,
    " seed=", config.seed,
    " tokens=", config.tokens.len,
    " maxTicks=", config.maxTicks.limitText(),
    " maxGames=", config.maxGames.limitText()

when isMainModule:
  let runtimeConfig = readRuntimeConfig()
  var
    config = RunConfig(
      address: runtimeConfig.host,
      port: runtimeConfig.port,
      seed: DefaultSeed,
      maxTicks: DefaultMaxTicks,
      maxGames: DefaultMaxGames,
      tokens: @[]
    )
  config.update(runtimeConfig.config)
  config.echoStartupConfig()
  if runtimeConfig.replayMode:
    runReplayServerLoop(config.address, config.port, runtimeConfig)
    quit(0)
  let localReplayPath =
    if runtimeConfig.replayUri.len > 0:
      getTempDir() / ("jumper-replay-" & $getCurrentProcessId() &
        ".bitreplay")
    else:
      ""
  runServerLoop(
    config.address,
    config.port,
    seed = config.seed,
    maxTicks = config.maxTicks,
    maxGames = config.maxGames,
    tokens = config.tokens,
    saveReplayPath = localReplayPath,
    runtimeConfig = runtimeConfig
  )
