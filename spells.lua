--[[==========================================================================
  FILE        : clericfood/spells.lua
  PACKAGE     : ClericFood Lua  (MacroQuest / EverQuest)
  VERSION     : 1.3.1
  CHANGES     : 1.0.0  First release, plain /cast with own retry counter.
                1.1.0  Casting goes through MQ2Cast with -maxtries so fizzles
                       and interrupts are detected and recast by the plugin.
                       Plain /cast remains as a fallback.
                1.2.0  Full inline documentation pass. No behaviour change.
                1.3.0  Summoning keeps casting until the item count is
                       reached. Fizzles and interrupts no longer count as
                       failures, so low Conjuration skill cannot end the
                       job early. A summon time limit is the safety net.
                       Fizzles and interrupts are counted from chat and
                       shown live in the window.
                1.3.1  Documentation audit: every code line now carries
                       its own comment or one directly above it.

  WHAT  : Finds the best food and drink summoning spells in the cleric's book,
          memorises them into a borrowed gem when needed, casts them, and keeps
          casting until the bags hold a requested number of the item.

  WHY   : The operator should not have to know or type spell names. A level 8
          cleric has Summon Food, a level 33 cleric also has Abundant Food which
          makes several loaves per cast, and an emulator server may use other
          names. Detecting the best known spell, and learning the item name from
          the cursor after the first cast, makes the script work on every
          cleric without editing code.

  WHERE : Required by actions.lua (the job runner) and ui.lua (to show what was
          detected and the last cast result).

  HOW   : FOOD_SPELLS and DRINK_SPELLS list candidates best first. The first one
          found in Me.Book wins, unless the operator typed an override. Casting
          prefers MQ2Cast: /casting "spell|gemN" -maxtries|N memorises the
          spell, casts it, and recasts on fizzle or interrupt up to N times,
          then Cast.Result says exactly why it stopped. When MQ2Cast is off or
          cannot be loaded, plain /memspell and /cast are used with the
          package's own retry counter. Each cast is followed by
          /autoinventory so the cursor is always clear for the next.

  WHEN  : Detection runs when the window opens and when Refresh is pressed.
          Casting runs only inside an actions.lua job.

  READING GUIDE (for future you)
    - "Gem" is one of the spell slots on the spell bar. Gem 8 is the default
      borrowed slot. "Memorise" means load a spell from the book into a gem.
    - MQ2Cast is a MacroQuest plugin. Its /casting command handles memorising,
      waiting for the gem to be ready, and recasting after a fizzle. Its
      Cast.Status TLO reads "I" when idle, and Cast.Result holds a code such
      as CAST_SUCCESS or CAST_FIZZLE after a cast finishes.
    - Call order inside one job:
        beginJob -> summonUntil('food') -> summonUntil('drink')
                 -> restore -> endJob
      summonUntil repeats castOnce, which picks castWithMQ2Cast or
      castWithPlainCast.
    - The goal of summonUntil is an ITEM COUNT, not a cast count. Every
      failed cast is sorted into one of three kinds:
        retryable  fizzle, interrupt, not ready yet -> cast again, no penalty
        fatal      stunned, missing component and so on -> stop now
        other      mana wait timed out, cursor stuck -> 3 in a row stops
      The summon time limit (summonTimeoutMin) stops a loop that is still
      making no progress after that many minutes. 0 means no limit.
==========================================================================]]--

local mq        = require('mq')                     -- TLO, mq.delay
local utils     = require('clericfood.utils')       -- cmd, delay, echo, aborted
local config    = require('clericfood.config')      -- settings (gem, tries, items)
local inventory = require('clericfood.inventory')   -- count, clearCursor, cursorName

local spells = {}

--[[==========================================================================
  CANDIDATE SPELL LISTS

  WHAT  : Food and drink summon spell names, best first.
  WHY   : Abundant versions make more items per cast, so they finish the job
          faster and cost less mana per item. Listing them first means they are
          chosen whenever the cleric knows them.
  WHERE : spells.detect.
  HOW   : Plain arrays. Add a name here to support another server's spell.
  WHEN  : Read on each detection.
==========================================================================]]--
spells.FOOD_SPELLS  = { 'Abundant Food',  'Summon Food'  }
spells.DRINK_SPELLS = { 'Abundant Drink', 'Summon Drink' }

--- Detected spell names ---------------------------------------------------------
-- WHAT : The food and drink spells the job will cast, or nil if none known.
-- WHY  : Cached so the window can show them every frame without walking the
--        spellbook every frame.
-- WHERE: Set by spells.detect, read by ui.lua and spells.summonUntil.
-- HOW  : Plain fields.
-- WHEN : Refreshed on demand.
spells.food  = nil
spells.drink = nil

