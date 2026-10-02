-- Forever Mouse Tooltip
-- Anchors tooltips to the mouse cursor instead of Blizzard's default
-- lower-right corner anchor, for the WoW Forever (Classic beta) client.
--
-- How it works:
-- Almost all of Blizzard's FrameXML calls a shared helper,
-- GameTooltip_SetDefaultAnchor(tooltip, parent), whenever it wants to show
-- a tooltip at the "default" position (action bars, bags, character panel,
-- quest log, merchant frame, etc). That helper normally does:
--     tooltip:SetOwner(parent, "ANCHOR_NONE")
--     tooltip:SetPoint("BOTTOMRIGHT", ...)
--
-- IMPORTANT: this must be done with hooksecurefunc, not by reassigning the
-- global. Forever (like Midnight) taints the *global function itself* when
-- an addon replaces it, and every later caller of that global -- including
-- unrelated Blizzard code such as party/raid frame updates -- inherits that
-- taint for its whole call chain. Once tainted, Blizzard's "secret value"
-- protections (e.g. health-bar color comparisons in CompactUnitFrame) throw
-- errors because tainted code isn't trusted to read/compare them. Using
-- hooksecurefunc instead runs our code strictly *after* Blizzard's own
-- untainted call, so the original global is never contaminated.
--
-- Frames that explicitly anchor tooltips elsewhere on purpose (e.g.
-- comparison tooltips, contextual anchors like ANCHOR_RIGHT/ANCHOR_TOP next
-- to a specific button, static minimap tooltips) are left alone on purpose:
-- there's no reliable way to tell "the default corner tooltip" apart from
-- "an intentionally custom-positioned one" from the anchor type alone, so
-- we don't try to guess and risk breaking deliberate placements.

local ADDON_NAME, ns = ...

local DEFAULTS = {
    -- Core positioning: uses Blizzard's native ANCHOR_CURSOR_LEFT/_RIGHT
    -- anchor types via SetOwner, which track the cursor continuously on
    -- the engine side with zero per-frame Lua involvement. We tried a
    -- fully custom 8-corner/edge system with manual SetPoint tracking
    -- instead (to support more placement choices), but any per-frame
    -- touching of GameTooltip -- even just reading it -- was found (via
    -- testing) to interfere with its own internal fade timer, causing
    -- unit tooltips to visibly "stick" for ~1s after the mouse left before
    -- fading. Native cursor anchors don't have that problem since we only
    -- call SetOwner/SetAnchorType once per tooltip show.
    cursorAnchorSide = "DEFAULT", -- which side of the cursor the tooltip appears on
    -- Offsets only take effect via SetAnchorType, not SetOwner's own
    -- offset params (those are documented to be ignored for cursor anchor
    -- types). Positive X moves right, positive Y moves up (Blizzard's own
    -- convention) -- so a negative Y here is "below the cursor".
    offsetX = 0,
    offsetY = 0,
    enabled = true,
    disableInCombat = false,

    -- New: extra info shown in tooltips. Off by default -- opt in via the
    -- options panel (Escape -> Options -> AddOns -> Forever Mouse Tooltip).
    showNpcId = false,
    showItemId = false,
    showSpellId = false,
    showFactionName = false,

    -- "NONE"/"SHIFT"/"CTRL"/"ALT" -- which modifier key (if any) pauses
    -- cursor-follow while held.
    pauseCursorModifier = "NONE",
    tooltipScale = 100, -- percent; 100 = no change from Blizzard's default size
}

local function GetSetting(key)
    -- ForeverMouseTooltipDB may briefly be nil before ADDON_LOADED has fired
    -- for this addon (SavedVariables aren't loaded until after all of our
    -- files have executed), so guard against that instead of erroring.
    local value = ForeverMouseTooltipDB and ForeverMouseTooltipDB[key]
    if value == nil then
        return DEFAULTS[key]
    end
    return value
end

local INFO_LINE_COLOR = { 0.6, 0.6, 0.6 }

