--[[==========================================================================
  FILE        : clericfood/config.lua
  PACKAGE     : ClericFood Lua  (MacroQuest / EverQuest)
  VERSION     : 1.3.1
  CHANGES     : 1.0.0  First release.
                1.1.0  Added useMQ2Cast and castMaxTries.
                1.2.0  Full inline documentation pass. No behaviour change.
                1.3.0  Added summonTimeoutMin.
                1.3.1  Documentation audit: every code line now carries
                       its own comment or one directly above it.

  WHAT  : Default settings, per character settings file load and save, and the
          live settings table every other module reads.

  WHY   : Food count, drink count, which group members are ticked, which spell
          gem to borrow, and how the other boxes accept trades are all things
          the operator changes from the window and expects to still be set the
          next time the script runs. Keeping them in one table, saved per
          server and character, means each cleric remembers its own choices and
          no value is hardcoded in the logic modules.

  WHERE : Required by spells.lua, group.lua, trade.lua, actions.lua, ui.lua and
          init.lua. Settings live in the MacroQuest config folder as
          clericfood_<server>_<character>.lua.

  HOW   : DEFAULTS is the full schema. config.load reads the saved file with
          loadfile, then copies every key from DEFAULTS that the file does not
          have, so adding a new setting in a later version never breaks an old
          file. config.save writes the table back with mq.pickle.

  WHEN  : config.load runs once at startup from init.lua. config.save runs
          whenever the window changes a value (debounced by ui.lua) and when
          the script ends.

  READING GUIDE (for future you)
    - The settings file is itself a small Lua file that returns a table. You
      can open it in a text editor and change values while the script is not
      running. Delete it to reset everything to DEFAULTS.
    - mq.configDir is the "config" folder inside your MacroQuest install.
==========================================================================]]--

local mq    = require('mq')                 -- MacroQuest API (configDir, pickle, TLO)
local utils = require('clericfood.utils')   -- clamp, warn, debug, bindDebugFlag

local config = {}

--[[==========================================================================
  DEFAULTS

  WHAT  : Every setting the package understands, with its starting value.
  WHY   : One readable list of everything configurable. Anything not listed
          here is not a setting.
  WHERE : config.load merges these into the saved file.
  HOW   : Plain nested Lua table. Comments explain each key.
  WHEN  : Read once at load time.
==========================================================================]]--
config.DEFAULTS = {
    -- How many of each item every ticked member should end up receiving.
    -- Edited by the Food each / Drink each boxes and /cfood food N.
    foodCount  = 10,
    drinkCount = 10,

    -- Spell names. Left blank means "auto detect the best one in my book".
    -- Auto detection walks FOOD_SPELLS / DRINK_SPELLS in spells.lua.
    foodSpell  = '',
    drinkSpell = '',

    -- Item names the spells create. These are learned automatically from the
    -- cursor the first time each spell is cast, and are needed before that
    -- only for the "Top up" mode and for counting existing stock.
    foodItem   = 'Summoned: Black Bread',
    drinkItem  = 'Summoned: Globe of Water',

    -- Spell gem borrowed when a summon spell is not already memorised.
    gem             = 8,
    -- Put back whatever was in that gem when the job finishes.
    restoreGem      = true,

    -- Mana handling. When a cast needs more mana than the cleric has, sit and
    -- wait up to medTimeoutSec for it, otherwise skip that cast.
    medForMana      = true,
    medTimeoutSec   = 120,

    -- Cast through MQ2Cast, which detects fizzles and interrupts and recasts
    -- on its own. The plugin is loaded for the job if needed and unloaded
    -- again afterwards if this package was the one that loaded it. Off falls
    -- back to plain /cast with the package's own retry counter.
    useMQ2Cast      = true,
    -- Attempts MQ2Cast makes per cast before reporting failure (-maxtries).
    -- Fizzles past this number are NOT a problem: the summon loop simply
    -- calls /casting again until the item count is reached.
    castMaxTries    = 5,

    -- Safety net for the summon loop, in minutes. Summoning keeps going
    -- through any number of fizzles until the item count is reached; this
    -- only stops a loop that runs longer than this. 0 means no limit.
    summonTimeoutMin = 20,

    -- Keep the cleric's own existing stock untouched. When true the script
    -- summons enough for everyone on top of what is already in the bags.
    preserveOwnStock = true,

    -- Top up mode: ask each box (through DanNet) how many it already carries
    -- and only give the difference. Off means always give the full count.
    topUp           = false,

    -- How the receiving box presses Trade. 'dannet', 'eqbc' or 'none'.
    -- 'none' assumes the operator or another automation accepts.
    acceptMethod    = 'dannet',

    -- Seconds to wait for the receiver to accept before cancelling the trade.
    tradeTimeoutSec = 12,

    -- Trade range in game units. Beyond this the cleric walks over with
    -- MQ2Nav when useNav is true, otherwise that member is skipped.
    tradeRange      = 15,
    useNav          = true,
    navTimeoutSec   = 30,

    -- Pause RGMercs on the cleric while the job runs so it does not try to
    -- cast or chase in the middle of a trade.
    pauseRGMercs    = true,

    -- Names ticked in the roster. Keyed by character name, value true.
    -- Example once saved: selected = { Roybox = true, Tankguy = true }
    selected        = {},

    -- Show the debug trace in chat.
    debug           = false,
}

