--[[==========================================================================
  FILE        : provisions/init.lua
  PACKAGE     : Provisions Lua  (MacroQuest / EverQuest)
  VERSION     : 2.0.0
  CHANGES     : 2.0.0  Merges the ClericFood 1.3.2 files init.lua and
                       actions.lua. Renamed to Provisions; the command is now
                       /prov. Adds the checkpoint that holds the job for
                       Pause and Combat Hold (RGMercs is handed back during a
                       fight and paused again afterwards), a trade queue
                       that moves busy members to the back and gives up
                       after a set number of tries, and the /prov pause and
                       /prov resume commands.
                1.0.0 to 1.3.2  Released as ClericFood (init.lua,
                       actions.lua). Full history in CHANGELOG.md.

  WHAT  : The entry point and the job runner. Loads settings, registers the
          /prov command and the window, then loops: when Hand Out is
          pressed it runs one complete job (summon, then trade to each
          ticked member) and always cleans up afterwards.

  WHY   : ImGui window code may not wait, but a job waits constantly (casts,
          trades, walking). So the window only sets a flag, and this file's
          main loop, which is allowed to wait, does the work. Keeping the
          runner and the entry point together puts the whole life of the
          script in one readable file.

  WHERE : Run by MacroQuest with /lua run provisions. MacroQuest looks for
          lua/provisions/init.lua. Requires every other file.

  HOW   : 1. startup: load settings, detect spells, fill the roster, bind
             /prov, register the window, install the checkpoint.
          2. main loop: tick (runs a requested job), check the game state,
             mq.delay(100).
          3. shutdown: save, unbind, say goodbye.

  WHEN  : From /lua run provisions until /prov quit, camping, or
          /lua stop provisions.

  READING GUIDE (for future you)
    - A job is: plan -> summon food -> summon drink -> trade queue.
      Its readable sequence is in run(); cleanup() undoes everything.
    - "Checkpoint" (see core.lua part 4) is a safe point before every cast
      and every trade. The code that runs there is checkpoint() in this
      file. It holds the job while:
        Paused       the operator pressed Pause; RGMercs stays paused
        Combat hold  the caster is in combat, and for combatSettleSec
                     seconds afterwards; RGMercs is handed back to fight
    - "Busy" means a member could not be traded right now (fighting, out of
      range, did not accept). Busy members go to the back of the queue and
      are tried again after busyRetrySec, up to busyTries times.
==========================================================================]]--

local mq       = require('mq')                    -- TLO, delay, bind, imgui
local core     = require('provisions.core')       -- helpers, settings, roster, job
local delivery = require('provisions.delivery')   -- bag counts, trades, DanNet
local casting  = require('provisions.casting')    -- spell detection and summoning
local ui       = require('provisions.ui')         -- the window

--- Main loop flag --------------------------------------------------------------------
-- WHAT : true while the script should keep running.
-- WHY  : /prov quit sets it false so the loop ends and shutdown runs.
-- WHERE: onCommand and the main loop.
-- HOW  : Plain boolean.
-- WHEN : Read every loop pass.
local running = true

--- Per job state -------------------------------------------------------------------
-- WHAT : What this job changed outside the package, so it can be undone.
-- WHY  : cleanup and the checkpoint must know whether this job paused
--        RGMercs, whether it is currently handed back during a fight, and
--        when the post combat settle time ends.
-- WHERE: run, checkpoint, cleanup.
-- HOW  : pausedMercs  this job sent /rgl pause
--        handedBack   /rgl unpause sent for a fight, not paused again yet
--        settleUntil  mq.gettime value until which the hold continues
--        savedStatus  status line to put back after a hold
-- WHEN : Reset at the start of every job.
local state = { pausedMercs = false, handedBack = false, settleUntil = 0, savedStatus = '' }

--[[--------------------------------------------------------------------------
  setStatus(fmt, ...)

  WHAT  : Updates the status line and echoes it.
  WHY   : Window and chat log say the same thing.
  WHERE : Throughout this file.
  HOW   : Formats into core.job.status, then core.echo.
  WHEN  : At each phase change.
----------------------------------------------------------------------------]]
local function setStatus(fmt, ...)
    core.job.status = select('#', ...) > 0 and string.format(fmt, ...) or fmt
    core.echo(core.job.status)
end

