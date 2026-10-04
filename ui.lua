--[[==========================================================================
  FILE        : clericfood/ui.lua
  PACKAGE     : ClericFood Lua  (MacroQuest / EverQuest)
  VERSION     : 1.3.1
  CHANGES     : 1.0.0  First release.
                1.1.0  MQ2Cast toggle, max tries box, last cast result line.
                1.2.0  Full inline documentation pass. No behaviour change.
                1.3.0  Live summon progress line with fizzle and interrupt
                       counts. Summon time limit box.
                1.3.1  Documentation audit: every code line now carries
                       its own comment or one directly above it.

  WHAT  : The ImGui window: a checkbox list of the group, food and drink count
          selectors, Hand Out and Stop buttons, live status, last results, and
          a collapsible Options section.

  WHY   : This is the feature the operator asked for. Ticking who gets fed and
          choosing how many is a two second job in a window, and the window
          shows at a glance whether each box was actually served.

  WHERE : Registered by init.lua through mq.imgui.init, which calls ui.render
          once per frame.

  HOW   : Draws only; never waits. Buttons call actions.request and
          actions.stop, which flip flags that init.lua's main loop acts on.
          Any changed setting marks the settings dirty, and ui.flushSave writes
          the file at most once a second so a slider drag is not hundreds of
          disk writes.

  WHEN  : Every frame while the window is open.

  READING GUIDE (for future you)
    - ImGui is "immediate mode": the whole window is redrawn from scratch
      every frame. There are no stored widgets. A button press is detected by
      the Button call returning true on the frame it was clicked.
    - Every ImGui.BeginX must be matched by its EndX, even when nothing is
      drawn in between. A missing End crashes the window.
    - Labels after ## are hidden IDs. "##give" draws no text but gives the
      checkbox a unique ID; PushID(row.name) makes it unique per row.
    - Window layout, top to bottom:
        drawCounts      Food each, Drink each, quick buttons
        drawRoster      Select all / Clear, the checkbox table
        drawRunControls Hand Out, Stop, status, spells, stock
        drawOptions     collapsible settings
==========================================================================]]--

local mq        = require('mq')                     -- gettime for the save debounce
local ImGui     = require('ImGui')                  -- the window toolkit
local utils     = require('clericfood.utils')       -- clamp
local config    = require('clericfood.config')      -- settings to read and edit
local inventory = require('clericfood.inventory')   -- stock on hand line
local spells    = require('clericfood.spells')      -- detected spells, last result
local group     = require('clericfood.group')       -- roster and ticks
local actions   = require('clericfood.actions')     -- request, stop, status, results

local ui = {}

--- Window open flag --------------------------------------------------------------
-- WHAT : Whether the window is shown. Closing it does not stop a running job.
-- WHY  : The operator may want the screen space back mid hand out.
-- WHERE: ui.render and /cfood in init.lua.
-- HOW  : Passed to and returned from ImGui.Begin.
-- WHEN : Toggled by the close button or the slash command.
ui.open = true

--- Save debounce -------------------------------------------------------------------
-- WHAT : dirty marks unsaved changes, lastSave is the time of the last write.
-- WHY  : Prevents writing the settings file on every frame of a drag.
-- WHERE: markDirty and ui.flushSave.
-- HOW  : Compared against mq.gettime.
-- WHEN : Every frame.
local dirty, lastSave = false, 0

--- Colours -------------------------------------------------------------------------
-- WHAT : RGBA tuples for status text (red, green, blue, alpha from 0 to 1).
-- WHY  : Green means fine, amber means look, red means act, grey is info.
-- WHERE: Roster and status drawing.
-- HOW  : Arrays of four floats unpacked into TextColored.
-- WHEN : Every frame.
local GREEN = { 0.35, 0.85, 0.40, 1.0 }
local AMBER = { 0.95, 0.80, 0.30, 1.0 }
local RED   = { 1.00, 0.40, 0.35, 1.0 }
local GREY  = { 0.65, 0.65, 0.65, 1.0 }  -- informational text and blank results

