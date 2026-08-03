## Shared decision brain for the leapfrog Jumper bot.
## Consumes an abstract WorldView (own box position, grounded flag, and
## visible players) and produces an input mask. The same brain runs in
## two hosts: tools/simlab.nim feeds it from full sim state for fast
## iteration, and the websocket bot feeds it from the sprite protocol.
##
## Strategy, learned from league replays:
## - The map is static; the route is hardcoded with exact takeoff points
##   so we never fall into a pit.
## - Three walls (x23, x38, x57) are taller than the 91 px solo jump and
##   need a body to climb on. League bots bounce endlessly at wall
##   bases; we ride a bouncing head and jump at the apex ("elevator").
## - Our seats recognize each other by "jl<slot>" names. The lowest
##   slot present acts as the runner; higher slots are supports that
##   pin at choke walls as dedicated bouncing ladders.
## - At a wall, exactly one body should own the pocket (pin + bounce)
##   while others climb it. Between two of our bots the higher slot
##   pins; against strangers we wait briefly, then pin ourselves.

import std/strutils

const
  TileSize* = 32
  LevelWidthTiles* = 64
  LevelHeightTiles* = 16
  BoxW* = 20
  BoxH* = 23
  JumpRise* = 91          ## exact solo jump rise in px
  TeamPrefix* = "jl"

  ## Input mask bits (identical to bitworld spriteprotocol buttons:
  ## Left = bit 2, Right = bit 3, A/jump = bit 5).
  MaskLeft* = 1'u8 shl 2
  MaskRight* = 1'u8 shl 3
  MaskJump* = 1'u8 shl 5

# The forest map baked in at compile time from the Tiled export.
const ForestTmx = staticRead("../../data/forest.tmx")

proc parseForest(): array[LevelHeightTiles * LevelWidthTiles, bool] =
  ## Compile-time solid grid: every gid except air, flag, seesaw, sign.
  const Start = "<data encoding=\"csv\">"
  let
    a = ForestTmx.find(Start) + Start.len
    b = ForestTmx.find("</data>")
  var y = 0
  for line in ForestTmx[a ..< b].strip().splitLines():
    var x = 0
    for cell in line.strip().strip(chars = {','}).split(','):
      let gid = parseInt(cell.strip())
      result[y * LevelWidthTiles + x] =
        gid != 0 and gid != 15 and gid != 54 and gid != 60
      inc x
    inc y

const SolidGrid* = parseForest()

proc solidTile*(tx, ty: int): bool =
  if tx < 0 or tx >= LevelWidthTiles or ty < 0 or ty >= LevelHeightTiles:
    return false
  SolidGrid[ty * LevelWidthTiles + tx]

type
  Wall* = object
    left*: int         ## wall column left edge px
    topFeet*: int      ## feet y when standing on the wall top
    pocketX*: int      ## ladder box x pressed against the wall
    stageX*: int       ## climber staging x left of the pocket
    pinX*: int         ## where WE stand when serving as the ladder
    takeoffA*: int     ## pocket-approach pit takeoff window (front px)
    takeoffB*: int

  SeenPlayer* = object
    x*, y*: int        ## collision box top-left, world px
    name*: string

  WorldView* = object
    ownX*, ownY*: int
    grounded*: bool
    players*: seq[SeenPlayer]   ## other visible players

  Role* = enum
    RoleRunner
    RoleSupport

  Brain* = object
    slot*: int
    tick*: int
    jumpCooldown: int
    prevY: int
    velY*: int
    lastProgressTick: int
    lastProgressX: int
    climbLastX: int
    climbLastMoveTick: int
    leftEscapeTick: int
    apexJumpTick: int
    rideSince: int
    stageWaitSince: int
    supportWall*: int   ## wall index this support mans

const
  ## The three choke walls, in route order.
  ## Wall2 is special: its pocket sits on the lone x37 tile past the
  ## x35-36 pit, so climbers stage on the x30-34 platform edge, jump
  ## the pit into the wall face, and retreat by jumping back left.
  Walls* = [
    Wall(left: 23 * 32, topFeet: 12 * 32,
      pocketX: 23 * 32 - BoxW, stageX: 23 * 32 - BoxW - 44,
      pinX: 23 * 32 - BoxW),
    Wall(left: 38 * 32, topFeet: 10 * 32,
      pocketX: 38 * 32 - BoxW, stageX: 34 * 32 + 4,
      pinX: 34 * 32 + 4, takeoffA: 1090, takeoffB: 1120),
    Wall(left: 57 * 32, topFeet: 10 * 32,
      pocketX: 57 * 32 - BoxW, stageX: 57 * 32 - BoxW - 44,
      pinX: 57 * 32 - BoxW),
  ]
  JumpCooldownTicks = 3
  LadderTol = 24          ## pinned-body distance from the pocket
  ZoneReach = 200         ## wall approach zone, px left of the wall
  StageWaitTicks = 60     ## patience before pinning despite strangers
  ApexMargin = 14         ## required clearance above the wall lip
  RidePatience = 48       ## ticks on a head before nudging the carrier

