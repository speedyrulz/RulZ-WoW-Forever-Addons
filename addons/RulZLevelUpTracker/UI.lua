-- RulZ Level Up Tracker: panel, minimap button and slash commands.
-- Art comes from the game's own borders, fonts and buttons where possible.
local ADDON_NAME, ns = ...

local MARK = "Interface\\AddOns\\" .. ADDON_NAME .. "\\Media\\RulZMark"
local TOOLTIP_BG = "Interface\\Tooltips\\UI-Tooltip-Background"
local TOOLTIP_BORDER = "Interface\\Tooltips\\UI-Tooltip-Border"
local BAR_TEXTURE = "Interface\\TargetingFrame\\UI-StatusBar"

local PANEL_COLOR = { 0.04, 0.02, 0.02, 0.94 }
local BORDER_COLOR = { 0.62, 0.1, 0.1, 1 }
local BAR_COLOR = { 0.72, 0.07, 0.07 }
local RESTED_COLOR = { 0.36, 0.07, 0.09 }
local TRACK_COLOR = { 0.1, 0.02, 0.02, 0.9 }
local TAB_DIM_ALPHA = 0.62

local PANEL_WIDTH = 240
local PANEL_HEIGHT = 212
local COMPACT_WIDTH = 210
local COMPACT_HEIGHT = 28
local MIN_SCALE_PERCENT = 70
local MAX_SCALE_PERCENT = 150
local HISTORY_LINES = 20
local PREFIX = "|cffed0a14RulZ:|r "

ns.MIN_SCALE_PERCENT = MIN_SCALE_PERCENT
ns.MAX_SCALE_PERCENT = MAX_SCALE_PERCENT
local INNER_WIDTH = PANEL_WIDTH - 24

local frame, mark, barHolder, tabs, rows, etaLabel, etaValue, bar, restedBar, barText, minimapButton
local fullLayoutOnly = {} -- widgets hidden in compact mode

local function Commas(n)
    local text = tostring(math.floor(n + 0.5))
    local count
    repeat
        text, count = text:gsub("^(-?%d+)(%d%d%d)", "%1,%2")
    until count == 0
    return text
end

local function FormatTime(seconds)
    seconds = math.floor(seconds + 0.5)
    local days = math.floor(seconds / 86400)
    local hours = math.floor(seconds % 86400 / 3600)
    local minutes = math.floor(seconds % 3600 / 60)
    if days > 0 then
        return string.format("%dd %dh", days, hours)
    elseif hours > 0 then
        return string.format("%dh %dm", hours, minutes)
    elseif minutes > 0 then
        return string.format("%dm %ds", minutes, seconds % 60)
    end
    return string.format("%ds", seconds)
end

local function ClockTime(timestamp)
    return (date("%I:%M %p", timestamp):gsub("^0", ""))
end

-- The time and day the estimate lands on, assuming you keep playing.
local function FinishTime(secondsLeft)
    local now = time()
    local finish = now + secondsLeft
    local day = date("%Y%m%d", finish)
    if day == date("%Y%m%d", now) then
        return ClockTime(finish)
    elseif day == date("%Y%m%d", now + 86400) then
        return "tomorrow " .. ClockTime(finish)
    end
    return date("%b %d", finish):gsub(" 0", " ") .. " " .. ClockTime(finish)
end

local function LevelSummary(entry)
    return string.format("%s at %s XP per hour", FormatTime(entry.seconds),
        Commas(entry.xp / entry.seconds * 3600))
end

local function NewText(parent, fontObject)
    return parent:CreateFontString(nil, "OVERLAY", fontObject)
end

local function SavePosition()
    local point, _, relativePoint, x, y = frame:GetPoint()
    ns.db.position = { point, relativePoint, x, y }
end

local function SetPanelShown(shown)
    ns.db.shown = shown
    frame:SetShown(shown)
    ns.Refresh()
end
ns.SetPanelShown = SetPanelShown

local function ModeLabel()
    for _, mode in ipairs(ns.MODES) do
        if mode.key == ns.db.mode then
            return mode.label
        end
    end
end

