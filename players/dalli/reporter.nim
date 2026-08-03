## Reporter: hooks the sprite renderer stream and narrates it as text.
##
## The reporter receives every server render packet (the same bytes the
## bot decodes) and prints lines a human or an LLM can read:
##   - static sprites (environment: sky, terrain tiles, sprite art)
##     are reported once, when first seen
##   - dynamic sprites (players, name tags, chat bubbles, HUD text)
##     are reported every frame (mode all, the default), or only when
##     their state changes (mode changes)
## Denoising built into every mode: object positions are converted from
## screen space to world space using the inferred camera offset, so a
## standing player reads as standing even while the viewport scrolls,
## and text sprites (chat, names, score) are only echoed when their
## content changes.
##
## On top of the raw object stream the reporter narrates per-player
## state transitions, one line per player per frame, only on change:
##   f=210 lf0: moving right          (horizontal velocity direction)
##   f=214 lf0: jumping               (vertical: rising)
##   f=221 lf0: falling               (vertical: dropping)
##   f=228 lf0: on ground             (support: landed on terrain)
##   f=240 d2: on top of lf0          (support: standing on a player)
##   f=252 lf0: at wall on right      (contact: pinned against a wall)
##   f=260 d2: died (fell at x=896)   (vanished from the render)
##   f=308 d2: respawned at (128,441) (reappeared after death)
##   f=310 lf0: reached the flag! ... (instant move away from the flag)
## Players are named from their name tag sprites when known.
##
## As tiles come into view the reporter also narrates the terrain,
## each feature once (described walking left to right):
##   f=90 terrain: step up 1 tile (32px) at x=512, 96px to the right
##   f=95 terrain: wall 3 tiles (96px) tall at x=1280, 200px to the right
##   f=99 terrain: drop 2 tiles (64px) at x=896, 64px to the left
##   f=101 terrain: hole 2 tiles (64px) wide, 2 tiles (64px) deep at x=896..959, 33px to the right
##   f=120 terrain: pit (bottomless) 4 tiles (128px) wide at x=1600..1727, 310px to the right
## Distances are measured from our own player (the one the camera
## follows). A pit is only reported when every cell from the approach
## height down to the level floor is known to be empty; a partially
## seen gap stays silent instead of guessing.

import std/[algorithm, sequtils, sets, strutils, tables]

const
  # World geometry (mirrors src/jumper.nim).
  WorldTileSize = 32
  LevelWidthTiles = 64
  LevelHeightTiles = 16
  SkyObjectId = 1
  TileObjectBase = 1000
  PlayerObjectBase = 5000
  TiledSpriteBase = 300
  NameSpriteBase = 10000
  FlagGid = 15
  SeesawGid = 54
  SignGid = 60
  PlayerSpriteOffsetX = 6
  PlayerSpriteOffsetY = 9
  PlayerBoxWidth = 20
  PlayerBoxHeight = 23
  DefaultViewportWidth = 320
  DefaultViewportHeight = 200
  MapLayerId = 0
  # Event tracking tuning.
  WallContactPixels = 6       ## solid this close to a side = wall contact
  CarrierSideTolerance = 24   ## x center offset for on-top-of detection
  CarrierGapMin = -6          ## feet-to-head gap window
  CarrierGapMax = 12
  TeleportPixels = 64         ## larger per-frame moves read as a respawn
  # Terrain narration tuning.
  MaxHoleTiles = 4            ## wider depressions read as drop + wall
  StepMaxTiles = 2            ## rises above this many tiles read as walls