--- Live settings ---------------------------------------------------------------
-- WHAT : The table every module reads and the window writes.
-- WHY  : A single shared table means a change in the window is seen by the
--        job runner on its very next step, with no message passing.
-- WHERE: Everywhere, as config.settings.
-- HOW  : Filled by config.load. Other modules keep a reference to config and
--        read config.settings.<key> each time, never a cached copy.
-- WHEN : Valid after config.load returns.
config.settings = {}

--[[--------------------------------------------------------------------------
  config.path()

  WHAT  : Returns the full path of this character's settings file.
  WHY   : Each cleric on each server gets its own file, so two clerics on one
          account do not overwrite each other's choices.
  WHERE : config.load and config.save.
  HOW   : mq.configDir plus server and character name. Spaces are removed from
          the server name so the file name is filesystem safe.
  WHEN  : On every load and save.
----------------------------------------------------------------------------]]
function config.path()
    -- EverQuest.Server is the server short name. gsub strips whitespace.
    -- The extra parentheses keep only the first return value of gsub.
    local server = (mq.TLO.EverQuest.Server() or 'server'):gsub('%s+', '')
    -- CleanName is the character name without any title or suffix.
    local name   = mq.TLO.Me.CleanName() or 'char'
    return string.format('%s/clericfood_%s_%s.lua', mq.configDir, server, name)
end

--[[--------------------------------------------------------------------------
  deepCopy(value)

  WHAT  : Returns an independent copy of a table, recursing into sub tables.
  WHY   : Defaults must never be mutated through the live table, otherwise the
          selected list would be shared between DEFAULTS and settings.
  WHERE : config.load only.
  HOW   : Recursive pairs copy. Non tables are returned as is.
  WHEN  : When filling missing keys from DEFAULTS.
----------------------------------------------------------------------------]]
local function deepCopy(value)
    -- Numbers, strings and booleans are copied by value in Lua already.
    if type(value) ~= 'table' then return value end
    local out = {}
    -- Copy every key, recursing so nested tables are fresh copies too.
    for k, v in pairs(value) do out[k] = deepCopy(v) end
    return out
end

