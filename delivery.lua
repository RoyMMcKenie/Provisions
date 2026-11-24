--[[==========================================================================
  FILE        : provisions/delivery.lua
  PACKAGE     : Provisions Lua  (MacroQuest / EverQuest)
  VERSION     : 2.0.0
  CHANGES     : 2.0.0  New file. Merges the ClericFood 1.3.2 files
                       inventory.lua and trade.lua. Adds peerInCombat (asks
                       a box through DanNet whether it is fighting), cancels
                       an open trade when the caster is attacked, returns a
                       reason with every trade result so busy members can be
                       retried later, and waits on the DanNet Received
                       timestamp so a query never reads a stale answer.
                1.0.0 to 1.3.2  Released as ClericFood (inventory.lua,
                       trade.lua). Full history in CHANGELOG.md.

  WHAT  : Everything that moves items: counting what is in the bags,
          clearing the cursor, lifting an exact quantity onto the cursor,
          walking into range, running a trade with one member, pressing
          Trade on the receiving box, and asking other boxes through DanNet
          what they carry and whether they are in combat.

  WHY   : Handing out "7 bread" means lifting exactly 7 off a stack of 20,
          dropping them on a player, and having both sides press Trade.
          Getting each step right against a live client is fiddly and is the
          most likely thing to need adjustment, so all of it sits together
          in one file with nothing else in it.

  WHERE : Required by casting.lua (bag counts and cursor) and init.lua
          (trades, DanNet counts, busy checks).

  HOW   : FindItem and FindItemCount for lookups, /autoinventory to stash,
          /itemnotify with /shiftkey or /ctrlkey for pickups, the QuantityWnd
          slider for partial stacks, /click left target to offer an item,
          /notify TradeWnd buttons to accept or cancel, /dex or /bct to make
          the other box accept, and /nav to walk.

  WHEN  : Bag helpers run throughout a job. Trades run after summoning.

  READING GUIDE (for future you)
    - EQ slot numbers 23 to 32 are the ten general inventory slots. A bag in
      slot 23 is "pack1", slot 32 is "pack10". Slots inside a bag are
      numbered from 1 in /itemnotify.
    - MacroQuest's ItemSlot2 is the slot inside the bag counted from 0, or
      -1 when the item sits loose in a general slot.
    - "Cursor" is the item stuck to the mouse pointer.
    - A "drop" is one stack placed in one trade slot, for example
      { item = 'Summoned: Black Bread', count = 10 }. A "plan" is the list
      of drops for one member.
    - A trade "reason" tells init.lua what happened:
        ok      something was delivered
        busy    the member is fighting, or the trade did not open or was
                not accepted; try this member again later
        range   could not get within trade range; try again later
        combat  the caster was attacked; the trade was cancelled and the
                member is tried again after the Combat Hold
        failed  a problem on the caster's side, such as a failed pickup
==========================================================================]]--

local mq   = require('mq')                -- TLO access, mq.delay, mq.gettime
local core = require('provisions.core')   -- output, cmd, delay, settings, combat

local delivery = {}

--[[==========================================================================
  PART 1 : BAGS AND CURSOR
==========================================================================]]--

--- General inventory slot range ------------------------------------------------
-- WHAT : EQ numbers the ten general inventory slots 23 through 32.
-- WHY  : Converting a slot to pack1 .. pack10 needs the offset, and items
--        outside this range (worn, bank) must never be touched.
-- WHERE: delivery.locate.
-- HOW  : Constants.
-- WHEN : On every pickup.
local FIRST_GENERAL_SLOT = 23
local LAST_GENERAL_SLOT  = 32

--[[--------------------------------------------------------------------------
  delivery.count(itemName)

  WHAT  : Returns how many of an exact item name the caster carries.
  WHY   : Decides how many more casts are needed and how much can be given.
  WHERE : casting.lua, init.lua, ui.lua, and the trade check below.
  HOW   : FindItemCount with a leading = for an exact match, so "Summoned:
          Black Bread" never matches some other bread.
  WHEN  : Before and during summoning, and around every trade.
----------------------------------------------------------------------------]]
function delivery.count(itemName)
    if not itemName or itemName == '' then return 0 end   -- nothing to count yet
    -- Sums every stack in every bag; nil when none are found.
    return mq.TLO.FindItemCount('=' .. itemName)() or 0
end

