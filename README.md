# Forever Mouse Tooltip

A tiny WoW addon that anchors the default game tooltip to the mouse cursor
instead of Blizzard's default lower-right corner. Built for **WoW Forever**
(the Classic beta, client flavor `wow_classic_beta`, version `1.60.x`).

Other WoW versions (retail, and some other Classic clients) have long had a
"Show tooltips at cursor" option in the Interface options. This beta client
doesn't expose that yet, so this addon replicates it.

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

## Notes on the `## Interface:` version

The TOC `## Interface:` number (`11701`) was read directly from strings in
the installed `WowB.exe` for this beta build. Classic-flavored clients
change their interface number with content patches, so if the addon shows
as "out of date" after a client update, bump this value — in-game, run:

```
/run print(select(4, GetBuildInfo()))
```

and update `ForeverMouseTooltip.toc` accordingly.

## Status

Not yet pushed anywhere — local development only for now.
