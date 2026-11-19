-- RulZ Equipment Tracker: window, rows, minimap button, character-sheet button
-- and slash commands. Art comes from the game's own borders, fonts and buttons.
local ADDON_NAME, ns = ...

local MARK = "Interface\\AddOns\\" .. ADDON_NAME .. "\\Media\\RulZMark"
local TOOLTIP_BG = "Interface\\Tooltips\\UI-Tooltip-Background"
local TOOLTIP_BORDER = "Interface\\Tooltips\\UI-Tooltip-Border"

local PANEL_COLOR = { 0.04, 0.02, 0.02, 0.94 }
local BORDER_COLOR = { 0.62, 0.1, 0.1, 1 }
-- RulZ design tokens as 0-1 RGB.
local ACCENT_COLOR = { 0.929, 0, 0.051 }        -- accent #ed000d
local ACCENT_TEXT_COLOR = { 1, 0.42, 0.447 }    -- accent-text #ff6b72
local OK_COLOR = { 0.29, 0.871, 0.502 }         -- ok #4ade80
local NEAR_COLOR = { 0.92, 0.92, 0.92 }
local DIM_COLOR = { 0.62, 0.62, 0.62 }
local STAT_COLOR = { 0.82, 0.82, 0.82 }
local TAB_DIM_ALPHA = 0.62
local TINT_ALPHA = 0.12
local LINE_ALPHA = 0.06

-- Item level against the average: below LOW_RATIO of it is "well below",
-- above HIGH_RATIO of it is "well above", anything between is "near".
local LOW_RATIO = 0.85
local HIGH_RATIO = 1.10

local PANEL_WIDTH = 480
local SIDE_MARGIN = 12
local ROW_WIDTH = PANEL_WIDTH - SIDE_MARGIN * 2
local ROW_HEIGHT = 30
local HEADER_HEIGHT = 62
local FOOTER_HEIGHT = 38
local ICON_SIZE = 26
local TEXT_LEFT = ICON_SIZE + 14
local SLOT_LABEL_WIDTH = 62
local LEVEL_WIDTH = 116
local MIN_SCALE_PERCENT = 70
local MAX_SCALE_PERCENT = 130
local PREFIX = "|cffed0a14RulZ:|r "
local DOT = "\194\183" -- middle dot, written as bytes to keep this file ASCII
local CHARACTER_BUTTON_WIDTH = 46
local CHARACTER_BUTTON_RIGHT = -62 -- keeps clear of the game's close button

ns.MIN_SCALE_PERCENT = MIN_SCALE_PERCENT
ns.MAX_SCALE_PERCENT = MAX_SCALE_PERCENT

local frame, avgText, emptyText, minimapButton, characterButton, characterHooked
local rows, tabs = {}, {}

local function NewText(parent, fontObject)
    return parent:CreateFontString(nil, "OVERLAY", fontObject)
end

local function Hex(color)
    return string.format("%02x%02x%02x",
        math.floor(color[1] * 255 + 0.5), math.floor(color[2] * 255 + 0.5), math.floor(color[3] * 255 + 0.5))
end

local function SavePosition()
    local point, _, relativePoint, x, y = frame:GetPoint()
    ns.db.position = { point, relativePoint, x, y }
end

local function SetPanelShown(shown)
    frame:SetShown(shown)
end
ns.SetPanelShown = SetPanelShown

local function TogglePanel()
    SetPanelShown(not frame:IsShown())
end

local function PlaceFrame()
    frame:ClearAllPoints()
    local position = ns.db.position
    if position then
        frame:SetPoint(position[1], UIParent, position[2], position[3], position[4])
    else
        frame:SetPoint("CENTER", UIParent, "CENTER", -340, 0)
    end
end

-- Offsets are measured in the frame's own scale, so the window is re-anchored
-- to keep its centre in the same place on screen.
function ns.SetScalePercent(percent)
    percent = math.min(math.max(percent, MIN_SCALE_PERCENT), MAX_SCALE_PERCENT)
    local oldScale = frame:GetScale()
    local newScale = percent / 100
    local x, y = frame:GetCenter()
    ns.db.scale = newScale
    frame:SetScale(newScale)
    if x then
        frame:ClearAllPoints()
        frame:SetPoint("CENTER", UIParent, "BOTTOMLEFT", x * oldScale / newScale, y * oldScale / newScale)
        SavePosition()
    end