proc feet(view: WorldView): int =
  view.ownY + BoxH

proc teamSlotOf*(name: string): int =
  ## Slot encoded in a teammate name ("jl<slot>"), or -1.
  if not name.startsWith(TeamPrefix):
    return -1
  let digits = name[TeamPrefix.len .. ^1]
  if digits.len == 0:
    return -1
  for ch in digits:
    if ch notin {'0' .. '9'}:
      return -1
  digits.parseInt()

proc jumpButton(brain: var Brain): uint8 =
  ## One-frame jump press honoring a short cooldown.
  if brain.jumpCooldown > 0:
    return 0
  brain.jumpCooldown = JumpCooldownTicks
  MaskJump

proc standingOnPlayer*(view: WorldView): bool =
  ## True when our feet rest on another player's head.
  for other in view.players:
    let
      dx = abs((other.x + BoxW div 2) - (view.ownX + BoxW div 2))
      gap = other.y - (view.ownY + BoxH)
    if dx < BoxW and gap >= -4 and gap <= 5:
      return true

proc inZone(wall: Wall, p: SeenPlayer): bool =
  ## True when a body is in the wall's approach zone, below its top.
  p.y + BoxH > wall.topFeet and
    p.x + BoxW >= wall.left - ZoneReach and
    p.x + BoxW <= wall.left + 8

proc pinnedLadder(view: WorldView, wall: Wall): int =
  ## Index of a body owning the wall pocket, or -1.
  result = -1
  for i in 0 ..< view.players.len:
    let p = view.players[i]
    if p.y + BoxH <= wall.topFeet:
      continue  # already above the wall
    if abs(p.x - wall.pocketX) <= LadderTol:
      return i

proc walkMask(brain: var Brain, view: WorldView, targetX: int): uint8 =
  ## Walks toward a target x with a stuck-hop when blocked by a small
  ## step or another body.
  if view.ownX != brain.climbLastX:
    brain.climbLastX = view.ownX
    brain.climbLastMoveTick = brain.tick
  if abs(view.ownX - targetX) <= 2:
    return 0
  result = if view.ownX < targetX: MaskRight else: MaskLeft
  # Stagger the stuck-hop cadence by slot so two blocked teammates
  # never hop in sync forever.
  if view.grounded and
      brain.tick - brain.climbLastMoveTick > 10 + brain.slot * 3:
    brain.climbLastMoveTick = brain.tick
    result = result or brain.jumpButton()

proc travelMask(
  brain: var Brain,
  view: WorldView,
  wall: Wall,
  targetX: int
): uint8 =
  ## Moves toward a target near the wall base, honoring the wall's own
  ## pit crossing in both directions (wall2's pocket sits past a pit).
  let goingRight = targetX > view.ownX
  if not view.grounded:
    return if goingRight: MaskRight else: MaskLeft
  if wall.takeoffB > 0:
    # Rightward: jump the pit from the takeoff window.
    if goingRight and targetX > wall.takeoffB - BoxW and
        view.ownX + BoxW >= wall.takeoffA and
        view.ownX + BoxW < wall.takeoffB:
      return MaskRight or brain.jumpButton()
    # Leftward from the pocket side: jump back over the pit.
    if not goingRight and view.ownX >= 1150 and targetX < 1150:
      brain.leftEscapeTick = brain.tick
      return MaskLeft or brain.jumpButton()
  brain.walkMask(view, targetX)

proc mountMask(brain: var Brain, view: WorldView, wall: Wall): uint8 =
  ## Mount protocol: back off to staging, then jump right INTO the
  ## wall face. We pin against the wall mid-air and slide down onto
  ## whatever body owns the pocket, which puts us on its head.
  if not view.grounded:
    return MaskRight
  if view.ownX > wall.stageX + 8:
    if wall.takeoffB > 0 and view.ownX >= 1150:
      # Wall2: no ground walk-back, jump the pit leftward.
      brain.leftEscapeTick = brain.tick
      return MaskLeft or brain.jumpButton()
    return brain.walkMask(view, wall.stageX)
  if view.ownX < wall.stageX - 6:
    return brain.walkMask(view, wall.stageX)
  MaskRight or brain.jumpButton()

