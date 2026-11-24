--[[==========================================================================
  FILE        : provisions/casting.lua
  PACKAGE     : Provisions Lua  (MacroQuest / EverQuest)
  VERSION     : 2.3.0
  CHANGES     : 2.3.0  detect now also fills casting.choices: the food and
                       drink spells from the candidate lists that are
                       scribed in this character's book, best first. The
                       window's spell drop downs list them. inBook is now
                       public as casting.inBook so the window can say
                       whether a typed name is scribed.
                2.2.0  No change in this file.
                2.1.0  No change in this file.
                2.0.0  Renamed from ClericFood spells.lua. Spell lists now
                       cover every class that summons food and drink
                       (Cleric, Druid, Shaman, Magician, Beastlord) and add
                       the Magician spells Cornucopia and Everfount. The
                       summon loop calls core.checkpoint before every cast,
                       so Pause and Combat Hold stop between casts, and time
                       spent holding does not count against the summon time
                       limit. Meditating and MQ2Cast retries end early when
                       a hold is wanted; a cast already in the air is always
                       allowed to finish.
                1.0.0 to 1.3.2  Released as ClericFood spells.lua. Full
                       history in CHANGELOG.md.

  WHAT  : Finds the best food and drink summoning spells in the spell book,
          memorises them into a borrowed gem when needed, casts them, and
          keeps casting until the bags hold a requested number of the item.

  WHY   : The operator should not have to know or type spell names. A level
          8 cleric has Summon Food, a level 33 cleric also has Abundant Food
          which makes several loaves per cast, a level 21 magician has
          Cornucopia, and an emulator server may use other names. Detecting
          the best known spell, and learning the item name from the cursor
          after the first cast, makes the script work on every summoning
          class without editing code.

  WHERE : Required by init.lua (the job runner) and ui.lua (to show what
          was detected and the live progress).

  HOW   : FOOD_SPELLS and DRINK_SPELLS list candidates best first. The first
          one found in Me.Book wins, unless the operator typed an override.
          Casting prefers MQ2Cast: /casting "spell|gemN" -maxtries|N
          memorises the spell, casts it, and recasts on fizzle or interrupt
          up to N times, then Cast.Result says why it stopped. When MQ2Cast
          is off or cannot be loaded, plain /memspell and /cast are used.
          Each cast is followed by /autoinventory so the cursor is clear.

  WHEN  : Detection runs at startup, on Refresh and at job start. Casting
          runs only inside a job.

  READING GUIDE (for future you)
    - "Gem" is one spell slot on the spell bar. Gem 8 is the default
      borrowed slot. "Memorise" means load a spell from the book into a gem.
    - MQ2Cast's Cast.Status TLO reads "I" when idle, and Cast.Result holds a
      code such as CAST_SUCCESS or CAST_FIZZLE after a cast finishes.
    - Call order inside one job:
        beginJob -> summonUntil('food') -> summonUntil('drink')
                 -> restore -> endJob
      summonUntil repeats castOnce, which picks castWithMQ2Cast or
      castWithPlainCast.
    - The goal of summonUntil is an ITEM COUNT, not a cast count. Every
      failed cast is sorted into one of three kinds:
        retryable  fizzle, interrupt, not ready, hold -> cast again
        fatal      stunned, missing component and so on -> stop now
        other      mana wait timed out, cursor stuck -> 3 in a row stops
    - A "hold" is Pause or Combat Hold (see core.lua part 4). A hold never
      cuts a cast short; it waits at the next checkpoint before a cast.
==========================================================================]]--

local mq       = require('mq')                     -- TLO, mq.delay, mq.event
local core     = require('provisions.core')        -- output, settings, checkpoint
local delivery = require('provisions.delivery')    -- count, freeSlots, cursor

local casting = {}