--[[--------------------------------------------------------------------------
  rgmercsRunning()

  WHAT  : True when the RGMercs Lua script is running on this client.
  WHY   : /rgl commands are only sent when RGMercs is loaded.
  WHERE : run.
  HOW   : Lua.Script('rgmercs').Status.
  WHEN  : Job start.
----------------------------------------------------------------------------]]
local function rgmercsRunning()
    return mq.TLO.Lua.Script('rgmercs').Status() == 'RUNNING'
end

--[[--------------------------------------------------------------------------
  checkpoint()

  WHAT  : The hold logic run at every safe point. Returns carry on (false
          when Stop was pressed) and the milliseconds spent holding.
  WHY   : A caster under attack cannot hand anything out and would only be
          interrupted casting, and the operator sometimes needs a moment.
          Holding at a safe point means no cast or trade is ever cut short.
  WHERE : Installed with core.bindCheckpoint in startup; called through
          core.checkpoint by casting.summonUntil and serveMembers.
  HOW   : Loops every 250 ms while a hold applies:
            - In combat (Combat Hold on): push settleUntil forward. The
              first time, if combatHandBack is on and this job paused
              RGMercs, send /rgl unpause once so RGMercs can fight.
            - Combat over and settle time passed: if RGMercs was handed
              back, send /rgl pause again.
            - Combat hold wins over Paused. A manual Pause keeps RGMercs
              paused, and a job paused during a fight stays Paused after.
          core.job.hold shows the reason in the window.
  WHEN  : Before every cast and every trade.
----------------------------------------------------------------------------]]
local function checkpoint()
    local job, s = core.job, core.settings
    local started, reason = mq.gettime(), ''   -- reason is the current hold text
    while not core.aborted() do
        local now      = mq.gettime()
        local fighting = s.combatHold and core.inCombat()
        if fighting then   -- still fighting
            state.settleUntil = now + s.combatSettleSec * 1000   -- settle restarts
            if s.combatHandBack and state.pausedMercs and not state.handedBack then
                core.cmd('/rgl unpause')    -- let RGMercs fight
                state.handedBack = true
            end
        elseif now >= state.settleUntil and state.handedBack then
            core.cmd('/rgl pause')          -- fight over: take control again
            state.handedBack = false
        end

        -- Which hold applies now, if any.
        local want = ''
        if fighting or now < state.settleUntil then
            want = 'Combat hold'
        elseif job.paused then   -- no fight, but the operator paused
            want = 'Paused'   -- manual Pause hold
        end
        if want == '' then break end        -- nothing holding us: carry on

        if want ~= reason then              -- entered or changed hold
            if reason == '' then state.savedStatus = job.status end
            reason, job.hold = want, want
            if want == 'Combat hold' then
                setStatus('Combat hold: waiting for the fight to end.')   -- shown in the window and chat
            else
                setStatus('Paused. Press Resume to carry on.')   -- shown in the window and chat
            end
        end
        mq.delay(250)                       -- yield while holding
    end

    local heldMs = 0
    if reason ~= '' then   -- we did hold this time
        heldMs = mq.gettime() - started     -- time spent holding
        job.hold = ''
        if not core.aborted() then
            job.status = state.savedStatus  -- put the old status back
            core.echo('Carrying on: %s', job.status)
        end
    end
    return not core.aborted(), heldMs   -- carry on flag and held time
end

