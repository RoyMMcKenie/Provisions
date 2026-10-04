--[[==========================================================================
  FILE        : clericfood/trade.lua
  PACKAGE     : ClericFood Lua  (MacroQuest / EverQuest)
  VERSION     : 1.3.1
  CHANGES     : 1.0.0  First release.
                1.1.0  No change in this file.
                1.2.0  Full inline documentation pass. No behaviour change.
                1.3.0  No change in this file.
                1.3.1  Documentation audit: every code line now carries
                       its own comment or one directly above it.

  WHAT  : Hands a list of item stacks to one group member: walks into range if
          needed, opens a trade by dropping stacks on the target, presses Trade,
          tells the receiving box to press Trade too, and verifies the items
          actually left the cleric's bags. Also asks a box how many of an item
          it already carries, for Top up mode.

  WHY   : A trade between two of the operator's own boxes needs both sides to
          click Trade. Doing that by hand six times defeats the purpose of the
          script. DanNet or EQBC can press the button on the receiving client,
          so the whole hand out runs unattended. Verifying by counting the
          cleric's own bags afterwards is the only reliable test that the trade
          really completed rather than being cancelled.

  WHERE : Required by actions.lua.

  HOW   : One trade window holds eight stacks. trade.giveItems builds a plan of
          stacks no larger than 20, sends them in batches of eight, and repeats
          a trade if more than eight stacks are needed. Each stack is lifted by
          inventory.pickUp and dropped with /click left target. Movement uses
          MQ2Nav when it is loaded and enabled.

  WHEN  : Called once per ticked member during a job, after summoning is done.

  READING GUIDE (for future you)
    - A "drop" is one stack placed into one trade slot, e.g.
      { item = 'Summoned: Black Bread', count = 10 }.
    - A "plan" is the list of drops for one member.
    - TradeWnd is EQ's trade window. TRDW_Trade_Button and TRDW_Cancel_Button
      are its button names, used with /notify.
    - Call order for one member:
        giveItems -> moveInRange -> buildPlan -> runOneTrade (repeat)
      runOneTrade -> inventory.pickUp + /click left target per drop
                  -> press Trade -> remoteAccept until closed -> verify
==========================================================================]]--

local mq        = require('mq')                     -- TLO, mq.delay, mq.gettime
local utils     = require('clericfood.utils')       -- cmd, delay, echo, aborted
local config    = require('clericfood.config')      -- range, timeouts, acceptMethod
local inventory = require('clericfood.inventory')   -- count, pickUp, clearCursor

local trade = {}

--- Slots in one EQ trade window -------------------------------------------------
-- WHAT : The number of item slots the giver gets in a player trade.
-- WHY  : Plans with more stacks than this must be split into several trades.
-- WHERE: runOneTrade.
-- HOW  : Constant.
-- WHEN : Read when batching.
local TRADE_SLOTS = 8

--- Largest stack used when splitting a count ------------------------------------
-- WHAT : The biggest single drop buildPlan will create.
-- WHY  : Summoned food and drink stack to 20 in EQ.
-- WHERE: buildPlan.
-- HOW  : Constant. Smaller real stacks are handled in runOneTrade.
-- WHEN : Read when planning.
local MAX_STACK = 20

--[[--------------------------------------------------------------------------
  tradeOpen()

  WHAT  : True when the cleric's trade window is open.
  WHY   : Used to detect that a drop started a trade and that a trade finished.
  WHERE : Throughout this file.
  HOW   : Window TLO, TradeWnd.
  WHEN  : While trading.
----------------------------------------------------------------------------]]
local function tradeOpen()
    return mq.TLO.Window('TradeWnd').Open() == true
end

--[[--------------------------------------------------------------------------
  trade.cancel()

  WHAT  : Cancels an open trade and stashes anything left on the cursor.
  WHY   : A trade left open blocks casting, movement and the next trade. On any
          failure the cleric must be returned to a clean state.
  WHERE : runOneTrade failure paths, actions.lua cleanup.
  HOW   : Clicks TRDW_Cancel_Button, waits for the window to close using a plain
          mq.delay so it still runs after Stop, then clears the cursor.
          Cancelling returns the offered items to the cleric's bags.
  WHEN  : On timeout, failure or Stop.
----------------------------------------------------------------------------]]
function trade.cancel()
    if tradeOpen() then
        utils.cmd('/notify TradeWnd TRDW_Cancel_Button leftmouseup')
        mq.delay(2000, function() return not tradeOpen() end)  -- wait up to 2 s for the trade window to close
    end
    inventory.clearCursor()  -- anything still held goes back in the bags