type
  ReportMode* = enum
    rmAll      ## dynamic objects: one line every frame
    rmChanges  ## dynamic objects: one line only when their state changes
    rmEvents   ## per-player state transitions only

  HorizontalMotion = enum
    hmUnknown, hmStill, hmLeft, hmRight

  VerticalMotion = enum
    vmUnknown, vmLevel, vmJumping, vmFalling

  Support = enum
    supUnknown, supAir, supGround, supPlayer

  WallSide = enum
    wsNone, wsLeft, wsRight

  PlayerTrack = object
    seen: bool               ## visible this frame
    worldX, worldY: int      ## collision box top-left, world space
    hadPosition: bool        ## worldX/worldY valid from a prior frame
    dead: bool               ## vanished from render, awaiting respawn
    horizontal: HorizontalMotion
    vertical: VerticalMotion
    support: Support
    supportPlayer: int       ## player index we stand on (supPlayer)
    wall: WallSide

  SpriteDef = object
    width, height: int
    label: string

  ObjectState = object
    x, y: int
    spriteId: int

  TileState = enum
    tsUnknown, tsSolid, tsEmpty

  Reporter* = object
    enabled*: bool
    mode*: ReportMode
    output: File
    ownsFile: bool
    frame: int
    cameraKnown: bool
    cameraX, cameraY: int
    viewWidth, viewHeight: int
    sprites: Table[int, SpriteDef]
    objects: Table[int, ObjectState]
    staticSeen: HashSet[int]        ## static object ids already reported
    lastDynamic: Table[int, string] ## object id -> last reported line body
    tracks: Table[int, PlayerTrack] ## player index -> tracked state
    playerNames: Table[int, string] ## player index -> name tag text
    tiles: array[LevelWidthTiles, array[LevelHeightTiles, TileState]]
    terrainReported: HashSet[string] ## feature keys already narrated
    flagTiles: HashSet[int]          ## tile indices holding a goal flag

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

proc initReporter*(target: string, mode = rmAll): Reporter =
  ## Opens a reporter. `target` is a file path, "-" for stdout, or ""
  ## for a disabled reporter that ignores every packet.
  result.mode = mode
  result.viewWidth = DefaultViewportWidth
  result.viewHeight = DefaultViewportHeight
  if target.len == 0:
    return
  result.enabled = true
  if target == "-":
    result.output = stdout
  else:
    result.output = open(target, fmWrite)
    result.ownsFile = true

proc close*(rep: var Reporter) =
  ## Closes the reporter output file when the reporter owns it.
  if rep.ownsFile:
    rep.output.close()
    rep.ownsFile = false
  rep.enabled = false

proc isTileObjectId(id: int): bool =
  ## Returns true when an object id belongs to a Tiled map cell.
  id >= TileObjectBase and
    id < TileObjectBase + LevelWidthTiles * LevelHeightTiles

proc isStaticObjectId(id: int): bool =
  ## Static objects are the environment: reported once, then silent.
  id == SkyObjectId or id.isTileObjectId()

proc isStaticSpriteLabel(label: string): bool =
  ## Static sprite definitions are art assets: tile cells, player
  ## frames, radar dots, the sky. Everything else (chat bubbles, name
  ## tags, HUD text) carries game state in its label and is dynamic.
  label == "sky" or
    label.startsWith("tile ") or
    label.startsWith("player ") or
    label.startsWith("radar ") or
    label.startsWith("debug ")

proc emit(rep: var Reporter, line: string) =
  ## Prints one report line.
  rep.output.writeLine(line)

proc updateCamera(rep: var Reporter) =
  ## Infers the camera offset from any visible tile object.
  for id, item in rep.objects.pairs:
    if not id.isTileObjectId():
      continue
    let index = id - TileObjectBase
    rep.cameraX = (index mod LevelWidthTiles) * WorldTileSize - item.x
    rep.cameraY = (index div LevelWidthTiles) * WorldTileSize - item.y
    rep.cameraKnown = true
    return
  rep.cameraKnown = false

proc reportStaticObject(rep: var Reporter, id: int, item: ObjectState) =
  ## Reports one environment object the first time it becomes visible.
  if id in rep.staticSeen:
    return
  rep.staticSeen.incl(id)
  if id == SkyObjectId:
    rep.emit("static sky")
    return
  let
    index = id - TileObjectBase
    tx = index mod LevelWidthTiles
    ty = index div LevelWidthTiles
    gid = item.spriteId - TiledSpriteBase
    label = rep.sprites.getOrDefault(item.spriteId).label
  if gid == FlagGid:
    rep.flagTiles.incl(index)
    rep.emit("f=" & $rep.frame & " terrain: goal flag at x=" &
      $(tx * WorldTileSize) & " (cell " & $tx & "," & $ty & ")")
  rep.emit("static tile cell=(" & $tx & "," & $ty & ") world=(" &
    $(tx * WorldTileSize) & "," & $(ty * WorldTileSize) & ") gid=" &
    $gid & " \"" & label & "\"")

