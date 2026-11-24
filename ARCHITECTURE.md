<!--
  FILE    : provisions/ARCHITECTURE.md
  PACKAGE : Provisions Lua (MacroQuest / EverQuest)
  VERSION : 2.3.2
  WHAT    : Maintainer's map of the package: what each file does, how a job
            flows through them, how Stop, Pause and Combat Hold work, where
            every setting is used, and recipes for common changes.
  WHY     : So the code can be picked up years later without rediscovering
            how the pieces fit.
  WHERE   : Beside init.lua in <MacroQuest>/lua/provisions/.
  WHEN    : Read before changing any code.
-->

# Provisions architecture

## Start here

If you only read one section, read this:

1. `init.lua` starts everything and runs a loop every 100 ms.
2. The window (`ui.lua`) never waits. Pressing Hand Out only sets
   `core.job.requested = true`.
3. On the next loop pass, `tick` in `init.lua` sees the flag and runs the
   whole job in `run`. Waiting is allowed there.
4. `run` calls `casting` to summon, then `serveMembers`, which calls
   `delivery` to trade.
5. Before every cast and every trade, `core.checkpoint()` runs. That is
   where Pause and Combat Hold wait.
6. `cleanup` in `init.lua` always runs afterwards and puts everything back.

## Module map

| File | One line job | Requires |
|---|---|---|
| `init.lua` | Startup, `/provisions`, main loop, job runner, checkpoint, trade queue, cleanup | all files |
| `ui.lua` | ImGui window, never waits | core, delivery, casting |
| `casting.lua` | Detect, memorise, cast, summon loop, MQ2Cast | core, delivery |
| `delivery.lua` | Bag counts, cursor, pickup, walk, trade, link to other boxes (MQRemote, DanNet, EQBC) | core |
| `core.lua` | Echo, cmd, abortable delay, settings, roster, job flags, combat check | nothing |
| `LICENSE` | MIT license terms | |
| `REDGUIDES.md` | RedGuides guide for MacroQuest Lua and its resource rules | |

The maintainer's PC tools, `dev/doc_audit.py` (checks the documentation
standard) and `dev/smoke_test.py` (runs the code against a fake MacroQuest),
are kept with the maintainer and are not part of the release or the zip.

Requires only point downward in this table. Keep it that way. A file that
requires something above it creates a loop and Lua will fail to load.

### Where the 1.3.2 files went

| ClericFood 1.3.2 | Provisions 2.0.0 |
|---|---|
| utils.lua, config.lua, group.lua | core.lua parts 1, 2 and 3 |
| (job flags in actions.lua) | core.lua part 4 |
| inventory.lua, trade.lua | delivery.lua parts 1 and 3 (part 2 is new DanNet code) |
| spells.lua | casting.lua |
| init.lua, actions.lua | init.lua |
| ui.lua | ui.lua |

## Flow of one hand out

```
Hand Out button / /provisions go
  core.request()                        sets job.requested = true
main loop (init.lua)
  tick()
    run()
      casting.detect()                  best food and drink spell
      core.refreshRoster(true)          live roster
      core.selectedRows()               ticked, in zone, not merc
      linkCheck()                       link plugin here? every member answers?
        delivery.ensureLink()           Plugin TLO; /plugin <name> load if missing
        delivery.loadOnOthers()         silent members, if loadOnOtherBoxes: /plugin load via DanNet or EQBC
        delivery.probe()                MQRemote pong round trip, or DanNet peers + /dquery
      /rgl pause                        if RGMercs is running
      casting.beginJob()                fizzle events on, load MQ2Cast if needed
      planNeeds()                       per member counts, Top up from row.probe
      casting.summonUntil('food', n)    loop until n carried, fizzles ignored
        core.checkpoint()               Pause and Combat Hold wait here
        casting.castOnce()
          waitForMana()
          castWithMQ2Cast()             /casting "x|gem8" -maxtries|5
            or castWithPlainCast()      /memspell, /cast
          learn item name, /autoinventory
      casting.summonUntil('drink', n)
      serveMembers(plan)                retry queue
        core.checkpoint()
        delivery.peerInCombat()         probe: Me.CombatState
        delivery.giveItems()
          delivery.moveInRange()        /nav id
          buildPlan()                   split into stacks of 20
          runOneTrade()                 up to 8 stacks
            delivery.pickUp()           shift, ctrl or quantity slider
            /click left target
            press Trade, waitForAccept()  delivery.remote: /rc, /dex or /bct; cancels on combat
            verify by recounting bags
    cleanup()
      delivery.cancel()
      delivery.clearCursor()
      /nav stop
      casting.restore()                 put gem 8 back
      casting.endJob()                  fizzle events off, unload MQ2Cast if we loaded it
      /rgl unpause                      only if we paused it and it is not handed back
```