--[[--------------------------------------------------------------------------
  colored(color, fmt, ...)

  WHAT  : Draws one line of coloured text.
  WHY   : Shortens every TextColored call in this file.
  WHERE : Throughout ui.lua.
  HOW   : Unpacks the colour and formats the text. No varargs means fmt is
          drawn as is, which keeps names containing % safe.
  WHEN  : While drawing.
----------------------------------------------------------------------------]]
local function colored(color, fmt, ...)
    local text = select('#', ...) > 0 and string.format(fmt, ...) or fmt
    ImGui.TextColored(color[1], color[2], color[3], color[4], text)
end

--[[--------------------------------------------------------------------------
  tooltip(text)

  WHAT  : Shows text when the previous control is hovered.
  WHY   : Puts the explanation of each option next to the option, so nobody
          needs the README while playing.
  WHERE : After most controls.
  HOW   : IsItemHovered refers to the control drawn just before this call.
  WHEN  : While drawing.
----------------------------------------------------------------------------]]
local function tooltip(text)
    if ImGui.IsItemHovered() then ImGui.SetTooltip(text) end
end

--[[--------------------------------------------------------------------------
  markDirty()

  WHAT  : Flags that settings changed and need saving.
  WHY   : See the save debounce note above.
  WHERE : Every control that edits a setting.
  HOW   : Sets the local dirty flag.
  WHEN  : On change.
----------------------------------------------------------------------------]]
local function markDirty()
    dirty = true
end

--[[--------------------------------------------------------------------------
  ui.flushSave(force)

  WHAT  : Writes settings if dirty and a second has passed, or at once when
          forced.
  WHY   : Keeps disk writes rare while still saving promptly.
  WHERE : End of ui.render, and init.lua on exit with force = true.
  HOW   : config.save behind a time check.
  WHEN  : Every frame, and at shutdown.
----------------------------------------------------------------------------]]
function ui.flushSave(force)
    if not dirty then return end                 -- nothing changed
    local now = mq.gettime()
    if force or now - lastSave > 1000 then       -- at most one write per second
        config.save()
        dirty, lastSave = false, now
    end
end

--[[--------------------------------------------------------------------------
  checkbox(label, key, help)

  WHAT  : Draws a checkbox bound to a boolean setting.
  WHY   : Removes repetitive read, draw, compare, write code for each option.
  WHERE : drawOptions.
  HOW   : ImGui.Checkbox returns the new value; when it differs, store it and
          mark dirty.
  WHEN  : While drawing.
----------------------------------------------------------------------------]]
local function checkbox(label, key, help)
    local s = config.settings
    local value = ImGui.Checkbox(label, s[key] == true)        -- draw, get new state
    if value ~= s[key] then s[key] = value markDirty() end     -- store on change
    if help then tooltip(help) end
end

--[[--------------------------------------------------------------------------
  intInput(label, key, lo, hi, step, stepFast, help, width)

  WHAT  : Draws an integer box with plus and minus buttons, bound to a setting.
  WHY   : Food and drink counts, gem number and timeouts all need the same
          bounded number input.
  WHERE : drawCounts and drawOptions.
  HOW   : ImGui.InputInt (step is the +/- amount, stepFast is with ctrl held),
          then utils.clamp to the allowed range.
  WHEN  : While drawing.
----------------------------------------------------------------------------]]
local function intInput(label, key, lo, hi, step, stepFast, help, width)
    local s = config.settings
    ImGui.SetNextItemWidth(width or 120)                       -- box width in pixels
    local value = ImGui.InputInt(label, s[key], step or 1, stepFast or 5)
    value = utils.clamp(value, lo, hi)                         -- keep in range
    if value ~= s[key] then s[key] = value markDirty() end
    if help then tooltip(help) end
end

--[[--------------------------------------------------------------------------
  textInput(label, key, help)

  WHAT  : Draws a text box bound to a string setting.
  WHY   : Spell overrides and item names may need typing on unusual servers.
  WHERE : drawOptions.
  HOW   : ImGui.InputText, store when changed.
  WHEN  : While drawing.
----------------------------------------------------------------------------]]
local function textInput(label, key, help)
    local s = config.settings
    ImGui.SetNextItemWidth(220)
    local value = ImGui.InputText(label, s[key] or '')  -- draw the box, get the current text back
    if value ~= s[key] then s[key] = value markDirty() end  -- store on change and schedule a save
    if help then tooltip(help) end  -- hover help
