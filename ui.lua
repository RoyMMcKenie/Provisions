--[[==========================================================================
  FILE        : provisions/ui.lua
  PACKAGE     : Provisions Lua  (MacroQuest / EverQuest)
  VERSION     : 2.3.4
  CHANGES     : 2.3.4  The MQ2Cast tooltip matches the docs.
                2.3.3  Tooltip and comment fixes (other box loading, trade
                       range, ImGui waits).
                2.3.2  Adds the "Load the link plugin on other boxes"
                       checkbox under the link choice. Text says
                       /provisions.
                2.3.1  No change in this file.
                2.3.0  The Food spell and Drink spell override boxes are now
                       drop downs (spellPicker). They list "Type your own..."
                       at the top, then "Auto" with the best detected spell,
                       then every known food or drink summon spell scribed
                       in this character's book. "Type your own..." opens a
                       text box with a note saying whether that name is in
                       the book.
                2.2.0  Picking a link in Options now also asks for its
                       plugin to be loaded (core.requestLinkLoad). The
                       tooltip says so.
                2.1.0  The link choice in Options is now "Talk to other
                       boxes via" with MQRemote first (the default), then
                       DanNet, EQBC and Manual. Adds a Check links button
                       next to Stop. Shows "no MQRemote" (or "no DanNet")
                       results in red. Top up no longer says DanNet only.
                2.0.0  Renamed from ClericFood ui.lua; window title is now
                       Provisions. Adds a Pause / Resume button next to Stop,
                       shows the current hold (Paused or Combat hold) on the
                       status line, shows a warning for classes without
                       summon spells, and adds Options for Combat Hold,
                       handing RGMercs back during a fight, the settle time,
                       and the busy member tries and retry time.
                1.0.0 to 1.3.2  Released as ClericFood ui.lua. Full history
                       in CHANGELOG.md.

  WHAT  : The ImGui window: food and drink counts, the group checkbox list,
          Hand Out / Pause / Stop, live status and progress, and Options.

  WHY   : The operator picks who gets food and drink and how much without
          typing commands, and can see at a glance what the job is doing.

  WHERE : Required by init.lua, which registers ui.render with
          mq.imgui.init. Reads and writes core.settings and core.job; reads
          casting and delivery for display only.

  HOW   : Immediate mode GUI: ui.render redraws everything every frame from
          the current state. Controls write straight into core.settings and
          mark them dirty; a debounced save writes the file at most once a
          second. Buttons only flip flags in core.job; the job itself runs
          in init.lua's main loop.

  WHEN  : Every frame while the window is open.

  READING GUIDE (for future you)
    - Nothing in this file may wait (no mq.delay). The MacroQuest docs say
      mq.delay inside an ImGui callback raises an error.
    - BeginDisabled / EndDisabled must always come in pairs.
    - PushID / PopID make the "##give" checkbox label unique per row.
    - Most settings are locked while a job runs, including while it is
      paused, so the plan cannot change underneath the job.
==========================================================================]]--

local mq       = require('mq')                    -- gettime for the save debounce
local ImGui    = require('ImGui')                 -- the window toolkit
local core     = require('provisions.core')       -- settings, roster, job flags
local delivery = require('provisions.delivery')   -- stock on hand line
local casting  = require('provisions.casting')    -- detected spells, progress

local ui = {}

--- Window visibility ---------------------------------------------------------------
-- WHAT : true while the window is shown.
-- WHY  : /provisions toggles it and the title bar X closes it.
-- WHERE: ui.render and init.lua onCommand.
-- HOW  : ImGui.Begin returns the new value.
-- WHEN : Every frame.
ui.open = true

--- Save debounce -------------------------------------------------------------------------
-- WHAT : dirty is true when settings changed since the last save; lastSave
--        is when that save happened.
-- WHY  : Typing in a number box changes the value every frame. Writing the
--        file every frame would be wasteful.
-- WHERE: markDirty and ui.flushSave.
-- HOW  : Plain locals.
-- WHEN : Every frame.
local dirty, lastSave = false, 0

