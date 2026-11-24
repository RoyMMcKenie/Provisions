--[[==========================================================================
  FILE        : provisions/core.lua
  PACKAGE     : Provisions Lua  (MacroQuest / EverQuest)
  VERSION     : 2.3.2
  CHANGES     : 2.3.2  Adds the loadOnOtherBoxes setting, off by default.
                       Help text now says /provisions.
                2.3.1  No change in this file.
                2.3.0  No change in this file.
                2.2.0  Adds the linkLoadRequested job flag and
                       core.requestLinkLoad, so picking a link in Options
                       (and starting the script) loads its plugin.
                2.1.0  The default link to other boxes (acceptMethod) is
                       now 'mqremote'. A saved choice is kept. Adds the
                       checkRequested job flag and core.requestCheck for
                       the new Check links button and /prov check.
                2.0.0  New file. Merges the ClericFood 1.3.2 files utils.lua,
                       config.lua and group.lua into one shared foundation,
                       renamed for every food and drink summoning class.
                       Adds the shared job flags (request, stop, pause,
                       resume), the combat check, the checkpoint hook used
                       for Pause and Combat Hold, five new settings for the
                       combat and busy member rules, and a one time import
                       of old ClericFood settings files.
                1.0.0 to 1.3.2  Released as ClericFood (utils.lua,
                       config.lua, group.lua). Full history in CHANGELOG.md.

  WHAT  : The foundation every other file stands on. Four parts:
            1. Output and waiting helpers (echo, cmd, abortable delay).
            2. Settings: defaults, per character load and save.
            3. The group roster that the checkbox list shows.
            4. Shared job state: the flags the window and slash commands
               flip (Hand Out, Stop, Pause, Resume) and the combat check.

  WHY   : These four parts are small, are needed by every other file, and
          never wait on the game themselves (apart from core.delay). Keeping
          them in one file means there is exactly one place that knows the
          chat tag, the settings file name, who is in the group, and whether
          the job is paused. Putting the job flags here, rather than in
          init.lua, lets ui.lua read and set them without requiring init.lua,
          which would be a require loop.

  WHERE : Required by delivery.lua, casting.lua, ui.lua and init.lua. It
          requires nothing from the package itself, so it sits at the bottom
          of the dependency graph and can never cause a circular require.

  HOW   : Plain Lua plus the mq API. Every wait is built on mq.delay, which
          yields back to MacroQuest so the window keeps painting while a
          spell is cast or a trade is pending. Settings are written with
          mq.pickle and read back with loadfile.

  WHEN  : Loaded first by init.lua and used for the whole life of the script.

  READING GUIDE (for future you)
    - "Yield" means hand control back to MacroQuest for a moment so the game
      and the window keep running. mq.delay is the only thing that yields.
    - "Job" means one press of Hand Out, from start to cleanup.
    - "Hold" means the job is waiting at a safe point, either because the
      operator pressed Pause or because Combat Hold saw a fight.
    - "Checkpoint" is a safe point in the job (before a cast, before a
      trade) where a hold is allowed to start. init.lua supplies the code
      that runs there; core.checkpoint just calls it.
    - A "row" is one line of the checkbox list; its fields are listed on
      core.roster below.
==========================================================================]]--

-- The MacroQuest Lua API: mq.cmd sends a slash command, mq.delay waits
-- while yielding, mq.TLO reads game data, mq.pickle saves a table.
local mq = require('mq')

-- The module table. Everything added to it is public; locals are private.
local core = {}

--[[==========================================================================
  PART 1 : OUTPUT AND WAITING
==========================================================================]]--

--- Colour code shortcuts -----------------------------------------------------
-- WHAT : Named aliases for the MacroQuest chat colour escapes.
-- WHY  : Raw \ag and \ar codes are unreadable at the call site.
-- WHERE: core.good, core.warn, core.err, core.debug.
-- HOW  : String constants. A backslash plus a letter in chat text changes
--        the colour from that point on.
-- WHEN : Read at echo time. Never changed after load.
core.color = {
    reset  = '\aw', -- white, back to normal text
    info   = '\at', -- teal, general information
    good   = '\ag', -- green, something succeeded
    warn   = '\ay', -- yellow, needs attention but not fatal
    bad    = '\ar', -- red, something failed
    accent = '\ao', -- orange, the [dbg] tag on debug lines
}