local function CycleMode()
    for index, mode in ipairs(ns.MODES) do
        if mode.key == ns.db.mode then
            ns.SetMode(ns.MODES[index % #ns.MODES + 1].key)
            return
        end
    end
end

local function CreateHeader()
    mark = frame:CreateTexture(nil, "ARTWORK")
    mark:SetTexture(MARK)

    local title = NewText(frame, "GameFontNormal")
    title:SetPoint("TOPLEFT", 35, -12)
    title:SetText("Level Up Tracker")

    local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
    close:SetSize(24, 24)
    close:SetPoint("TOPRIGHT", -3, -3)
    close:SetScript("OnClick", function() SetPanelShown(false) end)

    fullLayoutOnly[#fullLayoutOnly + 1] = title
    fullLayoutOnly[#fullLayoutOnly + 1] = close
end

local function CreateEstimate()
    etaLabel = NewText(frame, "GameFontNormalSmall")
    etaLabel:SetPoint("TOP", 0, -33)

    etaValue = NewText(frame, "GameFontHighlightLarge")
    etaValue:SetPoint("TOP", 0, -47)

    fullLayoutOnly[#fullLayoutOnly + 1] = etaLabel
    fullLayoutOnly[#fullLayoutOnly + 1] = etaValue
end

local function CreateBar()
    barHolder = CreateFrame("Frame", nil, frame, "BackdropTemplate")
    barHolder:SetBackdrop({
        bgFile = TOOLTIP_BG,
        edgeFile = TOOLTIP_BORDER,
        edgeSize = 10,
        insets = { left = 2, right = 2, top = 2, bottom = 2 },
    })
    barHolder:SetBackdropColor(unpack(TRACK_COLOR))
    barHolder:SetBackdropBorderColor(unpack(BORDER_COLOR))

    restedBar = CreateFrame("StatusBar", nil, barHolder)
    restedBar:SetPoint("TOPLEFT", 3, -3)
    restedBar:SetPoint("BOTTOMRIGHT", -3, 3)
    restedBar:SetStatusBarTexture(BAR_TEXTURE)
    restedBar:SetStatusBarColor(unpack(RESTED_COLOR))

    bar = CreateFrame("StatusBar", nil, barHolder)
    bar:SetAllPoints(restedBar)
    bar:SetFrameLevel(restedBar:GetFrameLevel() + 1)
    bar:SetStatusBarTexture(BAR_TEXTURE)
    bar:SetStatusBarColor(unpack(BAR_COLOR))

    barText = NewText(bar, "GameFontHighlightSmall")
    barText:SetPoint("CENTER")
end

local function CreateRows()
    rows = {}
    local labels = { "XP per hour", "XP earned", "Time tracked", "Rested XP", "Kills left", "Quests left" }
    for index, label in ipairs(labels) do
        local y = -91 - (index - 1) * 14
        local name = NewText(frame, "GameFontNormalSmall")
        name:SetPoint("TOPLEFT", 12, y)
        name:SetText(label)
        local value = NewText(frame, "GameFontHighlightSmall")
        value:SetPoint("TOPRIGHT", -12, y)
        rows[index] = value
        fullLayoutOnly[#fullLayoutOnly + 1] = name
        fullLayoutOnly[#fullLayoutOnly + 1] = value
    end
end

local function CreateTabs()
    tabs = {}
    local gap = 1
    local width = (INNER_WIDTH - gap * (#ns.MODES - 1)) / #ns.MODES
    for index, mode in ipairs(ns.MODES) do
        local tab = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
        tab:SetSize(width, 21)
        tab:SetPoint("BOTTOMLEFT", 12 + (index - 1) * (width + gap), 9)
        tab:SetText(mode.label)
        tab.key = mode.key
        tab:SetScript("OnClick", function() ns.SetMode(mode.key) end)
        tabs[index] = tab
        fullLayoutOnly[#fullLayoutOnly + 1] = tab
    end
end

local function ApplyLayout()
    local compact = ns.db.compact
    for _, widget in ipairs(fullLayoutOnly) do
        widget:SetShown(not compact)
    end

    mark:ClearAllPoints()
    barHolder:ClearAllPoints()
    if compact then
        frame:SetSize(COMPACT_WIDTH, COMPACT_HEIGHT)
        mark:SetSize(16, 16)
        mark:SetPoint("LEFT", 8, 0)
        barHolder:SetSize(COMPACT_WIDTH - 34, 18)
        barHolder:SetPoint("LEFT", mark, "RIGHT", 4, 0)
    else
        frame:SetSize(PANEL_WIDTH, PANEL_HEIGHT)
        mark:SetSize(20, 20)
        mark:SetPoint("TOPLEFT", 10, -8)
        barHolder:SetSize(INNER_WIDTH, 18)
        barHolder:SetPoint("TOP", 0, -68)
    end
end

local function ShowCompactTooltip(self)
    if not ns.db.compact then return end
    GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
    GameTooltip:SetText("RulZ Level Up Tracker")
    GameTooltip:AddLine("Tracking: " .. ModeLabel(), 1, 1, 1)
    GameTooltip:AddLine("Right-click: next tracking mode", 1, 1, 1)
    GameTooltip:Show()
end

function ns.SetCompact(compact)
    ns.db.compact = compact
    ApplyLayout()
    ns.Refresh()
end

function ns.SetLocked(locked)
    ns.db.locked = locked
end

-- Offsets are measured in the frame's own scale, so the panel is re-anchored to
-- keep its centre in the same place on screen.
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

local function CreatePanel()
    frame = CreateFrame("Frame", "RulZLevelUpTrackerFrame", UIParent, "BackdropTemplate")
    frame:SetScale(ns.db.scale)
    frame:SetFrameStrata("MEDIUM")
    frame:SetClampedToScreen(true)
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", function(self)
        if not ns.db.locked then self:StartMoving() end
    end)
    frame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        SavePosition()
    end)
    frame:SetScript("OnMouseUp", function(_, button)
        if button == "RightButton" and ns.db.compact then CycleMode() end
    end)
    frame:SetScript("OnEnter", ShowCompactTooltip)
    frame:SetScript("OnLeave", function() GameTooltip:Hide() end)
    frame:SetBackdrop({
        bgFile = TOOLTIP_BG,
        edgeFile = TOOLTIP_BORDER,
        edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    frame:SetBackdropColor(unpack(PANEL_COLOR))
    frame:SetBackdropBorderColor(unpack(BORDER_COLOR))

    local position = ns.db.position
    if position then
        frame:SetPoint(position[1], UIParent, position[2], position[3], position[4])
    else
        frame:SetPoint("CENTER", UIParent, "CENTER", 320, 120)
    end

    CreateHeader()
    CreateEstimate()
    CreateBar()
    CreateRows()
    CreateTabs()
    ApplyLayout()
    frame:SetShown(ns.db.shown)
end

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

local function CreateMinimapButton()
    minimapButton = CreateFrame("Button", "RulZLevelUpTrackerMinimapButton", Minimap)
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
            CycleMode()
        else
            SetPanelShown(not ns.db.shown)
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
        GameTooltip:SetText("RulZ Level Up Tracker")
        GameTooltip:AddLine("Left-click: show or hide", 1, 1, 1)
        GameTooltip:AddLine("Right-click: next tracking mode", 1, 1, 1)
        GameTooltip:AddLine("Drag: move this button", 1, 1, 1)
        GameTooltip:Show()
    end)
    minimapButton:SetScript("OnLeave", function() GameTooltip:Hide() end)
    PlaceMinimapButton()
end

local function RefreshTabs()
    for _, tab in ipairs(tabs) do
        local selected = tab.key == ns.db.mode
        tab:SetAlpha(selected and 1 or TAB_DIM_ALPHA)
        tab:SetNormalFontObject(selected and "GameFontHighlightSmall" or "GameFontNormalSmall")
        tab:SetHighlightFontObject("GameFontHighlightSmall")
    end
end

function ns.Refresh()
    if not frame or not frame:IsShown() then return end

    RefreshTabs()

    local cur, max, level, atMax = ns.GetProgress()
    local xp, seconds, perSecond = ns.GetStats(ns.db.mode)

    local rested = ns.GetRested()

    bar:SetMinMaxValues(0, math.max(max, 1))
    bar:SetValue(atMax and max or cur)
    restedBar:SetMinMaxValues(0, math.max(max, 1))
    restedBar:SetValue(atMax and 0 or math.min(cur + rested, max))
    rows[1]:SetText(perSecond and Commas(perSecond * 3600) or "-")
    rows[2]:SetText(Commas(xp))
    rows[3]:SetText(FormatTime(seconds) .. (ns.IsPaused() and " (AFK)" or ""))
    rows[4]:SetText(rested > 0 and Commas(rested) or "-")

    if atMax then
        etaLabel:SetText("Level " .. level)
        etaValue:SetText("Max level")
        barText:SetText(ns.db.compact and "Max level" or "")
        rows[5]:SetText("-")
        rows[6]:SetText("-")
        return
    end

    local percent = max > 0 and math.floor(cur / max * 100) or 0
    local secondsLeft = ns.GetEstimate(ns.db.mode, max - cur)
    local killsLeft, questsLeft = ns.GetKillsAndQuestsLeft(max - cur, level)
    if ns.db.compact then
        barText:SetText(string.format("%s: %s (%d%%)", ModeLabel(),
            secondsLeft and FormatTime(secondsLeft) or "Gathering data", percent))
    else
        barText:SetText(string.format("%s / %s (%d%%)", Commas(cur), Commas(max), percent))
    end
    etaValue:SetText(secondsLeft and FormatTime(secondsLeft) or "Gathering data")
    rows[5]:SetText("~" .. Commas(killsLeft))
    rows[6]:SetText("~" .. Commas(questsLeft))
    if secondsLeft then
        etaLabel:SetText(string.format("%s: level %d at %s", ModeLabel(), level + 1, FinishTime(secondsLeft)))
    else
        etaLabel:SetText(string.format("%s: time to level %d", ModeLabel(), level + 1))
    end
end

function ns.AnnounceLevel(entry)
    if entry.partial then
        print(string.format("%sLevel %d reached! Level %d was only partly tracked, so there's no time for it.",
            PREFIX, entry.level + 1, entry.level))
    else
        print(string.format("%sLevel %d reached in %s.", PREFIX, entry.level + 1, LevelSummary(entry)))
    end
end

local function ShowHistory()
    local history = ns.db.history
    if #history == 0 then
        print(PREFIX .. "no levels recorded yet.")
        return
    end
    print(PREFIX .. "time spent on each level:")
    for index = math.max(#history - HISTORY_LINES + 1, 1), #history do
        local entry = history[index]
        print(string.format("  Level %d: %s", entry.level,
            entry.partial and "partly tracked" or LevelSummary(entry)))
    end
end

function ns.CreateUI()
    CreatePanel()
    if Minimap then
        CreateMinimapButton()
    end
end

SLASH_RULZLEVELUPTRACKER1 = "/rulz"
SlashCmdList["RULZLEVELUPTRACKER"] = function(input)
    local command = strtrim(input or ""):lower()
    local scalePercent = tonumber(command:match("^scale%s+(%d+)$"))
    if command == "" then
        SetPanelShown(not ns.db.shown)
    elseif scalePercent then
        ns.SetScalePercent(scalePercent)
    elseif command == "compact" then
        ns.SetCompact(not ns.db.compact)
    elseif command == "lock" then
        ns.SetLocked(not ns.db.locked)
        print(PREFIX .. (ns.db.locked and "panel locked." or "panel unlocked."))
    elseif command == "config" then
        ns.OpenOptions()
    elseif command == "reset" then
        ns.Reset(ns.db.mode)
        print(PREFIX .. "reset the selected tracking mode.")
    elseif command == "history" then
        ShowHistory()
    elseif command == "hour" or command == "session" or command == "level" or command == "alltime" then
        ns.SetMode(command)
    else
        print(PREFIX .. "/rulz, /rulz hour, /rulz session, /rulz level, /rulz alltime, /rulz history, "
            .. "/rulz compact, /rulz lock, /rulz scale 70-150, /rulz config, /rulz reset")
    end
end
