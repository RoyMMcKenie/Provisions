<!--
  FILE    : provisions/README.md
  PACKAGE : Provisions Lua (MacroQuest / EverQuest)
  VERSION : 2.3.2
  WHAT    : Install, use and troubleshooting guide for the package.
  WHY     : So the package can be set up and tuned without reading the code.
  WHERE   : Lives beside init.lua in <MacroQuest>/lua/provisions/.
  WHEN    : Read before first run and when something misbehaves.
-->

# Provisions

A MacroQuest Lua package for any class that can summon food and drink
(Cleric, Druid, Shaman, Magician, Beastlord). It summons food and drink and
trades it to group members picked from a checkbox list, with separate food
and drink counts. It keeps casting through fizzles until it has enough,
holds when you are attacked, and comes back later for members who are busy
fighting.

Formerly ClericFood. Existing ClericFood settings are imported the first
time Provisions runs.

## Install

The package must sit in a folder named `provisions` inside your MacroQuest
`lua` directory.

With git, from the MacroQuest `lua` directory:

```
git clone https://github.com/RoyMMcKenie/Provisions.git provisions
```

Without git: on the GitHub page choose Code, then Download ZIP, unzip it,
and rename the folder from `Provisions-main` to `provisions`.

If you had ClericFood installed, you can delete the old `lua/clericfood`
folder after the first run.

The finished layout:

```
<MacroQuest>/lua/provisions/
    init.lua       entry point, job runner, Pause and Combat Hold, /provisions
    core.lua       chat output, settings, group roster, shared job flags
    casting.lua    spell detection and the summon loop (MQ2Cast)
    delivery.lua   bag handling, trading, link to other boxes
    ui.lua         the window
    README.md   ARCHITECTURE.md   CHANGELOG.md   LICENSE   REDGUIDES.md
```

For maintenance, start with ARCHITECTURE.md. It maps every file, shows the
full flow of a hand out, lists where each setting is used, and has recipes
for common changes. Every Lua file also carries a reading guide in its
header, a doc block on every function, a comment on every line of code, and
a "how to edit safely" section in its footer. The maintainer's PC test
tools (a documentation audit and an offline smoke test) are kept outside the
release, so the zip carries only what the game and its reader need.
REDGUIDES.md is the RedGuides guide for writing and publishing MacroQuest Lua.

Every file requires its siblings as `provisions.<name>`, so the folder name
matters.

### Plugins

| Plugin | Needed for | Required |
|---|---|---|
| MQRemote | Default link: receiving box presses Trade, link check, Top up counts, busy member check. Load on every character. | Recommended |
| MQ2DanNet | Alternative link with the same features | Optional |
| MQ2EQBC | Alternative link, pressing Trade only | Optional |
| MQ2Cast | Casting with automatic fizzle and interrupt retries | Recommended |
| MQ2Nav | Walking into trade range | Optional |
| RGMercs | Paused during the hand out, handed back during a fight | Optional |

Casting goes through MQ2Cast (`/casting "spell|gem8" -maxtries|5`), which
recasts on fizzles and interrupts and reports the reason in `Cast.Result`.
If MQ2Cast is not loaded the script loads it for the job and unloads it
after. If it cannot be loaded, or the option is turned off, plain `/cast`
is used.

### Link to other boxes (MQRemote)

Only the caster runs Provisions. The other characters only need MQRemote
loaded.

Provisions loads it for you where it can:

- On the caster: when you pick MQRemote under Options, when the script
  starts, and before every hand out or link check.
- On the other characters, only if you turn on "Load the link plugin on
  other boxes" in Options (off by default): if one does not answer and
  DanNet (or EQBC) is loaded on the caster, Provisions sends
  `/plugin MQRemote load` to that character through it, waits 4 seconds and
  asks again.

Provisions downloads nothing and talks to no outside server. Everything goes
through the MacroQuest plugins named above.

`/plugin MQRemote load` also tells MacroQuest to load it by itself next
session. If a character has no other link either, type this once there:

```
/plugin MQRemote load
```