-- Which function to check for each supported "pause cursor-follow" modifier
-- key. "NONE" means no modifier pauses it (the default).
local MODIFIER_KEY_CHECKS = {
    SHIFT = IsShiftKeyDown,
    CTRL = IsControlKeyDown,
    ALT = IsAltKeyDown,
}

-- Whether the cursor-follow behavior should apply right now, independent of
-- the "only unit tooltips" scoping (checked separately by callers).
local function ShouldFollowCursor()
    if not GetSetting("enabled") then
        return false
    end
    if GetSetting("disableInCombat") and InCombatLockdown() then
        return false
    end
    local isModifierDown = MODIFIER_KEY_CHECKS[GetSetting("pauseCursorModifier")]
    if isModifierDown and isModifierDown() then
        return false
    end
    return true
end

-- Native cursor-tracking anchor types. Blizzard's engine only provides
-- continuous (zero-lag, zero-delay) cursor tracking for these anchor
-- types -- anything else (e.g. full 8-corner/edge placement) requires
-- manually repositioning the tooltip ourselves every frame, which testing
-- confirmed interferes with GameTooltip's own internal fade timer and
-- reintroduces a ~1s "stuck" delay on unit tooltips after the mouse
-- leaves. Trading down from freely chosen corners/edges to these choices
-- is the price for keeping that native, delay-free tracking.
--
-- "CENTER" isn't a real Blizzard anchor type -- offsets were found (by
-- testing) to only actually take effect for ANCHOR_CURSOR_LEFT/_RIGHT, not
-- plain ANCHOR_CURSOR, on this client. We fake horizontal centering by
-- using ANCHOR_CURSOR_RIGHT (whose left edge anchors at the cursor) and
-- shifting it left by half the tooltip's own width -- see ApplyCursorAnchor.
local ANCHOR_TYPES = {
    DEFAULT = "ANCHOR_CURSOR", -- Blizzard's own default cursor anchor (bottom-right of cursor)
    RIGHT = "ANCHOR_CURSOR_RIGHT", -- tooltip appears to the right of the cursor
    LEFT = "ANCHOR_CURSOR_LEFT", -- tooltip appears to the left of the cursor
    CENTER = "ANCHOR_CURSOR_RIGHT", -- see comment above; offset is adjusted below
}

