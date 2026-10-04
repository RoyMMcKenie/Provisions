--[[==========================================================================
  FILE        : clericfood/group.lua
  PACKAGE     : ClericFood Lua  (MacroQuest / EverQuest)
  VERSION     : 1.3.1
  CHANGES     : 1.0.0  First release.
                1.1.0  No change in this file.
                1.2.0  Full inline documentation pass. No behaviour change.
                1.3.0  No change in this file.
                1.3.1  Documentation audit: every code line now carries
                       its own comment or one directly above it.

  WHAT  : Builds the roster the window shows as a checkbox list: the cleric
          plus every group member, with zone presence, distance and whether the
          member can receive a trade at all.

  WHY   : The window must reflect the live group. Members join, leave, die and
          zone, and mercenaries appear in the group list but cannot be handed
          items. Collecting all of that in one place keeps the window drawing
          code simple and keeps the job runner from trying to trade with
          someone who is not there.

  WHERE : Required by ui.lua (to draw the list), actions.lua (to decide who
          gets served) and init.lua (/cfood all).

  HOW   : Walks Group.Member(0) through Group.Member(n). Member 0 is always the
          cleric. Each row is a small table. The roster is rebuilt at most twice
          a second rather than every frame, because TLO lookups are not free
          and the window repaints about sixty times a second.

  WHEN  : group.refresh is called by ui.lua on a timer and by actions.lua at
          the start of each job.

  READING GUIDE (for future you)
    - A "row" is one line of the checkbox list. Its fields are listed on
      group.roster below.
    - Ticks are remembered by character NAME in the settings file, not by
      position, so reforming the group in a different order keeps them.
==========================================================================]]--

local mq     = require('mq')                  -- Group, Me and Spawn TLOs
local config = require('clericfood.config')   -- settings.selected (the ticks)

local group = {}

--- Cached roster -----------------------------------------------------------------
-- WHAT : Array of member rows, cleric first.
-- WHY  : The window reads this every frame. Rebuilding it every frame would
--        cost dozens of TLO calls per frame for no benefit.
-- WHERE: Read by ui.lua and actions.lua, written by group.refresh.
-- HOW  : Each row:
--          name     string  character name
--          id       number  spawn id in this zone (nil if not in zone)
--          isSelf   bool    true for the cleric's own row
--          isMerc   bool    true for a mercenary (cannot trade)
--          present  bool    true when in this zone
--          distance number  units from the cleric (0 for self, 9999 unknown)
--          class    string  three letter class, e.g. WAR
-- WHEN : Replaced on each refresh.
group.roster = {}

--- Refresh throttle ----------------------------------------------------------------
-- WHAT : Time of the last rebuild in milliseconds, and the minimum gap.
-- WHY  : Limits refreshes to REFRESH_MS apart when called from the UI.
-- WHERE: group.refresh.
-- HOW  : Compared against mq.gettime.
-- WHEN : Every refresh call.
local lastRefresh = 0
local REFRESH_MS  = 500

--[[--------------------------------------------------------------------------
  buildRow(member, isSelf)

  WHAT  : Converts one Group.Member TLO into a plain roster row.
  WHY   : Plain values are safe to read later even if the member has left the
          group since; a stale TLO would return nil fields mid draw.
  WHERE : group.refresh.
  HOW   : Reads name, spawn id, distance, mercenary flag and class. present is
          true only if the member's spawn exists in this zone.
  WHEN  : During refresh.
----------------------------------------------------------------------------]]
local function buildRow(member, isSelf)
    -- Name works even when the member is in another zone.
    local name = member.Name() or '?'
    -- Spawn is the member's in zone body; its fields are nil when out of zone.
    local spawn = member.Spawn
    local id = spawn.ID()
    return {
        name     = name,  -- character name, also the key for the tick
        id       = id,  -- spawn id in this zone, nil when out of zone
        isSelf   = isSelf,  -- true only for member 0, the cleric
        isMerc   = member.Mercenary() == true,  -- mercenaries are listed but cannot receive items
        present  = id ~= nil and id > 0,  -- in zone when there is a valid spawn id
        distance = isSelf and 0 or (spawn.Distance() or 9999),  -- self is 0; 9999 means unknown
        class    = spawn.Class.ShortName() or '',  -- three letter class, e.g. WAR
    }
end

