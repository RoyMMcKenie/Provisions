<!--
  FILE    : clericfood/CHANGELOG.md
  PACKAGE : ClericFood Lua (MacroQuest / EverQuest)
  WHAT    : Version history of the package.
  WHY     : Explains when and why each behaviour was added.
  WHERE   : Beside init.lua.
  WHEN    : Add an entry with every change, newest at the top. Then update
            the VERSION line and CHANGES block in every .lua file to match
            (dev/doc_audit.py checks this).
-->

# Changelog

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
  END OF FILE : clericfood/CHANGELOG.md
-->
