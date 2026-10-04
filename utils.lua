--[[==========================================================================
  FILE        : clericfood/utils.lua
  PACKAGE     : ClericFood Lua  (MacroQuest / EverQuest)
  VERSION     : 1.3.1
  CHANGES     : 1.0.0  First release.
                1.1.0  No change in this file.
                1.2.0  Full inline documentation pass. No behaviour change.
                1.3.0  No change in this file.
                1.3.1  Documentation audit: every code line now carries
                       its own comment or one directly above it.

  WHAT  : Low level shared helpers used by every other module in the package:
          prefixed console output, debug gated tracing, traced slash command
          dispatch, cooperative abortable delays, and small numeric helpers.

  WHY   : Every module needs to print, wait, and send commands. Putting those
          three things in one place guarantees that every line printed carries
          the same [ClericFood] tag (so it can be told apart from RGMercs and
          MQ2Nav spam when six clients are running), that every command can be
          traced in one spot when Debug is on, and that every wait in the
          package honours the Stop button the same way.

  WHERE : Required by config.lua, inventory.lua, spells.lua, group.lua,
          trade.lua, actions.lua, ui.lua and init.lua. It requires nothing
          from the package itself, so it sits at the bottom of the dependency
          graph and can never cause a circular require.

  HOW   : Pure Lua plus the mq API. Every wait is built on mq.delay, which
          yields back to MacroQuest so the ImGui window keeps painting while a
          spell is being cast or a trade is pending. Nothing here busy waits.

  WHEN  : Loaded first by init.lua and referenced for the whole lifetime of
          the script.

  READING GUIDE (for future you)
    - "Yield" means hand control back to MacroQuest for a moment so the game
      and the window keep running. mq.delay is the only thing that yields.
    - A "getter" here is a small function stored in a variable that returns a
      value when called. utils stores two of them (debug and abort) so it can
      ask other modules questions without requiring them.
==========================================================================]]--

-- The MacroQuest Lua API. Gives access to mq.cmd (send a slash command),
-- mq.delay (wait while yielding) and mq.TLO (read game data).
local mq = require('mq')

-- The module table. Everything added to it below is public; local functions
-- and variables are private to this file.
local utils = {}

--- Colour code shortcuts -----------------------------------------------------
-- WHAT : Named aliases for the MacroQuest chat colour escapes.
-- WHY  : Raw \ag and \ar codes are unreadable at the call site. Names make the
--        intent of each message obvious when reading the code later.
-- WHERE: utils.good, utils.warn, utils.err, utils.debug and any module that
--        builds a coloured line.
-- HOW  : Plain string constants concatenated into echo payloads. MacroQuest
--        reads a backslash plus a letter inside chat text as a colour change.
-- WHEN : Read at echo time. Never changed after load.
utils.color = {
    reset  = '\aw', -- white, used to return to normal text after a colour
    info   = '\at', -- teal, general information
    good   = '\ag', -- green, something succeeded
    warn   = '\ay', -- yellow, something needs attention but is not fatal
    bad    = '\ar', -- red, something failed
    accent = '\ao', -- orange, used for the [dbg] tag on debug lines
}

--- Package chat prefix -------------------------------------------------------
-- WHAT : The [ClericFood] tag stamped on the front of every console line.
-- WHY  : Lets the operator filter this script's output from everything else.
-- WHERE: utils.echo only (all other output functions go through echo).
-- HOW  : String constant with colour codes. \ax resets colour after the tag.
-- WHEN : Applied to every printed line.
local PREFIX = '\aw[\agClericFood\aw]\ax '

--- Debug flag getter ---------------------------------------------------------
-- WHAT : A function that returns true when debug tracing is on.
-- WHY  : utils must not require config (config requires utils), so config
--        pushes a getter in through utils.bindDebugFlag instead. This keeps
--        the dependency graph one directional.
-- WHERE: utils.debug and utils.cmd.
-- HOW  : Defaults to a function returning false until config binds it, so
--        any debug call made before settings load is silently skipped.
-- WHEN : Bound once during config.load, read on every traced call.
local debugEnabled = function() return false end

--- Abort flag getter ---------------------------------------------------------
-- WHAT : A function that returns true when the operator has pressed Stop.
-- WHY  : Every wait in the package must be interruptible. Rather than every
--        module checking the job state itself, utils.delay checks this once.
-- WHERE: utils.delay and utils.aborted.
-- HOW  : actions.lua binds its own abort test through utils.bindAbortFlag.
--        Until then it always answers "not aborted".
-- WHEN : Bound once at startup, read during every wait.
local abortRequested = function() return false end

