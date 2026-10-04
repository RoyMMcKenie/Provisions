--[[==========================================================================
  FILE        : clericfood/actions.lua
  PACKAGE     : ClericFood Lua  (MacroQuest / EverQuest)
  VERSION     : 1.3.1
  CHANGES     : 1.0.0  First release.
                1.1.0  Loads MQ2Cast for the job and unloads it afterwards
                       through spells.beginJob and spells.endJob.
                1.2.0  Full inline documentation pass. No behaviour change.
                1.3.0  No change in this file.
                1.3.1  Documentation audit: every code line now carries
                       its own comment or one directly above it.

  WHAT  : The job runner. When the operator presses Hand Out, this works out
          how much food and drink each ticked member needs, summons enough of
          both, trades it out member by member, and then puts everything back:
          the borrowed spell gem, MQ2Cast, RGMercs, an open trade, the cursor.

  WHY   : ImGui callbacks run every frame and must never wait. Casting and
          trading take many seconds. The window therefore only sets a request
          flag, and init.lua's main loop calls actions.tick, which runs the
          whole job here where waiting is allowed. Keeping all orchestration in
          one file also means the order of operations is readable top to
          bottom in actions.run.

  WHERE : Required by ui.lua (buttons and status) and init.lua (main loop and
          slash commands).

  HOW   : actions.request sets a flag. actions.tick sees it and calls
          actions.run inside pcall, so an unexpected error still reaches the
          cleanup step. Stop sets stopRequested, which utils.delay sees through
          the abort binding and which every loop checks between steps.

  WHEN  : actions.tick runs every main loop pass. actions.run runs only when a
          job has been requested.

  READING GUIDE (for future you)
    - "Job" means one press of Hand Out, start to finish.
    - "Reserve" is the stock the cleric keeps: its existing stock (when Keep
      my existing stock is on) plus its own ticked share. Members are shorted
      before the reserve is touched.
    - Full order of one job:
        tick -> run:
          detect spells, refresh group, collect ticked rows
          pause RGMercs, load MQ2Cast
          planNeeds (Top up queries happen here)
          summon food, summon drink
          trade each member
        tick -> cleanup:
          cancel trade, clear cursor, stop nav, restore gem,
          unload MQ2Cast, unpause RGMercs
==========================================================================]]--

local mq        = require('mq')                     -- TLO and Lua.Script check
local utils     = require('clericfood.utils')       -- echo, cmd, aborted, bindAbortFlag
local config    = require('clericfood.config')      -- counts and options
local inventory = require('clericfood.inventory')   -- stock counts, clearCursor
local spells    = require('clericfood.spells')      -- detect, summonUntil, restore
local group     = require('clericfood.group')       -- roster and ticks
local trade     = require('clericfood.trade')       -- giveItems, queryCount, cancel

local actions = {}

--- Job state ---------------------------------------------------------------------
-- WHAT : Flags and display text describing the current or last job.
-- WHY  : The window shows these so the operator always knows what the cleric
--        is doing and what the last run delivered.
-- WHERE: Written here, read by ui.lua.
-- HOW  : requested     true between Hand Out and the job actually starting
--        running       true while a job is in progress
--        stopRequested true after Stop until cleanup finishes
--        status        one line of text for the window
--        results       member name -> { food = n, drink = n, note = text }
-- WHEN : Updated throughout a job.
actions.requested     = false
actions.running       = false
actions.stopRequested = false
actions.status        = 'Idle'  -- text shown next to the Hand Out button
actions.results       = {}  -- filled per member by actions.run, shown in the Last result column

-- Tell utils how to know Stop was pressed, so every utils.delay in every
-- module ends early when it is.
utils.bindAbortFlag(function() return actions.stopRequested end)

--[[--------------------------------------------------------------------------
  setStatus(fmt, ...)

  WHAT  : Updates the status line and echoes it.
  WHY   : One call keeps the window and the chat log saying the same thing.
  WHERE : Throughout actions.run.
  HOW   : Formats, stores in actions.status, echoes.
  WHEN  : At each phase change.
----------------------------------------------------------------------------]]
local function setStatus(fmt, ...)
    actions.status = select('#', ...) > 0 and string.format(fmt, ...) or fmt
    utils.echo(actions.status)
end