end

-- Rows -----------------------------------------------------------------------

local function ShowSlotTooltip(button)
    local row = button.row
    GameTooltip:SetOwner(button, "ANCHOR_RIGHT")
    local hasItem = GameTooltip:SetInventoryItem("player", row.slot)
    if not hasItem then
        GameTooltip:SetText(row.label)
    end
    GameTooltip:Show()
end

local function CreateRow(index)
    local row = CreateFrame("Frame", nil, frame)
    row:SetSize(ROW_WIDTH, ROW_HEIGHT)
    row:SetPoint("TOPLEFT", SIDE_MARGIN, -(HEADER_HEIGHT + (index - 1) * ROW_HEIGHT))

    row.tint = row:CreateTexture(nil, "BACKGROUND")
    row.tint:SetAllPoints()
    row.tint:SetColorTexture(ACCENT_COLOR[1], ACCENT_COLOR[2], ACCENT_COLOR[3], TINT_ALPHA)

    local line = row:CreateTexture(nil, "BORDER")
    line:SetPoint("BOTTOMLEFT")
    line:SetPoint("BOTTOMRIGHT")
    line:SetHeight(1)
    line:SetColorTexture(1, 1, 1, LINE_ALPHA)

    -- A red bar plus the word "Upgrade", so the hint doesn't rely on color alone.
    row.marker = row:CreateTexture(nil, "ARTWORK")
    row.marker:SetPoint("TOPLEFT", 0, -2)
    row.marker:SetPoint("BOTTOMLEFT", 0, 2)
    row.marker:SetWidth(3)
    row.marker:SetColorTexture(unpack(ACCENT_COLOR))

    local button = CreateFrame("Button", nil, row)
    button:SetSize(ICON_SIZE, ICON_SIZE)
    button:SetPoint("LEFT", 7, 0)
    button:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
    button:RegisterForClicks("LeftButtonUp")
    button.row = row
    button:SetScript("OnEnter", ShowSlotTooltip)
    button:SetScript("OnLeave", function() GameTooltip:Hide() end)
    button:SetScript("OnClick", function()
        -- Shift-click links the item into the chat box.
        if row.link and IsShiftKeyDown() and ChatEdit_InsertLink then
            ChatEdit_InsertLink(row.link)
        end
    end)
    row.icon = button:CreateTexture(nil, "ARTWORK")
    row.icon:SetAllPoints()
    row.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)

    row.slotLabel = NewText(row, "GameFontNormalSmall")
    row.slotLabel:SetPoint("TOPLEFT", TEXT_LEFT + 4, -4)
    row.slotLabel:SetWidth(SLOT_LABEL_WIDTH)
    row.slotLabel:SetJustifyH("LEFT")
    row.slotLabel:SetWordWrap(false)
    row.slotLabel:SetTextColor(unpack(DIM_COLOR))

    local nameLeft = TEXT_LEFT + 4 + SLOT_LABEL_WIDTH + 4
    row.name = NewText(row, "GameFontNormalSmall")
    row.name:SetPoint("TOPLEFT", nameLeft, -4)
    row.name:SetWidth(ROW_WIDTH - nameLeft - LEVEL_WIDTH - 8)
    row.name:SetJustifyH("LEFT")
    row.name:SetWordWrap(false)

    row.stats = NewText(row, "GameFontHighlightSmall")
    row.stats:SetPoint("BOTTOMLEFT", TEXT_LEFT + 4, 4)
    row.stats:SetWidth(ROW_WIDTH - TEXT_LEFT - 4 - LEVEL_WIDTH - 8)
    row.stats:SetJustifyH("LEFT")
    row.stats:SetWordWrap(false)
    row.stats:SetTextColor(unpack(STAT_COLOR))

    row.level = NewText(row, "GameFontHighlightSmall")
    row.level:SetPoint("TOPRIGHT", -6, -4)
    row.level:SetWidth(LEVEL_WIDTH)
    row.level:SetJustifyH("RIGHT")
    row.level:SetWordWrap(false)

    row.upgrade = NewText(row, "GameFontNormalSmall")
    row.upgrade:SetPoint("BOTTOMRIGHT", -6, 4)
    row.upgrade:SetText("Upgrade")
    row.upgrade:SetTextColor(unpack(ACCENT_TEXT_COLOR))

    return row