proc reportSpriteDef(rep: var Reporter, id: int, def: SpriteDef) =
  ## Reports sprite definitions: static art once, text content on change.
  if id >= NameSpriteBase and id < NameSpriteBase + 256 and
      def.label.startsWith("name "):
    rep.playerNames[id - NameSpriteBase] = def.label[5 .. ^1]
  let known = id in rep.sprites
  if def.label.isStaticSpriteLabel():
    if not known:
      rep.emit("static sprite id=" & $id & " " & $def.width & "x" &
        $def.height & " \"" & def.label & "\"")
  elif not known or rep.sprites[id].label != def.label:
    # Chat bubbles, name tags, and HUD text redefine their sprite when
    # the text changes: the label change IS the game event.
    rep.emit("f=" & $rep.frame & " text id=" & $id & " \"" &
      def.label & "\"")
  rep.sprites[id] = def

# ---- per-player state transitions -------------------------------------------

proc playerName(rep: Reporter, index: int): string =
  ## Returns the display name for one player index.
  rep.playerNames.getOrDefault(index, "player " & $index)

proc solidAt(rep: Reporter, worldX, worldY: int): bool =
  ## Returns true when a world pixel is inside visible solid terrain.
  if worldX < 0 or worldY < 0:
    return false
  let
    tx = worldX div WorldTileSize
    ty = worldY div WorldTileSize
  if tx >= LevelWidthTiles or ty >= LevelHeightTiles:
    return false
  let id = TileObjectBase + ty * LevelWidthTiles + tx
  if id notin rep.objects:
    return false
  let gid = rep.objects[id].spriteId - TiledSpriteBase
  gid > 0 and gid != FlagGid and gid != SeesawGid and gid != SignGid

proc onGround(rep: Reporter, track: PlayerTrack): bool =
  ## Returns true when a player box rests on solid terrain.
  let footY = track.worldY + PlayerBoxHeight + 1
  var x = track.worldX + 2
  while x <= track.worldX + PlayerBoxWidth - 2:
    if rep.solidAt(x, footY) or rep.solidAt(x, footY + 2):
      return true
    x += 2
  false

proc playerBelow(rep: Reporter, index: int): int =
  ## Returns the index of the player this one stands on, or -1.
  let track = rep.tracks[index]
  for otherIndex, other in rep.tracks.pairs:
    if otherIndex == index or not other.seen:
      continue
    let
      dx = abs((other.worldX + PlayerBoxWidth div 2) -
        (track.worldX + PlayerBoxWidth div 2))
      gap = other.worldY - (track.worldY + PlayerBoxHeight)
    if dx <= CarrierSideTolerance and
        gap >= CarrierGapMin and gap <= CarrierGapMax:
      return otherIndex
  -1

proc wallContact(rep: Reporter, track: PlayerTrack): WallSide =
  ## Returns which side of the player touches solid terrain, if any.
  var y = track.worldY + 4
  while y <= track.worldY + PlayerBoxHeight - 2:
    if rep.solidAt(track.worldX + PlayerBoxWidth + WallContactPixels, y):
      return wsRight
    if rep.solidAt(track.worldX - WallContactPixels, y):
      return wsLeft
    y += 2

proc trackEvent(rep: var Reporter, index: int, what: string) =
  ## Prints one player state transition line.
  rep.emit("f=" & $rep.frame & " " & rep.playerName(index) & ": " & what)

# ---- terrain narration -------------------------------------------------------

proc isSolidGid(gid: int): bool =
  ## Returns true when a Tiled gid blocks players.
  gid > 0 and gid != FlagGid and gid != SeesawGid and gid != SignGid