Provisions sends commands with `/rc server <Name> <command>`. MQRemote can
send commands but cannot read values back, so to ask a box a question the
caster sends a command that makes that box send `/provisions pong ...` back,
with its own combat state and item counts filled in.

Before every hand out Provisions checks the link:

- If MQRemote is not loaded on the caster it is loaded. If that fails, it
  stops before casting and tells you what to type.
- Every ticked member must answer. Anyone who does not is left out, shown
  in red as "no MQRemote", and named in chat.

Press Check links (or type `/provisions check`) to run the same check without
summoning anything. Each member shows what it carries.

DanNet still works: pick DanNet under Options. The check then also looks
at the DanNet peer list. If a VPN is running, DanNet may pick the VPN
network; `/dnet interface` shows which one it uses.

## Run

```
/lua run provisions
```

1. Set Food each and Drink each (0 to 80, or use the 5 / 10 / 20 buttons).
2. Tick the members to feed. Tick your own row to keep a set for yourself.
3. Press Hand Out.

The caster memorises the summon spells into the borrowed gem if needed,
casts until it carries enough for everyone, then walks to and trades each
ticked member in turn. The receiving box is told to press Trade through
MQRemote (or DanNet or EQBC). When finished it restores the borrowed gem and unpauses
RGMercs.

### Pause

Pause holds the job at the next safe point: before the next cast or the
next trade. A spell already being cast and a trade already open always
finish first. RGMercs stays paused while you are paused. Press Resume to
carry on exactly where it stopped. Time spent paused does not count against
the summon time limit.

### Combat Hold

You cannot hand anything out while being attacked, and a summon spell
would only be interrupted. With Combat Hold on (the default), whenever you
are in combat the job holds:

1. An open trade is cancelled and the items come back to your bags.
2. RGMercs is unpaused so it can fight and heal.
3. When the fight has been over for the settle time (5 seconds), RGMercs is
   paused again and the job carries on.

If you pressed Pause during the fight, the job stays paused afterwards with
RGMercs paused.

### Busy members

A member who is fighting will not open a trade window. Before each trade
Provisions asks the member through MQRemote (or DanNet) whether it is in
combat. A member
who is in combat, or whose trade does not open or is not accepted, goes to
the back of the line and is tried again after 10 seconds. After 3 tries
that member is given up on, shown in red as "busy, gave up" and listed in
chat. Press Hand Out again later to serve them.

## Commands

| Command | Action |
|---|---|
| `/provisions` | Toggle the window |
| `/provisions go` | Hand out with current settings |
| `/provisions pause` | Hold at the next safe point |
| `/provisions resume` | Carry on after a pause |
| `/provisions stop` | Stop a running hand out |
| `/provisions all` | Tick every eligible member |
| `/provisions check` | Check the link to every ticked member, without summoning |
| `/provisions food N` | Set food per member |
| `/provisions drink N` | Set drink per member |
| `/provisions quit` | Save and end |
| `/provisions help` | List the commands |

`/provisions go` can be sent from another box: `/rc server Castername /provisions go`.
`/provisions pong` is used internally for answers from other boxes.

## Spells used