--[[--------------------------------------------------------------------------
  delivery.freeSlots()

  WHAT  : Returns the number of empty bag slots.
  WHY   : Summoning onto full bags leaves the item stuck on the cursor and
          blocks every later cast.
  WHERE : casting.lua summonUntil.
  HOW   : Me.FreeInventory.
  WHEN  : Before each cast.
----------------------------------------------------------------------------]]
function delivery.freeSlots()
    return mq.TLO.Me.FreeInventory() or 0   -- nil on a bad read counts as none
end

--[[--------------------------------------------------------------------------
  delivery.cursorName() / delivery.cursorStack()

  WHAT  : Name and stack size of whatever is on the cursor (nil and 0 when
          empty).
  WHY   : Summon spells drop their item on the cursor. Reading the name is
          how the package learns the real item name on any server, and the
          stack size is how a pickup is verified.
  WHERE : casting.lua castOnce, delivery.pickUp.
  HOW   : Cursor TLO. A non stackable item reports Stack 0 but is still one
          item, so anything under 1 counts as 1.
  WHEN  : After a cast and after a pickup.
----------------------------------------------------------------------------]]
function delivery.cursorName()
    return mq.TLO.Cursor.Name()   -- nil when the cursor is empty
end

-- Number of items held on the cursor; see the block above.
function delivery.cursorStack()
    if not mq.TLO.Cursor.ID() then return 0 end   -- empty cursor
    local stack = mq.TLO.Cursor.Stack() or 1
    if stack < 1 then stack = 1 end               -- non stackable item
    return stack
end

--[[--------------------------------------------------------------------------
  delivery.clearCursor(timeoutMs)

  WHAT  : Puts whatever is on the cursor into the bags. Returns true when the
          cursor ends up empty.
  WHY   : The cursor must be empty before casting and before lifting an item
          for a trade.
  WHERE : casting.lua castOnce, delivery.cancel, init.lua cleanup.
  HOW   : /autoinventory repeated until clear or out of time. Uses plain
          mq.delay rather than core.delay so it still works during cleanup
          after Stop.
  WHEN  : After every cast and after any cancelled pickup or trade.
----------------------------------------------------------------------------]]
function delivery.clearCursor(timeoutMs)
    local deadline = mq.gettime() + (timeoutMs or 3000)   -- default 3 seconds
    while mq.TLO.Cursor.ID() and mq.gettime() < deadline do
        core.cmd('/autoinventory')                        -- first fitting slot
        -- Give the game a quarter second to move it before trying again.
        mq.delay(250, function() return not mq.TLO.Cursor.ID() end)
    end
    return not mq.TLO.Cursor.ID()                         -- true when empty
end

--[[--------------------------------------------------------------------------
  delivery.locate(itemName)

  WHAT  : Finds the first stack of an item and says where it is.
  WHY   : /itemnotify needs a location, not a name.
  WHERE : delivery.pickUp.
  HOW   : FindItem with an exact match. Returns { pack, slot, stack } for an
          item in a bag, { slotId, stack } for a loose item, or nil when the
          item is not carried in general inventory.
  WHEN  : Right before each pickup.
----------------------------------------------------------------------------]]
function delivery.locate(itemName)
    local item = mq.TLO.FindItem('=' .. itemName)
    if not item() then return nil end          -- not carried at all

    local slot  = item.ItemSlot() or -1        -- 23 to 32 in general inventory
    local slot2 = item.ItemSlot2() or -1       -- slot in bag from 0, -1 if loose
    local stack = item.Stack() or 1            -- size of this one stack
    if stack < 1 then stack = 1 end

    -- Refuse anything outside general inventory (worn, bank and so on).
    if slot < FIRST_GENERAL_SLOT or slot > LAST_GENERAL_SLOT then
        core.debug('%s found in slot %d, outside general inventory', itemName, slot)
        return nil
    end
    if slot2 >= 0 then   -- item is inside a bag
        -- Inside a bag: pack number 1 to 10 and a bag slot counted from 1.
        return { pack = slot - FIRST_GENERAL_SLOT + 1, slot = slot2 + 1, stack = stack }
    end
    return { slotId = slot, stack = stack }    -- loose in a general slot
end