-- By the time any of our hooks run, Blizzard's own code has *always*
-- already called tooltip:SetOwner(...) -- either inside
-- GameTooltip_SetDefaultAnchor itself (for the "default corner" case: bags,
-- action bars, etc.) or natively for world-unit mouseover tooltips (which
-- bypass GameTooltip_SetDefaultAnchor entirely and call SetOwner directly,
-- which is also why switching mouseover from one unit straight to another
-- doesn't necessarily re-trigger our GameTooltip_SetDefaultAnchor hook).
-- That means we never need to call tooltip:SetOwner(...) ourselves at
-- all: SetAnchorType alone can change the anchor type and offset on an
-- already-owned tooltip, with no content-clearing side effect (unlike
-- SetOwner, which is effectively a hide/show cycle and was wiping out
-- Blizzard's own name/health/level lines whenever we called it a second
-- time from Handle*Tooltip to refine positioning after content was
-- added). This also fixes a related bug where switching mouseover
-- directly from one unit to another (e.g. NPC to player, with no gap in
-- between) could leave the tooltip "stuck" on the previous anchor,
-- because GameTooltip_SetDefaultAnchor -- our only previous trigger for
-- calling SetOwner -- doesn't reliably re-fire for that transition.
-- Calling SetAnchorType unconditionally every time, regardless of
-- whether anything changed, means there's no stale state to get stuck in.
local function ApplyCursorAnchor(tooltip)
    local side = GetSetting("cursorAnchorSide")
    local anchorType = ANCHOR_TYPES[side] or ANCHOR_TYPES.DEFAULT
    local offsetX = GetSetting("offsetX") or 0
    local offsetY = GetSetting("offsetY") or 0

    if side == "CENTER" then
        -- tooltip:GetWidth() is a plain read, not a risky call -- safe to
        -- use here. On the very first (tentative) call, before content is
        -- set, this may reflect a stale size from a previous tooltip; it
        -- gets corrected once Handle*Tooltip re-applies this after the
        -- real content (and width) is known.
        local width = tooltip:GetWidth() or 0
        offsetX = offsetX - (width / 2)
    end

    tooltip:SetAnchorType(anchorType, offsetX, offsetY)
end

local lastAppliedScale
local function ApplyScale(tooltip)
    -- Only called on tooltip-show and when the "Tooltip Scale" setting
    -- itself changes (see the slider's value-changed callback below) --
    -- not from a per-frame loop. SetScale forces a full layout
    -- recalculation, so it doesn't need to (and shouldn't) run every
    -- frame; a plain local cache (not a field written onto the tooltip)
    -- since we only ever touch GameTooltip itself.
    local scale = (GetSetting("tooltipScale") or 100) / 100
    if scale ~= lastAppliedScale then
        tooltip:SetScale(scale)
        lastAppliedScale = scale
    end
end

-- Tracks whether we last positioned this tooltip via the cursor anchor (as
-- opposed to Blizzard's own default), so RevertToDefaultAnchor knows
-- whether there's anything to actually undo. Reset on OnTooltipCleared.
local positionedByUs = false
local suppressDefaultAnchorHook = false

local function RevertToDefaultAnchor(tooltip)
    if not positionedByUs then
        return
    end
    -- GameTooltip_SetDefaultAnchor is hooked via hooksecurefunc, so calling
    -- it ourselves would normally re-trigger OnDefaultAnchor below;
    -- suppress that one reentrant call so we don't immediately undo our
    -- own revert. This is the one remaining case that still calls
    -- GameTooltip_SetDefaultAnchor (and therefore SetOwner) -- deliberately
    -- rare, since it only runs while paused (combat or the pause key held).
    suppressDefaultAnchorHook = true
    GameTooltip_SetDefaultAnchor(tooltip, tooltip:GetOwner())
    suppressDefaultAnchorHook = false
    positionedByUs = false
end

-- Repositions (or reverts) the tooltip based on current settings. Only
-- handles positioning -- scale is applied separately. Safe to call every
-- time (OnDefaultAnchor's tentative guess AND Handle*Tooltip's content-
-- aware correction) since ApplyCursorAnchor never touches SetOwner.
local function UpdateTooltipPosition(tooltip)
    if not ShouldFollowCursor() then
        RevertToDefaultAnchor(tooltip)
        return
    end
    ApplyCursorAnchor(tooltip)
    positionedByUs = true
end

-- Runs once per tooltip show (not every frame): applies the current scale
-- and gives positioning its first (tentative, since content type isn't
-- known yet) placement.
local function OnDefaultAnchor(tooltip, parent)
    if suppressDefaultAnchorHook then
        return
    end
    ApplyScale(tooltip)
    UpdateTooltipPosition(tooltip)
end

if type(GameTooltip_SetDefaultAnchor) == "function" then
    hooksecurefunc("GameTooltip_SetDefaultAnchor", OnDefaultAnchor)
end

-- ================= Extra info lines =================
-- On this client (the retail engine repointed at Classic-era content),
-- GameTooltip no longer reliably fires the old OnTooltipSetUnit/Item/Spell
-- scripts -- those were replaced in modern clients by TooltipDataProcessor,
-- which runs addon callbacks behind Blizzard's own taint barrier and is the
-- sanctioned extension point here. We prefer it when available and fall
-- back to the legacy HookScript approach (still pcall-guarded) for true
-- Classic-Era clients that lack TooltipDataProcessor entirely.
local USE_TOOLTIP_DATA_PROCESSOR = TooltipDataProcessor
    and TooltipDataProcessor.AddTooltipPostCall
    and Enum and Enum.TooltipDataType

local function RegisterTooltipHook(scriptType, handler)
    local ok = pcall(GameTooltip.HookScript, GameTooltip, scriptType, handler)
    if not ok then
        -- This client doesn't support this tooltip script type; the
        -- corresponding "Extra Information" option will simply have no
        -- effect instead of erroring.
    end
end

-- "CENTER" mode's offset depends on the tooltip's own width, which isn't
-- final yet when OnDefaultAnchor applies its first, tentative placement
-- (GameTooltip_SetDefaultAnchor fires before content is set). For unit/
-- item/spell tooltips, Handle*Tooltip above re-applies positioning once
-- content is known, correcting the offset. But plenty of tooltips never go
-- through those handlers (e.g. mailbox, auction house, bag slots without
-- an item, generic SetText tooltips) -- for those, the offset was staying
-- stuck at whatever the *previous* tooltip's width happened to be, which
-- could shove a small tooltip far off to one side if the prior tooltip was
-- large. OnSizeChanged fires whenever the tooltip's actual width changes
-- (not continuously, so no fade-delay risk) and lets us correct the CENTER
-- offset for every tooltip type uniformly.
RegisterTooltipHook("OnSizeChanged", function(self)
    if GetSetting("cursorAnchorSide") == "CENTER" and positionedByUs then
        ApplyCursorAnchor(self)
    end
end)

local function GetNpcIdFromGUID(guid)
    if not guid then
        return nil
    end
    local unitType, _, _, _, _, npcId = strsplit("-", guid)
    if unitType == "Creature" or unitType == "Vehicle" or unitType == "Pet" then
        return npcId
    end
    return nil
end

-- Shared logic for a unit tooltip, regardless of which hook mechanism
-- delivered it. `unit` may be nil if we couldn't resolve a unit token (we
-- still fall back to `guid` for the NPC ID line in that case). Note: we
-- never call tooltip:Show()/ClearLines() here -- AddLine on an already-
-- visible tooltip resizes it on its own, and calling Show() ourselves is
-- one of the operations that can taint the tooltip on this client.
-- Positioning is handled separately by UpdateTooltipPosition (via
-- GameTooltip_SetDefaultAnchor and OnSizeChanged), so these handlers only
-- deal with the extra info lines.
--
-- Blizzard periodically re-fires this postcall for the *same* unit tooltip
-- while it's still shown (to keep the health/power values it displays
-- live), not just once per mouseover. Without dedup, that meant we kept
-- calling AddLine again and again for the same unit, endlessly growing and
-- re-laying-out the tooltip. lastInfoKey tracks what we last added info
-- lines for; it's reset on OnTooltipCleared so a genuinely new mouseover
-- (even over the same unit again later) still gets them.
local lastInfoKey

