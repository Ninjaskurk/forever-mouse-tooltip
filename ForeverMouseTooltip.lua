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
    -- Core positioning: rather than a raw pixel offset (which turned out
    -- to be re-scaled by the tooltip's own "Tooltip Scale" setting --
    -- SetPoint offsets are interpreted in the *child* frame's own scaled
    -- coordinate space, not the parent's), we anchor a specific corner of
    -- the tooltip directly to the cursor (zero offset needed) and only use
    -- a small "gap" for breathing room, which we explicitly compensate for
    -- the tooltip's own scale (see ApplyCursorAnchor).
    cursorAnchorCorner = "BOTTOM_RIGHT", -- which side of the cursor the tooltip appears on
    gapX = 16,
    gapY = 8,
    enabled = true,
    disableInCombat = false,

    -- New: extra info shown in tooltips. Off by default -- opt in via the
    -- options panel (Escape -> Options -> AddOns -> Forever Mouse Tooltip).
    showNpcId = false,
    showItemId = false,
    showSpellId = false,
    showFactionName = false,

    -- New: positioning refinements. Off by default.
    disableForUnits = false,
    disableForItems = false,
    disableForSpells = false,
    disableForOther = false,
    -- "NONE"/"SHIFT"/"CTRL"/"ALT" -- which modifier key (if any) pauses
    -- cursor-follow while held.
    pauseCursorModifier = "NONE",
    tooltipScale = 100, -- percent; 100 = no change from Blizzard's default size

    -- New: this client keeps a unit tooltip fully visible for roughly a
    -- second after the mouse leaves the unit before it starts fading --
    -- confirmed (with the whole addon disabled) to be native client
    -- behavior, not something we cause. Off by default since it's a
    -- cosmetic workaround, not a bug fix.
    fasterUnitFadeOut = false,
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

-- Which corner/edge-midpoint of the tooltip attaches to the cursor for
-- each "cursorAnchorCorner" choice, and which direction (sign) the gap
-- nudges it away from the cursor in each axis. 0 means "centered on that
-- axis" (no gap applied) for the edge-midpoint options.
local ANCHOR_CORNERS = {
    BOTTOM_RIGHT = { point = "TOPLEFT", signX = 1, signY = -1 },
    BOTTOM_LEFT = { point = "TOPRIGHT", signX = -1, signY = -1 },
    TOP_RIGHT = { point = "BOTTOMLEFT", signX = 1, signY = 1 },
    TOP_LEFT = { point = "BOTTOMRIGHT", signX = -1, signY = 1 },
    BELOW = { point = "TOP", signX = 0, signY = -1 },
    ABOVE = { point = "BOTTOM", signX = 0, signY = 1 },
    LEFT = { point = "RIGHT", signX = -1, signY = 0 },
    RIGHT = { point = "LEFT", signX = 1, signY = 0 },
}

-- A tiny invisible frame that tracks the cursor on its own OnUpdate,
-- independent of GameTooltip entirely. We anchor GameTooltip to *this*
-- frame instead of computing/re-setting GameTooltip's own anchor every
-- frame: GameTooltip is a large, complex frame with its own internal
-- layout/fade/taint-sensitive logic, and repeatedly calling
-- ClearAllPoints/SetPoint/SetClampedToScreen on it 60 times a second was
-- both causing the unit-tooltip fade-out delay (constantly touching it
-- while it was trying to fade away) and fighting with whatever Blizzard
-- does internally when the tooltip's own scale changes (making the
-- anchor visibly "jump" as the Tooltip Scale slider moved). Anchoring to
-- a moving reference frame means we only need to set GameTooltip's point
-- once per show -- it then tracks the cursor for free as this frame moves,
-- with zero further touches to GameTooltip itself.
local cursorAnchor = CreateFrame("Frame", "ForeverMouseTooltipCursorAnchor", UIParent)
cursorAnchor:SetSize(1, 1)

-- State for the optional "Instant Unit Tooltip Fade" setting below. This
-- works around what turned out to be native client behavior (confirmed by
-- testing with the whole addon disabled): a unit tooltip stays fully
-- visible for roughly a second after the mouse leaves the unit before it
-- starts fading, likely because Blizzard's own periodic health/power
-- refresh keeps re-showing it. We can't call tooltip:Hide() ourselves to
-- work around this (see the taint warning above HandleUnitTooltip et al)
-- -- but SetAlpha is a plain cosmetic property, runs no script, and isn't
-- one of the calls known to taint the tooltip, so we snap it invisible
-- ourselves the instant the mouse is no longer over any unit, independent
-- of whatever timer Blizzard is using internally.
local fasterFadeActive = false