end

--[[--------------------------------------------------------------------------
  drawCounts()

  WHAT  : The food and drink quantity selectors plus quick set buttons.
  WHY   : The two numbers the operator changes most often sit at the top.
  WHERE : ui.render.
  HOW   : Two bounded intInputs, then 5 / 10 / 20 buttons that set both, and
          Drink only / Food only buttons that zero the other. Disabled while a
          job runs so the plan cannot change underneath it.
  WHEN  : Every frame.
----------------------------------------------------------------------------]]
local function drawCounts()
    local s = config.settings
    ImGui.BeginDisabled(actions.running)   -- grey out during a job

    intInput('Food each', 'foodCount', 0, 80, 1, 5,
        'How many food items every ticked member should receive.')
    ImGui.SameLine()                       -- keep Drink on the same line
    intInput('Drink each', 'drinkCount', 0, 80, 1, 5,
        'How many drink items every ticked member should receive.')

    -- Quick set buttons on one row.
    for _, n in ipairs({ 5, 10, 20 }) do
        if ImGui.Button(tostring(n) .. ' each') then
            s.foodCount, s.drinkCount = n, n
            markDirty()  -- schedule a save
        end
        tooltip('Set both food and drink to ' .. n .. '.')  -- hover help for each quick button
        ImGui.SameLine()  -- next button on the same row
    end
    if ImGui.Button('Drink only') then s.foodCount = 0 markDirty() end  -- zero food, keep drink
    tooltip('Set food to zero.')  -- hover help
    ImGui.SameLine()  -- next button on the same row
    if ImGui.Button('Food only') then s.drinkCount = 0 markDirty() end  -- zero drink, keep food
    tooltip('Set drink to zero.')  -- hover help

    ImGui.EndDisabled()                    -- must match BeginDisabled above
end

--[[--------------------------------------------------------------------------
  resultText(name)

  WHAT  : Builds the Last result cell for one member, with a colour.
  WHY   : Shows at a glance who was served and who was missed.
  WHERE : drawRoster.
  HOW   : Compares delivered to requested from actions.results. Green when
          full or a note applies (kept, already stocked), amber when partly
          served, red when nothing arrived, blank when not in the last job.
  WHEN  : Every frame.
----------------------------------------------------------------------------]]
local function resultText(name)
    local r = actions.results[name]
    if not r then return GREY, '' end                -- not part of last job
    local text = string.format('%d food, %d drink', r.food or 0, r.drink or 0)
    if r.note then text = text .. ' (' .. r.note .. ')' end
    local s = config.settings
    local full = (r.food or 0) >= s.foodCount and (r.drink or 0) >= s.drinkCount  -- true when this member got at least the full counts
    if r.note or full then return GREEN, text end  -- green: full, kept, or already stocked
    if (r.food or 0) + (r.drink or 0) > 0 then return AMBER, text end  -- amber: something arrived but not everything
    return RED, text  -- red: nothing arrived
end