proc bounceAt(brain: var Brain, view: WorldView, wall: Wall,
    postX: int): uint8 =
  ## Ladder duty: hold a spot near the wall and bounce on a
  ## slot-staggered cadence so riders can elevator off our head.
  if abs(view.ownX - postX) > 6:
    return brain.travelMask(view, wall, postX)
  if view.grounded and
      brain.tick mod 14 == (brain.slot * 5) mod 14:
    result = brain.jumpButton()

proc wallMask(
  brain: var Brain,
  view: WorldView,
  wall: Wall,
  atOwnPost: bool
): uint8 =
  ## One wall interaction step, deadlock-free by construction:
  ## - Riding a head: jump right the moment the apex clears the lip.
  ## - Supports at their post always pin and bounce (the ladder).
  ## - Otherwise mount, in priority order: a teammate more sacrificial
  ##   than us (higher slot, any position), else the frontmost body
  ##   ahead of us. The frontmost body with nobody to mount pins the
  ##   wall itself and serves until relieved.
  if view.standingOnPlayer():
    if view.grounded and view.feet - JumpRise <= wall.topFeet - ApexMargin:
      let button = brain.jumpButton()
      if button != 0:
        # Latch the crossing: hold right until we land so the wall
        # logic cannot steer us back mid-flight.
        brain.apexJumpTick = brain.tick
        brain.rideSince = 0
      return MaskRight or button
    # Riding, but too low to clear: a carrier standing flat on the
    # wall3 approach leaves us 14 px short, so we only get over when it
    # bounces. A carrier that never bounces is a deadlock -- replays
    # show 1932 ticks spent on one. Nudge periodically: the hop keeps
    # us pinned against the wall face and may catch the carrier's own
    # rise on the way back down.
    if brain.rideSince == 0:
      brain.rideSince = brain.tick
    elif view.grounded and brain.tick - brain.rideSince > RidePatience:
      brain.rideSince = brain.tick
      return MaskRight or brain.jumpButton()
    return 0
  brain.rideSince = 0
  if atOwnPost:
    return brain.bounceAt(view, wall, wall.pinX)
  var
    mountable = false
    lowerTeammateHere = false
  for p in view.players:
    if p.y + BoxH <= wall.topFeet:
      continue  # already above the wall
    if p.y + 4 < view.ownY and abs(p.x - view.ownX) < BoxW:
      continue  # directly above us: a rider, not a ladder
    if p.x < wall.pocketX - 60 or p.x > wall.pocketX + 8:
      continue  # not holding the wall base
    mountable = true
    let slot = teamSlotOf(p.name)
    if slot >= 0 and slot < brain.slot:
      lowerTeammateHere = true
  if mountable and not lowerTeammateHere:
    return brain.mountMask(view, wall)
  # Nobody at the wall base (or a lower-slot teammate is climbing and
  # we defer to them): hold the pocket as the ladder.
  brain.bounceAt(view, wall, wall.pinX)

