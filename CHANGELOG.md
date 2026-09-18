# Changelog

All notable changes to this addon are documented here.
Format loosely follows [Keep a Changelog](https://keepachangelog.com/).

## [Unreleased]
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
