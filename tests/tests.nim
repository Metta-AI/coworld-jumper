import std/os

{.warning[UnusedImport]: off.}
import jumper
{.warning[UnusedImport]: on.}

echo "Testing Jumper"
doAssert fileExists("coworld_manifest.json"), "manifest should exist"
doAssert fileExists("data/forest.tmx"), "map should exist"
doAssert fileExists("data/spritesheet.png"), "spritesheet should exist"
doAssert fileExists("players/dalli.nim"), "dalli bot should exist"