Detected from your spellbook, best first. Levels are from the
[Allakhazam spell database](https://everquest.allakhazam.com/db/spells?type=mag&level=1&opt=And+Higher).

| Spell | Makes | Class levels |
|---|---|---|
| Cornucopia | Food, a stack per cast | Magician 21 |
| Abundant Food | Food, several per cast | Cleric 33 |
| Summon Food | Food | Cleric 8, Druid 11, Shaman 6, Magician 1, Beastlord 29 |
| Everfount | Drink, a stack per cast | Magician 22 |
| Abundant Drink | Drink, several per cast | Cleric 28 |
| Summon Drink | Drink | Cleric 3, Druid 10, Shaman 2, Magician 1, Beastlord 17 |

Other classes see a warning and can pick "Type your own..." in the Food
spell or Drink spell drop down in Options and enter a server's own spell. The item each spell creates is learned from the
cursor after the first cast.

## Options

| Option | Default | Meaning |
|---|---|---|
| Talk to other boxes via | MQRemote | MQRemote, DanNet, EQBC or Manual. EQBC can only press Trade. Manual means you or another script accepts. A choice saved by an older version is kept. |
| Load the link plugin on other boxes | Off | When a box does not answer, send it `/plugin <name> load` through DanNet or EQBC if one is up on the caster. |
| Top up only | Off | Ask each box its current count (MQRemote or DanNet) and give only the shortfall. |
| Keep my existing stock | On | Never hand out food already in your bags. |
| Pause RGMercs | On | `/rgl pause` during the job, only if RGMercs is running. |
| Walk with MQ2Nav | On | Walk into range when a member is too far. |
| Cast with MQ2Cast | On | Plugin handles fizzles and interrupts. |
| Meditate when out of mana | On | Sit and wait instead of failing a cast. |
| Restore borrowed gem | On | Put the original spell back afterwards. |
| Combat Hold | On | Hold the job while you are in combat. |
| Hand back to RGMercs during combat | On | Unpause RGMercs during the fight, pause it again afterwards. |
| Combat settle | 5 s | Quiet time after a fight before carrying on (0 to 60). |
| Busy tries | 3 | Attempts per busy member before giving up (1 to 10). |
| Busy retry | 10 s | Wait before trying a busy member again (2 to 120). |
| Spell gem | 8 | Gem used when a summon spell is not memorised. |
| Max tries per cast | 5 | MQ2Cast `-maxtries` for one `/casting` call. Fizzles past this are fine; the script casts again. |
| Summon time limit | 20 min | Summoning keeps going through any number of fizzles until the count is reached. This is only a safety net, and time held does not count. 0 = no limit. |
| Trade range | 15 | Units. EQ allows about 20. |
| Accept timeout | 12 s | Trade is cancelled if not accepted in time. |
| Walk timeout | 30 s | Longest walk to one member. |
| Meditate timeout | 120 s | Longest wait for mana per cast. |
| Food spell / Drink spell | Auto | Drop down. "Type your own..." (top) opens a box for any spell name, with a note saying whether it is in your book. "Auto" uses the best spell you have scribed. Below that, every known summon spell in this character's book. A typed name that is not scribed is ignored and Auto is used. |
| Food item / Drink item name | Learned | The item each spell creates. Filled in after the first cast. |

Settings save per server and character to
`<MacroQuest>/config/provisions_<server>_<name>.lua`.

## Troubleshooting

Turn on Debug trace in Options. Every command sent is echoed in chat.

| Symptom | Likely cause |
|---|---|
| Partial counts lift the whole stack | QuantityWnd control names differ on your client. Check `QTYW_slider` and `QTYW_Accept_Button` with `/windows`. |
| Item stays on cursor at the target | Out of range or line of sight, or the member is fighting. It will be tried again. |
| "MQRemote could not be loaded" | Type `/plugin MQRemote load` on the caster and read the MacroQuest message. The plugin file may be missing from your MacroQuest build. |
| A member shows "no MQRemote" | MQRemote is not loaded on that character (and was not loaded through DanNet, which needs the "Load the link plugin on other boxes" option), or the character is on another server. Type `/plugin MQRemote load` there, then press Check links. |
| Quick manual link test | On the caster type `/rc server Name /sit`. The other character should sit. |
| A member shows "no DanNet" | That character is missing from `${DanNet.Peers}`. Check `/dnet interface` on both; a VPN can move DanNet to the wrong network. |
| Trade times out | The receiver did not get the accept command. Press Check links. |
| A member always shows "busy, gave up" | The link reports them in combat, or their client never accepts. |
| Job sits on "Combat hold" | You are still in combat or have mobs on your extended target window. |
| Top up gives full amount | The box did not report its counts, so the full count is used. Press Check links. |
| Summoning is slow and fizzles a lot | Low Conjuration skill. It will still finish; each fizzle also gives a chance to raise the skill. Watch the progress line. |
| Summoning stops with a reason in red | MQ2Cast reported something retries cannot fix, such as stunned or missing component. |
| "No free bag slot" | Bags full with no partial stack to grow. |

## License

MIT. See LICENSE. Use, change and share it freely; keep the copyright notice.

<!--
  END OF FILE : provisions/README.md
-->