--- Gem bookkeeping for restoreGem ----------------------------------------------
-- WHAT : The spell that was in the borrowed gem before the job touched it.
-- WHY  : Lets spells.restore put the operator's bar back the way it was, which
--        matters because RGMercs expects its own spell lineup.
-- WHERE: Set by rememberGem, consumed by spells.restore.
-- HOW  : Three states. nil = nothing recorded yet this job. false = the gem
--        was empty. A string = the spell name to put back.
-- WHEN : Captured on the first memorise of a job, cleared on restore.
local originalGemSpell = nil

--- MQ2Cast lifecycle bookkeeping ------------------------------------------------
-- WHAT : loadedMQ2Cast is true when this package loaded MQ2Cast for the job.
--        spells.lastResult holds the last Cast.Result string for the window.
-- WHY  : The package must leave the plugin list as the operator had it, so it
--        unloads MQ2Cast only if it was the one that loaded it. This matches
--        how the PetGear package treats MQ2Cast around RGMercs.
-- WHERE: spells.beginJob, spells.endJob, castWithMQ2Cast, ui.lua.
-- HOW  : Plain fields.
-- WHEN : Set at job start, cleared at job end.
local loadedMQ2Cast = false
spells.lastResult   = ''

--- Live summon progress ------------------------------------------------------------
-- WHAT : What the summon loop is doing right now, for the window.
-- WHY  : With a low Conjuration skill a summon can take many minutes. The
--        operator needs to see it is progressing and how often it fizzles.
-- WHERE: Written by spells.summonUntil and the chat events below, read by
--        ui.lua drawRunControls.
-- HOW  : kind     'food' or 'drink', nil when not summoning
--        have     items carried now
--        target   items wanted
--        fizzles  fizzles seen during this summon
--        interrupts interrupts seen during this summon
-- WHEN : Reset by beginJob and at the start of each summonUntil.
spells.progress = { kind = nil, have = 0, target = 0, fizzles = 0, interrupts = 0 }

--- Chat event counters -----------------------------------------------------------
-- WHAT : Running totals of fizzle and interrupt messages seen in chat.
-- WHY  : MQ2Cast retries fizzles silently inside one /casting call, and plain
--        /cast cannot tell a fizzle from anything else. Counting the game's
--        own messages works for both paths and tells castOnce whether a
--        failed cast was "just a fizzle".
-- WHERE: Incremented by the event callbacks, read by castOnce and
--        summonUntil.
-- HOW  : Plain numbers. They only ever go up during a job; callers take a
--        snapshot before a cast and compare after.
-- WHEN : Live while the events are registered (between beginJob and endJob).
local fizzleCount    = 0
local interruptCount = 0

--- Event names and the chat text they match ---------------------------------------
-- WHAT : MacroQuest event patterns for the fizzle and interrupt messages.
-- WHY  : One place to fix if a server words the messages differently.
-- WHERE: registerEvents and unregisterEvents.
-- HOW  : #*# is MacroQuest's wildcard, matching any text including none.
-- WHEN : Registered at job start, removed at job end.
local EVENTS = {
    { name = 'clericfood_fizzle',     text = '#*#Your spell fizzles#*#' },
    { name = 'clericfood_interrupt1', text = '#*#Your spell is interrupted#*#' },
    { name = 'clericfood_interrupt2', text = '#*#Your casting has been interrupted#*#' },  -- alternate interrupt wording on some clients
}

--[[--------------------------------------------------------------------------
  registerEvents() / unregisterEvents()

  WHAT  : Start and stop listening for the fizzle and interrupt messages.
  WHY   : Listening only during a job keeps the counters meaningful and
          avoids reacting to fizzles from normal play.
  WHERE : spells.beginJob and spells.endJob.
  HOW   : mq.event(name, pattern, callback) registers a chat pattern. The
          callback runs when mq.doevents() is called, which castOnce does
          after every cast. mq.unevent removes it.
  WHEN  : Job start and job end.
----------------------------------------------------------------------------]]
local function registerEvents()
    -- First entry is the fizzle message; the rest are interrupt wordings.
    for i, e in ipairs(EVENTS) do
        mq.unevent(e.name)   -- in case a previous run did not clean up
        if i == 1 then
            mq.event(e.name, e.text, function() fizzleCount = fizzleCount + 1 end)
        else
            mq.event(e.name, e.text, function() interruptCount = interruptCount + 1 end)  -- interrupt events count into interruptCount
        end
    end