--[[==========================================================================
  CANDIDATE SPELL LISTS
  WHAT  : Food and drink summon spell names, best first.
  WHY   : Bigger summons finish the job faster and cost less mana per item,
          so they are chosen whenever the caster knows them. Only one class
          can scribe each of the bigger spells, so the order between them
          never matters in practice.
  WHERE : casting.detect.
  HOW   : Plain arrays. Add a name here to support another server's spell.
          Reference levels (Allakhazam spell database):
            Summon Drink    CLR 3, DRU 10, SHM 2, MAG 1, BST 17
            Summon Food     CLR 8, DRU 11, SHM 6, MAG 1, BST 29
            Cornucopia      MAG 21 (stack of Black Bread)
            Everfount       MAG 22 (stack of Globes of Water)
            Abundant Drink  CLR 28
            Abundant Food   CLR 33
  WHEN  : Read on each detection.
==========================================================================]]--
casting.FOOD_SPELLS  = { 'Cornucopia', 'Abundant Food',  'Summon Food'  }
casting.DRINK_SPELLS = { 'Everfount',  'Abundant Drink', 'Summon Drink' }

--- Summoning classes ---------------------------------------------------------------
-- WHAT : Class short names that have a food or drink summon spell.
-- WHY  : Other classes can still run the package with an override spell
--        (for example a server custom spell), but get a warning at startup.
-- WHERE: casting.classNote.
-- HOW  : Set keyed by Me.Class.ShortName.
-- WHEN : Read once at startup.
casting.SUMMON_CLASSES = { CLR = true, DRU = true, SHM = true, MAG = true, BST = true }

--- Detected spells and job state ---------------------------------------------------
-- WHAT : The chosen spell names (nil when none known), the spell that was
--        in the borrowed gem before the job, whether this package loaded
--        MQ2Cast, the last MQ2Cast result, and live progress for the window.
-- WHY  : ui.lua shows these; restore and endJob need the saved values.
-- HOW  : Module fields for public values, locals for private ones.
--        originalGemSpell: nil = not recorded yet, false = gem was empty.
-- WHEN : Reset at every job start.
casting.food       = nil
casting.drink      = nil
casting.choices    = { food = {}, drink = {} }   -- scribed candidates, best first; filled by detect
casting.lastResult = ''   -- last MQ2Cast Cast.Result, shown in the window
casting.progress   = { kind = nil, have = 0, target = 0, fizzles = 0, interrupts = 0 }
local originalGemSpell = nil
local loadedMQ2Cast    = false

--- Chat events and counters ----------------------------------------------------------
-- WHAT : Patterns for the game's fizzle and interrupt messages, and running
--        counters bumped when they are seen.
-- WHY  : The window shows how many casts fizzled, and the plain /cast path
--        uses the counters to tell a fizzle from a real failure.
-- WHERE: registerEvents, castOnce.
-- HOW  : mq.event patterns; #*# matches any text.
-- WHEN : Registered for the length of each job only.
local fizzleCount, interruptCount = 0, 0
local EVENTS = {
    { name = 'provisions_fizzle',     text = '#*#Your spell fizzles#*#' },
    { name = 'provisions_interrupt1', text = '#*#Your spell is interrupted#*#' },   -- interrupt wording on most clients
    { name = 'provisions_interrupt2', text = '#*#Your casting has been interrupted#*#' },  -- alternate wording
}

--[[--------------------------------------------------------------------------
  registerEvents() / unregisterEvents()

  WHAT  : Start and stop listening for the fizzle and interrupt messages.
  WHY   : Listening only during a job keeps the counters meaningful.
  WHERE : casting.beginJob and casting.endJob.
  HOW   : mq.event(name, pattern, callback); callbacks run when
          mq.doevents() is called, which castOnce does after every cast.
  WHEN  : Job start and job end.
----------------------------------------------------------------------------]]
local function registerEvents()
    for i, e in ipairs(EVENTS) do
        mq.unevent(e.name)   -- in case a previous run did not clean up
        if i == 1 then
            mq.event(e.name, e.text, function() fizzleCount = fizzleCount + 1 end)
        else
            -- Both interrupt wordings count into the same counter.
            mq.event(e.name, e.text, function() interruptCount = interruptCount + 1 end)
        end
    end
end

-- Remove every event registered above; mq.unevent is safe if never added.
local function unregisterEvents()
    for _, e in ipairs(EVENTS) do mq.unevent(e.name) end