--[[--------------------------------------------------------------------------
  utils.bindDebugFlag(getter)

  WHAT  : Installs the function utils uses to decide whether to trace.
  WHY   : Avoids a circular require between utils and config.
  WHERE : Called by config.load.
  HOW   : Stores the supplied function in the local debugEnabled upvalue.
  WHEN  : Once, right after settings are loaded.
----------------------------------------------------------------------------]]
function utils.bindDebugFlag(getter)
    -- Only accept a real function. Anything else would crash later when
    -- utils.debug tries to call it, so ignore it and keep the old getter.
    if type(getter) == 'function' then debugEnabled = getter end
end

--[[--------------------------------------------------------------------------
  utils.bindAbortFlag(getter)

  WHAT  : Installs the function utils uses to decide whether to stop waiting.
  WHY   : Lets utils.delay cut a wait short the instant Stop is pressed, without
          utils needing to know anything about the job runner.
  WHERE : Called by actions.lua at load time.
  HOW   : Stores the supplied function in the local abortRequested upvalue.
  WHEN  : Once, at module load.
----------------------------------------------------------------------------]]
function utils.bindAbortFlag(getter)
    -- Same safety check as bindDebugFlag.
    if type(getter) == 'function' then abortRequested = getter end
end

--[[--------------------------------------------------------------------------
  utils.aborted()

  WHAT  : Returns true if the operator has asked the current job to stop.
  WHY   : Long loops (summon N items, deliver to N members) check this between
          steps so they exit cleanly rather than half way through a trade.
  WHERE : spells.lua, trade.lua, actions.lua.
  HOW   : Calls the bound abort getter.
  WHEN  : Between steps of any multi step operation.
----------------------------------------------------------------------------]]
function utils.aborted()
    -- Compare to true so a getter that returns nil counts as "not aborted".
    return abortRequested() == true
end

--[[--------------------------------------------------------------------------
  utils.echo(fmt, ...)

  WHAT  : Writes one formatted, prefixed line to the EQ console.
  WHY   : Single choke point for all output so the tag and formatting are
          always consistent.
  WHERE : Every module.
  HOW   : string.format when varargs are supplied, then prefix, then mq.cmd
          with /echo. mq.cmd is used instead of mq.cmdf because the text is
          already formatted and must not be re parsed as a format string.
  WHEN  : Any time, including before config is loaded.
----------------------------------------------------------------------------]]
function utils.echo(fmt, ...)
    -- select('#', ...) counts the extra arguments. If there are none, fmt is
    -- printed as is; this matters because a name containing % would break
    -- string.format if we always formatted.
    local msg = select('#', ...) > 0 and string.format(fmt, ...) or tostring(fmt)
    -- /echo prints to the MacroQuest chat window on this client only.
    mq.cmd('/echo ' .. PREFIX .. msg)
end

--[[--------------------------------------------------------------------------
  utils.good(fmt, ...) / utils.warn(fmt, ...) / utils.err(fmt, ...)

  WHAT  : Coloured variants of utils.echo for success, warning and failure.
  WHY   : The operator should be able to spot a failed trade at a glance in a
          scrolling chat window. Colour does that faster than words.
  WHERE : Every module that reports an outcome.
  HOW   : Wraps the formatted message in a colour code and calls utils.echo.
          The message is formatted here first, then passed to echo with no
          varargs so echo does not format it a second time.
  WHEN  : When reporting results.
----------------------------------------------------------------------------]]
function utils.good(fmt, ...)
    local msg = select('#', ...) > 0 and string.format(fmt, ...) or tostring(fmt)
    utils.echo(utils.color.good .. msg)   -- green line
end

function utils.warn(fmt, ...)
    local msg = select('#', ...) > 0 and string.format(fmt, ...) or tostring(fmt)  -- format once here; echo is then called with no varargs
    utils.echo(utils.color.warn .. msg)   -- yellow line
end

function utils.err(fmt, ...)
    local msg = select('#', ...) > 0 and string.format(fmt, ...) or tostring(fmt)  -- same pattern for the red failure line
    utils.echo(utils.color.bad .. msg)    -- red line
end

--[[--------------------------------------------------------------------------
  utils.debug(fmt, ...)

  WHAT  : Prints a trace line only when Debug is enabled in settings.
  WHY   : Lets the operator see every decision the script makes while testing
          against the live client, without that noise during normal use.
  WHERE : Any module.
  HOW   : Checks the bound debug getter, then prints with an orange [dbg] tag.
  WHEN  : At decision points and before waits.
----------------------------------------------------------------------------]]
function utils.debug(fmt, ...)
    -- Leave immediately when Debug is off, before doing any formatting work.
    if not debugEnabled() then return end
    local msg = select('#', ...) > 0 and string.format(fmt, ...) or tostring(fmt)
    utils.echo(utils.color.accent .. '[dbg] ' .. utils.color.reset .. msg)