--- Package chat prefix -------------------------------------------------------
-- WHAT : The [Provisions] tag stamped on every console line.
-- WHY  : Lets the operator tell this script's lines apart from RGMercs and
--        MQ2Nav output when several clients are running.
-- WHERE: core.echo only; every other output function goes through echo.
-- HOW  : String constant with colour codes. \ax resets colour after it.
-- WHEN : Applied to every printed line.
local PREFIX = '\aw[\agProvisions\aw]\ax '

--[[--------------------------------------------------------------------------
  format(fmt, ...)

  WHAT  : Formats a message only when arguments were supplied.
  WHY   : A character name containing % would break string.format if every
          message were formatted, so plain text is passed through as is.
  WHERE : Every output helper in this part.
  HOW   : select('#', ...) counts the extra arguments.
  WHEN  : On every echo, warn, err, debug and cmd call.
----------------------------------------------------------------------------]]
local function format(fmt, ...)
    -- No extra arguments: return the text untouched.
    return select('#', ...) > 0 and string.format(fmt, ...) or tostring(fmt)
end

--[[--------------------------------------------------------------------------
  core.echo(fmt, ...)

  WHAT  : Writes one formatted, prefixed line to the MacroQuest chat window.
  WHY   : Single choke point for all output so the tag is always present.
  WHERE : Every file.
  HOW   : format, then /echo with the prefix. mq.cmd is used rather than
          mq.cmdf so the finished text is never parsed as a format string.
  WHEN  : Any time, even before settings are loaded.
----------------------------------------------------------------------------]]
function core.echo(fmt, ...)
    -- /echo prints on this client only.
    mq.cmd('/echo ' .. PREFIX .. format(fmt, ...))
end

--[[--------------------------------------------------------------------------
  core.good(fmt, ...) / core.warn(fmt, ...) / core.err(fmt, ...)

  WHAT  : Coloured versions of core.echo for success, warning and failure.
  WHY   : A failed trade should stand out in a scrolling chat window.
  WHERE : Every file that reports an outcome.
  HOW   : Formats once here, adds the colour, then calls echo with no extra
          arguments so the text is not formatted twice.
  WHEN  : When reporting results.
----------------------------------------------------------------------------]]
function core.good(fmt, ...)
    core.echo(core.color.good .. format(fmt, ...))  -- green line
end

-- Yellow line, same pattern as core.good.
function core.warn(fmt, ...)
    core.echo(core.color.warn .. format(fmt, ...))  -- yellow line
end

-- Red line, same pattern as core.good.
function core.err(fmt, ...)
    core.echo(core.color.bad .. format(fmt, ...))   -- red line
end

--[[--------------------------------------------------------------------------
  core.debug(fmt, ...)

  WHAT  : Prints a trace line only when Debug trace is on in Options.
  WHY   : Shows every decision while testing in game without that noise in
          normal play.
  WHERE : Any file.
  HOW   : Reads core.settings.debug directly (settings live in this file),
          then prints with an orange [dbg] tag.
  WHEN  : At decision points and before waits.
----------------------------------------------------------------------------]]
function core.debug(fmt, ...)
    -- Leave at once when Debug is off, before doing any formatting work.
    if not (core.settings and core.settings.debug) then return end
    core.echo(core.color.accent .. '[dbg] ' .. core.color.reset .. format(fmt, ...))
end

--[[--------------------------------------------------------------------------
  core.cmd(fmt, ...)

  WHAT  : Formats and sends one slash command, tracing it first.
  WHY   : Every command passes through here, so Debug trace shows the exact
          command stream, the fastest way to find a wrong window or control
          name in game.
  WHERE : Every file that sends a command.
  HOW   : format, debug trace, mq.cmd.
  WHEN  : Whenever the game must be told to do something.
----------------------------------------------------------------------------]]
function core.cmd(fmt, ...)
    -- Build the final command text.
    local line = format(fmt, ...)
    core.debug('cmd: %s', line)   -- shown only when Debug trace is on
    -- mq.cmd does not wait for the game to act; callers wait afterwards.
    mq.cmd(line)
end

--[[--------------------------------------------------------------------------
  core.aborted()

  WHAT  : Returns true when the operator has pressed Stop.
  WHY   : Long loops check this between steps so they end cleanly rather
          than half way through a trade.
  WHERE : casting.lua, delivery.lua, init.lua.
  HOW   : Reads core.job.stopRequested (defined in part 4 of this file).
  WHEN  : Between steps of any multi step operation.
----------------------------------------------------------------------------]]
function core.aborted()
    -- Compare to true so a missing flag counts as "not stopped".
    return core.job.stopRequested == true
end