--- Colours --------------------------------------------------------------------------------
-- WHAT : RGBA colours used for text.
-- WHY  : Green good, amber attention, red problem, grey information.
-- WHERE: Throughout this file.
-- HOW  : Tables of four numbers from 0 to 1.
-- WHEN : While drawing.
local GREEN = { 0.35, 0.85, 0.40, 1.0 }
local AMBER = { 0.95, 0.80, 0.30, 1.0 }
local RED   = { 1.00, 0.40, 0.35, 1.0 }
local GREY  = { 0.65, 0.65, 0.65, 1.0 }   -- informational text and blank results

--[[--------------------------------------------------------------------------
  colored(color, fmt, ...) / tooltip(text) / markDirty()

  WHAT  : colored draws one line of coloured text. tooltip shows text when
          the previous control is hovered. markDirty flags a settings change.
  WHY   : Shortens every call site in this file.
  WHERE : Throughout this file.
  HOW   : colored formats only when arguments are given, so names with a %
          are safe. tooltip uses IsItemHovered on the last drawn control.
  WHEN  : While drawing.
----------------------------------------------------------------------------]]
local function colored(color, fmt, ...)
    local text = select('#', ...) > 0 and string.format(fmt, ...) or fmt
    ImGui.TextColored(color[1], color[2], color[3], color[4], text)
end

-- Hover help for the control drawn just before this call.
local function tooltip(text)
    if ImGui.IsItemHovered() then ImGui.SetTooltip(text) end
end

-- A setting changed; ui.flushSave writes it soon.
local function markDirty()
    dirty = true
end

--[[--------------------------------------------------------------------------
  ui.flushSave(force)

  WHAT  : Writes settings when dirty and a second has passed, or at once
          when forced.
  WHY   : Keeps disk writes rare while still saving promptly.
  WHERE : End of ui.render; init.lua at shutdown with force = true.
  HOW   : core.save behind a time check.
  WHEN  : Every frame, and at shutdown.
----------------------------------------------------------------------------]]
function ui.flushSave(force)
    if not dirty then return end                -- nothing changed
    local now = mq.gettime()
    if force or now - lastSave > 1000 then      -- at most one write a second
        core.save()
        dirty, lastSave = false, now
    end
end

--[[--------------------------------------------------------------------------
  checkbox / intInput / textInput

  WHAT  : Controls bound to one setting each.
  WHY   : Removes repeated read, draw, compare, write code for every option.
  WHERE : drawCounts and drawOptions.
  HOW   : Draw with the current value; when the returned value differs,
          store it and mark dirty. intInput clamps to lo..hi.
  WHEN  : While drawing.
----------------------------------------------------------------------------]]
local function checkbox(label, key, help)
    local s = core.settings
    local value = ImGui.Checkbox(label, s[key] == true)          -- new state
    if value ~= s[key] then s[key] = value markDirty() end       -- store on change
    if help then tooltip(help) end
end

-- Bounded integer box with + and - buttons (stepFast with ctrl held).
local function intInput(label, key, lo, hi, step, stepFast, help, width)
    local s = core.settings
    ImGui.SetNextItemWidth(width or 120)
    local value = ImGui.InputInt(label, s[key], step or 1, stepFast or 5)   -- draw the box, get the value back
    value = core.clamp(value, lo, hi)                            -- keep in range
    if value ~= s[key] then s[key] = value markDirty() end
    if help then tooltip(help) end
end

-- Free text box for item names.
local function textInput(label, key, help)
    local s = core.settings
    ImGui.SetNextItemWidth(220)
    local value = ImGui.InputText(label, s[key] or '')   -- draw the box, get the text back
    if value ~= s[key] then s[key] = value markDirty() end   -- store on change and schedule a save
    if help then tooltip(help) end   -- hover help
end

