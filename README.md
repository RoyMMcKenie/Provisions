<!--
  FILE    : clericfood/README.md
  PACKAGE : ClericFood Lua (MacroQuest / EverQuest)
  VERSION : 1.3.1
  WHAT    : Install, use and troubleshooting guide for the package.
  WHY     : So the package can be set up and tuned without reading the code.
  WHERE   : Lives beside init.lua in <MacroQuest>/lua/clericfood/.
  WHEN    : Read before first run and when something misbehaves.
-->

# ClericFood

A MacroQuest Lua package that lets a cleric summon food and drink and trade it
to group members picked from a checkbox list, with separate food and drink
counts.

## Install

Copy the folder, named exactly `clericfood`, into your MacroQuest `lua`
directory:

```
<MacroQuest>/lua/clericfood/
    init.lua      ui.lua       actions.lua
    spells.lua    trade.lua    inventory.lua
    group.lua     config.lua   utils.lua
    README.md     ARCHITECTURE.md   CHANGELOG.md
    dev/doc_audit.py    dev/smoke_test.py     (PC tools, not used in game)
```

For maintenance, start with ARCHITECTURE.md. It maps every file, shows the
full flow of a hand out, lists where each setting is used, and has recipes
for common changes. Every Lua file also carries a reading guide in its
header, a doc block on every function, a comment on every line of code, and
a "how to edit safely" section in its footer. After any edit, run
`python dev/doc_audit.py` to confirm nothing is undocumented and
`python dev/smoke_test.py` to test the logic without logging in.

Every module requires its siblings as `clericfood.<name>`, so the folder name
matters.

### Plugins

| Plugin | Needed for | Required |
|---|---|---|
| MQ2DanNet | Receiving box presses Trade, Top up counts | Recommended |
| MQ2EQBC | Alternative to DanNet for accepting | Optional |
| MQ2Cast | Casting with automatic fizzle and interrupt retries | Recommended |
| MQ2Nav | Walking into trade range | Optional |

Casting goes through MQ2Cast (`/casting "spell|gem8" -maxtries|5`), which
recasts on fizzles and interrupts and reports the reason in `Cast.Result`. If
MQ2Cast is not loaded the script loads it for the job and unloads it after.
If it cannot be loaded, or the option is turned off, plain `/cast` is used.

## Run

```
/lua run clericfood
```

1. Set Food each and Drink each (0 to 80, or use the 5 / 10 / 20 buttons).
2. Tick the members to feed. Tick your own row to keep a set for yourself.
3. Press Hand Out.

The cleric memorises the summon spells into the borrowed gem if needed, casts
until it carries enough for everyone, then walks to and trades each ticked
member in turn. The receiving box is told to press Trade through DanNet or
EQBC. When finished it restores the borrowed gem and unpauses RGMercs.

## Commands

| Command | Action |
|---|---|
| `/cfood` | Toggle the window |
| `/cfood go` | Hand out with current settings |
| `/cfood stop` | Stop a running hand out |
| `/cfood all` | Tick every eligible member |
| `/cfood food N` | Set food per member |
| `/cfood drink N` | Set drink per member |
| `/cfood quit` | Save and end |

`/cfood go` can be sent from another box: `/dex clericname /cfood go`.

## Spells used

Detected from your spellbook, best first:

| Type | Spells |
|---|---|
| Food | Abundant Food, Summon Food (cleric 8) |
| Drink | Abundant Drink, Summon Drink (cleric 3) |

Use the override boxes in Options for any other spell name. The item each
spell creates is learned from the cursor after the first cast.

## Options

| Option | Default | Meaning |
|---|---|---|
| Receiver accepts via | DanNet | How the other box presses Trade. Manual means you or another script accepts. |
| Top up only | Off | Ask each box its current count with DanNet and give only the shortfall. |
| Keep my existing stock | On | Never hand out food already in the cleric's bags. |
| Pause RGMercs | On | `/rgl pause` during the job, only if RGMercs is running. |
| Walk with MQ2Nav | On | Walk into range when a member is too far. |
| Cast with MQ2Cast | On | Plugin handles fizzles and interrupts. |
| Max tries per cast | 5 | MQ2Cast `-maxtries` for one `/casting` call. Fizzles past this are fine; the script casts again. |
| Summon time limit | 20 min | Summoning keeps going through any number of fizzles until the count is reached. This is only a safety net. 0 = no limit. |
| Meditate when out of mana | On | Sit and wait instead of failing a cast. |
| Restore borrowed gem | On | Put the original spell back afterwards. |
| Spell gem | 8 | Gem used when a summon spell is not memorised. |
| Trade range | 15 | Units. EQ allows about 20. |
| Accept timeout | 12 s | Trade is cancelled if not accepted in time. |

Settings save per server and character to
`<MacroQuest>/config/clericfood_<server>_<name>.lua`.

## Troubleshooting

Turn on Debug trace in Options. Every command sent is echoed in chat.

| Symptom | Likely cause |
|---|---|
| Partial counts lift the whole stack | QuantityWnd control names differ on your client. Check `QTYW_slider` and `QTYW_Accept_Button` with `/windows`. |
| Item stays on cursor at the target | Out of range or line of sight. Lower Trade range or enable MQ2Nav. |
| Trade times out | Receiver is not on DanNet under that name, or a different accept method is needed. |
| Top up gives full amount | The box did not answer the DanNet query in 2 seconds, so the full count is used. |
| Summoning is slow and fizzles a lot | Low Conjuration skill. It will still finish; each fizzle also gives a chance to raise the skill. Watch the progress line. |
| Summoning stops with a reason in red | MQ2Cast reported something retries cannot fix, such as stunned or missing component. |
| "No free bag slot" | Bags full with no partial stack to grow. |

<!--
  END OF FILE : clericfood/README.md
-->