end

local function unregisterEvents()  -- remove every event registered above
    for _, e in ipairs(EVENTS) do mq.unevent(e.name) end  -- mq.unevent is safe even if the event was never added
end

--[[--------------------------------------------------------------------------
  mq2castLoaded()

  WHAT  : True when the MQ2Cast plugin is loaded.
  WHY   : Decides which casting path castOnce takes.
  WHERE : spells.beginJob, spells.endJob, usingMQ2Cast.
  HOW   : Plugin TLO.
  WHEN  : Job start and every cast.
----------------------------------------------------------------------------]]
local function mq2castLoaded()
    return mq.TLO.Plugin('MQ2Cast').IsLoaded() == true
end

--[[--------------------------------------------------------------------------
  usingMQ2Cast()

  WHAT  : True when this cast should go through MQ2Cast.
  WHY   : One test used by castOnce and summonUntil so they always agree.
  WHERE : spells.castOnce, spells.summonUntil.
  HOW   : Setting on and plugin loaded.
  WHEN  : Every cast.
----------------------------------------------------------------------------]]
local function usingMQ2Cast()
    return config.settings.useMQ2Cast and mq2castLoaded()
end

--[[--------------------------------------------------------------------------
  spells.beginJob()

  WHAT  : Loads MQ2Cast for the job if the setting is on and it is not loaded.
  WHY   : Fizzle handling is the plugin's job, but the operator should not have
          to remember to load it.
  WHERE : actions.run, right after RGMercs is paused.
  HOW   : Resets progress, registers the fizzle and interrupt chat events,
          then /plugin mq2cast load, wait up to 3 seconds, record that this
          package loaded it. If loading fails, warn and fall back to plain
          /cast.
  WHEN  : Once at the start of every job.
----------------------------------------------------------------------------]]
function spells.beginJob()
    spells.lastResult = ''   -- clear the window's "Last cast result" line
    -- Fresh progress and counters, then start listening for fizzles.
    spells.progress = { kind = nil, have = 0, target = 0, fizzles = 0, interrupts = 0 }
    fizzleCount, interruptCount = 0, 0
    registerEvents()
    -- Nothing to do if the operator turned MQ2Cast off or it is already loaded.
    -- In the already loaded case loadedMQ2Cast stays false, so endJob leaves it.
    if not config.settings.useMQ2Cast or mq2castLoaded() then return end
    utils.echo('Loading MQ2Cast for this hand out.')
    utils.cmd('/plugin mq2cast load')
    if utils.delay(3000, mq2castLoaded) then  -- wait up to 3 s for the plugin to report loaded
        loadedMQ2Cast = true   -- we loaded it, so we must unload it later
    else
        utils.warn('MQ2Cast did not load, using plain /cast with own retries.')
    end
end

--[[--------------------------------------------------------------------------
  spells.endJob()

  WHAT  : Unloads MQ2Cast if this package loaded it.
  WHY   : Leaves the plugin list exactly as it was before the job.
  WHERE : actions.lua cleanup.
  HOW   : Removes the chat events, clears progress, then /plugin mq2cast
          unload when loadedMQ2Cast is set.
  WHEN  : End of every job, including Stop and errors.
----------------------------------------------------------------------------]]
function spells.endJob()
    unregisterEvents()                -- stop counting fizzles from normal play
    spells.progress.kind = nil        -- window stops showing summon progress
    if loadedMQ2Cast and mq2castLoaded() then
        utils.cmd('/plugin mq2cast unload')
    end
    loadedMQ2Cast = false   -- reset for the next job either way
end

--[[--------------------------------------------------------------------------
  rememberGem(name)

  WHAT  : Records what is in the borrowed gem before a summon spell goes there.
  WHY   : Both casting paths can overwrite the gem, and restoreGem needs the
          original spell name either way.
  WHERE : spells.memorize and castWithMQ2Cast.
  HOW   : Only when the summon spell is not already memorised and nothing has
          been recorded yet this job.
  WHEN  : Before the first memorise of a job.
----------------------------------------------------------------------------]]
local function rememberGem(name)
    -- Already memorised somewhere: the borrowed gem will not be touched.
    if mq.TLO.Me.Gem(name)() then return end
    -- Record only once per job. The second summon spell (drink) goes into the
    -- same gem, and we want the ORIGINAL spell, not the food spell.
    if originalGemSpell == nil then
        originalGemSpell = mq.TLO.Me.Gem(config.settings.gem).Name() or false
    end