end

-- Item level colored by how it compares with the average.
local function LevelColor(ilvl, average)
    if not average or average <= 0 then
        return NEAR_COLOR
    end
    if ilvl < average * LOW_RATIO then
        return ACCENT_TEXT_COLOR
    elseif ilvl > average * HIGH_RATIO then
        return OK_COLOR
    end
    return NEAR_COLOR
end

local function LevelText(data, average)
    if not data.ilvl then
        return "ilvl ?"
    end
    local text = string.format("|cff%silvl %d|r", Hex(LevelColor(data.ilvl, average)), math.floor(data.ilvl + 0.5))
    if data.requiredLevel then
        text = text .. string.format(" |cff%s%s req %d|r", Hex(DIM_COLOR), DOT, data.requiredLevel)
    end
    return text
end

local function ApplyRow(row, data, average)
    row.slot = data.slot
    row.label = data.label
    row.link = data.link
    row.slotLabel:SetText(data.label)
    row.tint:SetShown(data.upgrade == true)
    row.marker:SetShown(data.upgrade == true)
    row.upgrade:SetShown(data.upgrade == true)

    if data.link then
        row.icon:SetTexture(data.icon)
        row.icon:SetDesaturated(false)
        row.icon:SetAlpha(1)
        local color = data.quality and ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[data.quality]
        if color then
            row.name:SetTextColor(color.r, color.g, color.b)
        else
            row.name:SetTextColor(1, 1, 1)
        end
        row.name:SetText(data.name)
        row.level:SetText(LevelText(data, average))
        row.stats:SetText(data.stats or "")
        return
    end

    row.icon:SetTexture(data.emptyTexture)
    row.icon:SetDesaturated(true)
    row.icon:SetAlpha(0.45)
    row.level:SetText("")
    row.stats:SetText("")
    row.name:SetTextColor(unpack(DIM_COLOR))
    if data.twoHandFill then
        row.name:SetText("Two-handed weapon equipped")
    elseif data.empty then
        row.name:SetText("Empty")
    else
        row.name:SetText("Loading...")
    end
end

local function RefreshTabs()
    for _, tab in ipairs(tabs) do
        local selected = tab.key == ns.db.sortMode
        tab:SetAlpha(selected and 1 or TAB_DIM_ALPHA)
        tab:SetNormalFontObject(selected and "GameFontHighlightSmall" or "GameFontNormalSmall")
        tab:SetHighlightFontObject("GameFontHighlightSmall")
    end
end

function ns.Refresh()
    if not frame or not frame:IsShown() then return end

    local gear, summary = ns.GetGear()
    for index, data in ipairs(gear) do
        ApplyRow(rows[index], data, summary.average)
    end
    RefreshTabs()

    if summary.average then
        avgText:SetText(string.format("Average item level  |cff%s%.1f|r", Hex(NEAR_COLOR), summary.average))
    else
        avgText:SetText("Average item level  -")
    end
    emptyText:SetText(string.format("Empty slots  |cff%s%d|r",
        Hex(summary.emptyCount > 0 and ACCENT_TEXT_COLOR or NEAR_COLOR), summary.emptyCount))
end

-- Window ---------------------------------------------------------------------

local function CreateHeader()
    local mark = frame:CreateTexture(nil, "ARTWORK")
    mark:SetTexture(MARK)
    mark:SetSize(20, 20)
    mark:SetPoint("TOPLEFT", 10, -8)

    local title = NewText(frame, "GameFontNormal")
    title:SetPoint("TOPLEFT", 35, -12)
    title:SetText("Equipment Tracker")

    local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
    close:SetSize(24, 24)
    close:SetPoint("TOPRIGHT", -3, -3)
    close:SetScript("OnClick", function() SetPanelShown(false) end)

    avgText = NewText(frame, "GameFontNormal")
    avgText:SetPoint("TOPLEFT", 14, -35)
    avgText:SetJustifyH("LEFT")

    emptyText = NewText(frame, "GameFontNormal")
    emptyText:SetPoint("TOPRIGHT", -14, -35)
    emptyText:SetJustifyH("RIGHT")
