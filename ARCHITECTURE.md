<!--
  FILE    : clericfood/ARCHITECTURE.md
  PACKAGE : ClericFood Lua (MacroQuest / EverQuest)
  VERSION : 1.3.1
  WHAT    : Maintainer's map of the package: what each file does, how a job
            flows through them, where every setting is used, and recipes
            for common changes.
  WHY     : So the code can be picked up years later without rediscovering
            how the pieces fit.
  WHERE   : Beside init.lua in <MacroQuest>/lua/clericfood/.
  WHEN    : Read before changing any code.
-->

# ClericFood architecture

## Start here

If you only read one section, read this:

1. `init.lua` starts everything and runs a loop every 100 ms.
2. The window (`ui.lua`) never waits. Pressing Hand Out only sets
   `actions.requested = true`.
3. On the next loop pass, `actions.tick` sees the flag and runs the whole
   job in `actions.run`. Waiting is allowed there.
4. `actions.run` calls `spells` to summon, then `trade` to hand out.
5. `cleanup` in `actions.lua` always runs afterwards and puts everything
   back.

## Module map

| File | One line job | Requires |
|---|---|---|
| `init.lua` | Startup, `/cfood` command, main loop | all modules |
| `ui.lua` | ImGui window, never waits | utils, config, inventory, spells, group, actions |
| `actions.lua` | Job runner and cleanup | utils, config, inventory, spells, group, trade |
| `spells.lua` | Detect, memorise, cast, summon loop, MQ2Cast | utils, config, inventory |
| `trade.lua` | Walk, trade, remote accept, DanNet count query | utils, config, inventory |
| `group.lua` | Roster rows and ticks | config |
| `inventory.lua` | Count, stash, exact quantity pickup | utils |
| `config.lua` | Defaults, load, save | utils |
| `utils.lua` | Echo, cmd, abortable delay, clamp | nothing |
| `dev/doc_audit.py` | Checks the documentation standard (PC only) | Python |
| `dev/smoke_test.py` | Runs the code against a fake MacroQuest (PC only) | Python, lupa |

Requires only point downward in this table. Keep it that way. A module that
requires something above it creates a loop and Lua will fail to load.

## Flow of one hand out

```
Hand Out button / /cfood go
  actions.request()                     sets requested = true
main loop
  actions.tick()
    actions.run(state)
      spells.detect()                   best food and drink spell
      group.refresh(true)               live roster
      group.selectedRows()              ticked, in zone, not merc
      /rgl pause                        if RGMercs is running
      spells.beginJob()                 fizzle events on, load MQ2Cast if needed
      planNeeds()                       per member counts, Top up queries
      spells.summonUntil('food', n)     loop until n carried, fizzles ignored
        spells.castOnce()
          waitForMana()
          castWithMQ2Cast()             /casting "x|gem8" -maxtries|5
            or castWithPlainCast()      /memspell, /cast
          learn item name, /autoinventory
      spells.summonUntil('drink', n)
      for each member:
        trade.giveItems()
          trade.moveInRange()           /nav id
          buildPlan()                   split into stacks of 20
          runOneTrade()                 up to 8 stacks
            inventory.pickUp()          shift, ctrl or quantity slider
            /click left target
            press Trade, remoteAccept() /dex or /bct
            verify by recounting bags
    cleanup()
      trade.cancel()
      inventory.clearCursor()
      /nav stop
      spells.restore()                  put gem 8 back
      spells.endJob()                   fizzle events off, unload MQ2Cast if we loaded it
      /rgl unpause                      only if we paused it
```

## How Stop works

1. Stop sets `actions.stopRequested = true`.
2. `utils.delay` checks that flag through `utils.bindAbortFlag`, so every
   wait in every module ends early.
3. Loops check `utils.aborted()` between steps and exit.
4. When an MQ2Cast cast is running, `/interrupt` is sent so the plugin
   stops its own retries.
5. `cleanup` clears the flag first, so its own waits (gem restore, trade
   cancel) run to completion.

## How fizzles are handled

The summon loop's goal is an item count, not a cast count. It casts until
the bags hold the target number, however many fizzles that takes.

Every failed cast is sorted into one of three kinds:

| Kind | Examples | What happens |
|---|---|---|
| Retryable | Fizzle, interrupt, gem not ready (`RETRYABLE_RESULTS`, or a fizzle seen in chat) | Cast again. Never counts toward giving up. |
| Fatal | Stunned, missing component (`FATAL_RESULTS`) | Stop summoning at once, reason in red. |
| Other | Mana wait timed out, cursor stuck | 3 in a row stops summoning (`OTHER_FAILURE_LIMIT`). |