end

--[[--------------------------------------------------------------------------
  inBook(name)

  WHAT  : True when the cleric has scribed a spell of exactly this name.
  WHY   : Detection and override validation both need it.
  WHERE : pick.
  HOW   : Me.Book(name) returns the book page number or nil.
  WHEN  : During detection.
----------------------------------------------------------------------------]]
local function inBook(name)
    return name and name ~= '' and mq.TLO.Me.Book(name)() ~= nil
end

--[[--------------------------------------------------------------------------
  pick(override, candidates)

  WHAT  : Chooses which spell to use for one of food or drink.
  WHY   : An operator override always wins if it is actually scribed. If it is
          not, warn and fall back rather than failing the whole job.
  WHERE : spells.detect.
  HOW   : Check override, then walk candidates in order.
  WHEN  : During detection.
----------------------------------------------------------------------------]]
local function pick(override, candidates)
    -- 1. Operator typed a name in Options: use it if it is in the book.
    if override and override ~= '' then
        if inBook(override) then return override end
        utils.warn('Override spell "%s" is not in your book, auto detecting.', override)
    end
    -- 2. Otherwise the first candidate in the book wins (best first order).
    for _, name in ipairs(candidates) do
        if inBook(name) then return name end
    end
    -- 3. Nothing known. summonUntil reports this to the operator.
    return nil
end

--[[--------------------------------------------------------------------------
  spells.detect()

  WHAT  : Refreshes spells.food and spells.drink from the book and settings.
  WHY   : The cleric may scribe a new spell mid session, or the operator may
          change the override box.
  WHERE : init.lua at startup, ui.lua Refresh button, actions.lua at job start.
  HOW   : pick() for each.
  WHEN  : On demand.
----------------------------------------------------------------------------]]
function spells.detect()
    local s = config.settings
    spells.food  = pick(s.foodSpell,  spells.FOOD_SPELLS)
    spells.drink = pick(s.drinkSpell, spells.DRINK_SPELLS)  -- best drink spell, override first
    utils.debug('Detected food spell: %s, drink spell: %s',  -- trace what was chosen when Debug is on
        tostring(spells.food), tostring(spells.drink))  -- tostring turns nil into the word nil
end

--[[--------------------------------------------------------------------------
  spells.memorize(name)

  WHAT  : Makes sure a spell is memorised and ready. Returns true on success.
  WHY   : A cleric's bar is normally full of heals. The summon spell has to be
          swapped into a gem just for this job. Only the plain /cast path uses
          this; MQ2Cast memorises on its own.
  WHERE : castWithPlainCast.
  HOW   : If already in a gem, just wait for it to be ready. Otherwise record
          the gem's current spell (once per job), /memspell into the
          configured gem, wait for it to land, then wait for SpellReady.
  WHEN  : Before each plain cast.
----------------------------------------------------------------------------]]
function spells.memorize(name)
    -- Already on the bar: wait out any recast timer (up to 10 s) and go.
    if mq.TLO.Me.Gem(name)() then
        return utils.delay(10000, function() return mq.TLO.Me.SpellReady(name)() == true end)
    end

    local gem = config.settings.gem  -- the borrowed gem number from Options
    rememberGem(name)   -- note what we are about to overwrite

    utils.echo('Memorising %s in gem %d.', name, gem)
    utils.cmd('/memspell %d "%s"', gem, name)
    -- Memorising takes a few seconds; allow 20 in case of lag.
    if not utils.delay(20000, function() return mq.TLO.Me.Gem(name)() ~= nil end) then
        utils.err('Could not memorise %s.', name)
        return false
    end
    -- A freshly memorised gem has a short refresh before it can be cast.
    return utils.delay(15000, function() return mq.TLO.Me.SpellReady(name)() == true end)
end

--[[--------------------------------------------------------------------------
  spells.restore()

  WHAT  : Re memorises whatever was in the borrowed gem before the job.
  WHY   : Leaves the cleric's spell bar exactly as RGMercs expects it.
  WHERE : actions.lua cleanup.
  HOW   : Only runs when restoreGem is on and a spell was recorded. Uses plain
          mq.delay rather than utils.delay so it still completes after Stop.
  WHEN  : Job cleanup.
----------------------------------------------------------------------------]]
function spells.restore()
    -- Option off: forget what was recorded and leave the bar as it is.
    if not config.settings.restoreGem then originalGemSpell = nil return end

    -- A string means there was a spell there; false means the gem was empty.
    if originalGemSpell and originalGemSpell ~= '' then
        local gem = config.settings.gem
        -- Skip if the right spell is somehow already back in place.
        if mq.TLO.Me.Gem(gem).Name() ~= originalGemSpell then
            utils.echo('Restoring %s to gem %d.', originalGemSpell, gem)
            utils.cmd('/memspell %d "%s"', gem, originalGemSpell)
            mq.delay(20000, function() return mq.TLO.Me.Gem(gem).Name() == originalGemSpell end)  -- wait up to 20 s for the original spell to land
        end
    end
    originalGemSpell = nil   -- ready for the next job