--[[--------------------------------------------------------------------------
  planNeeds(rows)

  WHAT  : Works out how much food and drink each member should receive and
          the totals the caster must carry.
  WHY   : Summoning must be sized before trading starts, and Top up mode
          changes the per member numbers.
  WHERE : run.
  HOW   : Other members: full counts, or in Top up mode the shortfall
          reported by DanNet (full counts if no answer). The caster's own
          row, when ticked: an extra set, or in Top up mode the shortfall.
          Carry target = handed out + own share + existing stock when
          preserveOwnStock is on.
  WHEN  : Once at job start.
  RETURNS : { members = { {row, food, drink}, ... }, selfFood, selfDrink,
              totalFood, totalDrink, carryFood, carryDrink, reserveFood,
              reserveDrink }. The reserve must still be in the bags after
              trading.
----------------------------------------------------------------------------]]
local function planNeeds(rows)
    local s = core.settings
    local plan = { members = {}, selfFood = 0, selfDrink = 0, totalFood = 0, totalDrink = 0 }
    local haveFood  = delivery.count(s.foodItem)    -- caster stock now
    local haveDrink = delivery.count(s.drinkItem)

    for _, row in ipairs(rows) do
        local food, drink = s.foodCount, s.drinkCount   -- full amounts to start with
        if row.isSelf then   -- the caster ticked its own row
            if s.topUp then   -- only the shortfall for the caster
                food  = math.max(0, food - haveFood)    -- only the shortfall
                drink = math.max(0, drink - haveDrink)
            end
            plan.selfFood, plan.selfDrink = food, drink
        else
            if s.topUp then   -- ask the box what it carries
                local hf = delivery.queryCount(row.name, s.foodItem)    -- nil if no answer
                local hd = delivery.queryCount(row.name, s.drinkItem)
                if hf then food  = math.max(0, food - hf) end
                if hd then drink = math.max(0, drink - hd) end
            end
            plan.members[#plan.members + 1] = { row = row, food = food, drink = drink }   -- remember the amounts for trading
            plan.totalFood  = plan.totalFood + food   -- running total of food for others
            plan.totalDrink = plan.totalDrink + drink   -- running total of drink for others
        end
    end

    local baseFood  = s.preserveOwnStock and haveFood or 0    -- keep existing stock
    local baseDrink = s.preserveOwnStock and haveDrink or 0
    plan.carryFood    = baseFood  + plan.totalFood  + plan.selfFood
    plan.carryDrink   = baseDrink + plan.totalDrink + plan.selfDrink
    plan.reserveFood  = baseFood  + plan.selfFood   -- food that must stay in our bags
    plan.reserveDrink = baseDrink + plan.selfDrink   -- drink that must stay in our bags
    return plan   -- see RETURNS above
end

--[[--------------------------------------------------------------------------
  serveMembers(plan)

  WHAT  : Trades to every planned member through a retry queue. Returns the
          names of members who were given up on.
  WHY   : A member who is fighting will not open a trade window. Moving
          them to the back and trying again later serves everyone else
          first instead of failing the job.
  WHERE : run.
  HOW   : Queue entries { m, tries, notBefore }. Each pass:
            1. core.checkpoint (Pause and Combat Hold).
            2. Take the first entry whose notBefore has passed; if none is
               ready, wait 500 ms.
            3. Work out what can be spared without touching the reserve.
            4. If DanNet answers that the member is in combat, count it as
               busy without trying.
            5. Otherwise delivery.giveItems. Reasons:
                 ok      record and report
                 combat  the caster was attacked: back of the queue at no
                         cost; the next checkpoint holds
                 busy, range, failed  tries + 1; after busyTries give up,
                         else back of the queue for busyRetrySec
  WHEN  : After summoning.
----------------------------------------------------------------------------]]
local function serveMembers(plan)
    local s, results = core.settings, core.job.results
    local queue, gaveUp = {}, {}
    for _, m in ipairs(plan.members) do   -- every planned member joins the queue
        queue[#queue + 1] = { m = m, tries = 0, notBefore = 0 }   -- no tries yet, ready now
    end

    while #queue > 0 and not core.aborted() do   -- until everyone is served, given up, or Stop
        -- Step 1: safe point.
        if not core.checkpoint() then break end   -- Stop while holding

        -- Step 2: first entry that is ready.
        local now, idx = mq.gettime(), nil
        for i, e in ipairs(queue) do
            if e.notBefore <= now then idx = i break end
        end
        if not idx then   -- nobody is ready yet
            core.delay(500)   -- everyone left is waiting out busyRetrySec
        else
            local e = table.remove(queue, idx)
            local m = e.m

            -- Step 3: never dip into the reserve.
            local spareFood  = math.max(0, delivery.count(s.foodItem)  - plan.reserveFood)
            local spareDrink = math.max(0, delivery.count(s.drinkItem) - plan.reserveDrink)
            local food  = math.min(m.food,  spareFood)
            local drink = math.min(m.drink, spareDrink)   -- never more drink than we can spare
            if food < m.food or drink < m.drink then   -- stock ran short (summon stopped or timed out)
                core.warn('Short on stock for %s: giving %d food, %d drink.', m.row.name, food, drink)   -- yellow warning for the shortfall
            end
            local items = {}   -- what to hand this member
            if food  > 0 then items[#items + 1] = { item = s.foodItem,  count = food  } end   -- food line for the trade
            if drink > 0 then items[#items + 1] = { item = s.drinkItem, count = drink } end   -- drink line for the trade

            local reason, got = 'ok', {}   -- default outcome before trying
            if #items == 0 then   -- nothing to give this member
                results[m.row.name] = { food = 0, drink = 0, note = 'already stocked' }   -- green note in the window
                reason = 'done'   -- finished, no retry needed
            elseif delivery.peerInCombat(m.row.name) == true then   -- DanNet says the member is fighting
                core.warn('%s is in combat, will try again later.', m.row.name)  -- step 4
                reason = 'busy'
            else
                -- Step 5: one trade attempt.
                setStatus('Trading %d food, %d drink to %s.', food, drink, m.row.name)
                got, reason = delivery.giveItems(m.row, items)
            end

            if reason == 'ok' then   -- something arrived
                local gf, gd = got[s.foodItem] or 0, got[s.drinkItem] or 0   -- delivered counts, 0 if none
                results[m.row.name] = { food = gf, drink = gd }   -- for the Last result column
                if gf == food and gd == drink then   -- full delivery
                    core.good('%s received %d food, %d drink.', m.row.name, gf, gd)   -- green success line
                else
                    core.warn('%s received %d of %d food, %d of %d drink.', m.row.name, gf, food, gd, drink)   -- yellow partial line
                end
            elseif reason == 'combat' then   -- the caster was attacked
                table.insert(queue, e)   -- our fight, not theirs: no try used
            elseif reason ~= 'done' and reason ~= 'stop' then
                e.tries = e.tries + 1
                if e.tries >= s.busyTries then
                    results[m.row.name] = { food = 0, drink = 0, note = 'busy, gave up' }   -- red in the window
                    gaveUp[#gaveUp + 1] = m.row.name   -- listed in chat at the end
                    core.warn('Giving up on %s after %d tries.', m.row.name, e.tries)   -- yellow warning
                else
                    e.notBefore = mq.gettime() + s.busyRetrySec * 1000   -- not before busyRetrySec from now
                    results[m.row.name] = { food = 0, drink = 0, note = string.format('busy, try %d of %d', e.tries, s.busyTries) }   -- amber waiting note in the window
                    table.insert(queue, e)   -- back of the line
                end
            end
        end
    end
    return gaveUp   -- names given up on
end

--[[--------------------------------------------------------------------------
  cleanup()

  WHAT  : Returns the caster to a normal state after any job.
  WHY   : A job can end by success, Stop, or a Lua error. In every case an
          open trade must close, the cursor must be empty, the spell bar
          must be restored and RGMercs must resume if this job paused it.
  WHERE : tick, after run returns or errors.
  HOW   : Clears the stop, pause and hold flags first so the restore waits
          are not cut short, then cancels the trade, clears the cursor,
          stops nav, restores the gem, unloads MQ2Cast if loaded by us, and
          sends /rgl unpause only when this job paused RGMercs and it is not
          already handed back.
  WHEN  : End of every job.
----------------------------------------------------------------------------]]
local function cleanup()
    core.job.stopRequested = false   -- let cleanup waits run fully
    core.job.paused, core.job.hold = false, ''
    delivery.cancel()                -- no op when no trade is open
    delivery.clearCursor()
    if mq.TLO.Navigation.Active() then core.cmd('/nav stop') end
    casting.restore()                -- put the borrowed gem back
    casting.endJob()                 -- unload MQ2Cast if we loaded it
    if state.pausedMercs and not state.handedBack then
        core.cmd('/rgl unpause')     -- only if WE paused it
    end
end

--[[--------------------------------------------------------------------------
  run()

  WHAT  : One complete hand out.
  WHY   : The readable top to bottom sequence of the whole feature.
  WHERE : tick only.
  HOW   : 1. Detect spells, refresh the roster, collect ticked rows.
          2. Pause RGMercs if wanted and running; prepare casting.
          3. Plan needs.
          4. Summon food, then drink, up to the carry targets.
          5. Serve members through the retry queue.
          6. Report.
  WHEN  : When a job has been requested.
----------------------------------------------------------------------------]]
local function run()
    local s = core.settings
    core.job.results = {}   -- clear the window's result column
    casting.detect()
    core.refreshRoster(true)
    local rows = core.selectedRows()
    if #rows == 0 then   -- nobody to serve
        setStatus('Nobody ticked (or ticked members are not in zone).')   -- shown in the window and chat
        return
    end
    if s.foodCount == 0 and s.drinkCount == 0 then   -- both counts zero means nothing to do
        setStatus('Food and drink counts are both zero.')   -- tell the operator instead of doing nothing
        return
    end

    -- Step 2: take RGMercs out of the way while we work.
    if s.pauseRGMercs and rgmercsRunning() then
        core.cmd('/rgl pause')
        state.pausedMercs = true   -- remembered for checkpoint and cleanup
    end
    casting.beginJob()

    -- Step 3.
    setStatus('Planning hand out for %d member(s).', #rows)
    local plan = planNeeds(rows)

    -- Step 4: summon. Skip a kind when its count is 0 or we hold enough.
    if s.foodCount > 0 and plan.carryFood > delivery.count(s.foodItem) then
        setStatus('Summoning food: need %d.', plan.carryFood)
        casting.summonUntil('food', plan.carryFood)
    end
    if core.aborted() then setStatus('Stopped.') return end   -- Stop during food: skip the rest
    if s.drinkCount > 0 and plan.carryDrink > delivery.count(s.drinkItem) then   -- skip drink if 0 or we hold enough
        setStatus('Summoning drink: need %d.', plan.carryDrink)   -- status while summoning drink
        casting.summonUntil('drink', plan.carryDrink)   -- casts until carryDrink is held
    end
    if core.aborted() then setStatus('Stopped.') return end   -- Stop during drink: skip trading

    -- Step 5: stand (meditating may have sat us down) and trade.
    if mq.TLO.Me.Sitting() then core.cmd('/stand') end
    local gaveUp = serveMembers(plan)

    -- Step 6: report.
    if plan.selfFood > 0 or plan.selfDrink > 0 then
        core.job.results[mq.TLO.Me.CleanName() or 'Me'] = {
            food = plan.selfFood, drink = plan.selfDrink, note = 'kept' }
    end
    if #gaveUp > 0 then   -- some members were never served
        core.warn('Not served (busy): %s. Press Hand Out again later.', table.concat(gaveUp, ', '))   -- yellow list in chat
    end
    setStatus(core.aborted() and 'Stopped.' or 'Hand out complete.')   -- final status for this job
end

--[[--------------------------------------------------------------------------
  tick()

  WHAT  : Starts a requested job and guarantees cleanup afterwards.
  WHY   : The bridge between the non blocking window and the waiting job.
  WHERE : Main loop.
  HOW   : If requested: reset flags and state, run inside pcall, report any
          error, always cleanup, count the completed job.
  WHEN  : Every main loop pass; returns at once when nothing is requested.
----------------------------------------------------------------------------]]
local function tick()
    local job = core.job
    if not job.requested then return end   -- the common case
    job.requested, job.running, job.stopRequested = false, true, false
    job.paused, job.hold = false, ''
    state = { pausedMercs = false, handedBack = false, settleUntil = 0, savedStatus = '' }

    local ok, err = pcall(run)   -- run the whole job, catching any error
    if not ok then   -- the job raised a Lua error
        core.err('Hand out failed: %s', tostring(err))   -- red message with the error text
        job.status = 'Error, see chat.'   -- short status; details are in chat
    end
    cleanup()                        -- always, success or failure
    job.running   = false            -- window re enables Hand Out
    job.completed = job.completed + 1
end

--[[--------------------------------------------------------------------------
  printHelp()

  WHAT  : Lists the slash commands in chat.
  WHY   : Discoverability without opening the README.
  WHERE : /prov help and any unknown /prov argument.
  HOW   : core.echo lines.
  WHEN  : On request.
----------------------------------------------------------------------------]]
local function printHelp()
    core.echo('/prov          toggle the window')
    core.echo('/prov go       hand out with current settings')
    core.echo('/prov stop     stop a running hand out')   -- Stop button equivalent
    core.echo('/prov pause    hold at the next safe point')   -- Pause button equivalent
    core.echo('/prov resume   carry on after a pause')   -- Resume button equivalent
    core.echo('/prov all      tick every eligible group member')   -- Select all button equivalent
    core.echo('/prov food N   set food per member')   -- sets Food each
    core.echo('/prov drink N  set drink per member')   -- sets Drink each
    core.echo('/prov quit     save and end the script')   -- clean exit that saves settings
end

--[[--------------------------------------------------------------------------
  onCommand(...)

  WHAT  : Handler for /prov.
  WHY   : Lets the operator, a hotkey, or another box (through /dex) work
          the package without the window.
  WHERE : Bound with mq.bind in startup.
  HOW   : First word picks the action. Never waits; go only requests a job.
          Pause and resume work while a job holds, because the hold loop
          yields and MacroQuest runs commands during mq.delay.
  WHEN  : Whenever /prov is typed or broadcast.
----------------------------------------------------------------------------]]
local function onCommand(...)
    local args = { ... }                  -- words typed after /prov
    local sub  = (args[1] or ''):lower()  -- first word, any case
    local s    = core.settings
    if sub == '' then
        ui.open = not ui.open             -- bare /prov toggles the window
    elseif sub == 'go' then
        core.request()
    elseif sub == 'stop' then
        core.stop()   -- same as the Stop button
    elseif sub == 'pause' then   -- hold at the next safe point
        core.pause()   -- same as the Pause button
    elseif sub == 'resume' then   -- carry on after a pause
        core.resume()   -- same as the Resume button
    elseif sub == 'all' then   -- tick every non mercenary member
        core.refreshRoster(true)   -- make sure the roster is current
        core.setAll(true)   -- tick everyone eligible
        core.save()   -- remember the ticks
        core.echo('All eligible members ticked.')   -- confirm in chat
    elseif sub == 'food' or sub == 'drink' then   -- set a count from chat, e.g. /prov food 15
        local n = core.clamp(tonumber(args[2]) or 0, 0, 80)   -- 0 to 80, like the window
        s[sub .. 'Count'] = n             -- foodCount or drinkCount
        core.save()
        core.echo('%s per member set to %d.', sub, n)
    elseif sub == 'quit' then
        core.stop()                       -- wind down a running job first
        running = false                   -- loop exits on the next pass
    else
        printHelp()                       -- help, or anything unknown
    end
end

--[[--------------------------------------------------------------------------
  startup()

  WHAT  : One time initialisation.
  WHY   : Settings must exist before the window draws, and the spell lines
          need detection once.
  WHERE : Called once below, before the main loop.
  HOW   : core.load, class note, detect, roster, checkpoint, bind, window.
  WHEN  : Script start.
----------------------------------------------------------------------------]]
local function startup()
    core.load()                              -- first: everything reads settings
    local note = casting.classNote()
    if note then core.warn(note) end         -- non summoning class
    casting.detect()
    core.refreshRoster(true)
    core.bindCheckpoint(checkpoint)          -- Pause and Combat Hold logic
    mq.bind('/prov', onCommand)
    mq.imgui.init('provisions', ui.render)
    core.good('Loaded. Type /prov help for commands.')
end

startup()   -- one time setup before the main loop

--[[==========================================================================
  MAIN LOOP
  WHAT  : Runs jobs and yields.
  WHY   : Jobs must run on this coroutine, not in the window callback.
  WHERE : Here only.
  HOW   : tick, a game state check (ends at camp or character select),
          then mq.delay(100).
  WHEN  : Continuously until quit.
==========================================================================]]--
while running do
    tick()   -- a whole job if one was requested, else returns at once
    if mq.TLO.MacroQuest.GameState() ~= 'INGAME' then
        core.warn('Left the game world, ending.')
        break
    end
    mq.delay(100)   -- yield so the game and the window keep running
end

-- Shutdown: save pending edits, release the command.
ui.flushSave(true)
core.save()
mq.unbind('/prov')
core.echo('Ended.')   -- last line before the script ends

--[[==========================================================================
  END OF FILE : provisions/init.lua

  STARTUP   : /lua run provisions
  COMMANDS  : /prov, go, stop, pause, resume, all, food N, drink N, quit,
              help

  DEPENDENCIES : mq, provisions.core, delivery, casting, ui.
                 Optional: RGMercs (/rgl pause and /rgl unpause).

  HOW TO EDIT SAFELY
    - Never run a job from ui.lua. Window callbacks cannot wait.
    - Add a phase: put it in run in order; if it changes game state, add
      the undo step to cleanup so Stop and errors still put things back.
    - Add a hold reason: extend checkpoint. Keep it yielding (mq.delay)
      and keep Stop able to end it.
    - Add a trade reason: handle it in serveMembers and document it in the
      delivery.lua reading guide.
    - The reserve (own preserved stock plus own ticked share) is never
      handed out; a member is shorted instead.
    - New slash commands go in onCommand, printHelp and the README
      Commands table together.
    - /lua stop provisions ends immediately without the shutdown lines;
      /prov quit is the clean way out.
==========================================================================]]--