--[[--------------------------------------------------------------------------
  packWindowOpen(packNumber)

  WHAT  : True when the bag window for packN is open.
  WHY   : Some clients refuse /itemnotify into a closed bag. Knowing the
          state lets the script open it only when needed and close it again.
  WHERE : delivery.pickUp.
  HOW   : Window TLO; the window name is PackN.
  WHEN  : Before and after a pickup from a bag.
----------------------------------------------------------------------------]]
local function packWindowOpen(packNumber)
    return mq.TLO.Window('Pack' .. packNumber).Open() == true
end

--[[--------------------------------------------------------------------------
  notifyTarget(loc)

  WHAT  : Builds the /itemnotify location text for a located item.
  WHY   : Bag items and loose items use different syntax.
  WHERE : delivery.pickUp.
  HOW   : "in packN S" for a bag item, the slot number for a loose item.
  WHEN  : On every pickup.
----------------------------------------------------------------------------]]
local function notifyTarget(loc)
    if loc.pack then
        return string.format('in pack%d %d', loc.pack, loc.slot)  -- e.g. in pack3 5
    end
    return tostring(loc.slotId)                                    -- e.g. 27
end

--[[--------------------------------------------------------------------------
  delivery.pickUp(itemName, wanted)

  WHAT  : Lifts up to wanted of an item onto the cursor from one stack.
          Returns the number actually on the cursor (0 on failure).
  WHY   : Trades are built one stack at a time; the caller loops for more.
  WHERE : runOneTrade.
  HOW   : Whole stack: shift click. Exactly one: ctrl click. Anything else:
          plain click, wait for QuantityWnd, set the slider, press Accept.
          A closed bag is opened first and closed again afterwards.
  WHEN  : While filling a trade window.
----------------------------------------------------------------------------]]
function delivery.pickUp(itemName, wanted)
    -- Step 1: the cursor must be empty or the click would swap items.
    if mq.TLO.Cursor.ID() then
        core.warn('Cursor not empty before pickup, stashing it first.')
        if not delivery.clearCursor() then return 0 end
    end

    -- Step 2: find the first stack.
    local loc = delivery.locate(itemName)
    if not loc then
        core.err('Could not find %s in bags.', itemName)
        return 0   -- nothing lifted
    end
    local take  = math.min(wanted, loc.stack)   -- never more than this stack
    local where = notifyTarget(loc)

    -- Step 3: open the bag if it is closed. Right clicking a bag toggles it.
    local openedBag = false
    if loc.pack and not packWindowOpen(loc.pack) then
        core.cmd('/itemnotify pack%d rightmouseup', loc.pack)
        core.delay(1500, function() return packWindowOpen(loc.pack) end)  -- up to 1.5 s
        openedBag = true   -- close it again in step 5
    end

    -- Step 4: lift the right amount using the EQ click rules.
    if take >= loc.stack then
        core.cmd('/shiftkey /itemnotify %s leftmouseup', where)   -- whole stack
    elseif take == 1 then
        core.cmd('/ctrlkey /itemnotify %s leftmouseup', where)    -- exactly one
    else
        -- Part of a stack: a plain click opens the quantity slider.
        core.cmd('/itemnotify %s leftmouseup', where)
        local qtyOpen = core.delay(1500, function()
            return mq.TLO.Window('QuantityWnd').Open() == true
        end)
        if qtyOpen then   -- slider appeared
            -- Set the amount, let it register, then accept.
            core.cmd('/notify QuantityWnd QTYW_slider newvalue %d', take)
            mq.delay(150)
            core.cmd('/notify QuantityWnd QTYW_Accept_Button leftmouseup')
        end
    end
    -- Wait for the item to land on the cursor.
    core.delay(1500, function() return mq.TLO.Cursor.ID() ~= nil end)

    -- Step 5: close the bag only if we opened it.
    if openedBag and packWindowOpen(loc.pack) then
        core.cmd('/itemnotify pack%d rightmouseup', loc.pack)
    end

    -- Step 6: report what really happened.
    local got = delivery.cursorStack()
    if got == 0 then
        core.err('Pickup of %s failed.', itemName)
    elseif got ~= take then   -- got some but not what was asked
        core.debug('Asked for %d %s, cursor holds %d', take, itemName, got)  -- caller queues the rest
    end
    return got
end

--[[==========================================================================
  PART 2 : DANNET QUERIES
==========================================================================]]--

--[[--------------------------------------------------------------------------
  dannetLoaded()

  WHAT  : True when the MQ2DanNet plugin is loaded on this client.
  WHY   : Every DanNet feature is optional; without the plugin the package
          falls back to simpler behaviour.
  WHERE : delivery.query.
  HOW   : Plugin TLO.
  WHEN  : Before every query.
----------------------------------------------------------------------------]]
local function dannetLoaded()
    return mq.TLO.Plugin('MQ2DanNet').IsLoaded() == true