end

--[[--------------------------------------------------------------------------
  waitForMana(name)

  WHAT  : Ensures enough mana for one cast, sitting to meditate if allowed.
          Returns true when there is enough.
  WHY   : Summoning eighty items at level 8 will run a cleric dry. Waiting is
          better than a stream of "insufficient mana" failures.
  WHERE : spells.castOnce.
  HOW   : Compares Me.CurrentMana to Spell.Mana. If short and medForMana is on,
          /sit and wait up to medTimeoutSec.
  WHEN  : Before each cast.
----------------------------------------------------------------------------]]
local function waitForMana(name)
    local cost = mq.TLO.Spell(name).Mana() or 0                -- mana cost of the spell
    if (mq.TLO.Me.CurrentMana() or 0) >= cost then return true end
    if not config.settings.medForMana then
        utils.err('Not enough mana for %s.', name)
        return false  -- medForMana is off, so this cast is skipped
    end
    utils.echo('Meditating for mana (need %d).', cost)  -- tell the operator why the cleric sat down
    if not mq.TLO.Me.Sitting() then utils.cmd('/sit') end    -- sitting regenerates faster
    -- Casting will stand the cleric up automatically, so no /stand needed here.
    return utils.delay(config.settings.medTimeoutSec * 1000, function()
        return (mq.TLO.Me.CurrentMana() or 0) >= cost
    end)
end

--[[==========================================================================
  MQ2CAST RESULT HANDLING

  WHAT  : Which Cast.Result values mean "stop casting this job" versus "this
          attempt failed but another try later may work".
  WHY   : MQ2Cast already recasts fizzles and interrupts up to -maxtries. If it
          still reports CAST_FIZZLE after that, an outer retry is reasonable.
          Results like missing components or being stunned will not fix
          themselves by casting again, so the job should stop at once and say
          why.
  WHERE : castWithMQ2Cast and spells.summonUntil.
  HOW   : FATAL_RESULTS maps result codes to a readable reason. Any code not in
          this table (CAST_FIZZLE, CAST_INTERRUPTED, CAST_NOTREADY and so on)
          is treated as retryable.
  WHEN  : After every MQ2Cast cast.
==========================================================================]]--
local FATAL_RESULTS = {
    CAST_COMPONENTS = 'missing component',
    CAST_OUTOFMANA  = 'out of mana',
    CAST_STUNNED    = 'stunned',  -- stunned clerics cannot cast; stop rather than spam
    CAST_UNKNOWN    = 'spell not known',  -- spell name not recognised by MQ2Cast
    CAST_CANCELLED  = 'cancelled',  -- cast was cancelled by the game or another script
    CAST_ABORTED    = 'aborted',  -- cast was aborted, for example by /interrupt
}

--- Fatal flag from the last cast -----------------------------------------------------
-- WHAT : Set true when the last MQ2Cast result was in FATAL_RESULTS.
-- WHY  : Lets summonUntil stop at once instead of burning more attempts.
-- WHERE: Written by castWithMQ2Cast and castWithPlainCast, read by
--        spells.summonUntil.
-- HOW  : Boolean.
-- WHEN : Reset before every cast.
local lastFatal = false

--[[==========================================================================
  RETRYABLE RESULTS

  WHAT  : Cast.Result values that mean "nothing is wrong, just cast again".
  WHY   : A fizzle at low Conjuration skill is normal and must never end the
          job. Same for an interrupt or a gem that is not ready yet. These do
          not count toward the give up limit in summonUntil.
  WHERE : castWithMQ2Cast, and summonUntil through lastRetryable.
  HOW   : Set of result codes. Anything not here and not in FATAL_RESULTS is
          an "other" failure.
  WHEN  : After every MQ2Cast cast.
==========================================================================]]--
local RETRYABLE_RESULTS = {
    CAST_FIZZLE      = true,
    CAST_INTERRUPTED = true,
    CAST_DISTRACTED  = true,  -- you were distracted (moved or acted mid cast)
    CAST_RECOVER     = true,  -- spell still recovering after the last cast
    CAST_NOTREADY    = true,  -- gem not ready yet
}