end

--[[--------------------------------------------------------------------------
  utils.cmd(fmt, ...)

  WHAT  : Formats and sends one slash command to the game, tracing it first.
  WHY   : Every command the package sends passes through here, so turning on
          Debug shows the exact command stream, which is the fastest way to
          find a wrong window or control name.
  WHERE : Every module that sends a command.
  HOW   : string.format, optional debug trace, then mq.cmd.
  WHEN  : Whenever the game needs to be told to do something.
----------------------------------------------------------------------------]]
function utils.cmd(fmt, ...)
    -- Build the final command text, same varargs rule as echo.
    local line = select('#', ...) > 0 and string.format(fmt, ...) or tostring(fmt)
    -- Show the exact command in chat when Debug is on.
    utils.debug('cmd: %s', line)
    -- Send it. mq.cmd does not wait for the game to act on it; callers that
    -- need the result must wait with utils.delay afterwards.
    mq.cmd(line)
end

--[[--------------------------------------------------------------------------
  utils.delay(ms, condition)

  WHAT  : Waits up to ms milliseconds, returning early when condition() is
          true or when the operator presses Stop.
  WHY   : A plain mq.delay with a condition does not know about Stop. Wrapping
          it here means every wait in the package is abortable for free.
  WHERE : spells.lua, trade.lua, actions.lua, inventory.lua.
  HOW   : Calls mq.delay with a combined predicate. Returns true if the
          supplied condition became true, false on timeout or abort.
  WHEN  : Any time the script waits on the game.
----------------------------------------------------------------------------]]
function utils.delay(ms, condition)
    if condition == nil then
        -- No condition: a plain timed pause that still ends early on Stop.
        -- Returns true when the full pause ran, false when Stop cut it short.
        mq.delay(ms, function() return utils.aborted() end)
        return not utils.aborted()
    end
    -- mq.delay re checks the predicate every frame and returns as soon as it
    -- is true, or when ms has passed.
    mq.delay(ms, function() return utils.aborted() or condition() end)
    -- Report success only if we were not stopped AND the condition is true
    -- now. Re evaluating avoids reporting success on a timeout.
    return (not utils.aborted()) and condition() == true
end

--[[--------------------------------------------------------------------------
  utils.clamp(value, lo, hi)

  WHAT  : Constrains a number to the inclusive range lo to hi.
  WHY   : ImGui input boxes let the operator type anything. Clamping keeps food
          and drink counts inside what a trade can actually carry.
  WHERE : ui.lua, config.lua and init.lua.
  HOW   : tonumber (non numbers become lo), then math.max then math.min.
  WHEN  : Whenever a user editable number is accepted.
----------------------------------------------------------------------------]]
function utils.clamp(value, lo, hi)
    value = tonumber(value) or lo            -- text or nil falls back to lo
    return math.max(lo, math.min(hi, value)) -- squeeze into [lo, hi]
end

--[[--------------------------------------------------------------------------
  utils.plural(n, word)

  WHAT  : Returns "3 casts" style text with a naive plural (adds an s).
  WHY   : Status lines read naturally, which matters when scanning the log.
  WHERE : Available to any module. Not used for irregular words like loaf.
  HOW   : Appends an s when n is not 1.
  WHEN  : When building a status message.
----------------------------------------------------------------------------]]
function utils.plural(n, word)
    return string.format('%d %s%s', n, word, n == 1 and '' or 's')
end

-- Hand the module table to whoever wrote require('clericfood.utils').
return utils

--[[==========================================================================
  END OF FILE : clericfood/utils.lua

  SUMMARY OF PUBLIC API
    color                    table   Named chat colour codes.
    bindDebugFlag(fn)                Install the debug getter (config.lua).
    bindAbortFlag(fn)                Install the abort getter (actions.lua).
    aborted()                bool    True when Stop has been pressed.
    echo / good / warn / err         Prefixed, coloured console output.
    debug(fmt, ...)                  Output only when Debug is on.
    cmd(fmt, ...)                    Traced slash command dispatch.
    delay(ms, cond)          bool    Abortable cooperative wait.
    clamp(v, lo, hi)         number  Range constraint.
    plural(n, word)          string  "3 casts" style text.

  DEPENDENCIES : mq only.

  HOW TO EDIT SAFELY
    - Change the chat tag: edit PREFIX.
    - Add a colour: add a key to utils.color and use it with utils.echo.
    - Never require another clericfood module from this file. That would
      create a require loop because every module requires utils.
    - utils.delay must remain the only waiting primitive. A busy loop
      (while true do end without mq.delay) anywhere freezes the game client.
==========================================================================]]--
