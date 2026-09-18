# Forever Mouse Tooltip

A tiny WoW addon that anchors the default game tooltip to the mouse cursor
instead of Blizzard's default lower-right corner. Built for **WoW Forever**
(the Classic beta, client flavor `wow_classic_beta`, version `1.60.x`),
which doesn't offer this as a built-in option.

## How it works

Blizzard's FrameXML routes almost all "default position" tooltips (action
bars, bags, character panel, quest log, merchant frame, etc.) through a
shared helper function, `GameTooltip_SetDefaultAnchor(tooltip, parent)`.
This addon replaces that function with one that anchors the tooltip to
`ANCHOR_CURSOR` instead, and adds a safety-net hook via `hooksecurefunc` on
`GameTooltip:SetOwner` to catch any tooltip that sets an explicit
bottom/top-right anchor directly, bypassing the shared helper.

Tooltips deliberately anchored elsewhere on purpose (comparison tooltips,
shopping tooltips, static minimap tooltips, etc.) are left untouched.

## Install

Copy (or symlink) this folder into:

```
World of Warcraft/_classic_beta_/Interface/AddOns/ForeverMouseTooltip
```

## Usage

- `/fmt on` — enable cursor-anchored tooltips (default).
- `/fmt off` — restore Blizzard's default tooltip position.
- `/fmt offset <x> <y>` — adjust the pixel offset from the cursor (default `12 -12`).

## Icon

`icon.png` (256x256, referenced via `## IconTexture` in the TOC) is shown
next to the addon's name in the in-game AddOns list, if the client's AddOns
UI supports the `IconTexture` field. Source SVG lives in `assets/icon.svg`.

## Notes on the `## Interface:` version

The TOC `## Interface:` number (`11701`) was read directly from strings in
the installed `WowB.exe` for this beta build. Classic-flavored clients
change their interface number with content patches, so if the addon shows
as "out of date" after a client update, bump this value — in-game, run:

```
/run print(select(4, GetBuildInfo()))
```

and update `ForeverMouseTooltip.toc` accordingly.

## A note on Forever's addon restrictions

Forever inherits Midnight's addon restrictions, which block *combat
automation* (auto target-marking, auto raid assignments, real-time
mechanic-solving, automated WeakAuras-style responses) so player skill
decides fights rather than addon automation. Pure UI/customization addons
(unit frames, action bar skins, tooltip positioning, etc.) are unaffected.
This addon only repositions the default `GameTooltip`/`ItemRefTooltip`
frames — it reads no combat state and makes no decisions — so it falls
in the unrestricted "customization" category.