The only limit on fizzles is the summon time limit (`summonTimeoutMin`,
default 20 minutes, 0 = none).

Fizzles and interrupts are counted from the game's chat messages using
`mq.event` (patterns in `EVENTS` in `spells.lua`). The events are registered
in `spells.beginJob`, processed with `mq.doevents()` after every cast, and
removed in `spells.endJob`. The counts appear live in the window.

## Where each setting is used

| Setting | Read in |
|---|---|
| `foodCount`, `drinkCount` | actions.planNeeds, ui.drawCounts, ui.resultText |
| `foodSpell`, `drinkSpell` | spells.detect |
| `foodItem`, `drinkItem` | actions, spells.castOnce (learned here), ui |
| `gem`, `restoreGem` | spells.memorize, castWithMQ2Cast, spells.restore |
| `useMQ2Cast`, `castMaxTries` | spells.beginJob, usingMQ2Cast, castWithMQ2Cast |
| `summonTimeoutMin` | spells.summonUntil |
| `medForMana`, `medTimeoutSec` | spells.waitForMana |
| `preserveOwnStock` | actions.planNeeds |
| `topUp` | actions.planNeeds |
| `acceptMethod` | trade.remoteAccept |
| `tradeTimeoutSec` | trade.runOneTrade |
| `tradeRange`, `useNav`, `navTimeoutSec` | trade.moveInRange, ui.drawRoster |
| `pauseRGMercs` | actions.run |
| `selected` | group.isSelected, group.setSelected |
| `debug` | utils.debug through config.load |

## Common changes

| I want to | Edit |
|---|---|
| Add a new spell name | `FOOD_SPELLS` or `DRINK_SPELLS` in `spells.lua`, best first |
| Add a new option | `config.DEFAULTS`, then a control in `ui.drawOptions` |
| Add a slash command | `onCommand` and `printHelp` in `init.lua`, README table |
| Change the RGMercs pause commands | `actions.run` and `cleanup` |
| Add an accept method | `remoteAccept` in `trade.lua`, radio button in `ui.drawOptions` |
| Fix partial stack pickup | `inventory.pickUp`, check names with `/windows` |
| Treat another cast result as hopeless | `FATAL_RESULTS` in `spells.lua` |
| Treat another cast result as "just cast again" | `RETRYABLE_RESULTS` in `spells.lua` |
| Fizzle message worded differently on a server | `EVENTS` in `spells.lua` |
| Per member counts | `group.lua` selected storage, new column in `ui.drawRoster`, `planNeeds` |

## Documentation standard

Every Lua file follows the same layout so any file reads the same way:

1. **Header block** at the top: FILE, PACKAGE, VERSION, CHANGES (every
   package version, "No change in this file" where nothing changed), then
   WHAT, WHY, WHERE, HOW and WHEN for the file, then a READING GUIDE that
   explains game and MacroQuest terms used in the file.
2. **Module variables** each have a short block: WHAT, WHY, WHERE, HOW, WHEN.
3. **Every function** has a doc block directly above it with WHAT (what it
   does and returns), WHY (the reason it exists), WHERE (who calls it),
   HOW (the steps) and WHEN (at what point it runs).
4. **Every line of code** has a comment at the end of the line or within the
   three lines above it.
5. **Footer block** at the bottom: END OF FILE, a summary of the public
   functions, dependencies, and HOW TO EDIT SAFELY notes.

Markdown files carry a short HTML comment header and footer with the same
labels.

## Making a change: checklist

1. Make the code change.
2. Comment every new or changed line, and update the doc block of every
   function you touched (especially WHERE if callers changed).
3. Add an entry at the top of CHANGELOG.md with the new version number.
4. In every .lua file: set VERSION to the new number and add a CHANGES line
   (describe the change, or "No change in this file").
5. Update this file if the flow, a setting, or a module's job changed, and
   README.md if anything the operator sees changed.
6. Run `python dev/doc_audit.py` and fix anything it reports.
7. Run `python dev/smoke_test.py` and make sure all scenarios pass.
8. Test in game with Debug trace on.

## Glossary

| Term | Meaning |
|---|---|
| TLO | Top Level Object. MacroQuest's way to read game data, e.g. `mq.TLO.Me.CurrentMana()` |
| Gem | A spell bar slot |
| Cursor | The item held on the mouse pointer |
| Yield | Hand control back to MacroQuest briefly with `mq.delay` |
| Job | One Hand Out, start to cleanup |
| Drop | One stack placed into one trade slot |
| Plan | The list of drops for one member |
| Reserve | Stock the cleric keeps and never trades away |
| Peer | A box on DanNet, addressed by lower case name |

<!--
  END OF FILE : clericfood/ARCHITECTURE.md
-->
