--[[==========================================================================
  FILE        : clericfood/inventory.lua
  PACKAGE     : ClericFood Lua  (MacroQuest / EverQuest)
  VERSION     : 1.3.1
  CHANGES     : 1.0.0  First release.
                1.1.0  No change in this file.
                1.2.0  Full inline documentation pass. No behaviour change.
                1.3.0  No change in this file.
                1.3.1  Documentation audit: every code line now carries
                       its own comment or one directly above it.

  WHAT  : Everything that touches the cleric's own bags: counting an item,
          clearing the cursor into the bags, checking free space, and picking an
          exact quantity of an item up onto the cursor so it can be traded.

  WHY   : Handing out "7 bread" means lifting exactly 7 off a stack of 20. EQ
          only offers three ways to do that: shift click (whole stack), ctrl
          click (one), or a plain click that opens the quantity slider. Getting
          that right is fiddly and is the single most likely thing to need
          adjustment against a live client, so it lives in one module with
          nothing else in it.

  WHERE : Required by spells.lua (to stash summoned items and count stock),
          trade.lua (to lift items for a trade) and actions.lua (stock counts).

  HOW   : Uses FindItem / FindItemCount for lookups, /autoinventory to stash,
          /itemnotify with /shiftkey or /ctrlkey for pickups, and the
          QuantityWnd slider for partial stacks. Bags are opened only when the
          item lives inside a closed bag, and closed again afterwards so the
          screen is left as the operator had it.

  WHEN  : Whenever a summoned item needs to be stored, counted or lifted.

  READING GUIDE (for future you)
    - EQ slot numbers: 23 to 32 are the ten general inventory slots, left to
      right, top to bottom. A bag sitting in slot 23 is "pack1", slot 32 is
      "pack10". Slots inside a bag are numbered from 1 in /itemnotify.
    - MacroQuest's ItemSlot2 is the slot inside the bag counted from 0, or -1
      when the item is loose in a general slot (not in a bag).
    - "Cursor" is the item stuck to your mouse pointer. Summon spells put the
      new item there.
==========================================================================]]--

local mq    = require('mq')                 -- TLO access and mq.delay
local utils = require('clericfood.utils')   -- cmd, delay, echo helpers

local inventory = {}

--- First and last general inventory slot ids ------------------------------------
-- WHAT : EQ numbers the ten general inventory slots 23 through 32.
-- WHY  : An item's ItemSlot in that range is either a loose item in a general
--        slot or, when ItemSlot2 is 0 or more, an item inside the bag sitting
--        in that slot. Converting to pack1 .. pack10 needs the offset.
-- WHERE: inventory.locate.
-- HOW  : Constants.
-- WHEN : On every pickup.
local FIRST_GENERAL_SLOT = 23
local LAST_GENERAL_SLOT  = 32

--[[--------------------------------------------------------------------------
  inventory.count(itemName)

  WHAT  : Returns how many of an exact item name the cleric is carrying.
  WHY   : Used to decide how many more casts are needed and how much stock can
          be handed out.
  WHERE : spells.summonUntil, actions.lua, trade.lua, ui.lua.
  HOW   : FindItemCount with a leading = for an exact name match, so
          "Summoned: Black Bread" never matches some other bread item.
  WHEN  : Before and during summoning, and before each delivery.
----------------------------------------------------------------------------]]
function inventory.count(itemName)
    -- No name configured yet means nothing can be counted.
    if not itemName or itemName == '' then return 0 end
    -- FindItemCount sums every stack across all bags. The trailing () reads
    -- the value; it returns nil when nothing is found, hence "or 0".
    return mq.TLO.FindItemCount('=' .. itemName)() or 0
end

--[[--------------------------------------------------------------------------
  inventory.freeSlots()

  WHAT  : Returns the number of empty bag slots.
  WHY   : Summoning onto a full inventory leaves the item stuck on the cursor,
          which blocks every later cast. Checking first avoids that.
  WHERE : spells.summonUntil.
  HOW   : Me.FreeInventory.
  WHEN  : Before each cast.
----------------------------------------------------------------------------]]
function inventory.freeSlots()
    return mq.TLO.Me.FreeInventory() or 0
end

--[[--------------------------------------------------------------------------
  inventory.cursorName() / inventory.cursorStack()

  WHAT  : Name and stack size of whatever is on the cursor, or nil and 0.
  WHY   : Summon spells drop their item on the cursor. Reading the name is how
          the package learns the real item name on any server, and the stack
          size is how a pickup is verified.
  WHERE : spells.castOnce, inventory.pickUp, trade.lua.
  HOW   : Cursor TLO.
  WHEN  : After a cast and after a pickup.
----------------------------------------------------------------------------]]
function inventory.cursorName()
    return mq.TLO.Cursor.Name()   -- nil when the cursor is empty