end

--[[--------------------------------------------------------------------------
  delivery.query(name, query, timeoutMs)

  WHAT  : Runs one TLO query on another box through DanNet and returns the
          answer as text, or nil when there was no answer.
  WHY   : Top up mode needs item counts and the busy check needs the combat
          state of the other box.
  WHERE : delivery.queryCount, delivery.peerInCombat.
  HOW   : /dquery <peer> -q "<query>". The DanNet author documents that a
          new /dquery clears the stored answer and its Received timestamp,
          and that Received is filled in when the reply arrives. A short
          pause after the command lets the clear happen, then the wait is on
          DanNet(peer).Q(query).Received. Peer names are lower case.
  WHEN  : At job start (Top up) and before each trade (busy check).
----------------------------------------------------------------------------]]
function delivery.query(name, query, timeoutMs)
    if not dannetLoaded() then return nil end   -- no DanNet, no answer
    local peer = name:lower()                   -- DanNet peer names are lower case
    core.cmd('/dquery %s -q "%s"', peer, query)
    mq.delay(100)   -- let DanNet clear the previous answer first
    -- Wait for the reply timestamp; 0 or nil means not received yet.
    mq.delay(timeoutMs or 2000, function()
        return (mq.TLO.DanNet(peer).Q(query).Received() or 0) > 0
    end)
    local answer = mq.TLO.DanNet(peer).Q(query)()   -- the stored reply text
    if answer == nil or answer == '' or answer == 'NULL' then return nil end  -- no usable reply
    return tostring(answer)
end

--[[--------------------------------------------------------------------------
  delivery.queryCount(name, itemName)

  WHAT  : Asks another box how many of an item it carries. Returns a number
          or nil.
  WHY   : Top up mode gives only the shortfall.
  WHERE : init.lua planNeeds when topUp is on.
  HOW   : delivery.query with FindItemCount[=item], then tonumber.
  WHEN  : Once per member per item at job start.
----------------------------------------------------------------------------]]
function delivery.queryCount(name, itemName)
    local answer = tonumber(delivery.query(name, string.format('FindItemCount[=%s]', itemName)))
    core.debug('%s carries %s %s', name, tostring(answer), itemName)
    return answer   -- nil when the box did not answer
end

--[[--------------------------------------------------------------------------
  delivery.peerInCombat(name)

  WHAT  : Asks another box whether it is in combat. Returns true, false, or
          nil when it could not be asked.
  WHY   : A box that is fighting will not open a trade window. Asking first
          avoids a pointless trade attempt and its timeout.
  WHERE : init.lua trade queue.
  HOW   : delivery.query on Me.CombatState; COMBAT means fighting.
  WHEN  : Right before each trade attempt.
----------------------------------------------------------------------------]]
function delivery.peerInCombat(name)
    local state = delivery.query(name, 'Me.CombatState', 1500)
    if state == nil then return nil end   -- no DanNet or no reply
    return state == 'COMBAT'
end

--[[==========================================================================
  PART 3 : TRADING
==========================================================================]]--

--- Trade window limits -------------------------------------------------------------
-- WHAT : Item slots the giver gets in one trade, and the largest stack used.
-- WHY  : Plans with more than eight stacks need more than one trade, and
--        summoned food and drink stack to 20.
-- WHERE: buildPlan and runOneTrade.
-- HOW  : Constants.
-- WHEN : Read when planning and filling a trade.
local TRADE_SLOTS = 8
local MAX_STACK   = 20

--[[--------------------------------------------------------------------------
  tradeOpen()

  WHAT  : True when the caster's trade window is open.
  WHY   : Detects that a drop started a trade and that a trade finished.
  WHERE : Throughout this part.
  HOW   : Window TLO, TradeWnd.
  WHEN  : While trading.
----------------------------------------------------------------------------]]
local function tradeOpen()
    return mq.TLO.Window('TradeWnd').Open() == true
end