end

local function CreateFooter()
    local gap = 2
    local width = 128
    for index, mode in ipairs(ns.SORT_MODES) do
        local tab = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
        tab:SetSize(width, 21)
        tab:SetPoint("BOTTOMLEFT", SIDE_MARGIN + (index - 1) * (width + gap), 9)
        tab:SetText(mode.label)
        tab.key = mode.key
        tab:SetScript("OnClick", function() ns.SetSortMode(mode.key) end)
        tabs[index] = tab
    end

    local legend = NewText(frame, "GameFontNormalSmall")
    legend:SetPoint("BOTTOMRIGHT", -SIDE_MARGIN, 13)
    legend:SetWidth(PANEL_WIDTH - SIDE_MARGIN * 2 - (#ns.SORT_MODES * (width + gap)) - 6)
    legend:SetJustifyH("RIGHT")
    legend:SetWordWrap(false)
    legend:SetTextColor(unpack(DIM_COLOR))
    legend:SetText("Upgrade: 3 lowest, and empty")
end

local function CreatePanel()
    local slotCount = #ns.GetSlots()
    local wasShown = ns.db.shown -- the hide/show scripts below overwrite it
    frame = CreateFrame("Frame", "RulZEquipmentTrackerFrame", UIParent, "BackdropTemplate")
    frame:SetSize(PANEL_WIDTH, HEADER_HEIGHT + slotCount * ROW_HEIGHT + FOOTER_HEIGHT)
    frame:SetScale(ns.db.scale)
    frame:SetFrameStrata("MEDIUM")
    frame:SetToplevel(true)
    frame:SetClampedToScreen(true)
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", function(self) self:StartMoving() end)
    frame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        SavePosition()
    end)
    frame:SetScript("OnShow", function()
        ns.db.shown = true
        ns.Refresh()
    end)
    frame:SetScript("OnHide", function(self)
        -- Hiding the whole UI also fires this; only an explicit hide counts.
        if not self:IsShown() then
            ns.db.shown = false
        end
    end)
    frame:SetBackdrop({
        bgFile = TOOLTIP_BG,
        edgeFile = TOOLTIP_BORDER,
        edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    frame:SetBackdropColor(unpack(PANEL_COLOR))
    frame:SetBackdropBorderColor(unpack(BORDER_COLOR))
    PlaceFrame()

    CreateHeader()
    for index = 1, slotCount do
        rows[index] = CreateRow(index)
    end
    CreateFooter()

    tinsert(UISpecialFrames, "RulZEquipmentTrackerFrame")
    frame:Hide()
    if wasShown then
        frame:Show()
    end
end

-- Minimap button -------------------------------------------------------------

local function PlaceMinimapButton()
    local angle = math.rad(ns.db.minimapAngle)
    local radius = Minimap:GetWidth() / 2 + 8
    minimapButton:ClearAllPoints()
    minimapButton:SetPoint("CENTER", Minimap, "CENTER", math.cos(angle) * radius, math.sin(angle) * radius)
end

local function DragMinimapButton()
    local centerX, centerY = Minimap:GetCenter()
    local cursorX, cursorY = GetCursorPosition()
    local scale = Minimap:GetEffectiveScale()
    ns.db.minimapAngle = math.deg(math.atan2(cursorY / scale - centerY, cursorX / scale - centerX))
    PlaceMinimapButton()
end

function ns.SetMinimapShown(shown)
    ns.db.minimapHidden = not shown
    if minimapButton then
        minimapButton:SetShown(shown)
    end
end

local function CreateMinimapButton()
    minimapButton = CreateFrame("Button", "RulZEquipmentTrackerMinimapButton", Minimap)
    minimapButton:SetSize(31, 31)
    minimapButton:SetFrameStrata("MEDIUM")
    minimapButton:SetFrameLevel(8)
    minimapButton:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
    minimapButton:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    minimapButton:RegisterForDrag("LeftButton")

    local background = minimapButton:CreateTexture(nil, "BACKGROUND")
    background:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
    background:SetVertexColor(0, 0, 0, 1)
    background:SetSize(20, 20)
    background:SetPoint("TOPLEFT", 6, -5)

    local icon = minimapButton:CreateTexture(nil, "ARTWORK")
    icon:SetTexture(MARK)
    icon:SetSize(16, 16)
    icon:SetPoint("TOPLEFT", 8, -7)

    local border = minimapButton:CreateTexture(nil, "OVERLAY")
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    border:SetSize(53, 53)
    border:SetPoint("TOPLEFT")

    minimapButton:SetScript("OnClick", function(_, button)
        if button == "RightButton" then
            ns.OpenOptions()
        else
            TogglePanel()
        end
    end)
    minimapButton:SetScript("OnDragStart", function(self)
        self:SetScript("OnUpdate", DragMinimapButton)
    end)
    minimapButton:SetScript("OnDragStop", function(self)
        self:SetScript("OnUpdate", nil)
    end)
    minimapButton:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:SetText("RulZ Equipment Tracker")
        GameTooltip:AddLine("Left-click: show or hide", 1, 1, 1)
        GameTooltip:AddLine("Right-click: settings", 1, 1, 1)
        GameTooltip:AddLine("Drag: move this button", 1, 1, 1)
        GameTooltip:Show()
    end)
    minimapButton:SetScript("OnLeave", function() GameTooltip:Hide() end)
    PlaceMinimapButton()
    minimapButton:SetShown(not ns.db.minimapHidden)
end

-- Character sheet button -----------------------------------------------------

-- A small "Gear" button in the character sheet's title bar, to the left of the
-- game's close button and clear of the title text. Safe to call repeatedly.
function ns.EnsureCharacterButton()
    if not CharacterFrame then return end
    if not characterButton then
        characterButton = CreateFrame("Button", "RulZEquipmentTrackerCharacterButton",
            PaperDollFrame or CharacterFrame, "UIPanelButtonTemplate")
        characterButton:SetSize(CHARACTER_BUTTON_WIDTH, 20)
        characterButton:SetPoint("TOPRIGHT", CharacterFrame, "TOPRIGHT", CHARACTER_BUTTON_RIGHT, -14)
        characterButton:SetText("Gear")
        characterButton:SetScript("OnClick", TogglePanel)
        characterButton:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText("RulZ Equipment Tracker")
            GameTooltip:AddLine("Show or hide the item level window", 1, 1, 1)
            GameTooltip:Show()
        end)
        characterButton:SetScript("OnLeave", function() GameTooltip:Hide() end)
    end
    if not characterHooked and CharacterFrame.HookScript then
        characterHooked = true
        CharacterFrame:HookScript("OnShow", ns.EnsureCharacterButton)
    end
end

-- Slash commands -------------------------------------------------------------

function ns.CreateUI()
    CreatePanel()
    if Minimap then
        CreateMinimapButton()
    end
    ns.EnsureCharacterButton()
end

local function ResetPosition()
    ns.db.position = nil
    PlaceFrame()
    print(PREFIX .. "window moved back to its starting place.")
end

SLASH_RULZEQUIPMENTTRACKER1 = "/rulzgear"
SLASH_RULZEQUIPMENTTRACKER2 = "/rgear"
SlashCmdList["RULZEQUIPMENTTRACKER"] = function(input)
    local command = strtrim(input or ""):lower()
    if command == "" then
        TogglePanel()
    elseif command == "minimap" or command == "minimap show" or command == "minimap hide" then
        local shown
        if command == "minimap show" then
            shown = true
        elseif command == "minimap hide" then
            shown = false
        else
            shown = ns.db.minimapHidden
        end
        ns.SetMinimapShown(shown)
        print(PREFIX .. (shown and "minimap button shown." or "minimap button hidden."))
    elseif command == "reset" then
        ResetPosition()
    elseif command == "config" then
        ns.OpenOptions()
    else
        print(PREFIX .. "/rulzgear or /rgear shows the window. Also: /rgear minimap [show|hide], "
            .. "/rgear reset (window position), /rgear config, /rgear help")
    end
end
