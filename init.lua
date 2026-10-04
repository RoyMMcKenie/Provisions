--[[==========================================================================
  FILE        : clericfood/init.lua
  PACKAGE     : ClericFood Lua  (MacroQuest / EverQuest)
  VERSION     : 1.3.1
  CHANGES     : 1.0.0  First release.
                1.1.0  No change in this file.
                1.2.0  Full inline documentation pass. No behaviour change.
                1.3.0  No change in this file.
                1.3.1  Documentation audit: every code line now carries
                       its own comment or one directly above it.

  WHAT  : Entry point. Loads settings, detects spells, registers the window
          and the /cfood command, and runs the main loop that executes hand
          out jobs.

  WHY   : MacroQuest runs /lua run clericfood by loading this file. Keeping it
          to start up, command binding and the loop means every real behaviour
          lives in a module with one clear job.

  WHERE : <MacroQuest>/lua/clericfood/init.lua

  HOW   : The main loop calls actions.tick (which does nothing unless a job is
          requested) and then mq.delay to yield. Because the job runs inside
          actions.tick on this coroutine, waiting inside it is safe, while the
          ImGui callback stays non blocking.

  WHEN  : From /lua run clericfood until /lua stop clericfood or /cfood quit.

  READING GUIDE (for future you)
    - MacroQuest looks for init.lua when you run a folder by name, so this
      file name must not change.
    - The module map and the full flow of a job are in ARCHITECTURE.md.
    - Two threads of control exist:
        main loop (this file)  -> may wait; runs jobs
        ImGui callback (ui.lua) -> must never wait; only sets flags
==========================================================================]]--

-- Load order matters only in that utils and config must exist before others
-- use them; require handles that automatically because each module requires
-- what it needs.
local mq      = require('mq')
local utils   = require('clericfood.utils')     -- output helpers
local config  = require('clericfood.config')    -- settings load and save
local spells  = require('clericfood.spells')    -- spell detection
local group   = require('clericfood.group')     -- roster for /cfood all
local actions = require('clericfood.actions')   -- the job runner
local ui      = require('clericfood.ui')        -- the window

--- Run flag ------------------------------------------------------------------------
-- WHAT : The main loop runs while this is true.
-- WHY  : /cfood quit needs a clean way to end the script so settings are saved.
-- WHERE: main loop and the quit command.
-- HOW  : Plain boolean.
-- WHEN : Set false only on quit.
local running = true

--[[--------------------------------------------------------------------------
  printHelp()

  WHAT  : Lists the slash commands in chat.
  WHY   : Discoverability without opening the README.
  WHERE : /cfood help and any unknown /cfood argument.
  HOW   : utils.echo lines.
  WHEN  : On request.
----------------------------------------------------------------------------]]
local function printHelp()
    utils.echo('/cfood          toggle the window')
    utils.echo('/cfood go       hand out with current settings')
    utils.echo('/cfood stop     stop a running hand out')  -- Stop button equivalent
    utils.echo('/cfood all      tick every eligible group member')  -- Select all button equivalent
    utils.echo('/cfood food N   set food per member')  -- sets Food each
    utils.echo('/cfood drink N  set drink per member')  -- sets Drink each
    utils.echo('/cfood quit     save and end the script')  -- clean exit that saves settings
end

--[[--------------------------------------------------------------------------
  onCommand(...)

  WHAT  : Handler for /cfood.
  WHY   : Lets the operator, a hotkey, or another box (through /dex) start a
          hand out without touching the window.
  WHERE : Bound with mq.bind in startup.
  HOW   : First argument picks the action. Never waits; go only requests a job
          so the main loop runs it.
  WHEN  : Whenever /cfood is typed or broadcast.
----------------------------------------------------------------------------]]
local function onCommand(...)
    local args = { ... }                    -- words typed after /cfood
    local sub = (args[1] or ''):lower()     -- first word, case insensitive
    local s = config.settings

    if sub == '' then
        ui.open = not ui.open               -- bare /cfood toggles the window
    elseif sub == 'go' then
        actions.request()
    elseif sub == 'stop' then
        actions.stop()  -- same as the Stop button
    elseif sub == 'all' then  -- tick every non mercenary member
        group.refresh(true)                 -- make sure the roster is current
        group.setAll(true)
        config.save()
        utils.echo('All eligible members ticked.')
    elseif sub == 'food' or sub == 'drink' then  -- set a count from chat, e.g. /cfood food 15
        -- /cfood food 15 sets foodCount; same limits as the window.
        local n = utils.clamp(tonumber(args[2]) or 0, 0, 80)
        s[sub .. 'Count'] = n               -- builds 'foodCount' or 'drinkCount'
        config.save()
        utils.echo('%s per member set to %d.', sub, n)
    elseif sub == 'quit' then
        running = false                     -- main loop exits on next pass
    else
        printHelp()                         -- help, or anything unrecognised
    end
end

--[[--------------------------------------------------------------------------
  startup()

  WHAT  : One time initialisation.
  WHY   : Settings must exist before the window draws, and the spell lines in
          the window need detection to have run once.
  WHERE : Called once below, before the loop.
  HOW   : config.load, class check, spells.detect, group.refresh, bind command,
          register window.
  WHEN  : Script start.
----------------------------------------------------------------------------]]
local function startup()
    config.load()   -- must be first; everything else reads settings

    -- Warn, but allow, non clerics. Shaman, druid, magician and beastlord
    -- share the Summon Food and Summon Drink names.
    local class = mq.TLO.Me.Class.ShortName() or ''
    if class ~= 'CLR' then
        utils.warn('Built for clerics. %s can still use it if it has the same summon spells.', class)
    end

    spells.detect()        -- fill the Food spell / Drink spell line
    group.refresh(true)    -- fill the roster before the first frame

    mq.bind('/cfood', onCommand)                  -- register the slash command
    mq.imgui.init('clericfood', ui.render)        -- register the window callback

    utils.good('Loaded. Type /cfood help for commands.')
end

startup()  -- run the one time setup before entering the main loop

--[[==========================================================================
  MAIN LOOP

  WHAT  : Runs jobs and yields.
  WHY   : Jobs must run on this coroutine, not in the ImGui callback.
  WHERE : Here only.
  HOW   : actions.tick then a short mq.delay. The loop also ends if the
          character leaves the game world (camp or zone to character select).
  WHEN  : Continuously until quit.
==========================================================================]]--
while running do
    actions.tick()   -- runs a whole job if one was requested, else returns at once
    if mq.TLO.MacroQuest.GameState() ~= 'INGAME' then
        utils.warn('Left the game world, ending.')
        break
    end
    mq.delay(100)    -- yield 100 ms so the game and window keep running
end

-- Shutdown: save anything pending and release the command name.
ui.flushSave(true)
config.save()
mq.unbind('/cfood')
utils.echo('Ended.')  -- last line printed before the script ends

--[[==========================================================================
  END OF FILE : clericfood/init.lua

  STARTUP
    /lua run clericfood

  COMMANDS
    /cfood, /cfood go, /cfood stop, /cfood all, /cfood food N,
    /cfood drink N, /cfood quit, /cfood help

  DEPENDENCIES : mq, every clericfood module.

  HOW TO EDIT SAFELY
    - Keep the delay in the main loop short (100 ms). Longer makes the Hand
      Out button feel laggy because the job only starts on the next pass.
    - Any new slash command belongs in onCommand and printHelp together, and
      in the Commands table in README.md.
    - /lua stop clericfood ends the script immediately without running the
      shutdown lines; settings changed in the last second may not be saved.
      /cfood quit is the clean way out.
==========================================================================]]--