-- tooltip:GetUnit() was found (via /fmt debug) to go nil again shortly
-- after the mouse leaves the unit -- even though the tooltip itself keeps
-- showing the same content -- so using it to decide "is this still a unit
-- tooltip" flip-flopped: we'd force alpha to 0, then immediately see
-- hasUnit=false next tick, reset alpha back to 1 via ResetFasterFadeState,
-- and let Blizzard's own ~1s fade restart from full visibility, which
-- looked identical to the delay we were trying to remove. Tracking content
-- type ourselves (set in HandleUnitTooltip/Item/Spell, cleared only on
-- OnTooltipCleared below) is stable for the whole life of the tooltip.
local currentTooltipIsUnit = false

local function ResetFasterFadeState()
    if fasterFadeActive then
        fasterFadeActive = false
        GameTooltip:SetAlpha(1)
    end
end

-- Diagnosed via /fmt debug: Blizzard's own OnUpdate script on GameTooltip
-- (not anything we registered) was overwriting our SetAlpha(0) every frame
-- with its own slowly-decaying alpha, since our cursorAnchor frame and
-- GameTooltip are different frames with no guaranteed OnUpdate ordering --
-- our forced value kept losing the race, producing the same gradual fade
-- as before instead of an instant cut. HookScript (as opposed to a plain
-- OnUpdate on our own frame) runs our handler *after* GameTooltip's own
-- existing OnUpdate script every tick, guaranteeing we get the final say.
local ok = pcall(GameTooltip.HookScript, GameTooltip, "OnUpdate", function(self)
    if GetSetting("fasterUnitFadeOut") and self:IsShown() then
        if currentTooltipIsUnit and not UnitExists("mouseover") then
            fasterFadeActive = true
            self:SetAlpha(0)
        else
            ResetFasterFadeState()
        end
    else
        ResetFasterFadeState()
    end
end)
if not ok then
    -- This client doesn't support hooking GameTooltip's OnUpdate this way;
    -- the "Instant Unit Tooltip Fade" option will simply have no effect.
end

-- Diagnostic only (toggled via /fmt debug): logs the moment each of these
-- signals changes, with a timestamp, so we can tell apart "mouseover unit
-- token clears late" (an engine/raycast limitation we can't work around)
-- from "mouseover clears promptly but the tooltip itself still lingers"
-- (something we might still be able to influence).
local debugWatchEnabled = false
local lastDebugMouseover, lastDebugShown, lastDebugAlpha

cursorAnchor:SetScript("OnUpdate", function(self)
    if debugWatchEnabled then
        local mouseoverNow = UnitExists("mouseover") and true or false
        if mouseoverNow ~= lastDebugMouseover then
            lastDebugMouseover = mouseoverNow
            print(("|cff33ff99FMT debug|r t=%.2f mouseover=%s"):format(GetTime(), tostring(mouseoverNow)))
        end
        local shownNow = GameTooltip:IsShown() and true or false
        if shownNow ~= lastDebugShown then
            lastDebugShown = shownNow
            print(("|cff33ff99FMT debug|r t=%.2f tooltipShown=%s"):format(GetTime(), tostring(shownNow)))
        end
        local alphaNow = GameTooltip:GetAlpha()
        if not lastDebugAlpha or math.abs(alphaNow - lastDebugAlpha) > 0.05 then
            lastDebugAlpha = alphaNow
            print(("|cff33ff99FMT debug|r t=%.2f tooltipAlpha=%.2f"):format(GetTime(), alphaNow))
        end
    end

    if not ShouldFollowCursor() then
        return
    end
    local x, y
    if GetScaledCursorPosition then
        -- Prefer this over GetCursorPosition()/effective-scale division:
        -- it returns the cursor position already converted to UIParent's
        -- coordinate space, which sidesteps a scale-conversion bug on this
        -- client that was confining the tooltip to a small area near the
        -- top-left corner regardless of real cursor position.
        x, y = GetScaledCursorPosition()
    else
        local scale = UIParent:GetEffectiveScale()
        if not scale or scale == 0 then
            scale = 1
        end
        x, y = GetCursorPosition()
        x, y = x / scale, y / scale
    end
    self:ClearAllPoints()
    self:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", x, y)
end)