--- Spell picker state --------------------------------------------------------------
-- WHAT : TYPE_OWN is the label of the first drop down entry. typing holds,
--        per setting key, whether the operator chose to type a name.
-- WHY  : A typed name is not in the list, so the window must remember that
--        the text box is wanted even while the box is still empty.
-- WHERE: spellPicker.
-- HOW  : typing[key] true = show the text box. It also turns on by itself
--        when the saved setting is a name that is not in the list, so a
--        name typed in an earlier session is still shown and editable.
-- WHEN : Every frame the Options section is open.
local TYPE_OWN = 'Type your own...'
local typing = { foodSpell = false, drinkSpell = false }

--[[--------------------------------------------------------------------------
  setSpell(key, value)

  WHAT  : Stores a spell choice and refreshes detection.
  WHY   : The "Food spell / Drink spell" line under the buttons should show
          the new choice at once, not only at the next hand out.
  WHERE : spellPicker.
  HOW   : Write the setting, markDirty, casting.detect (which does not
          wait, so it is safe in the window).
  WHEN  : When a drop down entry is picked, or a typed name is scribed.
----------------------------------------------------------------------------]]
local function setSpell(key, value)
    core.settings[key] = value   -- '' means auto detect
    markDirty()   -- schedule a save
    casting.detect()   -- update casting.food / casting.drink now
end

--[[--------------------------------------------------------------------------
  spellPicker(label, key, kind, help)

  WHAT  : A drop down for the food or drink spell. Entries, top to bottom:
            Type your own...     shows a text box for any spell name
            Auto (<best spell>)  blank setting, best scribed spell is used
            each scribed spell   from casting.choices[kind], best first
  WHY   : The operator asked to pick from the spells the current character
          actually has, instead of typing a name from memory, while still
          being able to enter a server custom spell.
  WHERE : drawOptions, once for food and once for drink.
  HOW   : ImGui BeginCombo / Selectable / EndCombo. The preview shows the
          current choice. Picking an entry calls setSpell. In typing mode a
          text box follows; each edit is saved, and when the text is blank
          or a scribed spell, detection is refreshed at once. A note after
          the box says "In your book" (green), "Not in your book" (red,
          auto detect is used instead), or how to use the box (grey).
  WHEN  : Every frame the Options section is open.
----------------------------------------------------------------------------]]
local function spellPicker(label, key, kind, help)
    local s = core.settings
    local current = s[key] or ''   -- saved choice; '' = auto
    local choices = casting.choices[kind] or {}   -- scribed spells, best first
    local listed = current == ''   -- is the saved choice one of the entries?
    for _, name in ipairs(choices) do
        if name == current then listed = true end   -- a scribed list spell
    end
    if not listed then typing[key] = true end   -- a typed name from before

    local autoLabel = string.format('Auto (%s)', choices[1] or 'none found')   -- best scribed spell
    local preview = typing[key] and TYPE_OWN or (current == '' and autoLabel or current)
    ImGui.SetNextItemWidth(220)
    if ImGui.BeginCombo(label, preview) then   -- true while the list is open
        if ImGui.Selectable(TYPE_OWN, typing[key]) then typing[key] = true end   -- show the text box
        if ImGui.Selectable(autoLabel, not typing[key] and current == '') then   -- back to auto detect
            typing[key] = false
            setSpell(key, '')
        end
        for _, name in ipairs(choices) do   -- one entry per scribed spell
            if ImGui.Selectable(name, not typing[key] and current == name) then
                typing[key] = false
                setSpell(key, name)
            end
        end
        ImGui.EndCombo()   -- only when BeginCombo returned true
    end
    tooltip(help)   -- hover help for the drop down

    if not typing[key] then return end   -- no text box needed
    ImGui.SetNextItemWidth(220)
    local value = ImGui.InputText('##' .. key .. 'Typed', current)   -- hidden label, unique per setting
    if value ~= current then   -- the operator typed something
        s[key] = value
        markDirty()   -- schedule a save
        if value == '' or casting.inBook(value) then casting.detect() end   -- never warns for these
    end
    tooltip('The exact spell name as it appears in your spell book. Blank means auto detect.')
    ImGui.SameLine()   -- note to the right of the box
    if value == '' then
        colored(GREY, 'Blank: auto detect')
    elseif casting.inBook(value) then
        colored(GREEN, 'In your book')   -- scribed: this spell will be used
    else
        colored(RED, 'Not in your book, auto detect is used')   -- casting.pick falls back
    end
