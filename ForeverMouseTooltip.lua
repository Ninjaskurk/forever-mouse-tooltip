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

-- Saved offset (persisted via SavedVariables so it's easy to tweak with
-- /fmt without editing the addon).
ForeverMouseTooltipDB = ForeverMouseTooltipDB or {}

local DEFAULTS = {
    offsetX = 12,
    offsetY = -12,
    enabled = true,
    disableInCombat = false,
}

local function GetSetting(key)
    local value = ForeverMouseTooltipDB[key]
    if value == nil then
        return DEFAULTS[key]
    end
    return value
end

-- Runs after Blizzard's own (untainted) GameTooltip_SetDefaultAnchor call
-- and simply re-anchors to the cursor. hooksecurefunc hooks cannot be
-- removed, so /fmt off just makes this a no-op instead of unhooking.
local function CursorAnchor(tooltip, parent)
    if not GetSetting("enabled") then
        return
    end
    if GetSetting("disableInCombat") and InCombatLockdown() then
        -- Leave Blizzard's own default-corner anchor (already applied by
        -- the function we hooked) untouched while in combat.
        return
    end
    tooltip:SetOwner(parent, "ANCHOR_CURSOR", GetSetting("offsetX"), GetSetting("offsetY"))
end

if type(GameTooltip_SetDefaultAnchor) == "function" then
    hooksecurefunc("GameTooltip_SetDefaultAnchor", CursorAnchor)
end

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

    local category = Settings.RegisterVerticalLayoutCategory("Forever Mouse Tooltip")
    Settings.RegisterAddOnCategory(category)
    optionsCategoryID = category:GetID()

    local function AddCheckbox(variable, name, tooltipText, default)
        local setting = Settings.RegisterAddOnSetting(
            category, ADDON_NAME .. "_" .. variable, variable,
            ForeverMouseTooltipDB, type(default), name, default
        )
        Settings.CreateCheckbox(category, setting, tooltipText)
        return setting
    end

    local function AddOffsetSlider(variable, name, tooltipText, default)
        local setting = Settings.RegisterAddOnSetting(
            category, ADDON_NAME .. "_" .. variable, variable,
            ForeverMouseTooltipDB, type(default), name, default
        )
        local options = Settings.CreateSliderOptions(-50, 50, 1)
        options:SetLabelFormatter(MinimalSliderWithSteppersMixin.Label.Right)
        Settings.CreateSlider(category, setting, options, tooltipText)
        return setting
    end

    AddCheckbox("enabled", "Enable", "Anchor tooltips to the mouse cursor instead of the default corner.", DEFAULTS.enabled)
    AddCheckbox("disableInCombat", "Disable in Combat", "Keep Blizzard's default tooltip position while in combat.", DEFAULTS.disableInCombat)
    AddOffsetSlider("offsetX", "Horizontal Offset", "Pixel offset from the cursor on the X axis.", DEFAULTS.offsetX)
    AddOffsetSlider("offsetY", "Vertical Offset", "Pixel offset from the cursor on the Y axis.", DEFAULTS.offsetY)
end

CreateOptionsPanel()

local function OpenOptionsPanel()
    if optionsCategoryID and Settings and Settings.OpenToCategory then
        Settings.OpenToCategory(optionsCategoryID)
    else
        print("|cff33ff99ForeverMouseTooltip|r: options panel unavailable on this client; use /fmt on|off|offset|combat instead.")
    end
end

-- Slash command: /fmt [on|off|offset x y|combat on|off|options]
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
            ForeverMouseTooltipDB.offsetX = tonumber(x)
            ForeverMouseTooltipDB.offsetY = tonumber(y)
            print(("|cff33ff99ForeverMouseTooltip|r: offset set to %d, %d."):format(tonumber(x), tonumber(y)))
        else
            print("|cff33ff99ForeverMouseTooltip|r: usage /fmt offset <x> <y>")
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

