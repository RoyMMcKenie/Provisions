"""
=============================================================================
  FILE        : clericfood/dev/smoke_test.py
  PACKAGE     : ClericFood Lua  (MacroQuest / EverQuest)
  VERSION     : 1.3.1
  CHANGES     : 1.3.1  First version, saved from the tests run during 1.3.0.

  WHAT  : Runs the real ClericFood Lua code against a fake MacroQuest and a
          fake cleric, then checks the hand out ended the way it should.

  WHY   : Lets you test a code change on your PC without logging in, and
          catches broken logic before it reaches the game. It does NOT prove
          the in game window names or plugin commands are right; only a live
          run with Debug trace on can do that.

  WHERE : Lives in clericfood/dev/. Not used by the game.

  HOW   : Uses the lupa Python package to run Lua. A Lua block below builds
          a fake mq module: fake TLOs (Me, Group, Cursor, Cast, FindItem and
          so on) backed by a small table of game state, and a fake mq.cmd that
          reacts to the commands ClericFood sends (/casting puts bread on the
          cursor, /autoinventory moves it to the bags, /click left target
          offers it in a trade, /dex accepts the trade). Each scenario sets how
          the fake cleric behaves, runs one full hand out, and compares the
          result to what should happen.

          Scenarios:
            normal     every cast lands
            fizzle     4 of every 5 /casting calls fizzle on all 5 tries
            neverland  every cast fizzles, summon time limit 1 minute
            stunned    MQ2Cast reports CAST_STUNNED

  WHEN  : After any change to logic in actions, spells, trade or inventory.

  USAGE : pip install lupa
          python dev/smoke_test.py          (run from the clericfood folder)

  NOTE  : lupa runs standard Lua 5.4; MacroQuest runs LuaJIT (Lua 5.1). The
          package avoids features that differ, so a pass here is meaningful,
          but keep that difference in mind if you add new Lua syntax.
=============================================================================
"""

import os    # locate the package folder
import sys   # exit code

from lupa import LuaRuntime   # pip install lupa

# Parent of dev/ is the folder that contains clericfood/ as a subfolder.
PACKAGE_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ROOT_DIR = os.path.dirname(PACKAGE_DIR)