--[[--------------------------------------------------------------------------
  delivery.cancel()

  WHAT  : Cancels an open trade and puts anything on the cursor back in the
          bags.
  WHY   : An open trade blocks casting, movement and the next trade.
  WHERE : runOneTrade failure paths, init.lua checkpoint and cleanup.
  HOW   : TRDW_Cancel_Button, wait for the window to close with plain
          mq.delay so it works after Stop, then clear the cursor. Cancelling
          returns offered items to the caster's bags.
  WHEN  : On timeout, failure, combat or Stop.
----------------------------------------------------------------------------]]
function delivery.cancel()
    if tradeOpen() then
        core.cmd('/notify TradeWnd TRDW_Cancel_Button leftmouseup')
        mq.delay(2000, function() return not tradeOpen() end)  -- up to 2 s
    end
    delivery.clearCursor()   -- anything still held goes back in the bags
end

--[[--------------------------------------------------------------------------
  navAvailable()

  WHAT  : True when MQ2Nav is loaded and has a mesh for this zone.
  WHY   : Without a mesh MQ2Nav cannot move, and waiting would be pointless.
  WHERE : delivery.moveInRange.
  HOW   : Plugin TLO plus Navigation.MeshLoaded.
  WHEN  : Before walking.
----------------------------------------------------------------------------]]
local function navAvailable()
    if not mq.TLO.Plugin('MQ2Nav').IsLoaded() then return false end
    return mq.TLO.Navigation.MeshLoaded() == true
end

--[[--------------------------------------------------------------------------
  delivery.moveInRange(row)

  WHAT  : Gets the caster within trade range of a member. Returns true when
          in range.
  WHY   : EQ refuses a trade beyond about 20 units.
  WHERE : delivery.giveItems.
  HOW   : Live distance check. If too far and walking is allowed and
          possible, /nav id to the member until in range or out of time,
          then /nav stop.
  WHEN  : Before each trade attempt.
----------------------------------------------------------------------------]]
function delivery.moveInRange(row)
    local s = core.settings
    -- Look the member up fresh; they may have moved, died or zoned.
    local spawn = mq.TLO.Spawn('id ' .. row.id)
    if not spawn() then return false end
    if (spawn.Distance() or 9999) <= s.tradeRange then return true end   -- already close

    if not s.useNav then
        core.warn('%s is %.0f away and walking is off.', row.name, spawn.Distance() or 0)
        return false   -- walking is turned off
    end
    if not navAvailable() then   -- no MQ2Nav or no mesh
        core.warn('%s is out of range and MQ2Nav has no mesh here.', row.name)  -- cannot walk
        return false
    end

    core.echo('Walking to %s.', row.name)   -- tell the operator we are moving
    core.cmd('/nav id %d', row.id)   -- MQ2Nav paths around walls
    -- Stop as soon as we are inside trade range.
    local arrived = core.delay(s.navTimeoutSec * 1000, function()
        return (mq.TLO.Spawn('id ' .. row.id).Distance() or 9999) <= s.tradeRange
    end)
    core.cmd('/nav stop')            -- stop whether we arrived or not
    return arrived
end

--[[--------------------------------------------------------------------------
  remoteAccept(name)

  WHAT  : Tells the receiving box to press its Trade button.
  WHY   : Both sides must accept; this makes the hand out unattended.
  WHERE : runOneTrade.
  HOW   : DanNet /dex or EQBC /bct, depending on acceptMethod. 'none' sends
          nothing and leaves it to the operator or another automation.
  WHEN  : After the caster presses Trade, then every two seconds until the
          trade closes, in case the first command arrived too early.
----------------------------------------------------------------------------]]
local function remoteAccept(name)
    local method = core.settings.acceptMethod
    if method == 'dannet' then
        -- /dex <peer> <command> runs the command on that client.
        core.cmd('/dex %s /notify TradeWnd TRDW_Trade_Button leftmouseup', name:lower())
    elseif method == 'eqbc' then
        -- /bct <name> //<command>; the double slash is required.
        core.cmd('/bct %s //notify TradeWnd TRDW_Trade_Button leftmouseup', name)
    end
    -- 'none': intentionally nothing.
end