proc runnerMask(brain: var Brain, view: WorldView): uint8 =
  ## Executes the hardcoded route toward the flag.
  let
    x = view.ownX
    front = x + BoxW
    feet = view.feet
    grounded = view.grounded

  # Wall interactions come first: when we are left of a wall column,
  # below its top, and close enough, run the wall protocol.
  for wall in Walls:
    if feet > wall.topFeet and
        front <= wall.left + 4 and
        front >= wall.left - 160:
      return brain.wallMask(view, wall, atOwnPost = false)

  # Route segments keyed on x when grounded: exact pit takeoffs.
  if grounded:
    # Climbable step ahead: scan the map for a blocking column whose
    # top is within solo jump reach and hop it.
    block stepScan:
      for dx in countup(2, 26, 4):
        let cx = front + dx
        if cx >= LevelWidthTiles * TileSize:
          break
        if solidTile(cx div TileSize, (feet - 8) div TileSize):
          var topY = ((feet - 8) div TileSize) * TileSize
          while solidTile(cx div TileSize, topY div TileSize - 1):
            topY -= TileSize
          if feet - topY <= 88:
            return MaskRight or brain.jumpButton()
          break stepScan
    # Pit takeoff windows (front px) for gaps that need an early jump.
    const JumpWindows = [
      (270, 288),     # pit x9 from x0-8 ground
      (536, 544),     # pit x17 off the x13-16 platform
      (850, 864),     # off x26 ledge clean over x27-x29 onto x30
      (916, 928),     # pit x29 up onto x30 (fallback from lowland)
      (1112, 1120),   # pit x35-36 onto lone x37
      (1270, 1280),   # off x39 tower over pit x40-42
      (1592, 1600),   # pit x50-51 down to x52/x53
    ]
    for (a, b) in JumpWindows:
      if front >= a and front < b:
        return MaskRight or brain.jumpButton()
    # Stuck fallback: hop when we have not advanced for a second.
    if x > brain.lastProgressX:
      brain.lastProgressX = x
      brain.lastProgressTick = brain.tick
    elif x < brain.lastProgressX - 60:
      # Respawned: reset progress tracking.
      brain.lastProgressX = x
      brain.lastProgressTick = brain.tick
    elif brain.tick - brain.lastProgressTick > 24:
      brain.lastProgressTick = brain.tick
      return MaskRight or brain.jumpButton()
    return MaskRight
  # Airborne: hold right; brake when falling toward the x27-x29 strip
  # so a botched ledge exit cannot drift into pit x29.
  if brain.velY > 0 and x >= 864 and x < 916 and feet > 400:
    return 0
  # Crossing wall2 high up: while FALLING, kill the drift so we land on
  # the x38/x39 tower top instead of sailing into pit x40-42. Only
  # while falling: the same airspace is used by the short hop from the
  # x38 top up onto x39, and releasing right during that rise pins us
  # on the tower forever.
  if brain.velY > 0 and x >= 1204 and x < 1270 and feet < 340:
    return 0
  # Falling onto the x30-34 platform after the x29 pit jump: release
  # right so full-speed flight cannot overshoot into pit x35-36.
  if brain.velY > 0 and x >= 1020 and x < 1108 and feet > 380:
    return 0
  # Falling from spawn: stop short of pit x9 so the drop cannot carry
  # us past the jump window.
  if brain.velY > 0 and x + BoxW >= 258 and x < 320 and feet < 470:
    return 0
  MaskRight

proc supportMask(brain: var Brain, view: WorldView): uint8 =
  ## Support seat: travel the route until the post wall, then own its
  ## pocket and bounce forever as the team ladder.
  let wall = Walls[brain.supportWall]
  if view.feet > wall.topFeet and
      view.ownX + BoxW >= wall.left - 160 and
      view.ownX + BoxW <= wall.left + 4:
    return brain.wallMask(view, wall, atOwnPost = true)
  # Overshot past the post (pushed over the wall): walk back left and
  # drop into the pocket from above.
  if view.ownX + BoxW > wall.left + 4 and view.ownX < wall.left + 96:
    return MaskLeft
  brain.runnerMask(view)

proc decide*(brain: var Brain, view: WorldView, role: Role): uint8 =
  ## Main entry: one input mask per tick.
  brain.velY = view.ownY - brain.prevY
  brain.prevY = view.ownY
  inc brain.tick
  if brain.jumpCooldown > 0:
    dec brain.jumpCooldown
  # Edge guard: the x34 platform edge borders pit x35-36 and bodies
  # jostling at wall2 can shove us off. When grounded on the platform
  # lip without a deliberate jump in flight, step back in.
  if view.grounded and view.feet == 416 and
      view.ownX >= 1106 and view.ownX <= 1160:
    return MaskLeft
  # Commit guard: falling over pit x35-36 the only survivable exit is
  # the x37 tile at the wall base -- hold right hard (unless this is a
  # deliberate leftward escape jump back to the platform).
  if not view.grounded and brain.velY > 0 and
      view.ownX >= 1108 and view.ownX <= 1195 and view.feet > 330 and
      brain.tick - brain.leftEscapeTick > 30:
    return MaskRight
  # Apex-jump latch: while airborne right after a wall crossing jump,
  # keep flying right (with the tower-top drift release) instead of
  # letting wall logic steer us backward.
  if not view.grounded and brain.apexJumpTick > 0 and
      brain.tick - brain.apexJumpTick < 45:
    if brain.velY > 0 and view.ownX >= 1204 and view.ownX < 1270 and
        view.feet < 340:
      return 0
    return MaskRight
  case role
  of RoleRunner:
    brain.runnerMask(view)
  of RoleSupport:
    brain.supportMask(view)