--[[--------------------------------------------------------------------------
  actions.request() / actions.stop()

  WHAT  : Ask for a job to start, or ask the running job to stop.
  WHY   : Safe to call from ImGui and from slash commands because neither
          waits; they only flip flags.
  WHERE : ui.lua buttons, init.lua /cfood go and /cfood stop.
  HOW   : Flag assignment. request is ignored while a job is already running.
  WHEN  : On operator input.
----------------------------------------------------------------------------]]
function actions.request()
    if actions.running then
        utils.warn('A hand out is already running.')
        return
    end
    actions.requested = true   -- picked up by actions.tick on the next loop pass
end

function actions.stop()
    if actions.running then  -- Stop only means something while a job is in progress
        actions.stopRequested = true   -- every utils.delay now returns early
        actions.status = 'Stopping...'
    end
end

--[[--------------------------------------------------------------------------
  rgmercsRunning()

  WHAT  : True when the RGMercs Lua script is running on this client.
  WHY   : Pausing is only sent when RGMercs is actually loaded, so operators
          without it never see an unknown command error.
  WHERE : actions.run.
  HOW   : Lua.Script('rgmercs').Status.
  WHEN  : Job start.
----------------------------------------------------------------------------]]
local function rgmercsRunning()
    return mq.TLO.Lua.Script('rgmercs').Status() == 'RUNNING'
end