end

--[[--------------------------------------------------------------------------
  drawCounts()

  WHAT  : The food and drink quantity boxes plus quick set buttons.
  WHY   : The two numbers changed most often sit at the top.
  WHERE : ui.render.
  HOW   : Two intInputs (0 to 80), buttons for 5 / 10 / 20 each, and
          Drink only / Food only. Locked while a job runs.
  WHEN  : Every frame.
----------------------------------------------------------------------------]]
local function drawCounts()
    local s = core.settings
    ImGui.BeginDisabled(core.job.running)
    intInput('Food each', 'foodCount', 0, 80, 1, 5,   -- setting foodCount
        'How many food items every ticked member should receive.')   -- hover help for Food each
    ImGui.SameLine()   -- Drink on the same line
    intInput('Drink each', 'drinkCount', 0, 80, 1, 5,   -- setting drinkCount
        'How many drink items every ticked member should receive.')   -- hover help for Drink each
    for _, n in ipairs({ 5, 10, 20 }) do   -- three quick set buttons
        if ImGui.Button(tostring(n) .. ' each') then   -- true on the frame it is clicked
            s.foodCount, s.drinkCount = n, n   -- set both counts
            markDirty()   -- schedule a save
        end
        tooltip('Set both food and drink to ' .. n .. '.')   -- hover help for this button
        ImGui.SameLine()   -- next button on the same row
    end
    if ImGui.Button('Drink only') then s.foodCount = 0 markDirty() end
    tooltip('Set food to zero.')
    ImGui.SameLine()   -- next button on the same row
    if ImGui.Button('Food only') then s.drinkCount = 0 markDirty() end   -- zero drink, keep food
    tooltip('Set drink to zero.')   -- hover help
    ImGui.EndDisabled()   -- pairs with BeginDisabled above
end

--[[--------------------------------------------------------------------------
  resultText(name)

  WHAT  : Builds the Last result cell for one member, with a colour.
  WHY   : Shows at a glance who was served, who is waiting, who was missed.
  WHERE : drawRoster.
  HOW   : From core.job.results. Green when full or kept or already
          stocked or the link answered, amber when partly served or busy
          and waiting, red when nothing arrived, given up, or no link
          answer ("no MQRemote"), blank when not part of the last job.
  WHEN  : Every frame.
----------------------------------------------------------------------------]]
local function resultText(name)
    local r = core.job.results[name]
    if not r then return GREY, '' end   -- not part of the last job
    local text = string.format('%d food, %d drink', r.food or 0, r.drink or 0)
    if r.note then text = text .. ' (' .. r.note .. ')' end
    local s = core.settings
    local full = (r.food or 0) >= s.foodCount and (r.drink or 0) >= s.drinkCount   -- true when at least the full counts arrived
    if r.note == 'busy, gave up' then return RED, text end          -- missed
    if r.note and r.note:find('^no ') then return RED, text end     -- no link answer
    if r.note and r.note:find('^busy') then return AMBER, text end  -- waiting
    if r.note or full then return GREEN, text end                   -- kept, stocked, full
    if (r.food or 0) + (r.drink or 0) > 0 then return AMBER, text end
    return RED, text   -- nothing arrived
end