## How Stop works

1. Stop sets `core.job.stopRequested = true` and clears Pause.
2. `core.delay` checks that flag, so every wait in every file ends early.
3. Loops check `core.aborted()` between steps and exit. The checkpoint
   loop ends too.
4. When an MQ2Cast cast is running, `/interrupt` is sent so the plugin
   stops its own retries.
5. `cleanup` clears the flag first, so its own waits (gem restore, trade
   cancel) run to completion.

## How Pause and Combat Hold work

Both are holds at a checkpoint, a safe point before a cast or a trade.
`core.checkpoint()` calls the function `init.lua` installed with
`core.bindCheckpoint`. It loops every 250 ms while a hold applies and
returns two values: carry on (false after Stop) and the milliseconds held.
The summon loop adds the held time to its start time, so holds never count
against the summon time limit.

| Hold | Starts when | RGMercs | Ends when |
|---|---|---|---|
| Paused | Pause pressed (`core.job.paused`) | Stays paused | Resume pressed |
| Combat hold | Combat Hold on and `core.inCombat()` | `/rgl unpause` once (if Hand back is on and the job paused it) | Out of combat for `combatSettleSec`; then `/rgl pause` again |

Combat hold wins over Paused. If both apply, the job stays Paused after the
fight with RGMercs paused again.