--[[--------------------------------------------------------------------------
  drawRoster()

  WHAT  : The checkbox list of group members.
  WHY   : This is how the operator picks who gets food and drink.
  WHERE : ui.render.
  HOW   : Refresh the roster (throttled), then a five column table: Give,
          Name, Class, Distance, Last result. Mercenaries and members out of
          zone are shown but their boxes are disabled. The cleric's own row
          means "keep a set for me". Select all and Clear sit above the table.
  WHEN  : Every frame.
----------------------------------------------------------------------------]]
local function drawRoster()
    group.refresh(false)   -- throttled inside group.lua to twice a second

    -- Bulk tick buttons.
    ImGui.BeginDisabled(actions.running)
    if ImGui.Button('Select all') then group.setAll(true) markDirty() end
    ImGui.SameLine()
    if ImGui.Button('Clear') then group.setAll(false) markDirty() end  -- untick everyone
    ImGui.EndDisabled()  -- matches BeginDisabled above the buttons

    -- Table with borders and alternating row shading.
    local flags = ImGuiTableFlags.Borders + ImGuiTableFlags.RowBg  -- distinct bits, so + is a safe OR
    -- BeginTable returns false when the table is clipped; EndTable is then skipped.
    if not ImGui.BeginTable('##cfroster', 5, flags) then return end

    -- Column headers. Fixed columns use the pixel width given.
    ImGui.TableSetupColumn('Give',        ImGuiTableColumnFlags.WidthFixed, 40)
    ImGui.TableSetupColumn('Name',        ImGuiTableColumnFlags.WidthStretch)
    ImGui.TableSetupColumn('Class',       ImGuiTableColumnFlags.WidthFixed, 45)
    ImGui.TableSetupColumn('Dist',        ImGuiTableColumnFlags.WidthFixed, 45)  -- distance column, fixed width
    ImGui.TableSetupColumn('Last result', ImGuiTableColumnFlags.WidthStretch)  -- last result column takes the remaining width
    ImGui.TableHeadersRow()  -- draw the header row

    local range = config.settings.tradeRange  -- used to colour the distance figure
    for _, row in ipairs(group.roster) do  -- one table row per roster entry
        ImGui.TableNextRow()  -- start a new table row
        ImGui.PushID(row.name)   -- makes "##give" unique for this row

        -- Column 1: the checkbox.
        ImGui.TableNextColumn()
        local locked = actions.running or row.isMerc or not row.present
        ImGui.BeginDisabled(locked)
        local was = group.isSelected(row.name)  -- current tick state from settings
        local now = ImGui.Checkbox('##give', was)  -- draw the checkbox, returns the new state
        if now ~= was then group.setSelected(row.name, now) markDirty() end  -- store a change and schedule a save
        ImGui.EndDisabled()  -- matches BeginDisabled(locked)
        -- Explain why a box is greyed out, or what the self row means.
        if row.isMerc then tooltip('Mercenaries cannot receive items.')
        elseif not row.present then tooltip('Not in this zone.')
        elseif row.isSelf then tooltip('Keep a set in your own bags.') end

        -- Column 2: name, with a tag for self and mercs.
        ImGui.TableNextColumn()
        if row.isSelf then
            ImGui.Text(row.name .. ' (me)')
        elseif row.isMerc then  -- mercenary row
            colored(GREY, '%s (merc)', row.name)  -- grey name with a merc tag
        else
            ImGui.Text(row.name)  -- normal group member
        end

        -- Column 3: class short name.
        ImGui.TableNextColumn()
        ImGui.Text(row.class or '')

        -- Column 4: distance, green inside trade range, amber outside.
        ImGui.TableNextColumn()
        if not row.present then
            colored(GREY, 'away')
        elseif row.isSelf then  -- no distance shown for the cleric itself
            ImGui.Text('')  -- empty cell keeps the columns aligned
        else
            local c = row.distance <= range and GREEN or AMBER  -- green inside trade range, amber outside
            colored(c, '%.0f', row.distance)  -- distance rounded to whole units
        end

        -- Column 5: what the last job delivered.
        ImGui.TableNextColumn()
        local c, text = resultText(row.name)
        colored(c, text)

        ImGui.PopID()            -- must match PushID above
    end
    ImGui.EndTable()
end