--[[--------------------------------------------------------------------------
  drawRoster()

  WHAT  : The checkbox list of group members.
  WHY   : This is how the operator picks who gets food and drink.
  WHERE : ui.render.
  HOW   : Refresh (throttled in core), Select all / Clear, then a five
          column table: Give, Name, Class, Dist, Last result. Mercenaries
          and members out of zone are shown but locked. The caster's own
          row means "keep a set for me".
  WHEN  : Every frame.
----------------------------------------------------------------------------]]
local function drawRoster()
    core.refreshRoster(false)   -- at most twice a second
    ImGui.BeginDisabled(core.job.running)
    if ImGui.Button('Select all') then core.setAll(true) markDirty() end
    ImGui.SameLine()
    if ImGui.Button('Clear') then core.setAll(false) markDirty() end   -- untick everyone
    ImGui.EndDisabled()   -- pairs with BeginDisabled above the buttons

    local flags = ImGuiTableFlags.Borders + ImGuiTableFlags.RowBg   -- distinct bits
    if not ImGui.BeginTable('##provroster', 5, flags) then return end
    ImGui.TableSetupColumn('Give',        ImGuiTableColumnFlags.WidthFixed, 40)
    ImGui.TableSetupColumn('Name',        ImGuiTableColumnFlags.WidthStretch)
    ImGui.TableSetupColumn('Class',       ImGuiTableColumnFlags.WidthFixed, 45)   -- class column, fixed width
    ImGui.TableSetupColumn('Dist',        ImGuiTableColumnFlags.WidthFixed, 45)   -- distance column, fixed width
    ImGui.TableSetupColumn('Last result', ImGuiTableColumnFlags.WidthStretch)   -- result column takes the rest
    ImGui.TableHeadersRow()   -- draw the header row

    local range = core.settings.tradeRange   -- colours the distance figure
    for _, row in ipairs(core.roster) do
        ImGui.TableNextRow()
        ImGui.PushID(row.name)                -- unique ids for this row

        -- Give column.
        ImGui.TableNextColumn()
        local locked = core.job.running or row.isMerc or not row.present
        ImGui.BeginDisabled(locked)
        local was = core.isSelected(row.name)   -- current tick from settings
        local now = ImGui.Checkbox('##give', was)   -- draw the box, get the new state
        if now ~= was then core.setSelected(row.name, now) markDirty() end   -- store a change and schedule a save
        ImGui.EndDisabled()   -- pairs with BeginDisabled(locked)
        if row.isMerc then tooltip('Mercenaries cannot receive items.')   -- explain why the box is locked
        elseif not row.present then tooltip('Not in this zone.')   -- member is in another zone
        elseif row.isSelf then tooltip('Keep a set in your own bags.') end   -- caster row keeps a set

        -- Name column.
        ImGui.TableNextColumn()
        if row.isSelf then
            ImGui.Text(row.name .. ' (me)')
        elseif row.isMerc then   -- mercenary row
            colored(GREY, '%s (merc)', row.name)   -- grey name with a merc tag
        else
            ImGui.Text(row.name)   -- normal group member
        end

        -- Class and distance columns.
        ImGui.TableNextColumn()
        ImGui.Text(row.class or '')
        ImGui.TableNextColumn()
        if not row.present then   -- member is in another zone
            colored(GREY, 'away')   -- grey away marker
        elseif row.isSelf then   -- no distance for the caster
            ImGui.Text('')                    -- keeps the columns aligned
        else
            local c = row.distance <= range and GREEN or AMBER   -- inside trade range?
            colored(c, '%.0f', row.distance)
        end

        -- Last result column.
        ImGui.TableNextColumn()
        local c, text = resultText(row.name)
        colored(c, text)
        ImGui.PopID()                         -- pairs with PushID
    end
    ImGui.EndTable()
end