local function HandleUnitTooltip(tooltip, unit, guid)
    local key = "unit:" .. tostring(guid or unit)
    if key == lastInfoKey then
        -- Same unit as last refresh (Blizzard re-fires this postcall
        -- repeatedly to keep health/power live, not just on genuine
        -- mouseover) -- skip the repositioning re-check too, not just the
        -- AddLine calls below, since there's nothing new to correct.
        return
    end
    lastInfoKey = key

    -- Re-confirms/corrects the tentative "other" guess from OnDefaultAnchor
    -- now that we know this is really a unit tooltip. Only runs once per
    -- genuine new mouseover (guarded by the dedup above), not on every
    -- periodic health/power refresh.
    UpdateTooltipPosition(tooltip)

    if GetSetting("showFactionName") and unit then
        local englishFaction = UnitFactionGroup(unit)
        if englishFaction then
            tooltip:AddLine("Faction: " .. englishFaction, unpack(INFO_LINE_COLOR))
        end
    end

    if GetSetting("showNpcId") then
        local npcId = GetNpcIdFromGUID(guid or (unit and UnitGUID(unit)))
        if npcId then
            tooltip:AddLine("NPC ID: " .. npcId, unpack(INFO_LINE_COLOR))
        end
    end
end

local function HandleItemTooltip(tooltip, itemId)
    local key = "item:" .. tostring(itemId)
    if key == lastInfoKey then
        return
    end
    lastInfoKey = key

    UpdateTooltipPosition(tooltip)

    if GetSetting("showItemId") and itemId then
        tooltip:AddLine("Item ID: " .. itemId, unpack(INFO_LINE_COLOR))
    end