--- Retryable flag from the last cast -----------------------------------------------
-- WHAT : Set true when the last failed cast was a fizzle or similar.
-- WHY  : Tells summonUntil to cast again without counting a failure.
-- WHERE: Written by castWithMQ2Cast, castWithPlainCast and castOnce; read by
--        spells.summonUntil.
-- HOW  : Boolean.
-- WHEN : Reset before every cast.
local lastRetryable = false

--[[--------------------------------------------------------------------------
  castWithMQ2Cast(name)

  WHAT  : Casts a spell through MQ2Cast. Returns true when MQ2Cast reports
          CAST_SUCCESS.
  WHY   : MQ2Cast watches the chat for fizzle, interrupt and similar messages
          and recasts on its own up to -maxtries, so this package no longer
          has to guess from an empty cursor.
  WHERE : spells.castOnce.
  HOW   : Record the borrowed gem, send /casting "name|gemN" -maxtries|N,
          wait for Cast.Status to leave idle (I) and come back, then read
          Cast.Result. The wait allows twenty seconds per try plus thirty to
          memorise. Stop is honoured through utils.delay and also sends
          /interrupt so the plugin does not keep recasting.
  WHEN  : Every cast while MQ2Cast is in use.
----------------------------------------------------------------------------]]
local function castWithMQ2Cast(name)
    local s = config.settings
    lastFatal, lastRetryable = false, false
    rememberGem(name)   -- MQ2Cast will overwrite gemN if the spell is not on the bar

    -- Example sent: /casting "Summon Food|gem8" -maxtries|5
    utils.cmd('/casting "%s|gem%d" -maxtries|%d', name, s.gem, s.castMaxTries)

    -- Phase 1: wait for MQ2Cast to pick up the command (status leaves "I").
    utils.delay(2000, function() return mq.TLO.Cast.Status() ~= 'I' end)
    -- Phase 2: wait for it to finish all tries (status back to "I").
    local finished = utils.delay(30000 + s.castMaxTries * 20000, function()
        return mq.TLO.Cast.Status() == 'I'
    end)

    -- Operator pressed Stop: stop MQ2Cast's own retry loop too.
    if utils.aborted() then
        utils.cmd('/interrupt')
        return false
    end

    -- Read why it stopped and show it in the window.
    local result = mq.TLO.Cast.Result() or 'CAST_UNKNOWN'
    spells.lastResult = result
    if not finished then
        utils.err('%s: MQ2Cast did not finish in time.', name)  -- MQ2Cast still busy after the full wait
        return false  -- counts as an other failure in summonUntil
    end
    if result == 'CAST_SUCCESS' then return true end  -- landed: castOnce now waits for the item on the cursor

    if FATAL_RESULTS[result] then  -- hopeless result, see FATAL_RESULTS
        -- Retrying will not help: tell summonUntil to stop now.
        lastFatal = true
        utils.err('%s failed: %s (%s).', name, FATAL_RESULTS[result], result)
    elseif RETRYABLE_RESULTS[result] then
        -- Fizzled or interrupted on every try. Normal at low skill: summonUntil
        -- will simply cast again. Debug only, so chat is not flooded.
        lastRetryable = true
        utils.debug('%s: %s after %d tries, casting again.', name, result, s.castMaxTries)
    else
        -- Something unexpected. Counts toward the give up limit.
        utils.warn('%s failed: %s.', name, result)
    end
    return false
end

--[[--------------------------------------------------------------------------
  castWithPlainCast(name)

  WHAT  : Casts a spell with plain /memspell and /cast. Returns true when the
          cast appears to have completed.
  WHY   : Fallback for clients without MQ2Cast or with useMQ2Cast turned off.
          It cannot tell a fizzle from an interrupt, so success is judged by
          the item landing on the cursor in castOnce.
  WHERE : spells.castOnce.
  HOW   : spells.memorize, /cast, wait for the cast to start and end.
  WHEN  : Every cast while MQ2Cast is not in use.
----------------------------------------------------------------------------]]
local function castWithPlainCast(name)
    lastFatal, lastRetryable = false, false
    if not spells.memorize(name) then return false end
    utils.cmd('/cast "%s"', name)  -- plain EQ cast of a memorised spell by name
    -- Wait up to 1.5 s for the cast bar to appear (Casting has an ID) ...
    utils.delay(1500, function() return mq.TLO.Me.Casting.ID() ~= nil end)
    -- ... then up to 15 s for it to end. A fizzle ends it early.
    utils.delay(15000, function() return mq.TLO.Me.Casting.ID() == nil end)
    return true