`core.inCombat()` is true when `Me.CombatState` is `COMBAT` or
`Me.XTHaterCount` is above 0. Both are on the MacroQuest
[character data type page](https://docs.macroquest.org/reference/data-types/datatype-character/).

Long waits end early when a hold is wanted (`core.holdWanted()`), so the
hold starts promptly:

| Wait | What happens |
|---|---|
| Meditating for mana | Ends; the cast counts as retryable. |
| MQ2Cast working | The spell in the air finishes. If MQ2Cast is about to retry, `/interrupt` cancels the retry; counts as retryable. |
| Waiting for a trade accept (combat only) | Trade cancelled, items come back, reason `combat`; no try is used. |

## How busy members work

`serveMembers` in `init.lua` keeps a queue of `{ m, tries, notBefore }`.
Each pass runs the checkpoint, takes the first entry whose `notBefore` has
passed, and tries it.

| Trade reason | From | What happens |
|---|---|---|
| `ok` | delivery.giveItems | Recorded and reported. |
| `combat` | delivery (caster attacked) | Back of the queue, no try used. The next checkpoint holds. |
| `busy` | The link says fighting, or trade not opened or not accepted | Try +1, back of the queue for `busyRetrySec`. |
| `range` | Could not walk into range | Same as busy. |
| `failed` | Caster side problem (target, pickup) | Same as busy. |

After `busyTries` tries the member is given up on, noted as "busy, gave
up" and listed in chat at the end.

## How the link to other boxes works

The link is chosen with `acceptMethod`: `mqremote` (default), `dannet`,
`eqbc` or `none` (Manual).

MQRemote sends commands with `/rc server <Name> <command>` (the
[MQRemote docs](https://www.redguides.com/docs/projects/mqremote/)). It has
no documented way to read a value from another box, so a question is a
round trip:

```
caster:  /noparse /rc server Tank /rc server Cleric /provisions pong 7
             ${Me.CleanName} ${Me.CombatState} ${FindItemCount[=bread]} ${FindItemCount[=water]}
Tank:    receives "/rc server Cleric /provisions pong 7 ${...}", fills in its own
         values, sends it on
caster:  /provisions pong 7 Tank ACTIVE 5 3   ->  delivery.onPong stores it
```

`/noparse` stops the caster filling in the `${}` values itself; the MQRemote
docs show this pattern for having the receiving client parse them. The
number (7 here) is a token, so a late answer to an older question is never
taken for the current one. Only the caster runs Provisions; the others need
only the MQRemote plugin.

`linkCheck` in `init.lua` runs this before any summoning. First
`delivery.ensureLink` loads the plugin on the caster with
`/plugin <name> load` if it is missing. Members who do not answer are sent
the same load command through another link that is up here (DanNet, then
EQBC) by `delivery.loadOnOthers`, and asked again after `LOAD_WAIT_MS`.
Members who still do not answer are left out of the job with the note
"no MQRemote".

Picking a link in Options calls `core.requestLinkLoad`. The window may not
wait, so this only sets `job.linkLoadRequested`; `tick` then runs
`loadLinkNow`, which calls `ensureLink`. Startup sets the same flag.

DanNet queries use `/dquery peer -q "query"`, then wait on
`DanNet(peer).Q(query).Received`. The MQ2Dan
[README](https://github.com/dannuic/MQ2Dan/blob/master/README.md) documents
that a new `/dquery` clears the stored answer, so a stale reply is never
read.

## How fizzles are handled

The summon loop's goal is an item count, not a cast count. It casts until
the bags hold the target number, however many fizzles that takes.

| Kind | Examples | What happens |
|---|---|---|
| Retryable | Fizzle, interrupt, gem not ready (`RETRYABLE_RESULTS`, or a fizzle seen in chat), a hold | Cast again. Never counts toward giving up. |
| Fatal | Stunned, missing component (`FATAL_RESULTS`) | Stop summoning at once, reason in red. |
| Other | Mana wait timed out, cursor stuck | 3 in a row stops summoning (`OTHER_FAILURE_LIMIT`). |

The only limit on fizzles is the summon time limit (`summonTimeoutMin`,
default 20 minutes, 0 = none). Fizzles and interrupts are counted from chat
with `mq.event` (patterns in `EVENTS` in `casting.lua`) and shown live.

## Where each setting is used

| Setting | Read in |
|---|---|
| `foodCount`, `drinkCount` | init.planNeeds, ui.drawCounts, ui.resultText |
| `foodSpell`, `drinkSpell` | casting.detect, ui.spellPicker |
| `foodItem`, `drinkItem` | init, casting.castOnce (learned here), ui |
| `gem`, `restoreGem` | casting.memorize, castWithMQ2Cast, casting.restore |
| `useMQ2Cast`, `castMaxTries` | casting.beginJob, usingMQ2Cast, castWithMQ2Cast |
| `summonTimeoutMin` | casting.summonUntil |
| `medForMana`, `medTimeoutSec` | casting.waitForMana |
| `preserveOwnStock`, `topUp` | init.planNeeds |
| `loadOnOtherBoxes` | init.linkCheck, ui.drawOptions |
| `acceptMethod` | delivery.linkReady, ensureLink, loadOnOthers, remote, probe, init.linkCheck, loadLinkNow, ui.drawOptions |
| `tradeTimeoutSec` | delivery.waitForAccept |
| `tradeRange`, `useNav`, `navTimeoutSec` | delivery.moveInRange, ui.drawRoster |
| `pauseRGMercs` | init.run |
| `combatHold` | core.holdWanted, init.checkpoint, delivery.waitForAccept |
| `combatHandBack`, `combatSettleSec` | init.checkpoint |
| `busyTries`, `busyRetrySec` | init.serveMembers |
| `selected` | core.isSelected, core.setSelected |
| `debug` | core.debug |

## Common changes

| I want to | Edit |
|---|---|
| Add a new spell name | `FOOD_SPELLS` or `DRINK_SPELLS` in `casting.lua`, best first. It then appears in the Options drop down for characters who have it scribed |
| Change the spell drop downs | `spellPicker` in `ui.lua`; the list comes from `casting.choices`, filled by `casting.detect` |
| Add a new option | `core.DEFAULTS` (plus a clamp in `core.load` for numbers), then a control in `ui.drawOptions` |
| Add a slash command | `onCommand` and `printHelp` in `init.lua`, README table |
| Change the RGMercs commands | `run`, `checkpoint` and `cleanup` in `init.lua` |
| Change what counts as combat | `core.inCombat` |
| Add a hold reason | `checkpoint` in `init.lua`, and `core.holdWanted` if long waits should end for it |
| Add a link method | `LINKS`, `sendVia` and `delivery.probe` in `delivery.lua` (and the helper order in `loadOnOthers`), radio button in `ui.drawOptions` |
| Change how long other boxes get to load MQRemote | `LOAD_WAIT_MS` in `init.lua` |
| Fix partial stack pickup | `delivery.pickUp`, check names with `/windows` |
| Treat another cast result as hopeless | `FATAL_RESULTS` in `casting.lua` |
| Treat another cast result as "just cast again" | `RETRYABLE_RESULTS` in `casting.lua` |
| Fizzle message worded differently on a server | `EVENTS` in `casting.lua` |

## Documentation standard

Every Lua file follows the same layout so any file reads the same way:

1. **Header block** at the top: FILE, PACKAGE, VERSION, CHANGES (newest
   first), then WHAT, WHY, WHERE, HOW and WHEN for the file, then a READING
   GUIDE that explains game and MacroQuest terms used in the file.
2. **Module variables** each have a short block: WHAT, WHY, WHERE, HOW, WHEN.
3. **Every function** has a doc block above it with WHAT (what it does and
   returns), WHY (the reason it exists), WHERE (who calls it), HOW (the
   steps) and WHEN (at what point it runs). Small helpers that share a
   block with a sibling carry a one line comment directly above.
4. **Every line of code** has a comment at the end of the line or within the
   three lines above it.
5. **Footer block** at the bottom: END OF FILE, a summary of the public
   functions, dependencies, and HOW TO EDIT SAFELY notes.

Markdown files carry a short HTML comment header and footer with the same
labels. `dev/doc_audit.py` checks all of the Lua rules.

## Making a change: checklist

1. Make the code change.
2. Comment every new or changed line, and update the doc block of every
   function you touched (especially WHERE if callers changed).
3. Add an entry at the top of CHANGELOG.md with the new version number.
4. In every .lua file: set VERSION to the new number and add a CHANGES line
   (describe the change, or "No change in this file").
5. Update this file if the flow, a setting, or a file's job changed, and
   README.md if anything the operator sees changed.
6. Run `python dev/doc_audit.py` and fix anything it reports.
7. Run `python dev/smoke_test.py` and make sure all scenarios pass.
8. Test in game with Debug trace on, and on someone else's setup too.
9. Check the RedGuides resource rules and REDGUIDES.md still hold.
10. Commit with a message that starts with the version, for example
   `2.0.1: fix busy retry timing`, and push to GitHub.

## Glossary

| Term | Meaning |
|---|---|
| TLO | Top Level Object. MacroQuest's way to read game data, e.g. `mq.TLO.Me.CurrentMana()` |
| Gem | A spell bar slot |
| Cursor | The item held on the mouse pointer |
| Yield | Hand control back to MacroQuest briefly with `mq.delay` |
| Job | One Hand Out, start to cleanup |
| Checkpoint | A safe point before a cast or trade where a hold may start |
| Hold | Waiting at a checkpoint: Paused or Combat hold |
| Hand back | Unpausing RGMercs during a Combat hold so it can fight |
| Busy | A member who could not be traded right now |
| Drop | One stack placed into one trade slot |
| Plan | The list of drops for one member |
| Reserve | Stock the caster keeps and never trades away |
| Peer | A box on DanNet, addressed by lower case name |
| Link | How commands reach other boxes: MQRemote, DanNet, EQBC or Manual |
| Pong | The answer a box sends back over MQRemote: `/provisions pong token name combat food drink` |

<!--
  END OF FILE : provisions/ARCHITECTURE.md
-->
