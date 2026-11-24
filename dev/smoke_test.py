"""
=============================================================================
  FILE        : provisions/dev/smoke_test.py
  PACKAGE     : Provisions Lua  (MacroQuest / EverQuest)
  VERSION     : 2.0.0
  CHANGES     : 2.0.0  Renamed for the Provisions package. Now runs the real
                       init.lua start to finish (startup, main loop, one
                       job, shutdown) instead of calling the job runner
                       directly. Adds fakes for Me.CombatState,
                       Me.XTHaterCount and DanNet queries with Received, and
                       three new scenarios: paused, combat and busy. The
                       normal scenario also checks the one time import of an
                       old ClericFood settings file.
                1.3.2  No change in this file.
                1.3.1  First version, saved from the tests run during 1.3.0.

  WHAT  : Runs the real Provisions Lua code against a fake MacroQuest and a
          fake caster, then checks the hand out ended the way it should.

  WHY   : Lets you test a code change on your PC without logging in, and
          catches broken logic before it reaches the game. It does NOT prove
          the in game window names or plugin commands are right; only a live
          run with Debug trace on can do that.

  WHERE : Lives in provisions/dev/. Not used by the game.

  HOW   : Uses the lupa Python package to run Lua. The Lua block below
          builds a fake mq module: fake TLOs backed by a small table of game
          state G, and a fake mq.cmd that reacts to the commands the package
          sends (/casting puts bread on the cursor, /autoinventory moves it
          to the bags, /click left target offers it in a trade, /dex accepts
          the trade, the trade Cancel button returns offered items). A fake
          clock moves forward on every delay so time limits, retry gaps and
          settle times all play out quickly.

          Each scenario writes a settings file, queues one hand out with
          core.request(), and runs init.lua. The fake game state reports
          INGAME until a job has completed, then CHARSELECT, so the main
          loop ends on its own and shutdown runs.

          Scenarios (7 food and 3 drink to Tank and Wiz):
            normal     every cast lands; settings come from an old
                       clericfood_ file (import check)
            fizzle     4 of every 5 /casting calls fizzle on all 5 tries
            neverland  every cast fizzles, summon time limit 1 minute
            stunned    MQ2Cast reports CAST_STUNNED
            paused     Pause pressed on the 3rd cast, Resume 5 s later;
                       RGMercs must stay paused through the hold
            combat     a 6 s fight on the 3rd cast, and another when the
                       first trade opens (that trade is cancelled); RGMercs
                       must be handed back and paused again
            busy       DanNet reports Tank in combat twice, Wiz always;
                       Tank is served, Wiz is given up after 3 tries

  WHEN  : After any change to logic in init, casting, delivery or core.

  USAGE : pip install lupa
          python dev/smoke_test.py          (run from the provisions folder)

  NOTE  : lupa runs standard Lua 5.4; MacroQuest runs LuaJIT (Lua 5.1). The
          package avoids features that differ, so a pass here is meaningful,
          but keep that difference in mind if you add new Lua syntax.
=============================================================================
"""

import os    # locate the package folder, remove test settings files
import sys   # exit code

from lupa import LuaRuntime   # pip install lupa

# provisions/ is the parent of dev/, and its parent holds the provisions
# folder, which is where require('provisions.x') must be resolved from.
PACKAGE_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ROOT_DIR = os.path.dirname(PACKAGE_DIR)

# Where the fake mq.configDir points, and the two settings file names.
CONFIG_DIR = '/tmp'
NEW_FILE = os.path.join(CONFIG_DIR, 'provisions_test_Cleric.lua')
OLD_FILE = os.path.join(CONFIG_DIR, 'clericfood_test_Cleric.lua')