end

--[[--------------------------------------------------------------------------
  spells.castOnce(name, kind)

  WHAT  : Casts one summon spell and stashes the result. Returns true when an
          item was created.
  WHY   : The single unit of work the summon loop repeats.
  WHERE : spells.summonUntil.
  HOW   : Clear cursor, mana check, snapshot the fizzle counters, cast through
          MQ2Cast (preferred) or plain /cast, process chat events and update
          progress, wait for the item on the cursor (marking the cast
          retryable if chat showed a fizzle), learn its name into the
          settings if it differs (kind is 'food' or 'drink'), then
          /autoinventory.
  WHEN  : Inside a job only.
----------------------------------------------------------------------------]]
function spells.castOnce(name, kind)
    -- Clear last cast's verdict first. Without this, an early return below
    -- (stuck cursor, no mana) would inherit the previous cast's flags.
    lastFatal, lastRetryable = false, false

    -- A held item would block the summon; stash it first.
    if not inventory.clearCursor() then
        utils.err('Cursor is stuck, cannot cast.')
        return false
    end
    if not waitForMana(name) then return false end  -- not enough mana and could not meditate in time

    -- Snapshot the chat counters so we can tell if THIS cast fizzled.
    local fizzBefore, intBefore = fizzleCount, interruptCount

    -- Choose the casting path. Both functions take the same argument.
    local cast = usingMQ2Cast() and castWithMQ2Cast or castWithPlainCast
    local ok = cast(name)

    -- Run any queued chat event callbacks so the counters are current, then
    -- copy them into the progress table for the window.
    mq.doevents()
    spells.progress.fizzles    = spells.progress.fizzles + (fizzleCount - fizzBefore)
    spells.progress.interrupts = spells.progress.interrupts + (interruptCount - intBefore)

    if not ok then return false end  -- cast failed; flags above say whether it was a fizzle

    -- The summoned item should now be on the cursor.
    if not utils.delay(2500, function() return mq.TLO.Cursor.ID() ~= nil end) then
        -- No item. If chat showed a fizzle or interrupt, it is retryable.
        mq.doevents()
        if fizzleCount > fizzBefore or interruptCount > intBefore then
            lastRetryable = true
        end
        utils.debug('%s produced nothing (fizzle or interrupt).', name)  -- trace only, fizzles are normal
        return false  -- castOnce failed; lastRetryable decides what happens next
    end

    -- Learn the real item name so counting works on any server.
    local made = inventory.cursorName()
    local key = kind == 'food' and 'foodItem' or 'drinkItem'
    if made and made ~= config.settings[key] then
        utils.echo('Learned %s item name: %s', kind, made)  -- first cast on this server: tell the operator the item name
        config.settings[key] = made  -- store it so counting and trading use the right name
        config.save()  -- persist so the next run knows it before casting
    end

    -- Put it in the bags; true when the cursor is clear again.
    return inventory.clearCursor()
end