--[[--------------------------------------------------------------------------
  drawRunControls()

  WHAT  : Hand Out, Pause / Resume and Stop, the status line, progress,
          detected spells and stock on hand.
  WHY   : Start, hold, stop and "what is it doing" belong together.
  WHERE : ui.render.
  HOW   : Hand Out and Check links only when idle. Pause / Resume and
          Stop only while running; the Pause button reads Resume while
          paused. The status
          line shows the hold reason in amber when holding. Progress comes
          from casting.progress.
  WHEN  : Every frame.
----------------------------------------------------------------------------]]
local function drawRunControls()
    local s, job = core.settings, core.job
    ImGui.BeginDisabled(job.running)
    if ImGui.Button('Hand Out', 120, 0) then core.request() end   -- request a job; init.lua runs it
    ImGui.EndDisabled()   -- pairs with BeginDisabled(job.running)
    tooltip('Summon what is needed and trade it to every ticked member.')   -- hover help for Hand Out

    ImGui.SameLine()   -- Pause on the same row
    ImGui.BeginDisabled(not job.running)   -- only usable while a job runs
    if ImGui.Button(job.paused and 'Resume' or 'Pause', 80, 0) then core.togglePause() end   -- one button: Pause or Resume
    tooltip(job.paused and 'Carry on from where the job stopped.'   -- hover help depends on the state
        or 'Hold at the next safe point. A cast or trade in progress finishes first. RGMercs stays paused.')   -- help text while not paused
    ImGui.SameLine()   -- Stop on the same row
    if ImGui.Button('Stop', 80, 0) then core.stop() end   -- ask the job to stop
    tooltip('End the job and clean up.')   -- hover help for Stop
    ImGui.EndDisabled()   -- pairs with BeginDisabled(not job.running)

    ImGui.SameLine()   -- Check links on the same row
    ImGui.BeginDisabled(job.running)   -- only when idle
    if ImGui.Button('Check links', 100, 0) then core.requestCheck() end   -- init.lua runs the check
    ImGui.EndDisabled()   -- pairs with BeginDisabled(job.running)
    tooltip('Ask every ticked member to answer over the chosen link, without summoning anything.')   -- hover help

    ImGui.SameLine()   -- status text on the same row
    if job.hold ~= '' then   -- the job is holding right now
        colored(AMBER, '[%s] %s', job.hold, job.status)       -- holding
    elseif job.paused then
        colored(AMBER, '[Pause requested] %s', job.status)    -- not at a safe point yet
    else
        colored(job.running and AMBER or GREEN, job.status)
    end

    local p = casting.progress   -- live summon numbers
    if job.running and p.kind then   -- only while summoning
        colored(AMBER, 'Summoning %s: %d of %d   fizzles %d   interrupts %d',   -- progress line
            p.kind, p.have, p.target, p.fizzles, p.interrupts)   -- values from casting.progress
    end
    local note = casting.classNote()   -- nil for summoning classes
    if note then colored(RED, note) end                       -- non summoning class
    colored(GREY, 'Food spell: %s   Drink spell: %s',
        casting.food or 'none found', casting.drink or 'none found')
    if casting.lastResult ~= '' then
        colored(casting.lastResult == 'CAST_SUCCESS' and GREY or AMBER,   -- amber when the last cast did not succeed
            'Last cast result: %s', casting.lastResult)   -- e.g. Last cast result: CAST_FIZZLE
    end
    colored(GREY, 'Carrying: %d %s, %d %s',   -- stock in the caster bags
        delivery.count(s.foodItem), s.foodItem,   -- food count and item name
        delivery.count(s.drinkItem), s.drinkItem)   -- drink count and item name
end