end

--[[--------------------------------------------------------------------------
  navAvailable()

  WHAT  : True when MQ2Nav is loaded and has a mesh for this zone.
  WHY   : Asking MQ2Nav to move without a mesh does nothing and the script
          would wait out the full timeout for no reason.
  WHERE : trade.moveInRange.
  HOW   : Plugin TLO plus Navigation.MeshLoaded.
  WHEN  : Before moving.
----------------------------------------------------------------------------]]
local function navAvailable()
    if not mq.TLO.Plugin('MQ2Nav').IsLoaded() then return false end
    return mq.TLO.Navigation.MeshLoaded() == true
end

--[[--------------------------------------------------------------------------
  trade.moveInRange(row)

  WHAT  : Gets the cleric within trade range of a member. Returns true when in
          range.
  WHY   : EQ refuses a trade beyond roughly 20 units. Boxes often stand a
          little apart at a camp, so a short walk saves skipping them.
  WHERE : trade.giveItems.
  HOW   : Reads live distance. If too far and useNav is on and available,
          /nav id to the member and wait until in range or the nav timeout,
          then /nav stop.
  WHEN  : Before each member's trade.
----------------------------------------------------------------------------]]
function trade.moveInRange(row)
    local s = config.settings
    -- Look the member up fresh by spawn id; they may have moved or died.
    local spawn = mq.TLO.Spawn('id ' .. row.id)
    if not spawn() then return false end
    if (spawn.Distance() or 9999) <= s.tradeRange then return true end   -- already close

    if not s.useNav then
        utils.warn('%s is %.0f away and navigation is off, skipping.', row.name, spawn.Distance() or 0)
        return false  -- member too far and walking is turned off
    end
    if not navAvailable() then  -- no mesh means MQ2Nav cannot move us
        utils.warn('%s is out of range and MQ2Nav has no mesh here, skipping.', row.name)  -- tell the operator why this member is skipped
        return false  -- skip this member
    end

    utils.echo('Walking to %s.', row.name)  -- let the operator know why the cleric is moving
    utils.cmd('/nav id %d', row.id)   -- MQ2Nav paths around walls
    -- Stop as soon as we are inside trade range, not when nav reaches them.
    local arrived = utils.delay(s.navTimeoutSec * 1000, function()
        return (mq.TLO.Spawn('id ' .. row.id).Distance() or 9999) <= s.tradeRange
    end)
    utils.cmd('/nav stop')  -- stop walking whether we arrived or timed out
    return arrived  -- true only if we reached trade range
end

--[[--------------------------------------------------------------------------
  trade.queryCount(name, itemName)

  WHAT  : Asks another box through DanNet how many of an item it carries.
          Returns a number, or nil if the box did not answer.
  WHY   : Top up mode gives only what each box is short of, so nobody ends up
          with three stacks of bread they will never eat.
  WHERE : actions.lua planNeeds when topUp is on.
  HOW   : /dquery with FindItemCount, then reads the cached answer from
          DanNet(peer).Q(query). Peer names are lower case in DanNet.
  WHEN  : Once per member per item at job start.
----------------------------------------------------------------------------]]
function trade.queryCount(name, itemName)
    if not mq.TLO.Plugin('MQ2DanNet').IsLoaded() then return nil end
    local peer  = name:lower()
    -- The query text runs on the OTHER client, e.g. FindItemCount[=Summoned: Black Bread]
    local query = string.format('FindItemCount[=%s]', itemName)
    utils.cmd('/dquery %s -q "%s"', peer, query)
    -- Wait up to 2 s for the answer to arrive.
    mq.delay(2000, function()
        local r = mq.TLO.DanNet(peer).Q(query)()
        return r ~= nil and r ~= '' and r ~= 'NULL'
    end)
    -- tonumber returns nil for anything that is not a number (no answer).
    local answer = tonumber(mq.TLO.DanNet(peer).Q(query)())
    utils.debug('%s carries %s %s', name, tostring(answer), itemName)
    return answer
end