--[[--------------------------------------------------------------------------
  core.delay(ms, condition)

  WHAT  : Waits up to ms milliseconds, ending early when condition() turns
          true or Stop is pressed. Returns true only when the condition was
          met (or, with no condition, when the full time ran).
  WHY   : A bare mq.delay does not know about Stop. Wrapping it here makes
          every wait in the package stoppable for free.
  WHERE : casting.lua, delivery.lua, init.lua.
  HOW   : mq.delay with a combined predicate, then the condition is checked
          again so a timeout is never reported as success.
  WHEN  : Any time the script waits on the game.
----------------------------------------------------------------------------]]
function core.delay(ms, condition)
    if condition == nil then
        -- Plain timed pause that still ends early on Stop.
        mq.delay(ms, function() return core.aborted() end)
        return not core.aborted()   -- false when Stop cut it short
    end
    -- mq.delay checks the predicate every frame and returns when it is true.
    mq.delay(ms, function() return core.aborted() or condition() end)
    -- Success only if not stopped and the condition really holds now.
    return (not core.aborted()) and condition() == true
end

--[[--------------------------------------------------------------------------
  core.clamp(value, lo, hi)

  WHAT  : Squeezes a number into the inclusive range lo to hi.
  WHY   : Input boxes accept anything; counts must stay within what a trade
          can carry, and hand edited settings files may hold odd values.
  WHERE : core.load, ui.lua, init.lua.
  HOW   : tonumber (non numbers become lo), then math.max and math.min.
  WHEN  : Whenever a user editable number is accepted.
----------------------------------------------------------------------------]]
function core.clamp(value, lo, hi)
    value = tonumber(value) or lo            -- text or nil falls back to lo
    return math.max(lo, math.min(hi, value)) -- squeeze into [lo, hi]
end

--[[==========================================================================
  PART 2 : SETTINGS
==========================================================================]]--

--[[--------------------------------------------------------------------------
  DEFAULTS

  WHAT  : Every setting the package understands, with its starting value.
  WHY   : One readable list of everything configurable.
  WHERE : core.load merges these into the saved file.
  HOW   : Plain table. A comment explains each key.
  WHEN  : Read once at load time.
----------------------------------------------------------------------------]]
core.DEFAULTS = {
    -- How many of each item every ticked member should end up receiving.
    foodCount  = 10,
    drinkCount = 10,

    -- Spell names. Blank means "auto detect the best one in my book" from
    -- the lists in casting.lua.
    foodSpell  = '',
    drinkSpell = '',

    -- Item names the spells create. Learned from the cursor after the first
    -- cast; needed before that only for Top up mode and stock counts.
    foodItem   = 'Summoned: Black Bread',
    drinkItem  = 'Summoned: Globe of Water',

    -- Spell gem borrowed when a summon spell is not memorised, and whether
    -- to put the original spell back afterwards.
    gem        = 8,
    restoreGem = true,

    -- Sit for mana when a cast needs more than the caster has, for up to
    -- medTimeoutSec seconds per cast.
    medForMana    = true,
    medTimeoutSec = 120,

    -- Cast through MQ2Cast, which recasts fizzles and interrupts itself.
    -- castMaxTries is its -maxtries value for one /casting call.
    useMQ2Cast   = true,
    castMaxTries = 5,

    -- Safety net for the summon loop in minutes. Time spent paused or in
    -- Combat Hold does not count. 0 means no limit.
    summonTimeoutMin = 20,

    -- Keep the caster's existing stock and summon for everyone on top.
    preserveOwnStock = true,

    -- Top up mode: ask each box (through MQRemote or DanNet) what it
    -- carries and give only the shortfall.
    topUp = false,

    -- How commands reach the other boxes (press Trade, link check, Top up,
    -- busy check): 'mqremote' (default), 'dannet', 'eqbc' or 'none'
    -- (Manual). EQBC can only press Trade; it cannot answer questions.
    acceptMethod    = 'mqremote',
    -- Load the link plugin on other boxes (new in 2.3.2). Off by default so
    -- nothing runs on another character unless the operator turns it on.
    -- When on, a member who does not answer the link check is sent
    -- /plugin <name> load through another link already up here (DanNet or
    -- EQBC), then asked once more.
    loadOnOtherBoxes = false,
    -- Seconds to wait for the receiver to accept before cancelling.
    tradeTimeoutSec = 12,

    -- Trade range in game units, and walking there with MQ2Nav.
    tradeRange    = 15,
    useNav        = true,
    navTimeoutSec = 30,

    -- Pause RGMercs on the caster while the job runs.
    pauseRGMercs = true,

    -- Combat Hold (new in 2.0.0). When on, the job holds at the next safe
    -- point whenever the caster is in combat.
    combatHold      = true,
    -- During a Combat Hold, unpause RGMercs so it can fight and heal, then
    -- pause it again when the fight is over.
    combatHandBack  = true,
    -- Seconds out of combat before the job carries on, in case another mob
    -- joins the fight.
    combatSettleSec = 5,

    -- Busy member rules (new in 2.0.0). A member who is fighting, or whose
    -- trade does not open or is not accepted, moves to the back of the
    -- line. After busyTries attempts that member is given up on.
    busyTries    = 3,
    -- Seconds to wait before trying a busy member again.
    busyRetrySec = 10,

    -- Names ticked in the roster, keyed by character name, value true.
    selected = {},

    -- Show the debug trace in chat.
    debug = false,
}