end

local function HandleSpellTooltip(tooltip, spellId)
    local key = "spell:" .. tostring(spellId)
    if key == lastInfoKey then
        return
    end
    lastInfoKey = key

    UpdateTooltipPosition(tooltip)

    if GetSetting("showSpellId") and spellId then
        tooltip:AddLine("Spell ID: " .. spellId, unpack(INFO_LINE_COLOR))
    end
end

RegisterTooltipHook("OnTooltipCleared", function()
    lastInfoKey = nil
    positionedByUs = false
end)

if USE_TOOLTIP_DATA_PROCESSOR then
    -- Modern path: runs behind Blizzard's taint barrier, so AddLine here is
    -- safe. `data` carries structured fields (guid/id) directly; we still
    -- prefer the tooltip's own compat accessors (GetUnit/GetItem/GetSpell)
    -- when present since they're simpler, falling back to `data`.
    TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Unit, function(tooltip, data)
        if tooltip ~= GameTooltip then
            return
        end
        local unit
        if tooltip.GetUnit then
            local _, u = tooltip:GetUnit()
            unit = u
        end
        HandleUnitTooltip(tooltip, unit, data and data.guid)
    end)

    TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, function(tooltip, data)
        if tooltip ~= GameTooltip then
            return
        end
        local itemId = data and data.id
        if not itemId and tooltip.GetItem then
            local _, link = tooltip:GetItem()
            itemId = link and tonumber(link:match("item:(%d+)"))
        end
        HandleItemTooltip(tooltip, itemId)
    end)

    TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Spell, function(tooltip, data)
        if tooltip ~= GameTooltip then
            return
        end
        local spellId = data and data.id
        if not spellId and tooltip.GetSpell then
            local ok, _, id = pcall(tooltip.GetSpell, tooltip)
            if ok and type(id) == "number" then
                spellId = id
            end
        end
        HandleSpellTooltip(tooltip, spellId)
    end)
else
    -- Legacy fallback for true Classic-Era clients without
    -- TooltipDataProcessor. Each registration is pcall-guarded (see
    -- RegisterTooltipHook) since not every client build recognizes every
    -- tooltip script type.
    RegisterTooltipHook("OnTooltipSetUnit", function(self)
        local _, unit = self:GetUnit()
        if unit then
            HandleUnitTooltip(self, unit, UnitGUID(unit))
        end
    end)

    RegisterTooltipHook("OnTooltipSetItem", function(self)
        local _, link = self:GetItem()
        local itemId = link and tonumber(link:match("item:(%d+)"))
        HandleItemTooltip(self, itemId)
    end)

    RegisterTooltipHook("OnTooltipSetSpell", function(self)
        local ok, _, spellId = pcall(self.GetSpell, self)
        if ok and type(spellId) == "number" then
            HandleSpellTooltip(self, spellId)
        end
    end)
end

-- Continuous cursor-following comes for free from Blizzard's native
-- ANCHOR_CURSOR_LEFT/_RIGHT anchor types (set once per show in
-- ApplyCursorAnchor above) -- the engine moves the tooltip with the mouse
-- on its own, with no OnUpdate hook or per-frame repositioning needed at
-- all. Earlier attempts to support free-form corner/edge placement via
-- manual SetPoint on every frame caused a fade-out delay on unit tooltips
-- and fought with scale changes; this native approach has neither problem.

-- ================= Options panel (Escape -> Options -> AddOns) =================
-- Uses the modern Settings API (Settings.RegisterVerticalLayoutCategory /
-- Settings.RegisterAddOnSetting), available on this client. Guarded so the
-- addon still loads fine (just without a graphical panel) if a future/older
-- client build doesn't expose it -- the /fmt slash commands keep working
-- either way.
local optionsCategoryID