FAKE_MQ = r'''
-- Make require('provisions.x') find the files next to this test.
package.path = './?.lua;./?/init.lua;' .. package.path

-- G is the whole fake game state.
local G = {
  mana = 500,                       -- plenty of mana
  gem8 = 'Divine Aura',             -- spell in the borrowed gem before the job
  book = { ['Summon Food'] = 1, ['Summon Drink'] = 2 },  -- scribed spells
  inv = {},                         -- item name -> count in bags
  cursor = nil,                     -- { name, n } when holding an item
  castStatus = 'I',                 -- MQ2Cast status, idle between calls
  castResult = 'CAST_SUCCESS',      -- MQ2Cast result of the last /casting
  trade = false,                    -- trade window open?
  offered = {},                     -- stacks sitting in the open trade
  recv = {},                        -- target id -> item -> count received
  combat = false, combatUntil = 0,  -- caster fight state and end time
  dq = {},                          -- DanNet replies: peer|query -> { v, t }
  dqCount = {},                     -- peer -> number of combat queries so far
  cmds = {},                        -- every command sent, for inspection
  holds = {},                       -- hold reasons seen during delays
  tradesOpened = 0,                 -- how many trade windows were opened
}

-- val(v) returns an object that gives v when called and nil for any field,
-- imitating a TLO member such as mq.TLO.Me.ID.
local function val(v)
  return setmetatable({}, { __call = function() return v end,
                            __index = function() return val(nil) end })
end
local function count(n) return G.inv[n] or 0 end      -- bag count of an item

-- Fake clock. tick() runs the timed parts of each scenario.
local now = 0
local function core() return package.loaded['provisions.core'] end
local function tick()
  if G.combat and now >= G.combatUntil then G.combat = false end   -- fight ends
  local c = core()
  if c and c.job.hold ~= '' then G.holds[c.job.hold] = true end    -- record holds
  if SCENARIO == 'paused' and G.resumeAt and now >= G.resumeAt then
    G.resumeAt = nil; c.resume()                                    -- operator resumes
  end
end
local function fight(ms) G.combat = true; G.combatUntil = now + ms end  -- start a fight

local TLO = {}
-- The caster.
TLO.Me = {
  CleanName = val('Cleric'), ID = val(1),
  CurrentMana = function() return G.mana end,
  Sitting = val(false), FreeInventory = val(10),
  Class = { ShortName = val('CLR') },
  CombatState = function() return G.combat and 'COMBAT' or 'ACTIVE' end,
  XTHaterCount = val(0),
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
  local n = q:sub(2); G.lastFind = n                               -- remember the lookup
  if count(n) == 0 then return val(nil) end
  return setmetatable({ ItemSlot = val(23), ItemSlot2 = val(0),     -- pack1 slot 1
                        Stack = function() return math.min(20, count(n)) end },
                      { __call = function() return n end })
end
TLO.Window = function(w)                                           -- only TradeWnd closes
  return { Open = function() if w == 'TradeWnd' then return G.trade end return true end }
end
-- A group of the caster plus Tank and Wiz, all 10 units away.
TLO.Group = { Members = val(2), Member = function(i)
  local names = { [0] = 'Cleric', 'Tank', 'Wiz' }
  return setmetatable({ Name = val(names[i]), Mercenary = val(false),
    Spawn = { ID = val(i + 1), Distance = val(10), Class = { ShortName = val('WAR') } } },
    { __call = function() return names[i] end })
end }
TLO.Spawn = function() return setmetatable({ Distance = val(10) }, { __call = function() return 1 end }) end
TLO.Target = { ID = function() return G.target end }
TLO.Navigation = { Active = val(false), MeshLoaded = val(true) }
-- DanNet: Q(query) gives the stored reply; Received is 0 until it arrives.
TLO.DanNet = function(peer) return { Q = function(q)
  local r = G.dq[peer .. '|' .. q]
  return setmetatable({ Received = function() return r and r.t or 0 end },
                      { __call = function() return r and r.v end })
end } end
TLO.Lua = { Script = function() return { Status = val('RUNNING') } end }  -- RGMercs running
TLO.EverQuest = { Server = val('test') }
-- In game until one job has completed, then at character select.
TLO.MacroQuest = { GameState = function()
  local c = core()
  return (c and c.job.completed >= 1) and 'CHARSELECT' or 'INGAME'
end }

local evs, pending, castN = {}, {}, 0      -- chat events, queued names, /casting calls
local mq = { TLO = TLO, configDir = CONFIG_DIR,
  gettime = function() now = now + 50 tick() return now end,
  pickle = function() end, bind = function() end, unbind = function() end,
  imgui = { init = function() end },
  event = function(n, _, cb) evs[n] = cb end,
  unevent = function(n) evs[n] = nil end,
  doevents = function()                    -- fire queued chat events
    for _, n in ipairs(pending) do if evs[n] then evs[n]() end end
    pending = {}
  end,
}
-- A delay with a condition moves 10 ms and returns; callers check again.
function mq.delay(ms, cond) now = now + (cond and 10 or ms) tick() end

-- mq.cmd imitates the game reacting to each command.
function mq.cmd(c)
  G.cmds[#G.cmds + 1] = c
  if c:match('^/echo') then print((c:gsub('\a.', ''))) end        -- show chat
  local spell = c:match('^/casting "([^|]+)')
  if spell then                                                   -- a cast
    G.gem8 = spell; castN = castN + 1
    if castN == 3 and SCENARIO == 'paused' then                   -- operator presses Pause
      core().pause(); G.resumeAt = now + 5000
    end
    if castN == 3 and SCENARIO == 'combat' then fight(6000) end   -- mob attacks mid summon
    local fizzle = (SCENARIO == 'fizzle' and castN % 5 ~= 0) or SCENARIO == 'neverland'
    if SCENARIO == 'stunned' then G.castResult = 'CAST_STUNNED' return end
    if fizzle then                                                -- 5 fizzles, no item
      G.castResult = 'CAST_FIZZLE'
      for _ = 1, 5 do pending[#pending + 1] = 'provisions_fizzle' end
      return
    end
    G.castResult = 'CAST_SUCCESS'                                 -- item on the cursor
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
  if c == '/click left target' and G.cursor then                  -- offer in trade
    if not G.trade then
      G.tradesOpened = G.tradesOpened + 1
      if SCENARIO == 'combat' and G.tradesOpened == 1 then fight(6000) end  -- attacked mid trade
    end
    G.offered[#G.offered + 1] = G.cursor; G.cursor = nil; G.trade = true
  end
  if c:match('^/dex') and G.trade and not G.combat then           -- receiver accepts
    local r = G.recv[G.target] or {}; G.recv[G.target] = r
    for _, o in ipairs(G.offered) do r[o.name] = (r[o.name] or 0) + o.n end
    G.offered = {}; G.trade = false
  end
  if c:match('TRDW_Cancel_Button') then                           -- items come back
    for _, o in ipairs(G.offered) do G.inv[o.name] = count(o.name) + o.n end
    G.offered = {}; G.trade = false
  end
  local peer, query = c:match('^/dquery (%S+) %-q "(.+)"')
  if peer then                                                    -- DanNet reply
    local v = 'ACTIVE'
    if query == 'Me.CombatState' and SCENARIO == 'busy' then
      G.dqCount[peer] = (G.dqCount[peer] or 0) + 1
      if peer == 'wiz' or G.dqCount[peer] <= 2 then v = 'COMBAT' end
    end
    G.dq[peer .. '|' .. query] = { v = v, t = now }
  end
end
package.loaded['mq'] = mq
package.loaded['ImGui'] = {}                                      -- window is not drawn
_G.ImGuiTableFlags = { Borders = 1, RowBg = 2 }

-- Queue one hand out, then run the real entry point to the end.
require('provisions.core').request()
dofile('provisions/init.lua')

-- Hand the outcome back to Python.
local rgl = {}
for _, c in ipairs(G.cmds) do
  if c == '/rgl pause' or c == '/rgl unpause' then rgl[#rgl + 1] = c:sub(6) end
end
local r = require('provisions.core').job.results
return {
  tank_food = r.Tank and r.Tank.food or 0, tank_drink = r.Tank and r.Tank.drink or 0,
  wiz_food = r.Wiz and r.Wiz.food or 0,  wiz_drink = r.Wiz and r.Wiz.drink or 0,
  wiz_note = r.Wiz and r.Wiz.note or '', tank_note = r.Tank and r.Tank.note or '',
  recv_tank = (G.recv[2] or {})['Summoned: Black Bread'] or 0,
  gem8 = G.gem8, rgl = table.concat(rgl, ','), casts = castN,
  held_paused = G.holds['Paused'] == true, held_combat = G.holds['Combat hold'] == true,
  trade_open = G.trade, cursor = G.cursor ~= nil,
}
'''