end

--[[--------------------------------------------------------------------------
  mq2castLoaded() / usingMQ2Cast()

  WHAT  : True when MQ2Cast is loaded / when this cast should use it.
  WHY   : Decides which casting path castOnce takes; one test so every
          caller agrees.
  WHERE : beginJob, endJob, castOnce.
  HOW   : Plugin TLO, plus the useMQ2Cast setting.
  WHEN  : Job start and every cast.
----------------------------------------------------------------------------]]
local function mq2castLoaded()
    return mq.TLO.Plugin('MQ2Cast').IsLoaded() == true
end

-- Setting on and plugin loaded.
local function usingMQ2Cast()
    return core.settings.useMQ2Cast and mq2castLoaded()
end

--[[--------------------------------------------------------------------------
  casting.classNote()

  WHAT  : Returns a warning string when the caster's class has no food or
          drink summon spells, or nil when it does.
  WHY   : The package is for every summoning class. A Warrior running it by
          mistake should be told why nothing is detected.
  WHERE : init.lua at startup, ui.lua under the spell line.
  HOW   : Me.Class.ShortName against SUMMON_CLASSES.
  WHEN  : Startup and every frame of the window (cheap).
----------------------------------------------------------------------------]]
function casting.classNote()
    local cls = mq.TLO.Me.Class.ShortName() or '?'   -- e.g. CLR
    if casting.SUMMON_CLASSES[cls] then return nil end
    return string.format('%s has no food or drink summon spells. Use the override boxes in Options for a server custom spell.', cls)
end

--[[--------------------------------------------------------------------------
  casting.beginJob() / casting.endJob()

  WHAT  : Prepare for a job (reset progress, listen for fizzles, load
          MQ2Cast if needed) and tidy up afterwards (stop listening, unload
          MQ2Cast if this package loaded it).
  WHY   : Fizzle handling is MQ2Cast's job, but the operator should not
          have to remember to load it, and the plugin list should end up
          exactly as it was.
  WHERE : init.lua run (begin) and cleanup (end).
  HOW   : /plugin mq2cast load, wait up to 3 seconds; record that we did.
          If loading fails, warn and fall back to plain /cast.
  WHEN  : Once at the start and end of every job, including Stop.
----------------------------------------------------------------------------]]
function casting.beginJob()
    casting.lastResult = ''
    casting.progress   = { kind = nil, have = 0, target = 0, fizzles = 0, interrupts = 0 }
    fizzleCount, interruptCount = 0, 0   -- chat counters start from zero
    registerEvents()   -- start listening for fizzles
    if not core.settings.useMQ2Cast or mq2castLoaded() then return end  -- nothing to load
    core.echo('Loading MQ2Cast for this hand out.')
    core.cmd('/plugin mq2cast load')
    if core.delay(3000, mq2castLoaded) then
        loadedMQ2Cast = true   -- we loaded it, so we unload it later
    else
        core.warn('MQ2Cast did not load, using plain /cast with own retries.')
    end
end

-- Undo beginJob; see the block above.
function casting.endJob()
    unregisterEvents()
    casting.progress.kind = nil   -- window stops showing summon progress
    if loadedMQ2Cast and mq2castLoaded() then
        core.cmd('/plugin mq2cast unload')
    end
    loadedMQ2Cast = false   -- reset for the next job either way
end

--[[--------------------------------------------------------------------------
  rememberGem(name)

  WHAT  : Records what is in the borrowed gem before a summon spell goes
          there.
  WHY   : Both casting paths can overwrite the gem, and restore needs the
          original spell name.
  WHERE : casting.memorize and castWithMQ2Cast.
  HOW   : Only when the summon spell is not already on the bar and nothing
          has been recorded yet this job. false means the gem was empty.
  WHEN  : Before the first memorise of a job.
----------------------------------------------------------------------------]]
local function rememberGem(name)
    if mq.TLO.Me.Gem(name)() then return end   -- already memorised, nothing overwritten
    if originalGemSpell == nil then
        originalGemSpell = mq.TLO.Me.Gem(core.settings.gem).Name() or false
    end
end