proc updateTerrain(rep: var Reporter) =
  ## Learns tile states from the camera window of the frame just
  ## parsed. Every cell inside the window is knowable: solid cells
  ## arrive as objects, cells without an object are empty. Tiles are
  ## static, so knowledge accumulates across frames.
  let
    startTx = max(0, rep.cameraX div WorldTileSize)
    startTy = max(0, rep.cameraY div WorldTileSize)
    endTx = min(
      LevelWidthTiles - 1,
      (rep.cameraX + rep.viewWidth - 1) div WorldTileSize
    )
    endTy = min(
      LevelHeightTiles - 1,
      (rep.cameraY + rep.viewHeight - 1) div WorldTileSize
    )
  for tx in startTx .. endTx:
    for ty in startTy .. endTy:
      let id = TileObjectBase + ty * LevelWidthTiles + tx
      if id in rep.objects:
        let gid = rep.objects[id].spriteId - TiledSpriteBase
        rep.tiles[tx][ty] = if gid.isSolidGid(): tsSolid else: tsEmpty
      else:
        rep.tiles[tx][ty] = tsEmpty

proc surfaceRow(rep: Reporter, tx: int): int =
  ## Returns the confirmed walkable surface row for one column: the
  ## first known solid cell (scanning down) whose cell above is known
  ## empty. Rows above the camera window stay unknown and are skipped:
  ## the surface only needs air directly above it. Returns -1 when the
  ## surface is not confirmed yet, and LevelHeightTiles when the whole
  ## column is known empty (floorless).
  var sawUnknown = false
  for ty in 0 ..< LevelHeightTiles:
    case rep.tiles[tx][ty]
    of tsSolid:
      if ty > 0 and rep.tiles[tx][ty - 1] == tsEmpty:
        return ty
      return -1  # solid with unknown above: true top not confirmed
    of tsUnknown:
      sawUnknown = true
    of tsEmpty:
      discard
  if sawUnknown: -1 else: LevelHeightTiles

proc pixels(tiles: int): string =
  ## Formats one tile count with its pixel size.
  let unit = if tiles == 1: " tile (" else: " tiles ("
  $tiles & unit & $(tiles * WorldTileSize) & "px)"

proc ownWorldX(rep: Reporter): int =
  ## Returns our own player's box center x, or -1 when unknown. The
  ## server centers the camera on us, so the tracked player closest to
  ## the camera center is ours.
  let center = rep.cameraX + rep.viewWidth div 2
  var best = -1
  var bestDist = high(int)
  for track in rep.tracks.values:
    if not track.seen or not track.hadPosition:
      continue
    let
      boxCenter = track.worldX + PlayerBoxWidth div 2
      dist = abs(boxCenter - center)
    if dist < bestDist:
      bestDist = dist
      best = boxCenter
  best

proc distancePhrase(rep: Reporter, featureX: int): string =
  ## Describes how far one feature is from our own player.
  let own = rep.ownWorldX()
  if own < 0:
    return ""
  let dx = featureX - own
  if dx > 0:
    ", " & $dx & "px to the right"
  elif dx < 0:
    ", " & $(-dx) & "px to the left"
  else:
    ", right here"

proc terrainEvent(rep: var Reporter, key, what: string, featureX: int) =
  ## Prints one terrain feature line the first time it is confirmed.
  if key in rep.terrainReported:
    return
  rep.terrainReported.incl(key)
  rep.emit("f=" & $rep.frame & " terrain: " & what &
    rep.distancePhrase(featureX))

proc narrowGapEnd(rep: Reporter, startTx, approachRow: int): int =
  ## Scans right from one confirmed drop for the column where the
  ## surface comes back up to the approach height. Returns that column,
  ## or -1 when the gap is wider than a hole, runs off the level, or
  ## crosses a column whose surface is not confirmed yet.
  for tx in startTx .. min(startTx + MaxHoleTiles, LevelWidthTiles - 1):
    let row = rep.surfaceRow(tx)
    if row < 0:
      return -1
    if row <= approachRow:
      return tx
  -1

proc confirmedPit(rep: Reporter, tx, approachRow: int): bool =
  ## Returns true when one column is known empty from the approach
  ## height all the way past the level floor (a fall means death).
  ## Cells above the approach height may stay unknown (the camera
  ## never looks that high); a walker falls through this column
  ## regardless of what is up there.
  for ty in max(0, approachRow) ..< LevelHeightTiles:
    if rep.tiles[tx][ty] != tsEmpty:
      return false
  true

proc hasLandingBelow(rep: Reporter, tx, fromRow: int): bool =
  ## Returns true when one column has known solid ground at or below
  ## one approach height (a walker falling in could land).
  for ty in max(0, fromRow) ..< LevelHeightTiles:
    if rep.tiles[tx][ty] == tsSolid:
      return true
  false