# -----------------------------------------------------------------------------
# The fake MacroQuest, written in Lua. SCENARIO is set from Python before this
# runs. Every function here imitates just enough of the real API for
# ClericFood to run.
# -----------------------------------------------------------------------------
FAKE_MQ = r'''
-- Make require('clericfood.x') find the files next to this test.
package.path = './?.lua;./?/init.lua;' .. package.path

-- G is the whole fake game state.
local G = {
  mana = 500,                       -- plenty of mana
  gem8 = 'Divine Aura',             -- spell in the borrowed gem before the job
  book = { ['Summon Food'] = 1, ['Summon Drink'] = 2 },  -- scribed spells
  inv = {},                         -- item name -> count in bags
  cursor = nil,                     -- { name, n } when holding an item
  castStatus = 'I',                 -- MQ2Cast status, always idle between calls
  castResult = 'CAST_SUCCESS',      -- MQ2Cast result of the last /casting
  trade = false,                    -- trade window open?
  cmds = {},                        -- every command sent, for inspection
}

-- val(v) returns an object that gives v when called and nil for any field,
-- imitating a TLO member such as mq.TLO.Me.ID.
local function val(v)
  return setmetatable({}, { __call = function() return v end,
                            __index = function() return val(nil) end })
end
local function count(n) return G.inv[n] or 0 end      -- bag count of an item

local TLO = {}
-- The cleric.
TLO.Me = {
  CleanName = val('Cleric'), ID = val(1),
  CurrentMana = function() return G.mana end,
  Sitting = val(false), FreeInventory = val(10),
  Class = { ShortName = val('CLR') },
  Book = function(n) return val(G.book[n]) end,          -- book page or nil
  Gem = function(g)                                        -- Gem(8) or Gem('name')
    if type(g) == 'number' then
      return setmetatable({ Name = function() return G.gem8 end },
                          { __call = function() return G.gem8 end })
    end
    return val(G.gem8 == g and 8 or nil)
  end,
  SpellReady = function() return val(true) end,
  Casting = { ID = val(nil) },
}
TLO.Spell = function() return { Mana = val(10) } end
TLO.Plugin = function(n) return { IsLoaded = val(n == 'MQ2Cast' or n == 'MQ2DanNet') } end
TLO.Cast = { Status = function() return G.castStatus end,
             Result = function() return G.castResult end }
-- Cursor fields read straight from G.cursor.
TLO.Cursor = setmetatable({}, { __index = function(_, k)
  if k == 'ID'    then return function() return G.cursor and 1 or nil end end
  if k == 'Name'  then return function() return G.cursor and G.cursor.name end end
  if k == 'Stack' then return function() return G.cursor and G.cursor.n or 0 end end
end })
TLO.FindItemCount = function(q) return val(count(q:sub(2))) end   -- strip the =
TLO.FindItem = function(q)
  local n = q:sub(2); G.lastFind = n                               -- remember what was looked up
  if count(n) == 0 then return val(nil) end
  return setmetatable({ ItemSlot = val(23), ItemSlot2 = val(0),     -- pack1 slot 1
                        Stack = function() return math.min(20, count(n)) end },
                      { __call = function() return n end })
end
TLO.Window = function(w)                                           -- only TradeWnd can be closed
  return { Open = function() if w == 'TradeWnd' then return G.trade end return true end }
end
-- A group of the cleric plus Tank and Wiz, all 10 units away.
TLO.Group = { Members = val(2), Member = function(i)
  local names = { [0] = 'Cleric', 'Tank', 'Wiz' }
  return setmetatable({ Name = val(names[i]), Mercenary = val(false),
    Spawn = { ID = val(i + 1), Distance = val(10), Class = { ShortName = val('WAR') } } },
    { __call = function() return names[i] end })
end }
TLO.Spawn = function() return setmetatable({ Distance = val(10) }, { __call = function() return 1 end }) end
TLO.Target = { ID = function() return G.target end }
TLO.Navigation = { Active = val(false), MeshLoaded = val(true) }
TLO.DanNet = function() return { Q = function() return val(nil) end } end
TLO.Lua = { Script = function() return { Status = val('RUNNING') } end }  -- RGMercs running
TLO.EverQuest = { Server = val('test') }
TLO.MacroQuest = { GameState = val('INGAME') }

-- Fake clock: every gettime call moves time forward a little, and delays
-- move it forward too, so time limits can be reached in a test.
local now = 0
local evs, pending, castN = {}, {}, 0      -- chat events, queued event names, /casting calls
local mq = { TLO = TLO, configDir = '/tmp',
  gettime = function() now = now + 50 return now end,
  pickle = function() end, bind = function() end, unbind = function() end,
  imgui = { init = function() end },
  event = function(n, _, cb) evs[n] = cb end,
  unevent = function(n) evs[n] = nil end,
  doevents = function()                    -- fire queued chat events
    for _, n in ipairs(pending) do if evs[n] then evs[n]() end end
    pending = {}
  end,
}
function mq.delay(ms, cond) now = now + (cond and 10 or ms) end

-- mq.cmd imitates the game reacting to each command.
function mq.cmd(c)
  G.cmds[#G.cmds + 1] = c
  if c:match('^/echo') then print((c:gsub('\a.', ''))) end        -- show chat, colours stripped
  local spell = c:match('^/casting "([^|]+)')
  if spell then                                                   -- a cast
    G.gem8 = spell; castN = castN + 1
    local fizzle = (SCENARIO == 'fizzle' and castN % 5 ~= 0) or SCENARIO == 'neverland'
    if SCENARIO == 'stunned' then G.castResult = 'CAST_STUNNED' return end
    if fizzle then                                                -- 5 fizzle messages, no item
      G.castResult = 'CAST_FIZZLE'
      for _ = 1, 5 do pending[#pending + 1] = 'clericfood_fizzle' end
      return
    end
    G.castResult = 'CAST_SUCCESS'                                 -- item lands on the cursor
    G.cursor = { name = spell == 'Summon Food' and 'Summoned: Black Bread'
                         or 'Summoned: Globe of Water', n = 1 }
  end
  if c == '/autoinventory' and G.cursor then                      -- cursor into bags
    G.inv[G.cursor.name] = count(G.cursor.name) + G.cursor.n; G.cursor = nil
  end
  local mem = c:match('^/memspell %d+ "(.+)"'); if mem then G.gem8 = mem end
  local tid = c:match('^/target id (%d+)'); if tid then G.target = tonumber(tid) end
  if c:match('itemnotify in pack') and not c:match('rightmouseup') then   -- lift from bag
    local n = G.lastFind
    local take = c:match('/shiftkey') and math.min(20, count(n)) or (c:match('/ctrlkey') and 1 or nil)
    if take then G.cursor = { name = n, n = take }; G.inv[n] = count(n) - take
    else G.pendingQty = n end                                     -- waits for the slider
  end
  local q = c:match('QTYW_slider newvalue (%d+)'); if q then G.qty = tonumber(q) end
  if c:match('QTYW_Accept') then                                  -- slider accepted
    local n = G.pendingQty; G.cursor = { name = n, n = G.qty }; G.inv[n] = count(n) - G.qty
  end
  if c == '/click left target' and G.cursor then G.cursor = nil; G.trade = true end
  if c:match('^/dex') and G.trade then G.trade = false end        -- receiver accepts
end
package.loaded['mq'] = mq
package.loaded['ImGui'] = {}                                      -- window is not drawn in tests
_G.ImGuiTableFlags = { Borders = 1, RowBg = 2 }

-- Run one hand out: 7 food and 3 drink to Tank and Wiz.
local config = require('clericfood.config'); config.load()
config.settings.foodCount, config.settings.drinkCount = 7, 3
config.settings.selected = { Tank = true, Wiz = true }
if SCENARIO == 'neverland' then config.settings.summonTimeoutMin = 1 end
local actions = require('clericfood.actions'); require('clericfood.ui')
require('clericfood.spells').detect()
actions.request(); actions.tick()

-- Hand the outcome back to Python.
local paused, unpaused = false, false
for _, c in ipairs(G.cmds) do
  if c == '/rgl pause' then paused = true end
  if c == '/rgl unpause' then unpaused = true end
end
local r = actions.results
return {
  tank_food = r.Tank and r.Tank.food or 0, tank_drink = r.Tank and r.Tank.drink or 0,
  wiz_food = r.Wiz and r.Wiz.food or 0,  wiz_drink = r.Wiz and r.Wiz.drink or 0,
  gem8 = G.gem8, paused = paused, unpaused = unpaused, casts = castN,
}
'''

