# Forever Mouse Tooltip

A tiny WoW addon that anchors the default game tooltip to the mouse cursor
for things in the world, and next to the hovered element for HUD tooltips,
instead of Blizzard's default lower-right corner. Built for **WoW Forever**
(the Classic beta, client flavor `wow_classic_beta`, version `1.60.x`),
which doesn't offer this as a built-in option.

## How it works

Blizzard's FrameXML routes almost all "default position" tooltips (action
bars, bags, character panel, quest log, merchant frame, etc.) through a
shared helper function, `GameTooltip_SetDefaultAnchor(tooltip, parent)`.
This addon uses `hooksecurefunc` to run *after* that helper and re-anchor
the tooltip. World tooltips (mobs, players, NPCs, mailboxes, signposts —
anything owned by `UIParent`/`WorldFrame`) go to the cursor, using
Blizzard's own native `ANCHOR_CURSOR` / `ANCHOR_CURSOR_LEFT` /
`ANCHOR_CURSOR_RIGHT` anchor types (applied via
`SetAnchorType`, never `SetOwner`). This gives continuous, zero-lag cursor
tracking straight from the engine with no per-frame Lua involvement — an
earlier manual `SetPoint`-based implementation was found (through testing)
to interfere with GameTooltip's own internal fade timer, causing unit
tooltips to visibly "stick" for about a second after the mouse moved away
before fading out.

HUD tooltips (action buttons, unit frames, buffs, micro menu, etc.) are
anchored next to the hovered element instead, on the side facing the
middle of the screen — the same way Blizzard's default bag tooltips
behave. Many HUD frames (unit frames especially) are much bigger than
their visible art, so the addon measures the frame's visible textures and
anchors to those rather than the padded frame rectangle. Health bar fills
and health text are secret values on Forever, so bars are measured by their
outer frame and text is ignored. The result is cached while hovering,
since Blizzard re-anchors hovered unit frames and action buttons about
every 0.2s.

It intentionally does **not** reassign the global function directly.
Forever taints the global itself when an addon replaces it, and every
later caller — including unrelated Blizzard code such as party/raid frame
updates — inherits that taint for its whole call chain, which then trips
Forever's new "secret value" protections (e.g. health-bar color
comparisons throwing errors). `hooksecurefunc` runs strictly after
Blizzard's own untainted call, so the original global is never
contaminated.

Tooltips deliberately anchored elsewhere on purpose (bag items, comparison
tooltips, contextual anchors next to a specific button, static minimap
tooltips, etc.) are left untouched — they don't go through the shared
helper, and there's no reliable way to tell "the default corner tooltip"
apart from an intentionally custom-positioned one just from the anchor
type, so this addon doesn't try to guess.

## Install

Copy (or symlink) this folder into:

```
World of Warcraft/_classic_beta_/Interface/AddOns/ForeverMouseTooltip
```

## Usage

- `/fmt on` — enable tooltip repositioning (default).
- `/fmt off` — restore Blizzard's default tooltip position.
- `/fmt offset <x> <y>` — adjust the pixel offset from the cursor for world tooltips (default `0 0`).
- `/fmt combat on|off` — while `on`, keep Blizzard's default tooltip position during combat (default `off`).
- `/fmt hud element|cursor|default` — where HUD tooltips go: next to the hovered element (default), following the cursor, or Blizzard's default position.
- `/fmt debug` — toggle a line in every tooltip describing how it was positioned (default off).
- `/fmt options` — open the graphical options panel (Escape -> Options -> AddOns -> Forever Mouse Tooltip). Also reachable directly from the Escape menu without the slash command.

The options panel additionally offers:
- **Pause Key** — hold Shift/Ctrl/Alt to temporarily keep the tooltip at
  Blizzard's default position.
- **HUD Element Tooltips** — next to element (default), follow cursor, or
  Blizzard default.
- **Cursor Anchor** — Default (Blizzard's own bottom-right-of-cursor
  anchor; can't be offset), Bottom Left, Bottom Right, or Bottom Center
  (calculated so the tooltip is visually centered under the cursor).
- **Tooltip Scale** — resize the tooltip (50%-200%).
- **Horizontal/Vertical Offset** — world tooltips only.
- **Extra Information** — optionally add NPC ID, Item ID, Spell ID, and/or
  faction lines to tooltips.
- **Show Placement Debug** — same as `/fmt debug`, for troubleshooting.

All of the above are also available as checkboxes/sliders in the options
panel, which reads and writes the same SavedVariables the slash commands
do.

## Icon

`icon.png` (256x256, referenced via `## IconTexture` in the TOC) is shown
next to the addon's name in the in-game AddOns list, if the client's AddOns
UI supports the `IconTexture` field. Source SVG lives in `assets/icon.svg`.

## Notes on the `## Interface:` version

The TOC `## Interface:` number (`16001`) was confirmed in-game via
`/run print(select(4, GetBuildInfo()))` on client build `1.60.1.69913`.
Classic-flavored clients bump this with content patches, so if the addon
shows as "out of date" after a client update, re-run that command and
update `ForeverMouseTooltip.toc` accordingly.

## A note on Forever's addon restrictions

Forever inherits Midnight's addon restrictions, which block *combat
automation* (auto target-marking, auto raid assignments, real-time
mechanic-solving, automated WeakAuras-style responses) so player skill
decides fights rather than addon automation. Pure UI/customization addons
(unit frames, action bar skins, tooltip positioning, etc.) are unaffected.
This addon only repositions the default `GameTooltip`/`ItemRefTooltip`
frames — it reads no combat state and makes no decisions — so it falls
in the unrestricted "customization" category.