proc detectTerrain(rep: var Reporter) =
  ## Narrates terrain features between confirmed surface columns,
  ## walking the level left to right. Each feature is reported once.
  ## Changes that cannot be classified yet (surfaces or gap floors not
  ## seen) stay silent until a later frame confirms them.
  for tx in 0 ..< LevelWidthTiles - 1:
    let hLeft = rep.surfaceRow(tx)
    if hLeft < 0 or hLeft == LevelHeightTiles:
      continue
    let boundaryX = (tx + 1) * WorldTileSize

    # Bottomless pit first: it only needs cells below the approach
    # height, so it must not wait for a confirmed right-side surface
    # (the sky rows of a floorless column are never all seen).
    if rep.confirmedPit(tx + 1, hLeft):
      # Measure the full span of floorless columns.
      var endTx = tx + 1
      while endTx + 1 < LevelWidthTiles and
          rep.confirmedPit(endTx + 1, hLeft):
        inc endTx
      # Only report once the far rim is confirmed landable, so the
      # width is final.
      if endTx + 1 < LevelWidthTiles and
          rep.hasLandingBelow(endTx + 1, hLeft):
        rep.terrainEvent("pit:" & $tx, "pit (bottomless) " &
          pixels(endTx - tx) & " wide at x=" & $boundaryX & ".." &
          $((endTx + 1) * WorldTileSize - 1), boundaryX)
      continue

    let hRight = rep.surfaceRow(tx + 1)
    if hRight < 0:
      continue

    if hRight < hLeft:
      # Ground rises to the right.
      let rise = hLeft - hRight
      if rise <= StepMaxTiles:
        rep.terrainEvent("step:" & $tx, "step up " & pixels(rise) &
          " at x=" & $boundaryX, boundaryX)
      else:
        rep.terrainEvent("wall:" & $tx, "wall " & pixels(rise) &
          " tall at x=" & $boundaryX, boundaryX)
      continue

    if hRight > hLeft:
      # Ground falls away to the right: hole or drop.
      if hRight == LevelHeightTiles:
        continue  # column known empty but rims unclear; stay silent
      let backUp = rep.narrowGapEnd(tx + 1, hLeft)
      if backUp > 0:
        # Narrow depression that climbs back out: a hole.
        var deepest = hRight
        for gapTx in tx + 1 ..< backUp:
          let row = rep.surfaceRow(gapTx)
          if row > deepest and row < LevelHeightTiles:
            deepest = row
        rep.terrainEvent("hole:" & $tx, "hole " &
          pixels(backUp - tx - 1) & " wide, " &
          pixels(deepest - hLeft) & " deep at x=" & $boundaryX & ".." &
          $(backUp * WorldTileSize - 1), boundaryX)
      else:
        # Make sure it is a lasting drop, not an unconfirmed hole:
        # every column a hole could span must be confirmed lower.
        var lastingDrop = true
        for gapTx in tx + 1 .. min(tx + MaxHoleTiles, LevelWidthTiles - 1):
          let row = rep.surfaceRow(gapTx)
          if row < 0 or row <= hLeft:
            lastingDrop = false
            break
        if lastingDrop:
          rep.terrainEvent("drop:" & $tx, "drop " &
            pixels(hRight - hLeft) & " at x=" & $boundaryX, boundaryX)

proc nearFlag(rep: Reporter, track: PlayerTrack): bool =
  ## Returns true when a player box is within one frame's travel of a
  ## goal flag tile (the server respawns scorers the instant they
  ## touch the flag, so the render never shows the actual overlap).
  const Reach = 24
  for index in rep.flagTiles:
    let
      flagX = (index mod LevelWidthTiles) * WorldTileSize
      flagY = (index div LevelWidthTiles) * WorldTileSize
    if track.worldX + PlayerBoxWidth + Reach >= flagX and
        track.worldX <= flagX + WorldTileSize + Reach and
        track.worldY + PlayerBoxHeight + Reach >= flagY and
        track.worldY <= flagY + WorldTileSize + Reach:
      return true