end

function inventory.cursorStack()
    -- Empty cursor: nothing held.
    if not mq.TLO.Cursor.ID() then return 0 end
    -- Non stackable items report Stack 0 or nil, but there is still one item
    -- on the cursor, so treat anything below 1 as 1.
    local stack = mq.TLO.Cursor.Stack() or 1
    if stack < 1 then stack = 1 end
    return stack
end

--[[--------------------------------------------------------------------------
  inventory.clearCursor(timeoutMs)

  WHAT  : Puts whatever is on the cursor into the bags. Returns true when the
          cursor ends up empty.
  WHY   : The cursor must be empty before casting again and before lifting
          an item for trade.
  WHERE : spells.castOnce, trade.lua on cancel, actions.lua cleanup.
  HOW   : /autoinventory repeated until the cursor clears or time runs out.
          Repeats are needed because Abundant Food can produce more than one
          item and EQ sometimes needs a second nudge. Uses plain mq.delay, not
          utils.delay, so it still works during cleanup after Stop.
  WHEN  : After every cast and after any aborted pickup.
----------------------------------------------------------------------------]]
function inventory.clearCursor(timeoutMs)
    timeoutMs = timeoutMs or 3000                -- default: try for 3 seconds
    local deadline = mq.gettime() + timeoutMs    -- mq.gettime is milliseconds
    while mq.TLO.Cursor.ID() and mq.gettime() < deadline do
        utils.cmd('/autoinventory')              -- EQ puts the item in the first fitting slot
        -- Give the game up to a quarter second to move it before trying again.
        mq.delay(250, function() return not mq.TLO.Cursor.ID() end)
    end
    return not mq.TLO.Cursor.ID()                -- true when the cursor is empty
end

--[[--------------------------------------------------------------------------
  inventory.locate(itemName)

  WHAT  : Finds the first stack of an item and describes where it is.
  WHY   : /itemnotify needs a location, not a name.
  WHERE : inventory.pickUp.
  HOW   : FindItem with an exact match. Returns a table with the stack size and
          either { pack = n, slot = s } for an item inside a bag, or
          { slotId = id } for a loose item in a general slot. Returns nil when
          the item is not carried or lives somewhere the script will not touch
          (worn slots, bank).
  WHEN  : Right before each pickup.
----------------------------------------------------------------------------]]
function inventory.locate(itemName)
    -- FindItem returns the first matching item. Calling item() checks it exists.
    local item = mq.TLO.FindItem('=' .. itemName)
    if not item() then return nil end

    local slot  = item.ItemSlot() or -1    -- 23 to 32 for general inventory
    local slot2 = item.ItemSlot2() or -1   -- 0 based slot inside bag, -1 if loose
    local stack = item.Stack() or 1        -- how many are in this one stack
    if stack < 1 then stack = 1 end

    -- Refuse anything outside general inventory (worn, bank, and so on).
    if slot < FIRST_GENERAL_SLOT or slot > LAST_GENERAL_SLOT then
        utils.debug('%s found in slot %d, outside general inventory', itemName, slot)
        return nil
    end

    if slot2 >= 0 then  -- ItemSlot2 of 0 or more means the item is inside a bag
        -- Inside a bag: convert to pack number (1 to 10) and 1 based bag slot.
        return { pack = slot - FIRST_GENERAL_SLOT + 1, slot = slot2 + 1, stack = stack }
    end
    -- Loose in a general slot: /itemnotify accepts the raw slot number.
    return { slotId = slot, stack = stack }
end

--[[--------------------------------------------------------------------------
  packWindowOpen(packNumber)

  WHAT  : True when the bag window for packN is open.
  WHY   : Older clients and some builds refuse /itemnotify into a closed bag.
          Knowing the state lets the script open it only when needed and put
          it back afterwards.
  WHERE : inventory.pickUp.
  HOW   : Window TLO, window name is PackN.
  WHEN  : Before and after a pickup from a bag.
----------------------------------------------------------------------------]]
local function packWindowOpen(packNumber)
    return mq.TLO.Window('Pack' .. packNumber).Open() == true
end

--[[--------------------------------------------------------------------------
  notifyTarget(loc)

  WHAT  : Builds the /itemnotify location text for a located item.
  WHY   : Bag items and loose items use different syntax.
  WHERE : inventory.pickUp.
  HOW   : "in packN S" for bag items, the numeric slot id for loose items.
  WHEN  : On every pickup.
----------------------------------------------------------------------------]]
local function notifyTarget(loc)
    if loc.pack then
        return string.format('in pack%d %d', loc.pack, loc.slot)  -- e.g. "in pack3 5"
    end
    return tostring(loc.slotId)                                    -- e.g. "27"
end