--[[--------------------------------------------------------------------------
  buildPlan(items)

  WHAT  : Turns { { item, count }, ... } into single stack drops of at most
          MAX_STACK each.
  WHY   : The trade window takes one stack per slot.
  WHERE : delivery.giveItems.
  HOW   : Splits each count into chunks, for example 45 becomes 20, 20, 5.
          Real stacks may be smaller; runOneTrade then adds the remainder.
  WHEN  : Once per trade attempt.
----------------------------------------------------------------------------]]
local function buildPlan(items)
    local plan = {}
    for _, entry in ipairs(items) do
        local left = entry.count   -- still to split for this entry
        while left > 0 do
            local chunk = math.min(MAX_STACK, left)
            plan[#plan + 1] = { item = entry.item, count = chunk }
            left = left - chunk   -- what is left to split
        end
    end
    return plan   -- list of single stack drops
end

--[[--------------------------------------------------------------------------
  waitForAccept(row)

  WHAT  : After the caster presses Trade, keeps asking the receiver to
          accept until the window closes. Returns 'ok', 'busy' (not accepted
          in time), 'combat' (caster attacked) or 'stop'.
  WHY   : Split out of runOneTrade so the combat rule is easy to find.
  WHERE : runOneTrade.
  HOW   : Polls every 200 ms. remoteAccept every 2 seconds. If Combat Hold
          is on and the caster is attacked, gives up at once so the trade
          can be cancelled.
  WHEN  : Once per trade.
----------------------------------------------------------------------------]]
local function waitForAccept(row)
    local deadline = mq.gettime() + core.settings.tradeTimeoutSec * 1000
    local nextPoke = 0
    while tradeOpen() do   -- until the receiver accepts
        if core.aborted() then return 'stop' end                           -- Stop pressed
        if core.settings.combatHold and core.inCombat() then return 'combat' end  -- attacked
        if mq.gettime() >= deadline then return 'busy' end                 -- not accepted
        if mq.gettime() >= nextPoke then
            remoteAccept(row.name)                -- nudge the other box
            nextPoke = mq.gettime() + 2000        -- again in 2 seconds
        end
        mq.delay(200)                             -- short yield between checks
    end
    return 'ok'   -- window closed: accepted (verified by recount later)
end

--[[--------------------------------------------------------------------------
  runOneTrade(row, drops)

  WHAT  : One trade window's worth of drops with one member. Returns three
          values: item name to count delivered, the drops that did not fit,
          and a reason (see the reading guide).
  WHY   : Split from giveItems so a large hand out can repeat it.
  WHERE : delivery.giveItems.
  HOW   : 1. Count each item before.
          2. Target the member.
          3. Lift and drop each stack, up to eight. A short lift queues the
             remainder as the next drop. If the item stays on the cursor or
             the window never opens, the member is treated as busy.
          4. Press Trade and wait for the receiver (waitForAccept). Cancel
             if it was not accepted or the caster was attacked.
          5. Count again; the difference is what really left the bags.
  WHEN  : Once or more per trade attempt.
----------------------------------------------------------------------------]]
local function runOneTrade(row, drops)
    -- Step 1: counts before this trade.
    local before = {}
    for _, d in ipairs(drops) do before[d.item] = delivery.count(d.item) end

    -- Step 2: target the receiver.
    core.cmd('/target id %d', row.id)
    if not core.delay(2000, function() return mq.TLO.Target.ID() == row.id end) then
        core.err('Could not target %s.', row.name)
        return {}, drops, 'failed'   -- nothing could be targeted, nothing traded
    end

    -- Step 3: fill the trade slots. A while loop because drops can grow.
    local used, i, leftover = 0, 1, {}
    while i <= #drops do
        local d = drops[i]
        if used >= TRADE_SLOTS or core.aborted() then   -- no free trade slot left, or Stop
            leftover[#leftover + 1] = d          -- full (or Stop): next trade
        else
            local got = delivery.pickUp(d.item, d.count)
            if got == 0 then
                delivery.cancel()                -- caster side problem
                return {}, drops, 'failed'
            end
            -- Dropping an item on a player opens the trade or fills a slot.
            core.cmd('/click left target')
            if not core.delay(3000, function() return mq.TLO.Cursor.ID() == nil end) then
                -- Not taken: range, line of sight, or the member is fighting.
                core.warn('%s did not take the trade, will try again later.', row.name)
                delivery.cancel()
                return {}, drops, 'busy'
            end
            used = used + 1   -- one more trade slot filled
            -- Source stack was smaller than asked: queue the remainder next.
            if got < d.count then
                table.insert(drops, i + 1, { item = d.item, count = d.count - got })
            end
        end
        i = i + 1   -- next drop
    end

    -- The window should be open now that at least one item was dropped.
    if not core.delay(3000, tradeOpen) then
        core.warn('Trade window did not open with %s, will try again later.', row.name)
        delivery.cancel()
        return {}, drops, 'busy'   -- trade window never appeared
    end

    -- Step 4: our side presses Trade, then wait for the receiver.
    mq.delay(300)   -- let the last drop settle first
    core.cmd('/notify TradeWnd TRDW_Trade_Button leftmouseup')
    local outcome = waitForAccept(row)
    if tradeOpen() then
        -- Not accepted, attacked, or Stop: cancel and the items come back.
        if outcome == 'combat' then
            core.warn('Under attack, cancelling the trade with %s.', row.name)
        elseif outcome == 'busy' then
            core.warn('%s did not accept in time, will try again later.', row.name)  -- maybe fighting
        end
        delivery.cancel()
    end

    -- Step 5: the truth is in our bags.
    mq.delay(500)   -- give the inventory a moment to update
    local given, any = {}, false
    for item, was in pairs(before) do
        given[item] = math.max(0, was - delivery.count(item))
        if given[item] > 0 then any = true end   -- something really left the bags
    end
    if any then return given, leftover, 'ok' end                  -- something arrived
    return given, drops, (outcome == 'ok') and 'busy' or outcome  -- nothing moved
end

--[[--------------------------------------------------------------------------
  delivery.giveItems(row, items)

  WHAT  : One trade attempt with one member for everything in items.
          Returns item name to count delivered, and a reason.
  WHY   : The single call init.lua makes per attempt.
  WHERE : init.lua trade queue.
  HOW   : Walk into range ('range' when that fails), build the plan, run
          trades until the plan is empty, nothing moves, or Stop. The reason
          is 'ok' when anything arrived, otherwise the last trade's reason.
  WHEN  : Once per attempt, after summoning.
----------------------------------------------------------------------------]]
function delivery.giveItems(row, items)
    local total = {}
    if not delivery.moveInRange(row) then return total, 'range' end

    local remaining, reason, anyAtAll = buildPlan(items), 'busy', false   -- drops still to hand over
    while #remaining > 0 and not core.aborted() do   -- keep trading until done or Stop
        local given, leftover, why = runOneTrade(row, remaining)   -- one trade window
        reason = why   -- remember why it ended
        for item, n in pairs(given) do   -- add this trade to the totals
            total[item] = (total[item] or 0) + n   -- running total
            if n > 0 then anyAtAll = true end
        end
        if why ~= 'ok' then break end              -- nothing moved: stop here
        remaining = leftover
        if #remaining > 0 then mq.delay(500) end   -- short gap between trades
    end
    if anyAtAll then return total, 'ok' end
    return total, core.aborted() and 'stop' or reason   -- nothing delivered
end

return delivery   -- hand the module table to require('provisions.delivery')

--[[==========================================================================
  END OF FILE : provisions/delivery.lua

  SUMMARY OF PUBLIC API
    count(name)              number  Exact name count across bags.
    freeSlots()              number  Empty bag slots.
    cursorName()             string  Item on the cursor, or nil.
    cursorStack()            number  Items on the cursor, 0 if empty.
    clearCursor(ms)          bool    /autoinventory until empty.
    locate(name)             table   First stack location, or nil.
    pickUp(name, n)          number  Lift up to n onto the cursor.
    query(name, q, ms)       string  DanNet query answer, or nil.
    queryCount(name, item)   number  DanNet item count, or nil.
    peerInCombat(name)       bool    DanNet combat state, or nil.
    cancel()                         Cancel a trade, clear the cursor.
    moveInRange(row)         bool    Walk into trade range.
    giveItems(row, items)    table, reason   One trade attempt.

  DEPENDENCIES : mq, provisions.core.
                 Optional plugins: MQ2DanNet (accept, Top up, busy check),
                 MQ2EQBC (accept), MQ2Nav (walking).

  HOW TO EDIT SAFELY
    - Partial stack pickups failing: turn on Debug trace and check the
      QuantityWnd control names (QTYW_slider, QTYW_Accept_Button) with
      /windows in game.
    - Only general inventory is touched. Raise LAST_GENERAL_SLOT if a
      future client adds slots.
    - Add an accept method: a branch in remoteAccept and a radio button in
      ui.lua drawOptions.
    - Delivery is verified by recounting the caster's bags. Never let the
      caster receive items in the same trade or the count will be wrong.
    - New trade reasons must also be handled in init.lua serveMembers.
==========================================================================]]--