# What each scenario must produce: (tank food, tank drink, wiz food, wiz drink).
EXPECTED = {
    'normal':    (7, 3, 7, 3),   # everyone fully served
    'fizzle':    (7, 3, 7, 3),   # heavy fizzling still finishes
    'neverland': (0, 0, 0, 0),   # time limit stops it, nothing to give
    'stunned':   (0, 0, 0, 0),   # fatal result stops it at once
}


def run(scenario):
    """
    WHAT  : Runs one scenario and returns True when it passed.
    WHY   : Each scenario needs a fresh Lua state so modules reload cleanly.
    WHERE : Called by main.
    HOW   : New LuaRuntime, set SCENARIO, run FAKE_MQ from the folder above
            clericfood so require finds it, compare results to EXPECTED, and
            also check the gem was restored and RGMercs paused and resumed.
    WHEN  : Once per scenario.
    """
    print('\n=== scenario:', scenario)
    lua = LuaRuntime(unpack_returned_tuples=True)   # fresh Lua for each run
    lua.globals().SCENARIO = scenario               # read by the fake mq.cmd
    cwd = os.getcwd()
    os.chdir(ROOT_DIR)                              # so require('clericfood.x') works
    try:
        out = lua.execute(FAKE_MQ)
    finally:
        os.chdir(cwd)                               # always go back
    got = (out['tank_food'], out['tank_drink'], out['wiz_food'], out['wiz_drink'])
    ok = (got == EXPECTED[scenario]
          and out['gem8'] == 'Divine Aura'          # borrowed gem put back
          and out['paused'] and out['unpaused'])    # RGMercs paused and resumed
    print('result', got, 'casts', out['casts'], 'gem8', out['gem8'], 'PASS' if ok else 'FAIL')
    return ok


def main():
    """
    WHAT  : Runs every scenario and exits 0 if all pass.
    WHY   : Entry point when the script is run.
    WHERE : Bottom of this file.
    HOW   : Calls run for each EXPECTED key.
    WHEN  : When run from the command line.
    """
    results = [run(name) for name in EXPECTED]          # run them all, even after a failure
    print('\nALL PASS' if all(results) else '\nSOME FAILED')
    sys.exit(0 if all(results) else 1)


if __name__ == '__main__':
    main()   # only runs when executed directly

# =============================================================================
#   END OF FILE : clericfood/dev/smoke_test.py
#
#   HOW TO EDIT SAFELY
#     - Add a scenario: add a key to EXPECTED and a branch in the fake
#       /casting handler that sets how the cleric behaves.
#     - If ClericFood starts reading a new TLO, add a fake for it in TLO
#       above, or the test will fail with "attempt to index a nil value".
# =============================================================================