-- IMPORTANT: never call tooltip:SetOwner(...)/Show()/Hide()/ClearLines()
-- from our own code on this client -- SetOwner clears the tooltip and runs
-- Blizzard's OnTooltipCleared script *as addon code*, which taints the
-- tooltip (and a tainted tooltip on this client can silently fail to
-- display "secret" combat-related lines). ClearAllPoints/SetPoint run no
-- script at all, so they're safe.
--
-- We also don't use SetAnchorType("ANCHOR_CURSOR_LEFT"/"_RIGHT", x, y)
-- here even though it's documented to respect offsets: on this specific
-- client build it doesn't -- horizontally it only respects the *sign* of x
-- (snapping hard left/right regardless of magnitude) and vertically it
-- behaves inconsistently at larger values.
--
-- Called once per tooltip show (and again if/when the content type turns
-- out to be a unit/item/spell -- see UpdateTooltipPosition), NOT every
-- frame: continuous tracking now comes for free from cursorAnchor's own
-- OnUpdate above.
local function ApplyCursorAnchor(tooltip)
    local corner = ANCHOR_CORNERS[GetSetting("cursorAnchorCorner")] or ANCHOR_CORNERS.BOTTOM_RIGHT
    local gapX = GetSetting("gapX") or 0
    local gapY = GetSetting("gapY") or 0

    tooltip:ClearAllPoints()
    if tooltip.SetClampedToScreen then
        tooltip:SetClampedToScreen(false)
    end
    tooltip:SetPoint(corner.point, cursorAnchor, "BOTTOMLEFT", corner.signX * gapX, corner.signY * gapY)
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

-- Which "disableForX" setting applies to a tooltip, determined fresh each
-- time from its actual current content via the compat accessors
-- (GetUnit/GetItem/GetSpell) rather than relying on which hook delivered
-- it. At GameTooltip_SetDefaultAnchor time (before content is attached)
-- these all correctly report nothing set yet, so this naturally falls
-- through to "disableForOther" as a tentative guess; the Handle*Tooltip
-- callbacks below call this again once content is known, correcting it.
local function GetDisableSettingForTooltip(tooltip)
    if tooltip.GetUnit then
        local _, unit = tooltip:GetUnit()
        if unit then
            return "disableForUnits"
        end
    end
    if tooltip.GetItem then
        local _, link = tooltip:GetItem()
        if link then
            return "disableForItems"
        end
    end
    if tooltip.GetSpell then
        local ok, name = pcall(tooltip.GetSpell, tooltip)
        if ok and name then
            return "disableForSpells"
        end
    end
    return "disableForOther"
end

-- Whether *we* (not Blizzard's own default) currently own this tooltip's
-- anchor, so RevertToDefaultAnchor knows whether there's anything to
-- undo. Reset on OnTooltipCleared (see below).
local positionedByUs = false
local suppressDefaultAnchorHook = false

local function RevertToDefaultAnchor(tooltip)
    if not positionedByUs then
        return
    end
    -- GameTooltip_SetDefaultAnchor is hooked via hooksecurefunc, so calling
    -- it ourselves would normally re-trigger OnDefaultAnchor below;
    -- suppress that one reentrant call so we don't immediately undo our
    -- own revert.
    suppressDefaultAnchorHook = true
    GameTooltip_SetDefaultAnchor(tooltip, tooltip:GetOwner())
    suppressDefaultAnchorHook = false
    positionedByUs = false
end

-- Repositions (or reverts) the tooltip based on current settings and
-- content type. Only handles positioning -- scale is applied separately.
local function UpdateTooltipPosition(tooltip)
    if not ShouldFollowCursor() or GetSetting(GetDisableSettingForTooltip(tooltip)) then
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
-- GameTooltip_SetDefaultAnchor and OnUpdate), so these handlers only deal
-- with the extra info lines.
--
-- Blizzard periodically re-fires this postcall for the *same* unit tooltip
-- while it's still shown (to keep the health/power values it displays
-- live), not just once per mouseover. Without dedup, that meant we kept
-- calling AddLine again and again for the same unit, endlessly growing and
-- re-laying-out the tooltip -- which is what was causing the visible
-- "delay"/stutter specifically while hovering over units (most noticeable
-- on players, whose health ticks more often). lastInfoKey tracks what we
-- last added info lines for; it's reset on OnTooltipCleared so a genuinely
-- new mouseover (even over the same unit again later) still gets them.
local lastInfoKey

local function HandleUnitTooltip(tooltip, unit, guid)
    local key = "unit:" .. tostring(guid or unit)
    if key == lastInfoKey then
        -- Same unit as last refresh (Blizzard re-fires this postcall
        -- repeatedly to keep health/power live, not just on genuine
        -- mouseover) -- skip repositioning too, not just the AddLine
        -- calls below, so we don't keep touching GameTooltip while it
        -- may be trying to fade out.
        return
    end
    lastInfoKey = key
    currentTooltipIsUnit = true

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
    currentTooltipIsUnit = false

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
    currentTooltipIsUnit = false

    UpdateTooltipPosition(tooltip)

    if GetSetting("showSpellId") and spellId then
        tooltip:AddLine("Spell ID: " .. spellId, unpack(INFO_LINE_COLOR))
    end