local function CreateOptionsPanel()
    if not (Settings and Settings.RegisterVerticalLayoutCategory and Settings.RegisterAddOnSetting) then
        return
    end

    local category, layout = Settings.RegisterVerticalLayoutCategory("Forever Mouse Tooltip")
    Settings.RegisterAddOnCategory(category)
    optionsCategoryID = category:GetID()

    local function AddHeader(text)
        if CreateSettingsListSectionHeaderInitializer then
            layout:AddInitializer(CreateSettingsListSectionHeaderInitializer(text))
        end
    end

    local function AddCheckbox(variable, name, tooltipText, default)
        local setting = Settings.RegisterAddOnSetting(
            category, ADDON_NAME .. "_" .. variable, variable,
            ForeverMouseTooltipDB, type(default), name, default
        )
        Settings.CreateCheckbox(category, setting, tooltipText)
        return setting
    end

    local function AddSlider(variable, name, tooltipText, default, minValue, maxValue, step)
        local setting = Settings.RegisterAddOnSetting(
            category, ADDON_NAME .. "_" .. variable, variable,
            ForeverMouseTooltipDB, type(default), name, default
        )
        local options = Settings.CreateSliderOptions(minValue, maxValue, step)
        options:SetLabelFormatter(MinimalSliderWithSteppersMixin.Label.Right)
        Settings.CreateSlider(category, setting, options, tooltipText)
        return setting
    end

    -- The addon Settings API doesn't expose a native radio-button control;
    -- CreateDropdown is the closest single-select equivalent for a small
    -- fixed list of choices like this one.
    local function AddDropdown(variable, name, tooltipText, default, choices)
        local setting = Settings.RegisterAddOnSetting(
            category, ADDON_NAME .. "_" .. variable, variable,
            ForeverMouseTooltipDB, type(default), name, default
        )
        local function GetOptions()
            local container = Settings.CreateControlTextContainer()
            for _, choice in ipairs(choices) do
                container:Add(choice.value, choice.text)
            end
            return container:GetData()
        end
        Settings.CreateDropdown(category, setting, GetOptions, tooltipText)
        return setting
    end

    AddHeader("Positioning")
    AddCheckbox("enabled", "Enable", "Anchor tooltips to the mouse cursor instead of the default corner.", DEFAULTS.enabled)
    AddCheckbox("disableInCombat", "Disable in Combat", "Keep Blizzard's default tooltip position while in combat.", DEFAULTS.disableInCombat)
    AddDropdown("pauseCursorModifier", "Pause Key", "Hold this key to temporarily keep the tooltip at Blizzard's default position instead of following the cursor.", DEFAULTS.pauseCursorModifier, {
        { value = "NONE", text = "None (always follow cursor)" },
        { value = "SHIFT", text = "Shift" },
        { value = "CTRL", text = "Ctrl" },
        { value = "ALT", text = "Alt" },
    })
    AddDropdown("cursorAnchorSide", "Tooltip Anchor", "Which side of the cursor the tooltip appears on.", DEFAULTS.cursorAnchorSide, {
        { value = "DEFAULT", text = "Default (Can't be offset)" },
        { value = "RIGHT", text = "Bottom Right" },
        { value = "LEFT", text = "Bottom Left" },
        { value = "CENTER", text = "Bottom Center" },
    })
    AddSlider("offsetX", "Horizontal Offset", "Extra breathing room between the cursor and the tooltip. Positive moves right, negative moves left.", DEFAULTS.offsetX, -50, 50, 1)
    AddSlider("offsetY", "Vertical Offset", "Extra breathing room between the cursor and the tooltip. Positive moves up, negative moves down.", DEFAULTS.offsetY, -50, 50, 1)
    local scaleSetting = AddSlider("tooltipScale", "Tooltip Scale (%)", "Resize the tooltip. 100 = default size.", DEFAULTS.tooltipScale, 50, 200, 5)
    scaleSetting:SetValueChangedCallback(function()
        -- Apply immediately (event-driven) rather than waiting for the
        -- tooltip to be re-shown, so the slider gives instant feedback.
        if GameTooltip:IsShown() then
            ApplyScale(GameTooltip)
        end
    end)

    AddHeader("Extra Information")
    AddCheckbox("showNpcId", "Show NPC ID", "Add the creature/vehicle's numeric ID to unit tooltips.", DEFAULTS.showNpcId)
    AddCheckbox("showItemId", "Show Item ID", "Add the item's numeric ID to item tooltips.", DEFAULTS.showItemId)
    AddCheckbox("showSpellId", "Show Spell ID", "Add the spell's numeric ID to spell tooltips.", DEFAULTS.showSpellId)
    AddCheckbox("showFactionName", "Show Faction", "Add Alliance/Horde faction to unit tooltips, when available.", DEFAULTS.showFactionName)