--[[--------------------------------------------------------------------------
  drawRunControls()

  WHAT  : Hand Out and Stop buttons, the status line, and stock on hand.
  WHY   : Start, stop and "what is it doing" belong together.
  WHERE : ui.render.
  HOW   : Hand Out is disabled while running; Stop only while running.
          Stock counts come straight from inventory.count. The last MQ2Cast
          result is shown in amber when it was anything but CAST_SUCCESS.
          While summoning, a progress line shows items made against the
          target plus fizzle and interrupt counts from spells.progress.
  WHEN  : Every frame.
----------------------------------------------------------------------------]]
local function drawRunControls()
    local s = config.settings

    -- Hand Out: only clickable when idle. It only sets a flag (no waiting).
    ImGui.BeginDisabled(actions.running)
    if ImGui.Button('Hand Out', 120, 0) then actions.request() end
    ImGui.EndDisabled()
    tooltip('Summon what is needed and trade it to every ticked member.')  -- hover help for Hand Out
    ImGui.SameLine()  -- Stop on the same row
    -- Stop: only clickable while a job runs.
    ImGui.BeginDisabled(not actions.running)
    if ImGui.Button('Stop', 80, 0) then actions.stop() end
    ImGui.EndDisabled()

    -- Status text next to the buttons.
    ImGui.SameLine()
    colored(actions.running and AMBER or GREEN, actions.status)

    -- Live summon progress, only while a summon is running. Example:
    -- "Summoning food: 9 of 14   fizzles 6   interrupts 0"
    local p = spells.progress
    if actions.running and p.kind then
        colored(AMBER, 'Summoning %s: %d of %d   fizzles %d   interrupts %d',
            p.kind, p.have, p.target, p.fizzles, p.interrupts)  -- values from spells.progress
    end

    -- Information lines.
    colored(GREY, 'Food spell: %s   Drink spell: %s',
        spells.food or 'none found', spells.drink or 'none found')
    if spells.lastResult ~= '' then
        colored(spells.lastResult == 'CAST_SUCCESS' and GREY or AMBER,  -- amber when the last cast did not succeed
            'Last cast result: %s', spells.lastResult)  -- e.g. Last cast result: CAST_FIZZLE
    end
    colored(GREY, 'Carrying: %d %s, %d %s',  -- stock currently in the cleric's bags
        inventory.count(s.foodItem), s.foodItem,  -- food count and item name
        inventory.count(s.drinkItem), s.drinkItem)  -- drink count and item name
end

--[[--------------------------------------------------------------------------
  drawOptions()

  WHAT  : The collapsible Options section.
  WHY   : Settings that are set once per cleric stay out of the way.
  WHERE : ui.render.
  HOW   : Bound checkboxes, number inputs, text inputs and three radio buttons
          for the accept method. A Refresh button re runs spell detection.
  WHEN  : Every frame when expanded.
----------------------------------------------------------------------------]]
local function drawOptions()
    -- CollapsingHeader returns false while collapsed; nothing else to draw.
    if not ImGui.CollapsingHeader('Options') then return end
    local s = config.settings
    ImGui.BeginDisabled(actions.running)

    -- Accept method: { saved value, label shown }.
    ImGui.Text('Receiver accepts trade via:')
    for _, m in ipairs({ { 'dannet', 'DanNet' }, { 'eqbc', 'EQBC' }, { 'none', 'Manual' } }) do
        ImGui.SameLine()
        if ImGui.RadioButton(m[2], s.acceptMethod == m[1]) then  -- returns true on the frame it is clicked
            s.acceptMethod = m[1]  -- store the chosen method
            markDirty()  -- schedule a save
        end
    end

    -- On / off options. Keys match config.DEFAULTS.
    checkbox('Top up only (DanNet)', 'topUp',
        'Ask each box how many it already carries and give only the difference.')
    checkbox('Keep my existing stock', 'preserveOwnStock',
        'Summon for everyone on top of what is already in your bags.')  -- tooltip for preserveOwnStock
    checkbox('Pause RGMercs during hand out', 'pauseRGMercs',  -- setting pauseRGMercs
        'Sends /rgl pause at start and /rgl unpause at end, only if RGMercs is running.')  -- tooltip for pauseRGMercs
    checkbox('Walk to members with MQ2Nav', 'useNav',  -- setting useNav
        'Walk into trade range when a member is too far away.')  -- tooltip for useNav
    checkbox('Cast with MQ2Cast (auto retry fizzles)', 'useMQ2Cast',  -- setting useMQ2Cast
        'MQ2Cast detects fizzles and interrupts and recasts up to Max tries. Loaded for the job if needed.')  -- tooltip for useMQ2Cast
    checkbox('Meditate when out of mana', 'medForMana',  -- setting medForMana
        'Sit and wait for mana instead of skipping the cast.')  -- tooltip for medForMana
    checkbox('Restore borrowed spell gem', 'restoreGem',  -- setting restoreGem
        'Put the original spell back in the gem when finished.')  -- tooltip for restoreGem
    checkbox('Debug trace', 'debug', 'Print every command and decision to chat.')  -- setting debug

    -- Numbers: label, key, min, max, step, ctrl step, tooltip, width.
    intInput('Spell gem', 'gem', 1, 13, 1, 1, 'Gem to borrow when a summon spell is not memorised.', 100)
    intInput('Max tries per cast', 'castMaxTries', 1, 20, 1, 5, 'MQ2Cast -maxtries. Attempts per cast before it reports failure.', 100)
    intInput('Summon time limit (min)', 'summonTimeoutMin', 0, 240, 5, 15, 'Summoning keeps casting through fizzles until the count is reached. This only stops it after this many minutes. 0 = no limit.', 100)
    intInput('Trade range', 'tradeRange', 5, 25, 1, 5, 'Units. EQ allows about 20.', 100)  -- setting tradeRange
    intInput('Accept timeout (s)', 'tradeTimeoutSec', 3, 60, 1, 5, 'Cancel the trade if not accepted in this time.', 100)  -- setting tradeTimeoutSec
    intInput('Meditate timeout (s)', 'medTimeoutSec', 10, 600, 10, 60, 'Longest wait for mana per cast.', 100)  -- setting medTimeoutSec

    -- Text: usually left alone, there for unusual servers.
    textInput('Food spell override', 'foodSpell', 'Leave blank to auto detect.')
    textInput('Drink spell override', 'drinkSpell', 'Leave blank to auto detect.')
    textInput('Food item name', 'foodItem', 'Learned automatically after the first cast.')
    textInput('Drink item name', 'drinkItem', 'Learned automatically after the first cast.')  -- setting drinkItem

    if ImGui.Button('Refresh spells') then spells.detect() end  -- re run spell detection after scribing or editing an override
    ImGui.EndDisabled()  -- matches BeginDisabled at the top of Options