end

RegisterTooltipHook("OnTooltipCleared", function()
    lastInfoKey = nil
    positionedByUs = false
    currentTooltipIsUnit = false
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

-- Continuous cursor-following now comes for free from cursorAnchor's own
-- OnUpdate (see above) moving the frame GameTooltip is anchored to -- we
-- deliberately don't hook GameTooltip's own OnUpdate to re-position it
-- directly anymore; doing that at 60fps on GameTooltip itself (a large,
-- complex frame with its own fade/layout logic) was causing a fade-out
-- delay on unit tooltips and fighting with scale changes.

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
    AddDropdown("pauseCursorModifier", "Pause Cursor-Follow While Holding", "Hold this key to temporarily keep the tooltip at Blizzard's default position instead of following the cursor.", DEFAULTS.pauseCursorModifier, {
        { value = "NONE", text = "None (always follow cursor)" },
        { value = "SHIFT", text = "Shift" },
        { value = "CTRL", text = "Ctrl" },
        { value = "ALT", text = "Alt" },
    })
    AddCheckbox("disableForUnits", "Don't Reposition Unit Tooltips", "Leave unit (player/NPC) tooltips at the default position instead of following the cursor.", DEFAULTS.disableForUnits)
    AddCheckbox("disableForItems", "Don't Reposition Item Tooltips", "Leave item tooltips at the default position instead of following the cursor.", DEFAULTS.disableForItems)
    AddCheckbox("disableForSpells", "Don't Reposition Spell Tooltips", "Leave spell/ability tooltips at the default position instead of following the cursor.", DEFAULTS.disableForSpells)
    AddCheckbox("disableForOther", "Don't Reposition Other Tooltips", "Leave all other tooltips (action bars, currency, quests, etc.) at the default position instead of following the cursor.", DEFAULTS.disableForOther)
    AddCheckbox("fasterUnitFadeOut", "Instant Unit Tooltip Fade", "Hide unit tooltips immediately after the mouse leaves, instead of the client's native ~1 second lingering delay.", DEFAULTS.fasterUnitFadeOut)
    AddDropdown("cursorAnchorCorner", "Tooltip Appears", "Which side of the cursor the tooltip appears on.", DEFAULTS.cursorAnchorCorner, {
        { value = "BOTTOM_RIGHT", text = "Below and to the right" },
        { value = "BOTTOM_LEFT", text = "Below and to the left" },
        { value = "TOP_RIGHT", text = "Above and to the right" },
        { value = "TOP_LEFT", text = "Above and to the left" },
        { value = "BELOW", text = "Directly below (centered)" },
        { value = "ABOVE", text = "Directly above (centered)" },
        { value = "LEFT", text = "Directly left (centered)" },
        { value = "RIGHT", text = "Directly right (centered)" },
    })
    AddSlider("gapX", "Horizontal Gap", "Extra breathing room between the cursor and the tooltip, in screen pixels.", DEFAULTS.gapX, 0, 50, 1)
    AddSlider("gapY", "Vertical Gap", "Extra breathing room between the cursor and the tooltip, in screen pixels.", DEFAULTS.gapY, 0, 50, 1)
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
    elseif cmd == "gap" then
        local x, y = rest:match("^(%d+)%s+(%d+)$")
        if x and y then
            x, y = tonumber(x), tonumber(y)
            ForeverMouseTooltipDB.gapX = x
            ForeverMouseTooltipDB.gapY = y
            print(("|cff33ff99ForeverMouseTooltip|r: gap set to %d, %d."):format(x, y))
        else
            print("|cff33ff99ForeverMouseTooltip|r: usage /fmt gap <x> <y> (non-negative pixels; which side of the cursor is set in the options panel)")
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
    elseif cmd == "debug" then
        debugWatchEnabled = not debugWatchEnabled
        lastDebugMouseover, lastDebugShown, lastDebugAlpha = nil, nil, nil
        print("|cff33ff99ForeverMouseTooltip|r: debug watch " .. (debugWatchEnabled and "ON" or "OFF") .. " (logs mouseover/tooltip-shown/alpha transitions to chat).")
    else
        print("|cff33ff99ForeverMouseTooltip|r: /fmt on | /fmt off | /fmt gap <x> <y> | /fmt combat on|off | /fmt options | /fmt debug")
    end
end