end

-- IMPORTANT: SavedVariables (ForeverMouseTooltipDB) are only loaded by the
-- client *after* every file in this addon has finished executing, right
-- before ADDON_LOADED fires. If we built the options panel at the top level
-- of this file, Settings.RegisterAddOnSetting would capture a reference to
-- a throwaway empty table -- which the client then discards and replaces
-- with the real saved table -- so nothing the panel wrote ever reached disk,
-- and every /reload looked like a reset to defaults. Wait for ADDON_LOADED
-- (this addon specifically) so ForeverMouseTooltipDB is the real, final
-- table before wiring up the panel.
local loaderFrame = CreateFrame("Frame")
loaderFrame:RegisterEvent("ADDON_LOADED")
loaderFrame:SetScript("OnEvent", function(self, event, addonName)
    if addonName ~= ADDON_NAME then
        return
    end
    self:UnregisterEvent("ADDON_LOADED")

    ForeverMouseTooltipDB = ForeverMouseTooltipDB or {}
    CreateOptionsPanel()
end)

local function OpenOptionsPanel()
    if optionsCategoryID and Settings and Settings.OpenToCategory then
        Settings.OpenToCategory(optionsCategoryID)
    else
        print("|cff33ff99ForeverMouseTooltip|r: options panel unavailable on this client; use /fmt on|off|offset|combat instead.")
    end
end

-- Slash command: /fmt [on|off|offset x y|combat on|off|options]
-- Only covers the original core settings; the new extra-info and
-- positioning-refinement options are configured via the options panel only.
SLASH_FOREVERMOUSETOOLTIP1 = "/fmt"
SlashCmdList["FOREVERMOUSETOOLTIP"] = function(msg)
    local cmd, rest = msg:match("^(%S*)%s*(.-)$")
    cmd = (cmd or ""):lower()

    if cmd == "off" then
        ForeverMouseTooltipDB.enabled = false
        print("|cff33ff99ForeverMouseTooltip|r: disabled (tooltip stays at the default position).")
    elseif cmd == "on" then
        ForeverMouseTooltipDB.enabled = true
        print("|cff33ff99ForeverMouseTooltip|r: enabled, tooltip follows the cursor.")
    elseif cmd == "offset" then
        local x, y = rest:match("^(%-?%d+)%s+(%-?%d+)$")
        if x and y then
            x, y = tonumber(x), tonumber(y)
            ForeverMouseTooltipDB.offsetX = x
            ForeverMouseTooltipDB.offsetY = y
            print(("|cff33ff99ForeverMouseTooltip|r: offset set to %d, %d."):format(x, y))
        else
            print("|cff33ff99ForeverMouseTooltip|r: usage /fmt offset <x> <y> (pixels; positive x = right, positive y = up)")
        end
    elseif cmd == "combat" then
        local sub = rest:lower()
        if sub == "on" then
            ForeverMouseTooltipDB.disableInCombat = true
            print("|cff33ff99ForeverMouseTooltip|r: will keep the default tooltip position while in combat.")
        elseif sub == "off" then
            ForeverMouseTooltipDB.disableInCombat = false
            print("|cff33ff99ForeverMouseTooltip|r: cursor-anchored tooltip stays active in combat.")
        else
            print("|cff33ff99ForeverMouseTooltip|r: usage /fmt combat on|off")
        end
    elseif cmd == "options" then
        OpenOptionsPanel()
    else
        print("|cff33ff99ForeverMouseTooltip|r: /fmt on | /fmt off | /fmt offset <x> <y> | /fmt combat on|off | /fmt options")
    end
end