--[[--------------------------------------------------------------------------
  spells.summonUntil(kind, target)

  WHAT  : Casts the food or drink spell until the bags hold target of the item.
          Returns the final count.
  WHY   : The goal is an item count, not a cast count. At low Conjuration
          skill most casts may fizzle, and that is fine: the loop keeps going
          until the bags are full enough. Summoning everything up front, then
          trading, also lets Abundant spells overshoot harmlessly.
  WHERE : actions.lua.
  HOW   : Loop until have >= target:
            - stop if bags are full with nothing to stack onto
            - stop if the summon time limit has passed (0 = no limit)
            - castOnce, then sort the result:
                success    reset the "other" failure counter
                retryable  fizzle or interrupt: cast again, no penalty
                fatal      stunned, missing component: stop now
                other      3 in a row: stop
          Progress (have, target, fizzles, interrupts) is kept in
          spells.progress for the window.
  WHEN  : At the start of a job, once for food and once for drink.
----------------------------------------------------------------------------]]
function spells.summonUntil(kind, target)
    local s = config.settings
    -- Pick the spell and the settings key for its item name.
    local name    = kind == 'food' and spells.food or spells.drink
    local itemKey = kind == 'food' and 'foodItem' or 'drinkItem'
    if not name then
        utils.err('No %s summoning spell found in your book.', kind)  -- no food or drink spell scribed, nothing to cast
        return inventory.count(s[itemKey])  -- return what we already carry
    end

    -- Progress for the window. Fizzles and interrupts count up in castOnce.
    local p = spells.progress
    p.kind, p.target, p.fizzles, p.interrupts = kind, target, 0, 0

    -- Safety net: give up after this many milliseconds. 0 means never.
    local limitMs  = (s.summonTimeoutMin or 0) * 60000
    local started  = mq.gettime()
    local failures = 0   -- consecutive "other" failures; fizzles do not count
    local OTHER_FAILURE_LIMIT = 3

    while not utils.aborted() do
        -- Re count every pass; Abundant spells add several at once.
        local have = inventory.count(s[itemKey])
        p.have = have
        if have >= target then
            if p.fizzles > 0 then  -- report fizzles only if there were any
                utils.echo('%s done: %d made, %d fizzles along the way.', kind, have, p.fizzles)  -- summary line, e.g. food done: 14 made, 6 fizzles
            end
            return have  -- target reached
        end

        -- With no stack to grow and no empty slot, the item would stick on
        -- the cursor. (If have > 0 the existing stack may still have room.)
        if inventory.freeSlots() < 1 and have == 0 then
            utils.err('No free bag slot for %s.', kind)
            return have
        end

        -- Time limit check, so a cleric that can never land the spell does
        -- not sit here all night.
        if limitMs > 0 and mq.gettime() - started > limitMs then
            utils.err('%s: summon time limit (%d min) reached with %d of %d.',
                kind, s.summonTimeoutMin, have, target)
            return have  -- bags full, cannot summon more
        end

        utils.debug('%s: have %d of %d, casting %s', kind, have, target, name)  -- trace each attempt when Debug is on
        if spells.castOnce(name, kind) then  -- one cast; result flags sort the failure kind
            failures = 0                       -- landed one
        elseif lastFatal then
            -- Reason already printed in red. Retrying cannot help.
            return inventory.count(s[itemKey])
        elseif lastRetryable then
            -- Fizzle or interrupt: completely normal, just cast again.
            -- failures is left alone so these never trigger the give up rule.
        else
            failures = failures + 1
            if failures >= OTHER_FAILURE_LIMIT then
                utils.err('%d failed %s casts in a row (not fizzles), giving up.', failures, name)  -- something other than fizzles keeps failing
                return inventory.count(s[itemKey])  -- stop and return what was made
            end
        end
    end
    -- Stop was pressed.
    return inventory.count(s[itemKey])
end

return spells  -- hand the module table to require('clericfood.spells')

--[[==========================================================================
  END OF FILE : clericfood/spells.lua

  SUMMARY OF PUBLIC API
    FOOD_SPELLS / DRINK_SPELLS   Candidate names, best first.
    food / drink                 Detected spell names or nil.
    lastResult           string  Last MQ2Cast Cast.Result, for the window.
    progress             table   Live summon progress, for the window.
    detect()                     Refresh detection.
    beginJob() / endJob()        Load and unload MQ2Cast around a job.
    memorize(name)       bool    Memorise into borrowed gem and wait ready.
    restore()                    Put the borrowed gem back.
    castOnce(name, kind) bool    One cast plus stash, learns item name.
    summonUntil(kind, n) number  Cast until n are carried.

  DEPENDENCIES : mq, clericfood.utils, clericfood.config, clericfood.inventory.
                 Optional plugin: MQ2Cast (preferred casting path).

  HOW TO EDIT SAFELY
    - Support a new spell: add its name to FOOD_SPELLS or DRINK_SPELLS, best
      first. Or type it in the override box in Options; no code change.
    - Treat another MQ2Cast result as hopeless: add it to FATAL_RESULTS.
      Result codes come from the MQ2Cast TLO docs.
    - Treat another result as "just cast again": add it to RETRYABLE_RESULTS.
    - Change how many non fizzle failures in a row stop the loop: edit
      OTHER_FAILURE_LIMIT in summonUntil. Fizzles never count.
    - A server words the fizzle message differently: edit EVENTS.
    - The overall safety net is the summonTimeoutMin setting (0 = none).
    - Cleric levels for reference: Summon Drink 3, Summon Food 8, Abundant Food
      and Abundant Drink in the low thirties. Shaman, druid, magician and
      beastlord can run this package too because the spell names are shared.
    - If a full stack (usually 20) is reached, /autoinventory starts a new
      stack in the next free slot. The free slot check only blocks when there
      is no stack to grow and no empty slot.
==========================================================================]]--
