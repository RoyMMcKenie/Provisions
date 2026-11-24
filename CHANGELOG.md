<!--
  FILE    : provisions/CHANGELOG.md
  PACKAGE : Provisions Lua (MacroQuest / EverQuest)
  WHAT    : Version history of the package.
  WHY     : Explains when and why each behaviour was added.
  WHERE   : Beside init.lua.
  WHEN    : Add an entry with every change, newest at the top. Then update
            the VERSION line and CHANGES block in every .lua file to match
            (dev/doc_audit.py checks this).
-->

# Changelog

## 2.0.0 (2026-11-24)

Renamed from ClericFood to Provisions, because every class that summons
food and drink can use it.

Breaking changes

- Folder is now `provisions`. Run with `/lua run provisions`.
- Slash command is now `/prov` (was `/cfood`).
- Settings file is now `provisions_<server>_<name>.lua` in the MacroQuest
  config folder. An existing `clericfood_<server>_<name>.lua` is imported
  automatically the first time.
- The GitHub repository was renamed from ClericFood to Provisions. GitHub
  redirects the old address.

Consolidation from nine Lua files to five

- `core.lua` = utils + config + group, plus the shared job flags.
- `delivery.lua` = inventory + trade.
- `casting.lua` = spells.
- `init.lua` = init + actions.
- `ui.lua` stays.

New

- Pause / Resume button and `/prov pause`, `/prov resume`. The job holds at
  the next safe point (before a cast or a trade). A cast in the air or an
  open trade always finishes first. RGMercs stays paused while paused, and
  held time does not count against the summon time limit.
- Combat Hold (on by default). When the caster is in combat (Me.CombatState
  is COMBAT, or Me.XTHaterCount above 0), the job holds. An open trade is
  cancelled and the items come back. RGMercs is handed back (`/rgl unpause`)
  so it can fight and heal, then paused again once the fight has been over
  for the settle time (default 5 seconds).
- Busy members. A member who DanNet reports in combat, or whose trade does
  not open or is not accepted, moves to the back of the line and is tried
  again after 10 seconds, up to 3 tries. Members given up on are listed in
  chat and shown in red as "busy, gave up".
- All summoning classes: Cleric, Druid, Shaman, Magician and Beastlord.
  Magician Cornucopia and Everfount added to the spell lists. Other classes
  get a warning and can use the override boxes.
- New options: Combat Hold, Hand back to RGMercs during combat, Combat
  settle (s), Busy tries, Busy retry (s), Walk timeout (s).

Fixes

- DanNet queries wait on the Received timestamp, so a Top up count can no
  longer read the answer from a previous query.
- `/prov quit` during a job now stops the job cleanly first.

## 1.3.2 (2026-10-04)

- Prepared for GitHub at https://github.com/RoyMMcKenie/ClericFood.
- Added LICENSE (MIT).
- Added .gitignore (Python cache, zips, settings files, editor clutter).
- README: install by git clone or by downloading the zip from GitHub, and a
  License section.
- No code change.

## 1.3.1 (2026-10-04)

- Documentation audit. Every line of code in all nine Lua files now has a
  comment at the end of the line or within the three lines above it, on top
  of the existing file headers, function doc blocks and file footers.
- Every Lua file lists every package version in its CHANGES block, marked
  "No change in this file" where that applies, and all files carry VERSION
  1.3.1.
- Added dev/doc_audit.py, which checks the whole documentation standard and
  reports anything missing.
- Added dev/smoke_test.py, which runs the real code against a fake
  MacroQuest in four scenarios (normal, heavy fizzle, never lands, stunned).
- ARCHITECTURE.md gained a Documentation standard section and a checklist
  for making changes.
- No behaviour change in game.

## 1.3.0 (2026-10-04)

- Summoning keeps casting until the item count is reached. Fizzles and
  interrupts no longer count toward giving up, so a low Conjuration skill
  cannot end the hand out early.
- Failed casts are sorted into retryable, fatal and other. Only 3 "other"
  failures in a row (mana timeout, stuck cursor) stop the loop.
- New summon time limit option (default 20 minutes, 0 = no limit) as the
  only overall safety net.
- Fizzles and interrupts are counted from chat and shown live in the window:
  "Summoning food: 9 of 14   fizzles 6   interrupts 0".

## 1.2.0 (2026-10-04)

- Full documentation pass. Every file has inline comments in every function
  body, a reading guide in the header and a "how to edit safely" footer.
- Added ARCHITECTURE.md (module map, job flow, settings index, change recipes,
  glossary) and this changelog.
- No behaviour change.

## 1.1.0 (2026-10-04)

- Casting goes through MQ2Cast `/casting "spell|gemN" -maxtries|N`, which
  detects fizzles and interrupts and recasts on its own.
- MQ2Cast is loaded for the job if needed and unloaded afterwards if the
  package loaded it.
- Fatal results (missing component, stunned and others) stop summoning at
  once with the reason in red.
- New options: Cast with MQ2Cast, Max tries per cast. Window shows the last
  cast result.
- Plain `/cast` remains as a fallback.

## 1.0.0 (2026-10-03)

- First release: checkbox roster, food and drink counts, automatic spell
  detection, summon then trade, DanNet or EQBC remote accept, Top up mode,
  MQ2Nav walking, RGMercs pause, gem restore.

<!--
  END OF FILE : provisions/CHANGELOG.md
-->