--[[--------------------------------------------------------------------------
  inBook(name) / pick(override, candidates)

  WHAT  : inBook is true when a spell of exactly this name is scribed.
          pick chooses the spell for one of food or drink.
  WHY   : An operator override always wins if it is scribed; if not, warn
          and fall back rather than failing the whole job.
  WHERE : casting.detect.
  HOW   : Me.Book(name) returns a page number or nil. pick checks the
          override, then walks candidates in order.
  WHEN  : During detection.
----------------------------------------------------------------------------]]
local function inBook(name)
    return name and name ~= '' and mq.TLO.Me.Book(name)() ~= nil
end

-- Public so ui.lua can say whether a typed spell name is scribed.
casting.inBook = inBook

-- Override first, then the best known candidate, else nil.
local function pick(override, candidates)
    if override and override ~= '' then
        if inBook(override) then return override end
        core.warn('Override spell "%s" is not in your book, auto detecting.', override)   -- typed name is not scribed
    end
    for _, name in ipairs(candidates) do   -- walk the list best first
        if inBook(name) then return name end   -- first match is the best
    end
    return nil
end

--[[--------------------------------------------------------------------------
  casting.detect()

  WHAT  : Refreshes casting.food and casting.drink, and the lists of
          scribed candidates in casting.choices.
  WHY   : A new spell may be scribed mid session, or the override changed.
          The window's drop downs need to know which known spells this
          character actually has.
  WHERE : init.lua at startup and job start, ui.lua Refresh button and
          the spell drop downs.
  HOW   : pick() for each. choices: every FOOD_SPELLS or DRINK_SPELLS name
          that inBook confirms, in list order (best first). Me.Book(name)
          is a single lookup, so this stays cheap enough to run from the
          window.
  WHEN  : On demand.
----------------------------------------------------------------------------]]
function casting.detect()
    local s = core.settings
    casting.food  = pick(s.foodSpell,  casting.FOOD_SPELLS)
    casting.drink = pick(s.drinkSpell, casting.DRINK_SPELLS)   -- override first
    for kind, list in pairs({ food = casting.FOOD_SPELLS, drink = casting.DRINK_SPELLS }) do
        local scribed = {}   -- candidates this character has, best first
        for _, name in ipairs(list) do
            if inBook(name) then scribed[#scribed + 1] = name end   -- keep list order
        end
        casting.choices[kind] = scribed   -- read by ui.lua spellPicker
    end
    core.debug('Detected food spell: %s, drink spell: %s',
        tostring(casting.food), tostring(casting.drink))       -- tostring turns nil into text
end

--[[--------------------------------------------------------------------------
  casting.memorize(name)

  WHAT  : Makes sure a spell is memorised and ready. Returns true on success.
  WHY   : The plain /cast path must load the spell itself; MQ2Cast
          memorises on its own.
  WHERE : castWithPlainCast.
  HOW   : If on the bar, wait for SpellReady. Otherwise record the gem's
          spell, /memspell into the borrowed gem, wait for it to land, then
          wait for SpellReady.
  WHEN  : Before each plain cast.
----------------------------------------------------------------------------]]
function casting.memorize(name)
    if mq.TLO.Me.Gem(name)() then
        return core.delay(10000, function() return mq.TLO.Me.SpellReady(name)() == true end)
    end
    local gem = core.settings.gem   -- borrowed gem number from Options
    rememberGem(name)               -- note what we are about to overwrite
    core.echo('Memorising %s in gem %d.', name, gem)
    core.cmd('/memspell %d "%s"', gem, name)
    if not core.delay(20000, function() return mq.TLO.Me.Gem(name)() ~= nil end) then
        core.err('Could not memorise %s.', name)   -- red message: gem never filled
        return false   -- caller treats this as an other failure
    end
    return core.delay(15000, function() return mq.TLO.Me.SpellReady(name)() == true end)   -- true once the gem is ready to cast
end

--[[--------------------------------------------------------------------------
  casting.restore()

  WHAT  : Re memorises whatever was in the borrowed gem before the job.
  WHY   : Leaves the spell bar exactly as RGMercs expects it.
  WHERE : init.lua cleanup.
  HOW   : Only when restoreGem is on and a spell was recorded. Plain
          mq.delay so it still completes after Stop.
  WHEN  : Job cleanup.
----------------------------------------------------------------------------]]
function casting.restore()
    if not core.settings.restoreGem then originalGemSpell = nil return end
    if originalGemSpell and originalGemSpell ~= '' then
        local gem = core.settings.gem   -- the borrowed gem number
        if mq.TLO.Me.Gem(gem).Name() ~= originalGemSpell then   -- only memorise if it is not already back
            core.echo('Restoring %s to gem %d.', originalGemSpell, gem)   -- tell the operator what is happening
            core.cmd('/memspell %d "%s"', gem, originalGemSpell)   -- load the original spell again
            -- Wait up to 20 s for the original spell to land.
            mq.delay(20000, function() return mq.TLO.Me.Gem(gem).Name() == originalGemSpell end)
        end
    end
    originalGemSpell = nil   -- ready for the next job
end

--[[==========================================================================
  RESULT HANDLING
  WHAT  : Which Cast.Result values stop the job and which mean "cast again".
  WHY   : A fizzle at low Conjuration skill is normal and must never end the
          job. Missing components or a stun will not fix themselves.
  WHERE : castWithMQ2Cast and casting.summonUntil.
  HOW   : FATAL_RESULTS maps codes to a reason; RETRYABLE_RESULTS is a set.
          Anything in neither is an "other" failure. lastFatal and
          lastRetryable carry the verdict of the latest cast to summonUntil.
  WHEN  : After every cast.
==========================================================================]]--
local FATAL_RESULTS = {
    CAST_COMPONENTS = 'missing component',
    CAST_OUTOFMANA  = 'out of mana',
    CAST_STUNNED    = 'stunned',            -- stop rather than spam
    CAST_UNKNOWN    = 'spell not known',    -- name not recognised
    CAST_CANCELLED  = 'cancelled',          -- cancelled by the game or a script
    CAST_ABORTED    = 'aborted',            -- for example by /interrupt
}
local RETRYABLE_RESULTS = {
    CAST_FIZZLE      = true,
    CAST_INTERRUPTED = true,   -- cast was interrupted, cast again
    CAST_DISTRACTED  = true,   -- moved or acted mid cast
    CAST_RECOVER     = true,   -- spell still recovering
    CAST_NOTREADY    = true,   -- gem not ready yet
}
local lastFatal, lastRetryable = false, false

--[[--------------------------------------------------------------------------
  waitForMana(name)

  WHAT  : Ensures enough mana for one cast, sitting to meditate if allowed.
          Returns true when there is enough.
  WHY   : Summoning eighty items at low level runs the caster dry.
  WHERE : casting.castOnce.
  HOW   : Compare Me.CurrentMana to Spell.Mana. If short and medForMana is
          on, /sit and wait up to medTimeoutSec. The wait also ends when a
          hold is wanted (Pause or combat); the cast is then marked
          retryable so the summon loop goes to its checkpoint and holds.
  WHEN  : Before each cast.
----------------------------------------------------------------------------]]
local function waitForMana(name)
    local cost = mq.TLO.Spell(name).Mana() or 0
    if (mq.TLO.Me.CurrentMana() or 0) >= cost then return true end   -- enough already
    if not core.settings.medForMana then
        core.err('Not enough mana for %s.', name)
        return false   -- counts as an other failure
    end
    core.echo('Meditating for mana (need %d).', cost)
    if not mq.TLO.Me.Sitting() then core.cmd('/sit') end   -- sitting regenerates faster
    local ok = core.delay(core.settings.medTimeoutSec * 1000, function()
        return (mq.TLO.Me.CurrentMana() or 0) >= cost or core.holdWanted()
    end)
    if core.holdWanted() then   -- Pause or combat ended the wait
        lastRetryable = true   -- not a failure: hold, then try again
        return false
    end
    return ok
end

--[[--------------------------------------------------------------------------
  castWithMQ2Cast(name)

  WHAT  : Casts a spell through MQ2Cast. Returns true on CAST_SUCCESS.
  WHY   : MQ2Cast watches chat for fizzles and recasts on its own up to
          -maxtries, so this package does not have to guess.
  WHERE : casting.castOnce.
  HOW   : 1. Record the gem, send /casting "name|gemN" -maxtries|N.
          2. Wait for Cast.Status to leave idle (I).
          3. Wait for it to return to I, or for a hold to be wanted.
          4. On a hold: let the spell in the air finish (Me.Casting empty),
             and if MQ2Cast is still going (about to retry), send
             /interrupt to cancel its remaining retries. The result is
             marked retryable and NOT classified, because the CANCELLED or
             ABORTED code that follows is caused by us, not a real failure.
          5. Otherwise read Cast.Result and classify it.
          Stop also sends /interrupt so the plugin does not keep recasting.
  WHEN  : Every cast while MQ2Cast is in use.
----------------------------------------------------------------------------]]
local function castWithMQ2Cast(name)
    local s = core.settings
    rememberGem(name)   -- MQ2Cast overwrites gemN if the spell is not on the bar
    -- Step 1: hand the cast to MQ2Cast.
    core.cmd('/casting "%s|gem%d" -maxtries|%d', name, s.gem, s.castMaxTries)
    -- Step 2: give it up to 2 s to start.
    core.delay(2000, function() return mq.TLO.Cast.Status() ~= 'I' end)
    -- Step 3: up to 30 s to memorise plus 20 s per try, or until a hold.
    local finished = core.delay(30000 + s.castMaxTries * 20000, function()
        return mq.TLO.Cast.Status() == 'I' or core.holdWanted()
    end)
    if core.aborted() then   -- Stop was pressed during the cast
        core.cmd('/interrupt')   -- stop MQ2Cast recasting after Stop
        return false
    end
    -- Step 4: a hold was wanted while MQ2Cast was still working.
    if mq.TLO.Cast.Status() ~= 'I' and core.holdWanted() then
        -- Never cut a spell short: wait for the current cast bar to end.
        mq.delay(20000, function() return mq.TLO.Me.Casting.ID() == nil end)
        mq.delay(500)   -- let MQ2Cast record the result of that cast
        if mq.TLO.Cast.Status() ~= 'I' then
            core.debug('Hold wanted, cancelling MQ2Cast retries.')
            core.cmd('/interrupt')   -- cancel the queued retry only
            mq.delay(2000, function() return mq.TLO.Cast.Status() == 'I' end)
            lastRetryable = true     -- caused by the hold, not a failure
            return false
        end
        finished = true   -- MQ2Cast ended on its own; read its result below
    end
    -- Step 5: classify the result.
    local result = mq.TLO.Cast.Result() or 'CAST_UNKNOWN'
    casting.lastResult = result
    if not finished then
        core.err('%s: MQ2Cast did not finish in time.', name)   -- MQ2Cast still busy after the full wait
        return false   -- other failure
    end
    if result == 'CAST_SUCCESS' then return true end
    if FATAL_RESULTS[result] then
        lastFatal = true   -- summonUntil stops at once
        core.err('%s failed: %s (%s).', name, FATAL_RESULTS[result], result)   -- red message with the reason
    elseif RETRYABLE_RESULTS[result] then   -- a code that just means cast again
        lastRetryable = true   -- summonUntil casts again with no penalty
        core.debug('%s: %s after %d tries, casting again.', name, result, s.castMaxTries)   -- trace only, fizzles are normal
    else
        core.warn('%s failed: %s.', name, result)   -- other failure
    end
    return false
end

--[[--------------------------------------------------------------------------
  castWithPlainCast(name)

  WHAT  : Casts with plain /memspell and /cast. Returns true when the cast
          appears to have completed.
  WHY   : Fallback without MQ2Cast. It cannot tell a fizzle from an
          interrupt, so castOnce judges success by the item on the cursor.
  WHERE : casting.castOnce.
  HOW   : memorize, /cast, wait for the cast bar to start and end.
  WHEN  : Every cast while MQ2Cast is not in use.
----------------------------------------------------------------------------]]
local function castWithPlainCast(name)
    if not casting.memorize(name) then return false end
    core.cmd('/cast "%s"', name)   -- plain EQ cast of a memorised spell
    core.delay(1500, function() return mq.TLO.Me.Casting.ID() ~= nil end)    -- started
    core.delay(15000, function() return mq.TLO.Me.Casting.ID() == nil end)   -- ended
    return true
end

--[[--------------------------------------------------------------------------
  casting.castOnce(name, kind)

  WHAT  : One summon cast plus stashing the result. Returns true when an
          item was created.
  WHY   : The single unit of work the summon loop repeats.
  WHERE : casting.summonUntil.
  HOW   : Clear cursor, mana check, snapshot the chat counters, cast,
          process events and update progress, wait for the item on the
          cursor (marking the cast retryable if chat showed a fizzle),
          learn the item name into settings if it differs, /autoinventory.
          kind is 'food' or 'drink'.
  WHEN  : Inside a job only.
----------------------------------------------------------------------------]]
function casting.castOnce(name, kind)
    lastFatal, lastRetryable = false, false   -- fresh verdict for this cast
    if not delivery.clearCursor() then
        core.err('Cursor is stuck, cannot cast.')
        return false
    end
    if not waitForMana(name) then return false end   -- not enough mana and no meditation in time

    local fizzBefore, intBefore = fizzleCount, interruptCount   -- counters before this cast
    local cast = usingMQ2Cast() and castWithMQ2Cast or castWithPlainCast   -- pick the casting path for this cast
    local ok = cast(name)   -- run the cast; true means it landed
    mq.doevents()   -- run the chat callbacks now
    casting.progress.fizzles    = casting.progress.fizzles + (fizzleCount - fizzBefore)
    casting.progress.interrupts = casting.progress.interrupts + (interruptCount - intBefore)
    if not ok then return false end

    -- Summon spells put the item on the cursor; give it 2.5 s.
    if not core.delay(2500, function() return mq.TLO.Cursor.ID() ~= nil end) then
        mq.doevents()
        if fizzleCount > fizzBefore or interruptCount > intBefore then
            lastRetryable = true   -- a fizzle, not a real failure
        end
        core.debug('%s produced nothing (fizzle or interrupt).', name)
        return false
    end

    -- Learn the real item name the first time (servers differ).
    local made = delivery.cursorName()
    local key  = kind == 'food' and 'foodItem' or 'drinkItem'
    if made and made ~= core.settings[key] then
        core.echo('Learned %s item name: %s', kind, made)   -- first cast on this server teaches the name
        core.settings[key] = made   -- store it so counts and trades use it
        core.save()   -- next run knows it before casting
    end
    return delivery.clearCursor()   -- into the bags
end

--[[--------------------------------------------------------------------------
  casting.summonUntil(kind, target)

  WHAT  : Casts the food or drink spell until the bags hold target of the
          item. Returns the final count.
  WHY   : The goal is an item count, not a cast count, so low Conjuration
          skill only makes the job slower, never ends it early.
  WHERE : init.lua run.
  HOW   : Loop until have >= target:
            - core.checkpoint first: holds while paused or in combat,
              returns false on Stop. Time spent holding is added to the
              start time so it does not count against the time limit.
            - stop if bags are full with nothing to stack onto
            - stop if the summon time limit has passed (0 = no limit)
            - castOnce, then sort: success, retryable, fatal, other
              (3 other failures in a row stop).
  WHEN  : At the start of a job, once for food and once for drink.
----------------------------------------------------------------------------]]
function casting.summonUntil(kind, target)
    local s       = core.settings
    local name    = kind == 'food' and casting.food or casting.drink
    local itemKey = kind == 'food' and 'foodItem' or 'drinkItem'   -- settings key for the item name
    if not name then   -- no spell of this kind was found
        core.err('No %s summoning spell found in your book.', kind)   -- red message, nothing to cast
        return delivery.count(s[itemKey])   -- what we already carry
    end

    local p = casting.progress
    p.kind, p.target, p.fizzles, p.interrupts = kind, target, 0, 0   -- start fresh progress for the window
    local limitMs  = (s.summonTimeoutMin or 0) * 60000   -- time limit in milliseconds, 0 = none
    local started  = mq.gettime()   -- clock start, moved forward by held time
    local failures = 0   -- consecutive other failures; fizzles do not count
    local OTHER_FAILURE_LIMIT = 3

    while not core.aborted() do
        local have = delivery.count(s[itemKey])   -- how many we carry right now
        p.have = have   -- shown in the window
        if have >= target then   -- target reached
            if p.fizzles > 0 then   -- report fizzles only if there were any
                core.echo('%s done: %d made, %d fizzles along the way.', kind, have, p.fizzles)   -- summary line in chat
            end
            return have   -- target reached
        end

        -- Safe point: Pause and Combat Hold wait here.
        local carryOn, heldMs = core.checkpoint()
        if not carryOn then break end           -- Stop pressed while holding
        started = started + (heldMs or 0)       -- held time is not summon time

        if delivery.freeSlots() < 1 and have == 0 then
            core.err('No free bag slot for %s.', kind)
            return have   -- bags full, nothing can be summoned
        end
        if limitMs > 0 and mq.gettime() - started > limitMs then   -- safety net reached
            core.err('%s: summon time limit (%d min) reached with %d of %d.',   -- red message with progress so far
                kind, s.summonTimeoutMin, have, target)   -- values for the message above
            return have   -- stop with what was made
        end

        core.debug('%s: have %d of %d, casting %s', kind, have, target, name)   -- trace each attempt when Debug is on
        if casting.castOnce(name, kind) then   -- one cast; the flags sort any failure
            failures = 0                                  -- landed one
        elseif lastFatal then
            return delivery.count(s[itemKey])             -- hopeless, stop now
        elseif not lastRetryable then
            failures = failures + 1                       -- an other failure
            if failures >= OTHER_FAILURE_LIMIT then
                core.err('%d failed %s casts in a row (not fizzles), giving up.', failures, name)
                return delivery.count(s[itemKey])
            end
        end
        -- Retryable (fizzle, interrupt, hold): loop again with no penalty.
    end
    return delivery.count(s[itemKey])   -- Stop: report what was made
end

return casting   -- hand the module table to require('provisions.casting')

--[[==========================================================================
  END OF FILE : provisions/casting.lua

  SUMMARY OF PUBLIC API
    FOOD_SPELLS / DRINK_SPELLS   Candidate names, best first.
    SUMMON_CLASSES               Classes with summon spells.
    food / drink                 Detected spell names or nil.
    choices.food / .drink  table Scribed candidates, best first.
    inBook(name)         bool    Spell of exactly this name is scribed.
    lastResult           string  Last MQ2Cast Cast.Result.
    progress             table   Live summon progress for the window.
    classNote()          string  Warning for non summoning classes, or nil.
    detect()                     Refresh detection.
    beginJob() / endJob()        Load and unload MQ2Cast around a job.
    memorize(name)       bool    Memorise into the borrowed gem.
    restore()                    Put the borrowed gem back.
    castOnce(name, kind) bool    One cast plus stash; learns item name.
    summonUntil(kind, n) number  Cast until n are carried.

  DEPENDENCIES : mq, provisions.core, provisions.delivery.
                 Optional plugin: MQ2Cast (preferred casting path).

  HOW TO EDIT SAFELY
    - Support a new spell: add it to FOOD_SPELLS or DRINK_SPELLS, best
      first (it then shows in the Options drop down for anyone who has it
      scribed), or pick "Type your own..." in that drop down.
    - Another MQ2Cast result is hopeless: add it to FATAL_RESULTS. Another
      means "just cast again": add it to RETRYABLE_RESULTS.
    - Fizzles never count toward OTHER_FAILURE_LIMIT. The overall safety
      net is the summonTimeoutMin setting (0 = none), which excludes time
      spent holding.
    - A hold must never interrupt a spell in the air. Keep the wait on
      Me.Casting before the /interrupt in castWithMQ2Cast step 4.
    - A server words the fizzle message differently: edit EVENTS.
==========================================================================]]--