--- Live settings ---------------------------------------------------------------
-- WHAT : The table every file reads and the window writes.
-- WHY  : A change in the window is seen by the job on its very next step.
-- WHERE: Everywhere, as core.settings.
-- HOW  : Filled by core.load. Read core.settings.<key> each time; never keep
--        a copy, because core.load replaces the whole table.
-- WHEN : Valid after core.load returns.
core.settings = {}

--[[--------------------------------------------------------------------------
  settingsPath(prefix)

  WHAT  : Builds the settings file path for this server and character.
  WHY   : Each character on each server gets its own file, so two casters on
          one account never overwrite each other.
  WHERE : core.path (current name) and core.load (old ClericFood name).
  HOW   : mq.configDir plus prefix, server and character. Spaces are removed
          from the server name so the file name is safe.
  WHEN  : On every load and save.
----------------------------------------------------------------------------]]
local function settingsPath(prefix)
    -- The extra parentheses keep only the first return value of gsub.
    local server = (mq.TLO.EverQuest.Server() or 'server'):gsub('%s+', '')
    local name   = mq.TLO.Me.CleanName() or 'char'   -- name without titles
    return string.format('%s/%s_%s_%s.lua', mq.configDir, prefix, server, name)
end

--[[--------------------------------------------------------------------------
  core.path()

  WHAT  : Returns the full path of this character's settings file.
  WHY   : Public so README and debugging can show where settings live.
  WHERE : core.load, core.save.
  HOW   : settingsPath with the provisions prefix, for example
          config/provisions_<server>_<name>.lua.
  WHEN  : On every load and save.
----------------------------------------------------------------------------]]
function core.path()
    return settingsPath('provisions')   -- current file name scheme
end

--[[--------------------------------------------------------------------------
  deepCopy(value)

  WHAT  : Returns an independent copy of a table, recursing into sub tables.
  WHY   : DEFAULTS must never be changed through the live table, or the
          selected list would be shared between them.
  WHERE : core.load.
  HOW   : Recursive pairs copy. Non tables are returned as is.
  WHEN  : When filling missing keys from DEFAULTS.
----------------------------------------------------------------------------]]
local function deepCopy(value)
    -- Numbers, strings and booleans are already copied by value.
    if type(value) ~= 'table' then return value end
    local out = {}
    for k, v in pairs(value) do out[k] = deepCopy(v) end   -- recurse
    return out
end

--[[--------------------------------------------------------------------------
  readFile(path)

  WHAT  : Runs a saved settings file and returns its table, or nil.
  WHY   : Used for both the current file and the old ClericFood file.
  WHERE : core.load.
  HOW   : loadfile compiles the file without running it (nil when missing
          or broken). pcall runs it so a bad hand edit cannot crash.
  WHEN  : At startup.
----------------------------------------------------------------------------]]
local function readFile(path)
    local chunk = loadfile(path)          -- nil when the file does not exist
    if not chunk then return nil end
    local ok, data = pcall(chunk)         -- run it safely
    if ok and type(data) == 'table' then return data end
    core.warn('Settings file %s could not be read, using defaults.', path)  -- broken file
    return nil
end