--[[--------------------------------------------------------------------------
  drawOptions()

  WHAT  : The collapsible Options section.
  WHY   : Settings changed rarely stay out of the way.
  WHERE : ui.render.
  HOW   : Link method radio buttons (MQRemote, DanNet, EQBC, Manual; a
          pick also requests the plugin load), the opt in checkbox for
          loading the plugin on other boxes, bound checkboxes and number boxes in
          three groups (general, Combat Hold and busy members, limits),
          then the spell drop downs (spellPicker), item text boxes and
          Refresh spells. Locked while a
          job runs.
  WHEN  : Every frame when expanded.
----------------------------------------------------------------------------]]
local function drawOptions()
    if not ImGui.CollapsingHeader('Options') then return end
    local s = core.settings
    ImGui.BeginDisabled(core.job.running)   -- lock options while a job runs

    -- How commands reach the other boxes.
    ImGui.Text('Talk to other boxes via:')
    tooltip('MQRemote: /rc, checks and presses Trade. DanNet: /dex and /dquery. EQBC: presses Trade only. Manual: press Trade yourself. Picking one loads its plugin here if needed.')
    for _, m in ipairs({ { 'mqremote', 'MQRemote' }, { 'dannet', 'DanNet' }, { 'eqbc', 'EQBC' }, { 'none', 'Manual' } }) do
        ImGui.SameLine()   -- radio buttons side by side
        if ImGui.RadioButton(m[2], s.acceptMethod == m[1]) then   -- true on the frame it is clicked
            s.acceptMethod = m[1]   -- store the chosen method
            markDirty()   -- schedule a save
            core.requestLinkLoad()   -- init.lua loads the plugin if it is missing
        end
    end
    -- Opt in: load the link plugin on boxes that do not answer (off by default).
    checkbox('Load the link plugin on other boxes', 'loadOnOtherBoxes',   -- setting loadOnOtherBoxes
        'When a box does not answer the link check, send it /plugin <name> load through another link plugin (DanNet, EQBC or MQRemote) that is loaded here. Off by default.')   -- hover help for loadOnOtherBoxes

    -- General behaviour.
    checkbox('Top up only', 'topUp',
        'Ask each box how many it already carries and give only the difference. Needs MQRemote or DanNet.')
    checkbox('Keep my existing stock', 'preserveOwnStock',
        'Summon for everyone on top of what is already in your bags.')   -- hover help for preserveOwnStock
    checkbox('Pause RGMercs during hand out', 'pauseRGMercs',   -- setting pauseRGMercs
        'Sends /rgl pause at start and /rgl unpause at end, only if RGMercs is running.')   -- hover help for pauseRGMercs
    checkbox('Walk to members with MQ2Nav', 'useNav',   -- setting useNav
        'Walk into trade range when a member is too far away.')   -- hover help for useNav
    checkbox('Cast with MQ2Cast (auto retry fizzles)', 'useMQ2Cast',   -- setting useMQ2Cast
        'MQ2Cast recasts after a failed cast, up to Max tries. Loaded for the job if needed.')   -- hover help for useMQ2Cast
    checkbox('Meditate when out of mana', 'medForMana',   -- setting medForMana
        'Sit and wait for mana instead of skipping the cast.')   -- hover help for medForMana
    checkbox('Restore borrowed spell gem', 'restoreGem',   -- setting restoreGem
        'Put the original spell back in the gem when finished.')   -- hover help for restoreGem
    checkbox('Debug trace', 'debug', 'Print every command and decision to chat.')   -- setting debug

    -- Combat Hold and busy members.
    ImGui.Separator()
    checkbox('Combat Hold', 'combatHold',
        'Hold the job while you are in combat. Any open trade is cancelled and the items come back.')
    checkbox('Hand back to RGMercs during combat', 'combatHandBack',   -- setting combatHandBack
        'While holding for combat, unpause RGMercs so it can fight and heal, then pause it again afterwards.')   -- hover help for combatHandBack
    intInput('Combat settle (s)', 'combatSettleSec', 0, 60, 1, 5,   -- setting combatSettleSec
        'Seconds out of combat before the job carries on, in case another mob joins.', 100)   -- hover help for combatSettleSec
    intInput('Busy tries', 'busyTries', 1, 10, 1, 1,   -- setting busyTries
        'A member who is fighting or does not accept goes to the back of the line. Give up after this many tries.', 100)   -- hover help for busyTries
    intInput('Busy retry (s)', 'busyRetrySec', 2, 120, 1, 10,   -- setting busyRetrySec
        'Seconds before a busy member is tried again.', 100)   -- hover help for busyRetrySec

    -- Limits.
    ImGui.Separator()
    intInput('Spell gem', 'gem', 1, 13, 1, 1, 'Gem to borrow when a summon spell is not memorised.', 100)
    intInput('Max tries per cast', 'castMaxTries', 1, 20, 1, 5, 'MQ2Cast -maxtries. Attempts per cast before it reports failure.', 100)
    intInput('Summon time limit (min)', 'summonTimeoutMin', 0, 240, 5, 15,   -- setting summonTimeoutMin
        'Summoning keeps casting through fizzles until the count is reached. This stops it after this many minutes, not counting time held. 0 = no limit.', 100)   -- hover help for summonTimeoutMin
    intInput('Trade range', 'tradeRange', 5, 25, 1, 5, 'Units. Trades only open at close range.', 100)   -- setting tradeRange
    intInput('Accept timeout (s)', 'tradeTimeoutSec', 3, 60, 1, 5, 'Cancel the trade if not accepted in this time.', 100)   -- setting tradeTimeoutSec
    intInput('Walk timeout (s)', 'navTimeoutSec', 5, 120, 5, 15, 'Longest walk to one member.', 100)   -- setting navTimeoutSec
    intInput('Meditate timeout (s)', 'medTimeoutSec', 10, 600, 10, 60, 'Longest wait for mana per cast.', 100)   -- setting medTimeoutSec

    -- Names.
    ImGui.Separator()
    spellPicker('Food spell', 'foodSpell', 'food',   -- setting foodSpell
        'Auto uses the best food spell in your book. Pick a spell to always use it, or type your own.')
    spellPicker('Drink spell', 'drinkSpell', 'drink',   -- setting drinkSpell
        'Auto uses the best drink spell in your book. Pick a spell to always use it, or type your own.')
    textInput('Food item name', 'foodItem', 'Learned automatically after the first cast.')   -- setting foodItem
    textInput('Drink item name', 'drinkItem', 'Learned automatically after the first cast.')   -- setting drinkItem
    if ImGui.Button('Refresh spells') then casting.detect() end   -- re run detection after scribing or editing
    ImGui.EndDisabled()   -- pairs with BeginDisabled at the top