# Expected (tank food, tank drink, wiz food, wiz drink) per scenario.
EXPECTED = {
    'normal':    (7, 3, 7, 3),   # everyone fully served
    'fizzle':    (7, 3, 7, 3),   # heavy fizzling still finishes
    'neverland': (0, 0, 0, 0),   # time limit stops it, nothing to give
    'stunned':   (0, 0, 0, 0),   # fatal result stops it at once
    'paused':    (7, 3, 7, 3),   # held, resumed, finished
    'combat':    (7, 3, 7, 3),   # held twice, cancelled trade retried, finished
    'busy':      (7, 3, 0, 0),   # Tank served on try 3, Wiz given up
}


def write_settings(scenario):
    """
    WHAT  : Writes the settings file the scenario starts from.
    WHY   : init.lua loads settings itself, so the test sets them the same
            way the game would: a file in the config folder.
    WHERE : Called by run before each scenario.
    HOW   : Removes both old and new test files, then writes a Lua table.
            The normal scenario writes the old clericfood_ name to prove the
            one time import works. busyRetrySec is shortened to 2 seconds so
            the busy scenario runs fast.
    WHEN  : Once per scenario.
    """
    for path in (NEW_FILE, OLD_FILE):
        if os.path.exists(path):
            os.remove(path)                              # start clean
    limit = 1 if scenario == 'neverland' else 20         # summon time limit
    body = ('return { foodCount = 7, drinkCount = 3, summonTimeoutMin = %d, '
            'busyRetrySec = 2, selected = { Tank = true, Wiz = true } }\n' % limit)
    path = OLD_FILE if scenario == 'normal' else NEW_FILE   # import check on normal
    with open(path, 'w', encoding='utf-8') as fh:
        fh.write(body)