--[[--------------------------------------------------------------------------
  core.load()

  WHAT  : Reads the saved settings, imports old ClericFood settings on the
          first run after the rename, fills missing keys from DEFAULTS and
          keeps numbers in range.
  WHY   : Must start correctly on a first run (no file), after an upgrade
          (missing new keys), after the rename (old file name), and after a
          hand edit (values out of range).
  WHERE : init.lua startup.
  HOW   : readFile on the provisions file; when absent, readFile on the old
          clericfood file and say so. Then merge and clamp.
  WHEN  : Once at startup.
----------------------------------------------------------------------------]]
function core.load()
    local loaded = readFile(core.path())
    if not loaded then
        -- First run as Provisions: bring over the ClericFood choices if any.
        loaded = readFile(settingsPath('clericfood'))
        if loaded then core.echo('Imported your old ClericFood settings.') end  -- saved under the new name on next save
    end
    loaded = loaded or {}   -- still nothing: start from the defaults

    -- Merge: any key the file lacks gets its default; file values win.
    for key, value in pairs(core.DEFAULTS) do
        if loaded[key] == nil then loaded[key] = deepCopy(value) end
    end

    -- Sanitise every number to a range the code can handle.
    loaded.foodCount        = core.clamp(loaded.foodCount, 0, 80)
    loaded.drinkCount       = core.clamp(loaded.drinkCount, 0, 80)
    loaded.gem              = core.clamp(loaded.gem, 1, 13)
    loaded.castMaxTries     = core.clamp(loaded.castMaxTries, 1, 20)      -- MQ2Cast -maxtries
    loaded.summonTimeoutMin = core.clamp(loaded.summonTimeoutMin, 0, 240) -- 0 = no limit
    loaded.medTimeoutSec    = core.clamp(loaded.medTimeoutSec, 10, 600)   -- mana wait per cast
    loaded.tradeTimeoutSec  = core.clamp(loaded.tradeTimeoutSec, 3, 60)   -- accept wait
    loaded.tradeRange       = core.clamp(loaded.tradeRange, 5, 25)        -- EQ allows about 20
    loaded.navTimeoutSec    = core.clamp(loaded.navTimeoutSec, 5, 120)    -- walking limit
    loaded.combatSettleSec  = core.clamp(loaded.combatSettleSec, 0, 60)   -- quiet time after a fight
    loaded.busyTries        = core.clamp(loaded.busyTries, 1, 10)         -- attempts per busy member
    loaded.busyRetrySec     = core.clamp(loaded.busyRetrySec, 2, 120)     -- gap between attempts
    -- The roster ticks must be a table; anything else is replaced.
    if type(loaded.selected) ~= 'table' then loaded.selected = {} end

    core.settings = loaded   -- publish as the live table
    core.debug('Settings loaded from %s', core.path())
end

--[[--------------------------------------------------------------------------
  core.save()

  WHAT  : Writes the live settings to this character's file.
  WHY   : Keeps window choices between sessions.
  WHERE : ui.lua after a change, init.lua on commands and exit, casting.lua
          after learning an item name.
  HOW   : mq.pickle inside pcall, so a locked file only prints an error.
  WHEN  : After changes and at shutdown.
----------------------------------------------------------------------------]]
function core.save()
    local ok, err = pcall(mq.pickle, core.path(), core.settings)
    if not ok then core.err('Could not save settings: %s', tostring(err)) end  -- report, never crash
end

--[[==========================================================================
  PART 3 : GROUP ROSTER
==========================================================================]]--

--- Cached roster -----------------------------------------------------------------
-- WHAT : Array of member rows, caster first.
-- WHY  : The window reads it every frame; rebuilding it every frame would
--        cost dozens of TLO calls for no benefit.
-- WHERE: Read by ui.lua and init.lua, written by core.refreshRoster.
-- HOW  : Each row:
--          name     string  character name (also the key for the tick)
--          id       number  spawn id in this zone, nil when out of zone
--          isSelf   bool    true for the caster's own row
--          isMerc   bool    true for a mercenary (cannot trade)
--          present  bool    true when in this zone
--          distance number  units from the caster (0 self, 9999 unknown)
--          class    string  three letter class, for example WAR
-- WHEN : Replaced on each refresh.
core.roster = {}

--- Refresh throttle --------------------------------------------------------------
-- WHAT : Time of the last rebuild in milliseconds, and the minimum gap.
-- WHY  : The window repaints about sixty times a second; twice a second is
--        plenty for a roster.
-- WHERE: core.refreshRoster.
-- HOW  : Compared against mq.gettime.
-- WHEN : Every refresh call.
local lastRefresh = 0
local REFRESH_MS  = 500