proc updateTracks(rep: var Reporter) =
  ## Derives per-player motion and contact states for the frame just
  ## parsed and narrates every transition.
  if not rep.cameraKnown:
    return

  # Refresh positions from visible player objects. Player objects are
  # never viewport-culled by the server, so absence means death.
  for track in rep.tracks.mvalues:
    track.seen = false
  for id, item in rep.objects.pairs:
    if id < PlayerObjectBase or id >= PlayerObjectBase + 256:
      continue
    let index = id - PlayerObjectBase
    var track = rep.tracks.getOrDefault(index)
    let
      worldX = rep.cameraX + item.x + PlayerSpriteOffsetX
      worldY = rep.cameraY + item.y + PlayerSpriteOffsetY
    if track.dead:
      track.dead = false
      track.hadPosition = false
      rep.trackEvent(index, "respawned at (" & $worldX & "," & $worldY & ")")
    if track.hadPosition and
        (abs(worldX - track.worldX) > TeleportPixels or
         abs(worldY - track.worldY) > TeleportPixels):
      # An instant long move is the goal respawn when it starts at the
      # flag; anything else is unexplained (mis-track, server nudge).
      if rep.nearFlag(track):
        rep.trackEvent(index, "reached the flag! scored, respawned at (" &
          $worldX & "," & $worldY & ")")
      else:
        rep.trackEvent(index, "teleported to (" & $worldX & "," & $worldY & ")")
      track.horizontal = hmUnknown
      track.vertical = vmUnknown
      track.support = supUnknown
      track.wall = wsNone
      track.hadPosition = false
    track.seen = true
    if not track.hadPosition:
      track.worldX = worldX
      track.worldY = worldY
      track.hadPosition = true
      rep.tracks[index] = track
      continue

    # Horizontal motion direction.
    let dx = worldX - track.worldX
    let horizontal =
      if dx > 0: hmRight
      elif dx < 0: hmLeft
      else: hmStill
    if horizontal != track.horizontal:
      case horizontal
      of hmRight: rep.trackEvent(index, "moving right")
      of hmLeft: rep.trackEvent(index, "moving left")
      of hmStill: rep.trackEvent(index, "stopped")
      of hmUnknown: discard
      track.horizontal = horizontal

    # Vertical motion direction. The one-frame level moment at a jump
    # apex is not a state: only rising and dropping are narrated, and
    # returning to level ground reads as a support change below.
    let dy = worldY - track.worldY
    let vertical =
      if dy < 0: vmJumping
      elif dy > 0: vmFalling
      else: vmLevel
    if vertical != track.vertical:
      case vertical
      of vmJumping: rep.trackEvent(index, "jumping")
      of vmFalling: rep.trackEvent(index, "falling")
      of vmLevel, vmUnknown: discard
      track.vertical = vertical

    track.worldX = worldX
    track.worldY = worldY
    rep.tracks[index] = track

  # A tracked player missing from the render is dead: the server
  # renders every living player regardless of camera, and skips dead
  # ones until their respawn timer fires (2s).
  for index in rep.tracks.keys.toSeq():
    var track = rep.tracks[index]
    if track.seen or track.dead or not track.hadPosition:
      continue
    track.dead = true
    track.horizontal = hmUnknown
    track.vertical = vmUnknown
    track.support = supUnknown
    track.wall = wsNone
    rep.trackEvent(index, "died (fell at x=" & $track.worldX & ")")
    rep.tracks[index] = track

  # Contact states need every position refreshed first.
  for index in rep.tracks.keys.toSeq():
    var track = rep.tracks[index]
    if not track.seen or not track.hadPosition:
      continue

    let below = rep.playerBelow(index)
    let support =
      if below >= 0: supPlayer
      elif rep.onGround(track): supGround
      else: supAir
    if support != track.support or
        (support == supPlayer and below != track.supportPlayer):
      case support
      of supGround: rep.trackEvent(index, "on ground")
      of supPlayer: rep.trackEvent(index,
        "on top of " & rep.playerName(below))
      of supAir, supUnknown: discard
      track.support = support
      track.supportPlayer = below

    let wall = rep.wallContact(track)
    if wall != track.wall:
      case wall
      of wsRight: rep.trackEvent(index, "at wall on right")
      of wsLeft: rep.trackEvent(index, "at wall on left")
      of wsNone: rep.trackEvent(index, "off wall")
      track.wall = wall

    rep.tracks[index] = track

