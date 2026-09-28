# Changelog

All notable changes to this addon are documented here.
Format loosely follows [Keep a Changelog](https://keepachangelog.com/).

## [Unreleased]

## [0.2.0] - 2026-09-28
### Added
- Graphical options panel under Escape -> Options -> AddOns -> Forever
  Mouse Tooltip (via the modern `Settings` API), with checkboxes/sliders
  for Enable, Disable in Combat, and the X/Y cursor offset.
- "Disable in Combat" option: keeps Blizzard's default tooltip position
  while `InCombatLockdown()` is true instead of following the cursor.
- `/fmt combat on|off` and `/fmt options` slash commands.

## [0.1.2] - 2026-09-18
### Fixed
- **Critical**: replaced the direct `GameTooltip_SetDefaultAnchor`
  reassignment with `hooksecurefunc`. Reassigning the global tainted it,
  and every later caller of that global — including unrelated Blizzard
  code such as party/raid frame health updates — inherited the taint,
  which crashed on Forever's new "secret value" protections (health-bar
  color comparisons in `CompactUnitFrame.lua`). `hooksecurefunc` runs
  after Blizzard's own untainted call instead, so the global is never
  contaminated. `/fmt off` now just makes the hook a no-op (hooks can't
  be removed) instead of trying to restore the original function.
### Changed
- Confirmed `## Interface:` version in-game: `16001` (client build
  `1.60.1.69913`), replacing the earlier best-guess value read from
  binary strings.

### Fixed
- Removed the overly-broad `SetOwner` safety-net hook that forced
  `ANCHOR_CURSOR` on any tooltip using `ANCHOR_NONE`/`ANCHOR_BOTTOMRIGHT`/
  `ANCHOR_TOPRIGHT`. That could clobber tooltips deliberately positioned
  elsewhere by other UI code. The addon now only overrides
  `GameTooltip_SetDefaultAnchor`, which is the one path Blizzard itself
  uses for "default corner" tooltips.


## [0.1.0] - 2026-09-17
### Added
- Initial release: anchors the default `GameTooltip` to the mouse cursor
  instead of Blizzard's default lower-right corner, targeting WoW Forever
  (Classic beta, `wow_classic_beta` flavor, client version 1.60.x).
- `hooksecurefunc` safety net for tooltips that set an explicit
  bottom/top-right anchor directly.
- `/fmt on|off|offset <x> <y>` slash command.