def check_extra(scenario, out):
    """
    WHAT  : Scenario specific checks beyond the delivered counts. Returns a
            list of failure messages (empty when all good).
    WHY   : Pause, combat and busy behaviour is about the order of RGMercs
            commands and the notes, not only the counts.
    WHERE : Called by run.
    HOW   : out['rgl'] is the comma joined list of /rgl commands sent.
    WHEN  : Once per scenario.
    """
    bad = []
    rgl = out['rgl']
    if scenario == 'paused':
        if not out['held_paused']:
            bad.append('never held for Pause')
        if rgl != 'pause,unpause':
            bad.append('RGMercs should stay paused through a Pause, got ' + rgl)
    elif scenario == 'combat':
        if not out['held_combat']:
            bad.append('never held for combat')
        if not rgl.startswith('pause,unpause,pause') or rgl.count('unpause') < 3:
            bad.append('expected hand back and re pause for both fights, got ' + rgl)
        if out['recv_tank'] != 7:
            bad.append('Tank should hold exactly 7 bread, holds %d' % out['recv_tank'])
    else:
        if rgl != 'pause,unpause':
            bad.append('RGMercs pause and unpause expected, got ' + rgl)
    if scenario == 'busy':
        if out['wiz_note'] != 'busy, gave up':
            bad.append('Wiz note should be "busy, gave up", got ' + str(out['wiz_note']))
        if out['tank_note']:
            bad.append('Tank should have no note, got ' + str(out['tank_note']))
    if out['gem8'] != 'Divine Aura':
        bad.append('borrowed gem not restored: ' + str(out['gem8']))
    if out['trade_open'] or out['cursor']:
        bad.append('trade window or cursor left dirty')
    return bad


def run(scenario):
    """
    WHAT  : Runs one scenario and returns True when it passed.
    WHY   : Each scenario needs a fresh Lua state so modules reload cleanly.
    WHERE : Called by main.
    HOW   : Write settings, new LuaRuntime, set SCENARIO and CONFIG_DIR, run
            FAKE_MQ from the folder above provisions so require finds it,
            compare counts to EXPECTED, then run check_extra.
    WHEN  : Once per scenario.
    """
    print('\n=== scenario:', scenario)
    write_settings(scenario)
    lua = LuaRuntime(unpack_returned_tuples=True)   # fresh Lua for each run
    lua.globals().SCENARIO = scenario               # read by the fake mq.cmd
    lua.globals().CONFIG_DIR = CONFIG_DIR           # fake mq.configDir
    cwd = os.getcwd()
    os.chdir(ROOT_DIR)                              # so require('provisions.x') works
    try:
        out = lua.execute(FAKE_MQ)
    finally:
        os.chdir(cwd)                               # always go back
    got = (out['tank_food'], out['tank_drink'], out['wiz_food'], out['wiz_drink'])
    bad = [] if got == EXPECTED[scenario] else ['counts %s, expected %s' % (got, EXPECTED[scenario])]
    bad += check_extra(scenario, out)
    print('result', got, 'casts', out['casts'], 'rgl', out['rgl'], 'PASS' if not bad else 'FAIL')
    for b in bad:
        print('   ', b)                             # explain each failure
    return not bad


def main():
    """
    WHAT  : Runs every scenario and exits 0 if all pass.
    WHY   : Entry point when the script is run.
    WHERE : Bottom of this file.
    HOW   : Calls run for each EXPECTED key, then removes the test files.
    WHEN  : When run from the command line.
    """
    results = [run(name) for name in EXPECTED]          # run all, even after a failure
    for path in (NEW_FILE, OLD_FILE):
        if os.path.exists(path):
            os.remove(path)                              # leave /tmp tidy
    print('\nALL PASS' if all(results) else '\nSOME FAILED')
    sys.exit(0 if all(results) else 1)


if __name__ == '__main__':
    main()   # only runs when executed directly

# =============================================================================
#   END OF FILE : provisions/dev/smoke_test.py
#
#   HOW TO EDIT SAFELY
#     - Add a scenario: a key in EXPECTED, any special behaviour in the fake
#       mq.cmd (test SCENARIO), and extra checks in check_extra.
#     - A new TLO read by the package needs a fake in TLO above, or the run
#       fails with "attempt to call a nil value".
#     - The fake clock only moves inside mq.gettime and mq.delay. A loop in
#       the package that calls neither would hang this test, and would also
#       freeze the real game client.
# =============================================================================