--[[--------------------------------------------------------------------------
  planNeeds(rows)

  WHAT  : Works out how much food and drink each member should receive and
          the totals the cleric must carry.
  WHY   : Summoning must be sized before trading starts, and Top up mode
          changes the per member numbers.
  WHERE : actions.run.
  HOW   : For each other member: full counts, or in Top up mode the shortfall
          reported by DanNet (full counts if the box does not answer). For the
          cleric's own row, when ticked: an extra full set, or in Top up mode
          the shortfall against what is already carried. The carry target is
          the sum plus, when preserveOwnStock is on, the existing stock.
  WHEN  : Once at job start.

  RETURNS a table:
    members      array of { row, food, drink } for everyone but the cleric
    selfFood     food the cleric keeps for itself this job
    selfDrink    drink the cleric keeps for itself this job
    totalFood    food to hand out to others
    totalDrink   drink to hand out to others
    carryFood    food the cleric must hold before trading starts
    carryDrink   drink the cleric must hold before trading starts
    reserveFood  food that must still be in the bags after trading
    reserveDrink drink that must still be in the bags after trading
----------------------------------------------------------------------------]]
local function planNeeds(rows)
    local s = config.settings
    local plan = { members = {}, selfFood = 0, selfDrink = 0, totalFood = 0, totalDrink = 0 }
    -- What the cleric already holds before summoning anything.
    local haveFood  = inventory.count(s.foodItem)
    local haveDrink = inventory.count(s.drinkItem)

    for _, row in ipairs(rows) do  -- rows are the ticked, in zone members from group.selectedRows
        -- Start from the full amount from the window.
        local food, drink = s.foodCount, s.drinkCount
        if row.isSelf then
            -- Cleric's own row: in Top up mode only make up the shortfall.
            if s.topUp then
                food  = math.max(0, food - haveFood)
                drink = math.max(0, drink - haveDrink)
            end
            plan.selfFood, plan.selfDrink = food, drink  -- the cleric's own share, kept in its bags
        else
            -- Another box: in Top up mode ask it what it has. nil = no answer,
            -- in which case the full amount is used.
            if s.topUp then
                local hf = trade.queryCount(row.name, s.foodItem)
                local hd = trade.queryCount(row.name, s.drinkItem)
                if hf then food  = math.max(0, food - hf) end  -- hf is nil when the box did not answer; keep the full amount then
                if hd then drink = math.max(0, drink - hd) end  -- same rule for drink
            end
            plan.members[#plan.members + 1] = { row = row, food = food, drink = drink }  -- remember this member's amounts for the trade step
            plan.totalFood  = plan.totalFood + food  -- running total of food going to other boxes
            plan.totalDrink = plan.totalDrink + drink  -- running total of drink going to other boxes
        end
    end

    -- Existing stock counts toward the carry target only if we keep it.
    local baseFood  = s.preserveOwnStock and haveFood or 0
    local baseDrink = s.preserveOwnStock and haveDrink or 0
    plan.carryFood  = baseFood  + plan.totalFood  + plan.selfFood
    plan.carryDrink = baseDrink + plan.totalDrink + plan.selfDrink  -- drink the cleric must hold before trading starts
    plan.reserveFood  = baseFood  + plan.selfFood  -- food that must still be in the bags after all trades
    plan.reserveDrink = baseDrink + plan.selfDrink  -- drink that must still be in the bags after all trades
    return plan  -- see the RETURNS list in the doc block above
end

--[[--------------------------------------------------------------------------
  cleanup(pausedMercs)

  WHAT  : Returns the cleric to a normal state after any job.
  WHY   : A job can end by success, failure, Stop, or a Lua error. In every
          case an open trade must close, the cursor must be empty, the spell
          bar must be restored and RGMercs must resume.
  WHERE : actions.tick, after actions.run returns or errors.
  HOW   : Clears the stop flag first so the restore waits are not cut short,
          then cancels trade, clears cursor, stops nav, restores the gem,
          unloads MQ2Cast if this job loaded it, and unpauses RGMercs if this
          job paused it.
  WHEN  : End of every job.
----------------------------------------------------------------------------]]
local function cleanup(pausedMercs)
    actions.stopRequested = false                 -- let cleanup waits run fully
    trade.cancel()                                -- no-op if no trade is open
    inventory.clearCursor()                       -- nothing left on the mouse
    if mq.TLO.Navigation.Active() then utils.cmd('/nav stop') end
    spells.restore()                              -- put gem 8 back
    spells.endJob()                               -- unload MQ2Cast if we loaded it
    if pausedMercs then utils.cmd('/rgl unpause') end   -- only if WE paused it
end

--[[--------------------------------------------------------------------------
  actions.run(state)

  WHAT  : One complete hand out. Sets state.pausedMercs when it pauses
          RGMercs, so cleanup knows whether to unpause.
  WHY   : The readable top to bottom sequence of the whole feature.
  WHERE : actions.tick only.
  HOW   : 1. Detect spells, refresh roster, collect ticked rows.
          2. Pause RGMercs if requested and running, load MQ2Cast if needed.
          3. Plan needs.
          4. Summon food, then drink, up to the carry targets.
          5. Trade to each member, never dipping into the reserve.
          6. Record and report results.
  WHEN  : When a job has been requested.
----------------------------------------------------------------------------]]
function actions.run(state)
    local s = config.settings
    actions.results = {}   -- clear the window's Last result column

    -- Step 1: fresh view of spells and group.
    spells.detect()
    group.refresh(true)
    local rows = group.selectedRows()
    if #rows == 0 then  -- nothing to do: nobody ticked, or all ticked members left the zone
        setStatus('Nobody ticked (or ticked members are not in zone).')  -- shown in the window and chat
        return
    end
    if s.foodCount == 0 and s.drinkCount == 0 then  -- both counts zero would summon and trade nothing
        setStatus('Food and drink counts are both zero.')  -- tell the operator instead of silently doing nothing
        return
    end

    -- Step 2: get other automation out of the way.
    if s.pauseRGMercs and rgmercsRunning() then
        utils.cmd('/rgl pause')
        state.pausedMercs = true   -- remembered for cleanup
    end
    -- Load MQ2Cast if needed so fizzles and interrupts are recast by the plugin.
    spells.beginJob()

    -- Step 3: work out who needs what.
    setStatus('Planning hand out for %d member(s).', #rows)
    local plan = planNeeds(rows)

    -- Step 4: summon. Skipped when food is 0 or we already hold enough.
    if s.foodCount > 0 and plan.carryFood > inventory.count(s.foodItem) then
        setStatus('Summoning food: need %d.', plan.carryFood)
        spells.summonUntil('food', plan.carryFood)
    end
    if utils.aborted() then setStatus('Stopped.') return end  -- Stop pressed during food: skip drink and trading, cleanup still runs

    if s.drinkCount > 0 and plan.carryDrink > inventory.count(s.drinkItem) then  -- same as food: skip if drink is 0 or we already hold enough
        setStatus('Summoning drink: need %d.', plan.carryDrink)  -- status line while drink is being summoned
        spells.summonUntil('drink', plan.carryDrink)  -- casts until carryDrink is held; fizzles do not stop it
    end
    if utils.aborted() then setStatus('Stopped.') return end  -- Stop pressed during drink: skip trading, cleanup still runs

    -- Meditating may have left us sitting; we need to stand to walk and trade.
    if mq.TLO.Me.Sitting() then utils.cmd('/stand') end

    -- Step 5: trade each member in roster order.
    for _, m in ipairs(plan.members) do
        if utils.aborted() then break end

        -- What we can spare right now without touching the reserve.
        local spareFood  = math.max(0, inventory.count(s.foodItem)  - plan.reserveFood)
        local spareDrink = math.max(0, inventory.count(s.drinkItem) - plan.reserveDrink)
        local food  = math.min(m.food,  spareFood)
        local drink = math.min(m.drink, spareDrink)  -- never give more drink than we can spare
        if food < m.food or drink < m.drink then  -- true when stock ran short (a summon was stopped or timed out)
            utils.warn('Short on stock for %s: giving %d food, %d drink.', m.row.name, food, drink)  -- yellow warning so the operator knows this member was shorted
        end

        -- Build the item list for trade.giveItems, skipping zero amounts.
        local items = {}
        if food  > 0 then items[#items + 1] = { item = s.foodItem,  count = food  } end
        if drink > 0 then items[#items + 1] = { item = s.drinkItem, count = drink } end

        if #items == 0 then  -- nothing to give this member
            -- Top up found nothing missing (or no stock at all).
            actions.results[m.row.name] = { food = 0, drink = 0, note = 'already stocked' }
        else
            setStatus('Trading %d food, %d drink to %s.', food, drink, m.row.name)
            local got = trade.giveItems(m.row, items)  -- walk, trade and verify; returns item name to count delivered
            local gf, gd = got[s.foodItem] or 0, got[s.drinkItem] or 0  -- pull out the delivered food and drink counts, 0 if none
            actions.results[m.row.name] = { food = gf, drink = gd }  -- record for the Last result column
            -- Green when everything arrived, yellow when anything fell short.
            if gf == food and gd == drink then
                utils.good('%s received %d food, %d drink.', m.row.name, gf, gd)
            else
                utils.warn('%s received %d of %d food, %d of %d drink.', m.row.name, gf, food, gd, drink)  -- yellow: some or all of the items did not arrive
            end
        end
    end

    -- Step 6: show the cleric's own kept share in the results column.
    if plan.selfFood > 0 or plan.selfDrink > 0 then
        actions.results[mq.TLO.Me.CleanName() or 'Me'] = {
            food = plan.selfFood, drink = plan.selfDrink, note = 'kept' }
    end

    setStatus(utils.aborted() and 'Stopped.' or 'Hand out complete.')  -- final status for this job
end

--[[--------------------------------------------------------------------------
  actions.tick()

  WHAT  : Starts a requested job and guarantees cleanup afterwards.
  WHY   : The bridge between non blocking ImGui and the blocking job.
  WHERE : init.lua main loop.
  HOW   : If requested, mark running, call actions.run inside pcall with a
          state table that records whether RGMercs was paused, report any
          error, then always call cleanup.
  WHEN  : Every main loop pass. Returns at once when no job is requested.
----------------------------------------------------------------------------]]
function actions.tick()
    if not actions.requested then return end   -- the common case: nothing to do
    actions.requested     = false
    actions.running       = true
    actions.stopRequested = false

    -- state is filled in by run so cleanup knows what to undo, even on error.
    local state = { pausedMercs = false }
    -- pcall catches any Lua error inside run so cleanup still happens.
    local ok, err = pcall(actions.run, state)
    if not ok then
        utils.err('Hand out failed: %s', tostring(err))
        actions.status = 'Error, see chat.'  -- short status; the full error text is in chat
    end

    cleanup(state.pausedMercs)  -- always runs, success or failure, so the cleric is left clean
    actions.running = false   -- window re enables Hand Out
end

return actions

--[[==========================================================================
  END OF FILE : clericfood/actions.lua

  SUMMARY OF PUBLIC API
    requested / running / stopRequested   Job flags.
    status                    string      Current status line.
    results                   table       name -> { food, drink, note }.
    request()                             Ask for a hand out.
    stop()                                Ask the running job to stop.
    run(state)                            One full hand out (tick only).
    tick()                                Main loop hook.

  DEPENDENCIES : mq, clericfood.utils, config, inventory, spells, group, trade.

  HOW TO EDIT SAFELY
    - Never call actions.run from ui.lua. ImGui callbacks cannot wait.
    - Add a new phase: put it in actions.run in order, and if it changes game
      state (loads a plugin, moves, pauses something) add the undo step to
      cleanup so Stop and errors still put things back.
    - The reserve (own preserved stock plus own ticked share) is protected:
      a member is shorted rather than eating into it.
    - Change the RGMercs commands: edit /rgl pause in run and /rgl unpause in
      cleanup.
==========================================================================]]--