proc dynamicBody(rep: Reporter, id: int, item: ObjectState): string =
  ## Builds the state description for one dynamic object.
  let label = rep.sprites.getOrDefault(item.spriteId).label
  result = "obj=" & $id
  if id >= PlayerObjectBase and id < PlayerObjectBase + 256:
    result.add(" player=" & $(id - PlayerObjectBase))
  result.add(" \"" & label & "\"")
  if rep.cameraKnown:
    result.add(" world=(" & $(rep.cameraX + item.x) & "," &
      $(rep.cameraY + item.y) & ")")
  else:
    result.add(" screen=(" & $item.x & "," & $item.y & ")")

proc reportFrame(rep: var Reporter) =
  ## Reports all dynamic objects for the frame just parsed.
  var ids: seq[int]
  for id in rep.objects.keys:
    if not id.isStaticObjectId():
      ids.add(id)
  ids.sort()

  case rep.mode
  of rmEvents:
    discard  # transitions are narrated by updateTracks
  of rmAll:
    var camera = "cam=?"
    if rep.cameraKnown:
      camera = "cam=(" & $rep.cameraX & "," & $rep.cameraY & ")"
    rep.emit("-- f=" & $rep.frame & " " & camera & " dynamic=" & $ids.len)
    for id in ids:
      rep.emit("f=" & $rep.frame & " " & rep.dynamicBody(id, rep.objects[id]))
  of rmChanges:
    var seen = initHashSet[int]()
    for id in ids:
      seen.incl(id)
      let body = rep.dynamicBody(id, rep.objects[id])
      if rep.lastDynamic.getOrDefault(id) != body:
        rep.emit("f=" & $rep.frame & " " & body)
        rep.lastDynamic[id] = body
    var gone: seq[int]
    for id in rep.lastDynamic.keys:
      if id notin seen:
        gone.add(id)
    gone.sort()
    for id in gone:
      rep.emit("f=" & $rep.frame & " gone obj=" & $id)
      rep.lastDynamic.del(id)

proc consume*(rep: var Reporter, packet: string) =
  ## Feeds one raw server render packet through the reporter.
  if not rep.enabled:
    return
  var
    offset = 0
    sawFrame = false
  while offset < packet.len:
    let messageType = packet[offset].uint8
    inc offset
    case messageType
    of 0x01:
      if offset + 10 > packet.len:
        return
      let
        id = packet.readU16(offset)
        width = packet.readU16(offset + 2)
        height = packet.readU16(offset + 4)
        compressedLen = packet.readU32(offset + 6)
      offset += 10
      if compressedLen < 0 or offset + compressedLen + 2 > packet.len:
        return
      offset += compressedLen
      let labelLen = packet.readU16(offset)
      offset += 2
      if offset + labelLen > packet.len:
        return
      let def = SpriteDef(
        width: width,
        height: height,
        label: packet[offset ..< offset + labelLen]
      )
      offset += labelLen
      rep.reportSpriteDef(id, def)
    of 0x02:
      if offset + 11 > packet.len:
        return
      let
        id = packet.readU16(offset)
        item = ObjectState(
          x: packet.readI16(offset + 2),
          y: packet.readI16(offset + 4),
          spriteId: packet.readU16(offset + 9)
        )
      offset += 11
      rep.objects[id] = item
      if id.isStaticObjectId():
        rep.reportStaticObject(id, item)
    of 0x03:
      if offset + 2 > packet.len:
        return
      rep.objects.del(packet.readU16(offset))
      offset += 2
    of 0x04:
      rep.objects.clear()
      sawFrame = true
      inc rep.frame
    of 0x05:
      if offset + 5 > packet.len:
        return
      if int(packet[offset].uint8) == MapLayerId:
        rep.viewWidth = packet.readU16(offset + 1)
        rep.viewHeight = packet.readU16(offset + 3)
      offset += 5
    of 0x06:
      if offset + 3 > packet.len:
        return
      offset += 3
    else:
      return
  if sawFrame:
    rep.updateCamera()
    rep.updateTracks()
    if rep.cameraKnown:
      rep.updateTerrain()
      rep.detectTerrain()
    rep.reportFrame()
    rep.output.flushFile()