--[[--------------------------------------------------------------------------
  remoteAccept(name)

  WHAT  : Tells the receiving box to press its Trade button.
  WHY   : Both sides must accept. This is what makes the hand out unattended.
  WHERE : runOneTrade.
  HOW   : DanNet /dex or EQBC /bct depending on acceptMethod. 'none' does
          nothing and leaves acceptance to the operator or another automation.
  WHEN  : After the cleric presses Trade, and again every two seconds until
          the trade closes, in case the first command arrived before the
          receiver's window had opened.
----------------------------------------------------------------------------]]
local function remoteAccept(name)
    local method = config.settings.acceptMethod
    if method == 'dannet' then
        -- /dex <peer> <command> runs <command> on that client.
        utils.cmd('/dex %s /notify TradeWnd TRDW_Trade_Button leftmouseup', name:lower())
    elseif method == 'eqbc' then
        -- /bct <name> //<command> runs it there; the double slash is required.
        utils.cmd('/bct %s //notify TradeWnd TRDW_Trade_Button leftmouseup', name)
    end
    -- 'none': intentionally nothing.
end

--[[--------------------------------------------------------------------------
  buildPlan(items)

  WHAT  : Turns { { item = name, count = n }, ... } into a flat list of single
          stack drops, each no larger than MAX_STACK.
  WHY   : The trade window takes one stack per slot. Knowing the number of
          drops up front is how the giver knows whether one trade is enough.
  WHERE : trade.giveItems.
  HOW   : Splits each count into chunks of up to MAX_STACK. Real source stacks
          may be smaller, in which case inventory.pickUp returns less and
          runOneTrade adds the remainder as another drop.
  WHEN  : Once per member.
----------------------------------------------------------------------------]]
local function buildPlan(items)
    local plan = {}
    for _, entry in ipairs(items) do
        local left = entry.count  -- items still to split for this entry
        -- Example: 45 bread becomes drops of 20, 20 and 5.
        while left > 0 do
            local chunk = math.min(MAX_STACK, left)
            plan[#plan + 1] = { item = entry.item, count = chunk }
            left = left - chunk  -- subtract what was just planned
        end
    end
    return plan  -- list of single stack drops
end

--[[--------------------------------------------------------------------------
  runOneTrade(row, drops)

  WHAT  : Performs one trade window's worth of drops with one member. Returns
          two tables: how many of each item actually left the bags, and the
          drops that did not fit and still need another trade.
  WHY   : Separated from giveItems so large hand outs can repeat it cleanly.
  WHERE : trade.giveItems.
  HOW   : 1. Snapshot counts of every item in the drops.
          2. Target the member.
          3. For each drop, lift it and /click left target. If a lift returns
             fewer than asked, the rest is inserted as the next drop. Stops
             filling at eight slots; the rest goes to leftover.
          4. Press Trade, call remoteAccept until the window closes or time
             runs out. Cancel on timeout.
          5. Compare counts to the snapshot for the true result.
  WHEN  : Once or more per member.
----------------------------------------------------------------------------]]
local function runOneTrade(row, drops)
    -- Step 1: how many of each item we hold before this trade.
    local before = {}
    for _, d in ipairs(drops) do before[d.item] = inventory.count(d.item) end

    -- Step 2: target the receiver and confirm it took.
    utils.cmd('/target id %d', row.id)
    if not utils.delay(2000, function() return mq.TLO.Target.ID() == row.id end) then
        utils.err('Could not target %s.', row.name)
        return {}, drops  -- no target: nothing was traded, all drops remain
    end

    -- Step 3: fill trade slots.
    local used, i = 0, 1   -- used = slots filled, i = index into drops
    local leftover = {}
    -- A while loop (not ipairs) because drops can grow as we go.
    while i <= #drops do
        local d = drops[i]
        if used >= TRADE_SLOTS or utils.aborted() then
            -- Window full (or Stop): save this drop for the next trade.
            leftover[#leftover + 1] = d
        else
            local got = inventory.pickUp(d.item, d.count)
            if got == 0 then  -- lift failed (item missing or slider failed)
                trade.cancel()  -- close any half built trade and clear the cursor
                return {}, drops  -- nothing delivered
            end
            -- Dropping an item on a player opens the trade (first drop) or
            -- adds to the next free slot (later drops).
            utils.cmd('/click left target')
            local dropped = utils.delay(3000, function() return mq.TLO.Cursor.ID() == nil end)
            if not dropped then
                utils.err('Could not hand %s to %s (range or line of sight).', d.item, row.name)  -- item stayed on the cursor: too far or no line of sight
                trade.cancel()  -- close the trade, item returns to the bags
                return {}, drops  -- nothing delivered
            end
            used = used + 1  -- one more trade slot filled
            -- Source stack was smaller than asked: queue the remainder next.
            if got < d.count then
                table.insert(drops, i + 1, { item = d.item, count = d.count - got })
            end
        end
        i = i + 1  -- next drop
    end

    -- The window should be open now that at least one item was dropped.
    if not utils.delay(3000, tradeOpen) then
        utils.err('Trade window did not open with %s.', row.name)
        trade.cancel()
        return {}, drops  -- window never opened: nothing delivered
    end

    -- Step 4: our side presses Trade.
    mq.delay(300)   -- let the last drop settle in the window first
    utils.cmd('/notify TradeWnd TRDW_Trade_Button leftmouseup')

    -- Poke the receiver every 2 s until the window closes or time runs out.
    local deadline = mq.gettime() + config.settings.tradeTimeoutSec * 1000
    local nextPoke = 0
    while tradeOpen() and mq.gettime() < deadline and not utils.aborted() do
        if mq.gettime() >= nextPoke then  -- time to nudge the receiver again
            remoteAccept(row.name)  -- ask the other box to press Trade
            nextPoke = mq.gettime() + 2000  -- next nudge in 2 seconds
        end
        mq.delay(200)  -- short yield between checks
    end

    -- Still open means not accepted (or Stop): cancel, items come back.
    if tradeOpen() then
        utils.warn('%s did not accept in time, cancelling.', row.name)
        trade.cancel()
    end

    -- Step 5: the truth is in our bags. Count again and subtract.
    mq.delay(500)   -- give the inventory a moment to update
    local given = {}
    for item, was in pairs(before) do
        given[item] = math.max(0, was - inventory.count(item))
    end
    return given, leftover  -- delivered counts, and drops still to send
end

--[[--------------------------------------------------------------------------
  trade.giveItems(row, items)

  WHAT  : Gives a member everything in items. Returns a table of item name to
          number actually delivered.
  WHY   : The single call actions.lua makes per member.
  WHERE : actions.lua.
  HOW   : Move in range, build the drop plan, run trades until the plan is
          empty, a trade delivers nothing, or Stop is pressed.
  WHEN  : Once per ticked member, after summoning.
----------------------------------------------------------------------------]]
function trade.giveItems(row, items)
    local total = {}   -- item name -> delivered count across all trades
    if not trade.moveInRange(row) then return total end

    local remaining = buildPlan(items)
    while #remaining > 0 and not utils.aborted() do  -- keep trading until everything is sent or Stop
        local given, leftover = runOneTrade(row, remaining)  -- one trade window worth of drops
        -- Add this trade's results to the running total.
        local any = false
        for item, n in pairs(given) do
            total[item] = (total[item] or 0) + n
            if n > 0 then any = true end  -- at least something arrived in this trade
        end
        -- A trade that moved nothing means something is wrong; do not loop.
        if not any then break end
        remaining = leftover
        if #remaining > 0 then mq.delay(500) end   -- brief gap between trades
    end
    return total
end

return trade  -- hand the module table to require('clericfood.trade')

--[[==========================================================================
  END OF FILE : clericfood/trade.lua

  SUMMARY OF PUBLIC API
    cancel()                       Cancel open trade, clear cursor.
    moveInRange(row)       bool    Walk into trade range with MQ2Nav.
    queryCount(name, item) number  DanNet item count on another box, or nil.
    giveItems(row, items)  table   Deliver, return item to count delivered.

  DEPENDENCIES : mq, clericfood.utils, clericfood.config, clericfood.inventory.
                 Optional plugins: MQ2Nav (movement), MQ2DanNet (top up and
                 remote accept) or MQ2EQBC (remote accept).

  HOW TO EDIT SAFELY
    - Add another accept method: add a branch in remoteAccept and a radio
      button in ui.lua drawOptions.
    - /click left target is what opens a trade when the cursor holds an item
      and the target is a player. It clicks the spawn, not the target window.
    - If a receiving box runs its own auto accept, set acceptMethod to none to
      avoid double clicks.
    - Verification depends on counting the cleric's bags. If you ever let the
      cleric receive items in the same trade, that count would be wrong.
==========================================================================]]--