--[[--------------------------------------------------------------------------
  buildRow(member, isSelf)

  WHAT  : Converts one Group.Member TLO into a plain roster row.
  WHY   : Plain values stay safe to read even after the member leaves; a
          stale TLO would return nil fields in the middle of a draw.
  WHERE : core.refreshRoster.
  HOW   : Reads name, spawn id, distance, mercenary flag and class.
  WHEN  : During refresh.
----------------------------------------------------------------------------]]
local function buildRow(member, isSelf)
    local spawn = member.Spawn            -- the in zone body of the member
    local id = spawn.ID()                 -- nil when in another zone
    return {
        name     = member.Name() or '?',                     -- works across zones
        id       = id,                                       -- spawn id or nil
        isSelf   = isSelf,                                   -- member 0 is the caster
        isMerc   = member.Mercenary() == true,               -- mercs cannot trade
        present  = id ~= nil and id > 0,                     -- in this zone
        distance = isSelf and 0 or (spawn.Distance() or 9999),  -- 9999 = unknown
        class    = spawn.Class.ShortName() or '',            -- for example WAR
    }
end

--[[--------------------------------------------------------------------------
  core.refreshRoster(force)

  WHAT  : Rebuilds core.roster from the live group.
  WHY   : Keeps the checkbox list and the job in step with the game.
  WHERE : ui.lua every frame (throttled); init.lua with force = true.
  HOW   : Solo: just the caster from Me. Grouped: Group.Member(0) through
          Group.Member(Group.Members). The finished list is swapped in with
          one assignment so the window never sees half a roster.
  WHEN  : See WHERE.
----------------------------------------------------------------------------]]
function core.refreshRoster(force)
    local now = mq.gettime()
    if not force and now - lastRefresh < REFRESH_MS then return end  -- throttle
    lastRefresh = now

    local rows = {}
    -- Group.Members counts the OTHER members: 0 when solo, up to 5.
    local count = mq.TLO.Group.Members() or 0
    if count == 0 then
        -- Solo: build the caster's row straight from Me.
        rows[1] = { name = mq.TLO.Me.CleanName() or 'Me', id = mq.TLO.Me.ID(),
            isSelf = true, isMerc = false, present = true, distance = 0,
            class = mq.TLO.Me.Class.ShortName() or '' }   -- caster's class
    else
        -- Grouped: member 0 is the caster, 1 to count are the others.
        for i = 0, count do
            local member = mq.TLO.Group.Member(i)
            if member() then rows[#rows + 1] = buildRow(member, i == 0) end  -- skip empty slots
        end
    end
    core.roster = rows   -- one assignment, never half built
end

--[[--------------------------------------------------------------------------
  core.isSelected(name) / core.setSelected(name, value)

  WHAT  : Read and write the tick of one member by name.
  WHY   : Ticks are stored by name so they survive the group being reformed
          in a different order or the script restarting.
  WHERE : ui.lua checkboxes, core.setAll, core.selectedRows.
  HOW   : core.settings.selected[name]. Unticking stores nil so the settings
          file stays short.
  WHEN  : On draw and on click.
----------------------------------------------------------------------------]]
function core.isSelected(name)
    return core.settings.selected[name] == true   -- missing means not ticked
end

-- Store a tick (value true) or remove it (value false). See the block above.
function core.setSelected(name, value)
    core.settings.selected[name] = value and true or nil   -- nil keeps the file short
end

--[[--------------------------------------------------------------------------
  core.setAll(value)

  WHAT  : Ticks or unticks every eligible member at once.
  WHY   : Feeding the whole group is the common case and should be one click.
  WHERE : ui.lua Select all and Clear, /provisions all in init.lua.
  HOW   : Loops the roster, skipping mercenaries.
  WHEN  : On button press or command.
----------------------------------------------------------------------------]]
function core.setAll(value)
    for _, row in ipairs(core.roster) do
        if not row.isMerc then core.setSelected(row.name, value) end  -- mercs stay unticked
    end
end

--[[--------------------------------------------------------------------------
  core.selectedRows()

  WHAT  : Returns the roster rows that are ticked and can really be served.
  WHY   : The job should only ever see valid targets.
  WHERE : init.lua job start.
  HOW   : Ticked, not a mercenary, and in this zone.
  WHEN  : At job start.
----------------------------------------------------------------------------]]
function core.selectedRows()
    local out = {}
    for _, row in ipairs(core.roster) do
        -- All three must hold.
        if core.isSelected(row.name) and not row.isMerc and row.present then
            out[#out + 1] = row
        end
    end
    return out   -- ticked rows that can receive items
end

--[[==========================================================================
  PART 4 : SHARED JOB STATE, PAUSE AND COMBAT
==========================================================================]]--

--- Job state ---------------------------------------------------------------------
-- WHAT : Flags and display text describing the current or last job.
-- WHY  : The window, the slash commands and the job runner all need them.
--        Keeping them here means ui.lua never has to require init.lua.
-- WHERE: Written by the functions below and by init.lua; read by ui.lua.
-- HOW  : requested      Hand Out pressed, job not started yet
--        running        a job is in progress
--        stopRequested  Stop pressed, cleanup not finished yet
--        paused         Pause pressed; the job holds at the next safe point
--        hold           '' when working, else 'Paused' or 'Combat hold'
--        status         one line of text for the window
--        results        member name -> { food, drink, note }
--        completed      number of jobs finished this session
--        checkRequested Check links pressed, check not started yet
--        linkLoadRequested a link was picked (or startup); load its plugin
-- WHEN : Updated throughout a job.
core.job = {
    requested     = false,
    running       = false,
    stopRequested = false,   -- true after Stop until cleanup
    paused        = false,   -- true while Pause is wanted
    hold          = '',      -- shown in the window while holding
    status        = 'Idle',  -- shown next to the buttons
    results       = {},      -- filled per member by init.lua
    completed     = 0,       -- also lets the PC smoke test know a job ended
    checkRequested = false,  -- Check links pressed; init.lua tick runs it
    linkLoadRequested = false, -- link picked or startup; init.lua tick loads the plugin
}

--[[--------------------------------------------------------------------------
  core.request() / core.stop()

  WHAT  : Ask for a job to start, or ask the running job to stop.
  WHY   : Safe from the window and from slash commands because neither
          waits; they only flip flags that init.lua's main loop acts on.
  WHERE : ui.lua buttons, /provisions go and /provisions stop.
  HOW   : request is ignored while a job runs. stop also clears Pause so a
          paused job can wind down at once.
  WHEN  : On operator input.
----------------------------------------------------------------------------]]
function core.request()
    if core.job.running then
        core.warn('A hand out is already running.')
        return
    end
    core.job.requested = true   -- picked up by the main loop's next pass
end

--[[--------------------------------------------------------------------------
  core.requestCheck()

  WHAT  : Ask for a link check (no summoning, no trading).
  WHY   : The check waits for answers from other boxes, which the window
          and slash commands may not do, so like core.request it only sets
          a flag.
  WHERE : ui.lua Check links button and /provisions check.
  HOW   : Ignored while a job or a check runs. init.lua tick picks it up.
  WHEN  : On operator input.
----------------------------------------------------------------------------]]
function core.requestCheck()
    if core.job.running then
        core.warn('Busy, try the link check when this finishes.')
        return
    end
    core.job.checkRequested = true   -- picked up by the main loop's next pass
end

--[[--------------------------------------------------------------------------
  core.requestLinkLoad()

  WHAT  : Ask for the chosen link plugin to be loaded on this character.
  WHY   : Loading means waiting for the plugin to start, which the window
          may not do, so like core.request it only sets a flag.
  WHERE : ui.lua drawOptions (a link radio button is clicked) and init.lua
          startup.
  HOW   : Sets core.job.linkLoadRequested; init.lua tick runs loadLinkNow.
          No warning while busy: the options are locked during a job, and
          every job loads the plugin itself anyway.
  WHEN  : On a link pick and at startup.
----------------------------------------------------------------------------]]
function core.requestLinkLoad()
    core.job.linkLoadRequested = true   -- picked up by the main loop's next pass
end

-- Stop the running job. Works while paused or holding too.
function core.stop()
    if not core.job.running then return end   -- nothing to stop
    core.job.stopRequested = true             -- every core.delay now ends early
    core.job.paused = false                   -- release a pause so cleanup runs
    core.job.status = 'Stopping...'
end

--[[--------------------------------------------------------------------------
  core.pause() / core.resume() / core.togglePause()

  WHAT  : Hold the running job at its next safe point, or let it carry on.
  WHY   : The operator may need a moment without losing progress. Pause
          never cuts a cast or an open trade short; the hold starts at the
          next checkpoint. RGMercs stays paused during a manual Pause.
  WHERE : ui.lua Pause / Resume button, /provisions pause and /provisions resume.
  HOW   : Flip core.job.paused. The checkpoint code in init.lua does the
          actual holding.
  WHEN  : On operator input while a job runs.
----------------------------------------------------------------------------]]
function core.pause()
    if not core.job.running or core.job.paused then return end   -- only while running
    core.job.paused = true
    core.echo('Pause requested. Holding at the next safe point.')
end

-- Let a paused job carry on from where it stopped.
function core.resume()
    if not core.job.paused then return end   -- not paused, nothing to do
    core.job.paused = false
    core.echo('Resuming.')
end

-- One button that does whichever of the two applies.
function core.togglePause()
    if core.job.paused then core.resume() else core.pause() end  -- flip
end

--[[--------------------------------------------------------------------------
  core.inCombat()

  WHAT  : True when the caster is in a fight.
  WHY   : Nothing can be handed out while being attacked, and a summon spell
          will only be interrupted. Combat Hold uses this.
  WHERE : core.holdWanted, init.lua checkpoint, delivery.lua accept wait.
  HOW   : Two documented MacroQuest values. Me.CombatState reads COMBAT
          while in combat (it returns ACTIVE on clients that lack the
          feature). Me.XTHaterCount counts mobs on the extended target
          window that are attacking you, which catches a fight that has
          started before the combat state changes.
  WHEN  : At every checkpoint and while waiting on a trade.
----------------------------------------------------------------------------]]
function core.inCombat()
    if mq.TLO.Me.CombatState() == 'COMBAT' then return true end  -- game says fighting
    return (mq.TLO.Me.XTHaterCount() or 0) > 0                    -- something hates us
end

--[[--------------------------------------------------------------------------
  core.holdWanted()

  WHAT  : True when the job should stop at its next safe point.
  WHY   : Long waits inside casting.lua (meditating, MQ2Cast retries) end
          early when this turns true, so a hold starts promptly.
  WHERE : casting.lua waitForMana and castWithMQ2Cast, delivery.lua.
  HOW   : Paused, or Combat Hold on and in combat.
  WHEN  : Inside long waits.
----------------------------------------------------------------------------]]
function core.holdWanted()
    if core.job.paused then return true end                     -- manual Pause
    return core.settings.combatHold == true and core.inCombat() -- Combat Hold
end

--- Checkpoint hook -------------------------------------------------------------------
-- WHAT : The function that runs at each safe point of the job.
-- WHY  : The real hold logic needs RGMercs state that lives in init.lua.
--        Binding it here lets casting.lua and delivery.lua call
--        core.checkpoint without requiring init.lua.
-- WHERE: Bound by init.lua at load, called through core.checkpoint.
-- HOW  : Must return two values: true to carry on (false when Stop was
--        pressed), and the milliseconds spent holding. The default never
--        holds.
-- WHEN : Bound once at startup.
local checkpointFn = function() return not core.aborted(), 0 end

--[[--------------------------------------------------------------------------
  core.bindCheckpoint(fn) / core.checkpoint()

  WHAT  : Install the hold logic, and run it at a safe point.
  WHY   : See the checkpoint hook note above.
  WHERE : init.lua binds; casting.lua summon loop and init.lua trade queue
          call core.checkpoint.
  HOW   : bindCheckpoint stores fn when it is a function. checkpoint calls
          it and passes both results back.
  WHEN  : Before every cast and every trade.
----------------------------------------------------------------------------]]
function core.bindCheckpoint(fn)
    if type(fn) == 'function' then checkpointFn = fn end   -- ignore anything else
end

-- Run the bound hold logic. Returns carry on (bool) and held milliseconds.
function core.checkpoint()
    return checkpointFn()
end

return core   -- hand the module table to require('provisions.core')

--[[==========================================================================
  END OF FILE : provisions/core.lua

  SUMMARY OF PUBLIC API
    Part 1  color, echo, good, warn, err, debug, cmd, aborted,
            delay(ms, cond), clamp(v, lo, hi)
    Part 2  DEFAULTS, settings, path(), load(), save()
    Part 3  roster, refreshRoster(force), isSelected(name),
            setSelected(name, v), setAll(v), selectedRows()
    Part 4  job, request(), stop(), pause(), resume(), togglePause(),
            inCombat(), holdWanted(), bindCheckpoint(fn), checkpoint()

  DEPENDENCIES : mq only.

  HOW TO EDIT SAFELY
    - Never require another provisions file from here. Every file requires
      core, so that would create a require loop.
    - core.delay must stay the only waiting helper. A loop without mq.delay
      anywhere freezes the game client.
    - Add a setting: one commented key in DEFAULTS, a clamp line in
      core.load if it is a number, and a control in ui.lua drawOptions.
      Old settings files pick it up automatically.
    - Change the chat tag: edit PREFIX.
    - Change what counts as combat: edit core.inCombat. Both values used
      are on the MacroQuest character data type page.
    - The old ClericFood settings import in core.load only runs when no
      Provisions file exists yet. It can be removed in a later version.
==========================================================================]]--
