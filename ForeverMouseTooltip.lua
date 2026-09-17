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
-- We replace it with a version that anchors to the cursor instead. Frames
-- that explicitly anchor tooltips elsewhere on purpose (e.g. comparison
-- tooltips, static minimap tooltips) are untouched because they don't call
-- this helper.

local ADDON_NAME, ns = ...

-- Saved offset (persisted via SavedVariables so it's easy to tweak with
-- /fmt without editing the addon).
ForeverMouseTooltipDB = ForeverMouseTooltipDB or {}

local DEFAULTS = {
    offsetX = 12,
    offsetY = -12,
    enabled = true,
}

local function GetSetting(key)
    local value = ForeverMouseTooltipDB[key]
    if value == nil then
        return DEFAULTS[key]
    end
    return value
end

-- Keep a reference to Blizzard's original function so it can be restored
-- (e.g. via /fmt off) or chained by another addon if needed.
local original_SetDefaultAnchor = GameTooltip_SetDefaultAnchor

local function CursorAnchor(tooltip, parent)
    tooltip:SetOwner(parent, "ANCHOR_CURSOR", GetSetting("offsetX"), GetSetting("offsetY"))
end

local function ApplyHook()
    GameTooltip_SetDefaultAnchor = CursorAnchor
end

local function RemoveHook()
    GameTooltip_SetDefaultAnchor = original_SetDefaultAnchor
end

-- Some UI elements (e.g. certain action button and aura tooltips) call
-- GameTooltip:SetOwner(parent, "ANCHOR_NONE") directly and then SetPoint the
-- tooltip themselves, bypassing GameTooltip_SetDefaultAnchor entirely. Catch
-- the common "default corner" pattern as a safety net without touching
-- tooltips that were deliberately anchored elsewhere (ANCHOR_CURSOR already,
-- or comparison/shopping tooltips, which pass their own frame as parent and
-- are excluded below).
local WATCHED_ANCHORS = {
    ANCHOR_NONE = true,
    ANCHOR_BOTTOMRIGHT = true,
    ANCHOR_TOPRIGHT = true,
}

local suppressReanchor = false

local function OnTooltipSetOwner(self, parent, anchorType)
    if not GetSetting("enabled") then
        return
    end
    if suppressReanchor then
        return
    end
    if anchorType and WATCHED_ANCHORS[anchorType] then
        suppressReanchor = true
        self:SetOwner(parent, "ANCHOR_CURSOR", GetSetting("offsetX"), GetSetting("offsetY"))
        suppressReanchor = false
    end
end

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:SetScript("OnEvent", function(self, event, addonName)
    if event == "ADDON_LOADED" and addonName == ADDON_NAME then
        if GetSetting("enabled") then
            ApplyHook()
        end
        hooksecurefunc(GameTooltip, "SetOwner", OnTooltipSetOwner)
        self:UnregisterEvent("ADDON_LOADED")
    end
end)

-- Slash command: /fmt [on|off|offset x y]
SLASH_FOREVERMOUSETOOLTIP1 = "/fmt"
SlashCmdList["FOREVERMOUSETOOLTIP"] = function(msg)
    local cmd, rest = msg:match("^(%S*)%s*(.-)$")
    cmd = (cmd or ""):lower()

    if cmd == "off" then
        ForeverMouseTooltipDB.enabled = false
        RemoveHook()
        print("|cff33ff99ForeverMouseTooltip|r: disabled (reload UI to fully restore default behavior).")
    elseif cmd == "on" then
        ForeverMouseTooltipDB.enabled = true
        ApplyHook()
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
    else
        print("|cff33ff99ForeverMouseTooltip|r: /fmt on | /fmt off | /fmt offset <x> <y>")
    end
end