--[[--------------------------------------------------------------------------
  group.refresh(force)

  WHAT  : Rebuilds group.roster from the live group.
  WHY   : Keeps the checkbox list and the job runner in step with the game.
  WHERE : ui.lua each frame (throttled), actions.lua and init.lua with
          force = true.
  HOW   : When solo, the roster is just the cleric. Otherwise member 0 through
          Group.Members.
  WHEN  : See above.
----------------------------------------------------------------------------]]
function group.refresh(force)
    -- Throttle: skip if refreshed less than REFRESH_MS ago, unless forced.
    local now = mq.gettime()
    if not force and now - lastRefresh < REFRESH_MS then return end
    lastRefresh = now

    local rows = {}  -- new roster, built fresh then swapped in
    -- Group.Members counts OTHER members (0 when solo, up to 5).
    local count = mq.TLO.Group.Members() or 0

    if count == 0 then
        -- Solo: build the cleric's row directly from Me.
        rows[1] = {
            name = mq.TLO.Me.CleanName() or 'Me', id = mq.TLO.Me.ID(),
            isSelf = true, isMerc = false, present = true, distance = 0,
            class = mq.TLO.Me.Class.ShortName() or '',  -- cleric's class for the Class column
        }
    else
        -- Grouped: member 0 is the cleric, 1..count are the others.
        for i = 0, count do
            local member = mq.TLO.Group.Member(i)
            if member() then rows[#rows + 1] = buildRow(member, i == 0) end
        end
    end

    -- Swap in the new list in one assignment so the window never sees a
    -- half built roster.
    group.roster = rows
end

--[[--------------------------------------------------------------------------
  group.isSelected(name) / group.setSelected(name, value)

  WHAT  : Reads and writes the tick state of one member by name.
  WHY   : Ticks are stored by name in settings so they survive a group being
          reformed in a different order, or the script restarting.
  WHERE : ui.lua checkboxes, actions.lua, group.setAll.
  HOW   : config.settings.selected[name]. Unticking stores nil (removes the
          key) rather than false, so the settings file stays short.
  WHEN  : On draw and on click.
----------------------------------------------------------------------------]]
function group.isSelected(name)
    return config.settings.selected[name] == true
end

function group.setSelected(name, value)  -- value true ticks, false unticks
    config.settings.selected[name] = value and true or nil  -- untick stores nil so the settings file stays short
end

--[[--------------------------------------------------------------------------
  group.setAll(value)

  WHAT  : Ticks or unticks every eligible member at once.
  WHY   : "Feed the whole group" is the common case and should be one click.
  WHERE : ui.lua Select all and Clear buttons, /cfood all.
  HOW   : Loops the roster, skipping mercenaries.
  WHEN  : On button press.
----------------------------------------------------------------------------]]
function group.setAll(value)
    for _, row in ipairs(group.roster) do
        if not row.isMerc then group.setSelected(row.name, value) end
    end
end

--[[--------------------------------------------------------------------------
  group.selectedRows()

  WHAT  : Returns the roster rows that are ticked and can actually be served.
  WHY   : The job runner should only ever see valid targets.
  WHERE : actions.lua.
  HOW   : Filters out mercenaries and members not in the zone.
  WHEN  : At job start.
----------------------------------------------------------------------------]]
function group.selectedRows()
    local out = {}
    for _, row in ipairs(group.roster) do
        -- All three must hold: ticked, not a merc, and in this zone.
        if group.isSelected(row.name) and not row.isMerc and row.present then
            out[#out + 1] = row
        end
    end
    return out  -- only valid, ticked members
end

return group  -- hand the module table to require('clericfood.group')

--[[==========================================================================
  END OF FILE : clericfood/group.lua

  SUMMARY OF PUBLIC API
    roster                 table   Cached rows, cleric first.
    refresh(force)                 Rebuild, throttled unless forced.
    isSelected(name)       bool    Tick state.
    setSelected(name, v)           Set tick state.
    setAll(v)                      Tick or untick all eligible rows.
    selectedRows()         table   Ticked, present, non mercenary rows.

  DEPENDENCIES : mq, clericfood.config.

  HOW TO EDIT SAFELY
    - Add a column to the window: add the field in buildRow (and in the solo
      row in refresh), then draw it in ui.lua drawRoster.
    - Distance is refreshed with the roster, so the window figure can lag by
      up to REFRESH_MS. trade.lua always reads live distance before trading.
    - Per member counts could be added by storing a table instead of true in
      settings.selected[name]; isSelected would then test for a table.
==========================================================================]]--