end

--[[--------------------------------------------------------------------------
  ui.render()

  WHAT  : Draws the whole window for one frame.
  WHY   : The single entry point mq.imgui.init calls.
  WHERE : Registered in init.lua.
  HOW   : Begin, counts, roster, run controls, options, End, then flushSave.
  WHEN  : Every frame while ui.open is true.
----------------------------------------------------------------------------]]
function ui.render()
    if not ui.open then return end
    -- Starting size on first ever open; after that ImGui remembers it.
    ImGui.SetNextWindowSize(520, 460, ImGuiCond.FirstUseEver)
    local show
    -- Begin returns: still open (false when X clicked), and whether to draw
    -- (false when collapsed). "##clericfood" is a hidden stable window ID.
    ui.open, show = ImGui.Begin('Cleric Food and Drink##clericfood', ui.open)
    if show then
        drawCounts()
        ImGui.Separator()  -- divider line
        drawRoster()  -- checkbox list of the group
        ImGui.Separator()  -- divider line
        drawRunControls()  -- Hand Out, Stop, status, progress, stock
        ImGui.Separator()  -- divider line
        drawOptions()  -- collapsible settings
    end
    ImGui.End()          -- always called, even when show is false
    ui.flushSave(false)  -- debounced save of any change this frame
end

return ui

--[[==========================================================================
  END OF FILE : clericfood/ui.lua

  SUMMARY OF PUBLIC API
    open                    bool    Window visibility.
    render()                        Draw one frame (mq.imgui.init callback).
    flushSave(force)                Debounced settings write.

  DEPENDENCIES : mq, ImGui, clericfood.utils, config, inventory, spells, group,
                 actions.

  HOW TO EDIT SAFELY
    - Nothing in this file may call mq.delay or any function that waits.
    - Add an option: add the key to config.DEFAULTS, then one checkbox,
      intInput or textInput line in drawOptions.
    - Food and drink counts are global (same for every ticked member). A per
      member override column can be added to drawRoster later by storing
      counts in settings.selected[name] instead of true.
    - Change the 80 limit: edit both intInput lines in drawCounts and the
      clamp lines in config.load and init.lua.
==========================================================================]]--