--[[--------------------------------------------------------------------------
  inventory.pickUp(itemName, wanted)

  WHAT  : Lifts up to wanted of an item onto the cursor from a single stack.
          Returns the number actually on the cursor (0 on failure).
  WHY   : Trades are built one stack at a time. Taking from one stack per call
          keeps the logic simple; the caller loops for more.
  WHERE : trade.lua runOneTrade.
  HOW   : Picks the first stack. If wanted covers the whole stack, shift click.
          If wanted is 1, ctrl click. Otherwise plain click, wait for the
          QuantityWnd, set the slider to wanted, accept. The bag is opened
          first only if it was closed, and closed again afterwards.
  WHEN  : While filling a trade window.
----------------------------------------------------------------------------]]
function inventory.pickUp(itemName, wanted)
    -- Step 1: the cursor must be empty, or the click would swap items.
    if mq.TLO.Cursor.ID() then
        utils.warn('Cursor not empty before pickup, stashing it first.')
        if not inventory.clearCursor() then return 0 end
    end

    -- Step 2: find where the first stack lives.
    local loc = inventory.locate(itemName)
    if not loc then
        utils.err('Could not find %s in bags.', itemName)
        return 0  -- 0 tells the caller nothing was lifted
    end

    -- Never ask for more than this one stack holds; caller loops for the rest.
    local take  = math.min(wanted, loc.stack)
    local where = notifyTarget(loc)

    -- Step 3: open the bag if it is closed. Right clicking a bag toggles it.
    local openedBag = false
    if loc.pack and not packWindowOpen(loc.pack) then
        utils.cmd('/itemnotify pack%d rightmouseup', loc.pack)
        utils.delay(1500, function() return packWindowOpen(loc.pack) end)  -- wait up to 1.5 s for the bag window to open
        openedBag = true   -- remember so we close it again in step 5
    end

    -- Step 4: lift the right amount using the EQ click rules.
    if take >= loc.stack then
        -- Whole stack: shift + click lifts all of it with no slider.
        utils.cmd('/shiftkey /itemnotify %s leftmouseup', where)
    elseif take == 1 then
        -- Exactly one: ctrl + click lifts a single item with no slider.
        utils.cmd('/ctrlkey /itemnotify %s leftmouseup', where)
    else
        -- Part of a stack: a plain click opens the quantity slider window.
        utils.cmd('/itemnotify %s leftmouseup', where)
        local qtyOpen = utils.delay(1500, function()
            return mq.TLO.Window('QuantityWnd').Open() == true
        end)
        if qtyOpen then  -- slider window opened: set the amount and accept
            -- Move the slider to the amount we want, then press Accept.
            utils.cmd('/notify QuantityWnd QTYW_slider newvalue %d', take)
            mq.delay(150)   -- tiny pause so the slider value registers first
            utils.cmd('/notify QuantityWnd QTYW_Accept_Button leftmouseup')
        end
    end

    -- Wait for the item to actually appear on the cursor.
    utils.delay(1500, function() return mq.TLO.Cursor.ID() ~= nil end)

    -- Step 5: close the bag only if we were the ones who opened it.
    if openedBag and packWindowOpen(loc.pack) then
        utils.cmd('/itemnotify pack%d rightmouseup', loc.pack)
    end

    -- Step 6: report what we really got so the caller can adjust.
    local got = inventory.cursorStack()
    if got == 0 then
        utils.err('Pickup of %s failed.', itemName)
    elseif got ~= take then  -- got some, but not the amount asked for
        utils.debug('Asked for %d %s, cursor holds %d', take, itemName, got)  -- normal when the stack was smaller; caller queues the rest
    end
    return got  -- number of items now on the cursor
end

return inventory  -- hand the module table to require('clericfood.inventory')

--[[==========================================================================
  END OF FILE : clericfood/inventory.lua

  SUMMARY OF PUBLIC API
    count(name)            number  Exact name item count across bags.
    freeSlots()            number  Empty bag slots.
    cursorName()           string  Item name on cursor or nil.
    cursorStack()          number  Stack on cursor, 0 if empty.
    clearCursor(ms)        bool    /autoinventory until clear.
    locate(name)           table   First stack location, or nil.
    pickUp(name, n)        number  Lift up to n from one stack onto cursor.

  DEPENDENCIES : mq, clericfood.utils.

  HOW TO EDIT SAFELY
    - If partial pickups fail on your client, turn on Debug and check that the
      quantity window is named QuantityWnd with controls QTYW_slider and
      QTYW_Accept_Button (type /windows in game to list window names). Those
      names come from the MacroQuest /notify docs.
    - Only general inventory (slots 23 to 32 and their bags) is touched.
      Summoned food in a worn slot or the bank is ignored on purpose.
    - If a future client adds more general slots, raise LAST_GENERAL_SLOT.
==========================================================================]]--