end

--[[--------------------------------------------------------------------------
  ui.render()

  WHAT  : Draws the whole window for one frame.
  WHY   : The single entry point mq.imgui.init calls.
  WHERE : Registered in init.lua.
  HOW   : Begin, counts, roster, run controls, options, End, flushSave.
          End is always called, even when the window is collapsed.
  WHEN  : Every frame while ui.open is true.
----------------------------------------------------------------------------]]
function ui.render()
    if not ui.open then return end
    ImGui.SetNextWindowSize(540, 500, ImGuiCond.FirstUseEver)
    local show   -- second value from Begin: is the window expanded
    ui.open, show = ImGui.Begin('Provisions##provisions', ui.open)   -- draw the frame; X button sets ui.open false
    if show then   -- skip the contents when collapsed
        drawCounts()   -- food and drink counts
        ImGui.Separator()   -- divider line
        drawRoster()   -- checkbox list of the group
        ImGui.Separator()   -- divider line
        drawRunControls()   -- buttons, status, progress, stock
        ImGui.Separator()   -- divider line
        drawOptions()   -- collapsible settings
    end
    ImGui.End()            -- always, even when show is false
    ui.flushSave(false)    -- debounced save of any change this frame
end

return ui   -- hand the module table to require('provisions.ui')

--[[==========================================================================
  END OF FILE : provisions/ui.lua

  SUMMARY OF PUBLIC API
    open               bool   Window visibility.
    render()                  Draw one frame (mq.imgui.init callback).
    flushSave(force)          Debounced settings write.

  DEPENDENCIES : mq, ImGui, provisions.core, delivery, casting.

  HOW TO EDIT SAFELY
    - Nothing in this file may call mq.delay or anything that waits.
    - Add an option: a key in core.DEFAULTS (plus a clamp in core.load for
      numbers), then one checkbox, intInput or textInput line here.
    - Run buttons only call core.request, core.requestCheck,
      core.requestLinkLoad, core.togglePause and core.stop. Never
      run job steps from here.
    - Change the 80 limit: both intInput lines in drawCounts, the clamps in
      core.load and the /provisions food and drink handler in init.lua.
==========================================================================]]--