--[[--------------------------------------------------------------------------
  config.load()

  WHAT  : Reads the saved settings file, fills any missing keys from DEFAULTS,
          and sanitises numeric ranges.
  WHY   : The script must start correctly on first run (no file yet), after an
          upgrade (file missing new keys), and after a hand edit (values out of
          range).
  WHERE : Called by init.lua at startup.
  HOW   : loadfile inside pcall so a corrupt file falls back to defaults rather
          than crashing. Then a merge pass and a clamp pass. Finally binds the
          debug flag into utils.
  WHEN  : Once at startup.
----------------------------------------------------------------------------]]
function config.load()
    local loaded = {}

    -- loadfile compiles the file without running it. It returns nil when the
    -- file does not exist (first run) or has a syntax error.
    local chunk = loadfile(config.path())
    if chunk then
        -- Run the compiled file inside pcall so a runtime error in a hand
        -- edited file cannot crash the script. data is the returned table.
        local ok, data = pcall(chunk)
        if ok and type(data) == 'table' then
            loaded = data
        else
            utils.warn('Settings file could not be read, using defaults.')  -- bad file: fall back to defaults rather than crash
        end
    end

    -- Merge: any key the file lacks gets its default. Keys already in the
    -- file are left alone, so the operator's choices always win.
    for key, value in pairs(config.DEFAULTS) do
        if loaded[key] == nil then loaded[key] = deepCopy(value) end
    end

    -- Sanitise: keep every number inside a range the code can handle, in
    -- case the file was edited by hand or came from an older version.
    loaded.foodCount       = utils.clamp(loaded.foodCount, 0, 80)
    loaded.drinkCount      = utils.clamp(loaded.drinkCount, 0, 80)
    loaded.gem             = utils.clamp(loaded.gem, 1, 13)
    loaded.castMaxTries    = utils.clamp(loaded.castMaxTries, 1, 20)  -- MQ2Cast -maxtries between 1 and 20
    loaded.summonTimeoutMin = utils.clamp(loaded.summonTimeoutMin, 0, 240)  -- summon time limit in minutes; 0 means no limit
    loaded.tradeTimeoutSec = utils.clamp(loaded.tradeTimeoutSec, 3, 60)  -- seconds to wait for the receiver to accept
    loaded.tradeRange      = utils.clamp(loaded.tradeRange, 5, 25)  -- units; EQ trade range is about 20
    -- The roster ticks must be a table; anything else is replaced.
    if type(loaded.selected) ~= 'table' then loaded.selected = {} end

    -- Publish the result as the live table.
    config.settings = loaded

    -- Tell utils how to check the Debug option from now on.
    utils.bindDebugFlag(function() return config.settings.debug == true end)
    utils.debug('Settings loaded from %s', config.path())
end

--[[--------------------------------------------------------------------------
  config.save()

  WHAT  : Writes the live settings table to this character's file.
  WHY   : Persists window choices between sessions.
  WHERE : ui.lua after a change, init.lua on exit, spells.lua after learning an
          item name.
  HOW   : mq.pickle, which serialises a Lua table to a file that loadfile can
          read back. Wrapped in pcall so a locked or read only file only warns.
  WHEN  : After changes, and at shutdown.
----------------------------------------------------------------------------]]
function config.save()
    local ok, err = pcall(mq.pickle, config.path(), config.settings)
    if not ok then utils.err('Could not save settings: %s', tostring(err)) end
end

return config  -- hand the module table to require('clericfood.config')

--[[==========================================================================
  END OF FILE : clericfood/config.lua

  SUMMARY OF PUBLIC API
    DEFAULTS         table   Full settings schema with starting values.
    settings         table   Live settings, valid after load().
    path()           string  Per server, per character settings file path.
    load()                   Read, merge, sanitise.
    save()                   Persist with mq.pickle.

  DEPENDENCIES : mq, clericfood.utils.

  HOW TO EDIT SAFELY
    - Add a setting: add one key with a comment to DEFAULTS. Old files pick it
      up automatically on next load. If it is a number, add a clamp line in
      config.load. If the operator should change it, add a control in
      ui.lua drawOptions.
    - Change a default: edit DEFAULTS. Characters that already have a saved
      file keep their saved value; delete the file to pick up the new default.
    - Count limits of 80 equal one full trade window (8 slots) when food and
      drink are both 80 in stacks of 20. trade.lua opens extra trades if a
      plan ever needs more than 8 stacks.
==========================================================================]]--
