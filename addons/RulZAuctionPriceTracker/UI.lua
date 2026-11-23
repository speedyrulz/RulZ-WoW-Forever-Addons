-- RulZ Auction and Price Tracker: window, minimap, auction button and commands.
local ADDON_NAME, ns = ...

local MARK = "Interface\\AddOns\\RulZAuctionPriceTracker\\Media\\RulZMark"
local PANEL_COLOR = { 0.04, 0.02, 0.02, 0.94 }
local BORDER_COLOR = { 0.62, 0.1, 0.1, 1 }
local ROW_HEIGHT, ROW_COUNT = 26, 12
local MIN_SCALE_PERCENT, MAX_SCALE_PERCENT = 70, 130
ns.MIN_SCALE_PERCENT, ns.MAX_SCALE_PERCENT = MIN_SCALE_PERCENT, MAX_SCALE_PERCENT

local frame, minimapButton, auctionButton, search, slider, emptyText, footer, scanButton
local historyTitle, historySummary, bars = nil, nil, {}
local rows, headers, items = {}, {}, {}
local selected, selectedItem, offset, dirty, searchDelay = nil, nil, 0, true, nil
local scanElapsed, auctionElapsed, ageElapsed, scanDirty = 0, 0, 0, true
local AGE_INTERVAL = 30             -- seconds between refreshes of "x min ago"
local columns = {
    { key = "name", label = "Item", x = 12, width = 170 },
    { key = "low", label = "Lowest", x = 182, width = 120 },
    { key = "market", label = "Market", x = 302, width = 120 },
    { key = "qty", label = "Qty", x = 422, width = 52 },
    { key = "seen", label = "Last seen", x = 474, width = 95 },
}

local function Text(parent, font, x, y, width, align)
    local text = parent:CreateFontString(nil, "OVERLAY", font or "GameFontHighlightSmall")
    text:SetPoint("TOPLEFT", x, y)
    if width then text:SetWidth(width) end
    text:SetJustifyH(align or "LEFT")
    text:SetWordWrap(false)
    return text
end

local function Money(value)
    return value and ns.FormatMoney(value) or "-"
end

local function PlaceFrame()
    frame:ClearAllPoints()
    local p = ns.db.position
    if p then frame:SetPoint(p[1], UIParent, p[2], p[3], p[4])
    else frame:SetPoint("CENTER", UIParent, "CENTER", -200, 0) end
end

local function SavePosition()
    local point, _, relativePoint, x, y = frame:GetPoint()
    ns.db.position = { point, relativePoint, x, y }
end

function ns.SetPanelShown(shown)
    if frame then frame:SetShown(shown) end
end

function ns.SetScalePercent(percent)
    percent = math.min(math.max(percent, MIN_SCALE_PERCENT), MAX_SCALE_PERCENT)
    local oldScale = frame:GetScale()
    local x, y = frame:GetCenter()
    ns.db.scale = percent / 100
    frame:SetScale(ns.db.scale)
    if x and y then
        frame:ClearAllPoints()
        frame:SetPoint("CENTER", UIParent, "BOTTOMLEFT", x * oldScale / ns.db.scale, y * oldScale / ns.db.scale)
        SavePosition()
    end
end

local function TogglePanel()
    if frame then ns.SetPanelShown(not frame:IsShown()) end
end

local function LinkFor(item)
    if not item or not item.id then return nil end
    local getter = C_Item and C_Item.GetItemInfo or GetItemInfo
    if getter then
        local _, link = getter(item.id)
        -- A base item link cannot represent a random suffix.
        if link and item.key == tostring(item.id) then return ns.Clean(link) end
    end
end

local function IconFor(id)
    local getter = C_Item and C_Item.GetItemInfoInstant or GetItemInfoInstant
    if getter and id then
        local _, _, _, _, icon = getter(id)
        return ns.Clean(icon)
    end
end

local function UpdateHistory()
    -- A selected item the search has filtered out keeps its last known entry.
    for _, entry in ipairs(items) do
        if entry.key == selected then
            selectedItem = entry
            break
        end
    end
    local item = selected and selectedItem or nil
    historyTitle:SetText(item and (item.name or ("Item " .. tostring(item.id))) or "Select an item for history")
    local history = selected and ns.GetHistory(selected) or {}
    history = history or {}
    local low, high, maxPrice
    for _, day in ipairs(history) do
        if day.low then
            low = not low and day.low or math.min(low, day.low)
            high = not high and day.low or math.max(high, day.low)
            maxPrice = not maxPrice and day.low or math.max(maxPrice, day.low)
        end
        if day.market then maxPrice = math.max(maxPrice or 0, day.market) end
    end
    local price = selected and ns.GetPrice(selected) or nil
    historySummary:SetText(price and ("Lowest: " .. Money(price.low) .. "   Market: " .. Money(price.market)
        .. "   Qty: " .. tostring(price.qty or "-") .. "   Last seen: "
        .. (price.seen and ns.FormatAge(price.seen) or "-") .. "\n30-day low: " .. Money(low)
        .. "   High: " .. Money(high)) or (selected and "No price recorded." or ""))
    local byDay = {}
    for _, day in ipairs(history) do byDay[day.day] = day end
    local today = ns.Today()
    for index, bar in ipairs(bars) do
        local day = today and byDay[today - 30 + index] or nil
        bar.data = day
        if day and day.low and maxPrice and maxPrice > 0 then
            bar.fill:SetHeight(math.max(2, 76 * day.low / maxPrice))
            bar:Show()
        else
            if GameTooltip:IsShown() and GameTooltip:GetOwner() == bar then GameTooltip:Hide() end
            bar:Hide()
        end
    end
end

local function UpdateRows()
    local maximum = math.max(0, #items - ROW_COUNT)
    offset = math.min(offset, maximum)
    slider:SetMinMaxValues(0, maximum)
    slider:SetValue(offset)
    slider:SetShown(maximum > 0)
    for index, row in ipairs(rows) do
        local item = items[offset + index]
        row.item = item
        if item then
            row:Show()
            row.tint:SetShown(item.key == selected)
            row.marker:SetShown(item.key == selected)
            row.icon:SetTexture(IconFor(item.id) or 134400)
            local color = item.quality and ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[item.quality]
            if color then row.cells[1]:SetTextColor(color.r, color.g, color.b)
            else row.cells[1]:SetTextColor(1, 1, 1) end
            row.cells[1]:SetText(item.name or ("Item " .. tostring(item.id or "?")))
            row.cells[2]:SetText(Money(item.low))
            row.cells[3]:SetText(Money(item.market))
            row.cells[4]:SetText(item.qty and tostring(item.qty) or "-")
            row.cells[5]:SetText(item.seen and ns.FormatAge(item.seen) or "-")
        else row:Hide() end
        -- A tooltip open on this row belongs to the item that was here before.
        if GameTooltip:IsShown() and GameTooltip:GetOwner() == row and row.tipKey ~= (item and item.key) then
            if item then row:GetScript("OnEnter")(row) else GameTooltip:Hide() end
        end
    end
end

local function RefreshItems()
    if not frame or not frame:IsShown() or not dirty then return end
    items = ns.GetItems(search:GetText() or "", ns.db.sortKey, ns.db.sortAscending) or {}
    dirty = false
    for _, header in ipairs(headers) do
        header:SetText(header.label .. (header.key == ns.db.sortKey and (ns.db.sortAscending and " ^" or " v") or ""))
    end
    local summary = ns.GetSummary() or {}
    if #items == 0 then
        if (summary.items or 0) == 0 then emptyText:SetText("No saved items yet. Open the auction house and click RulZ Scan.")
        else emptyText:SetText("No items match your search.") end
        emptyText:Show()
    else emptyText:Hide() end
    UpdateRows()
    UpdateHistory()
end

local function ScanClick()
    local ok, reason = ns.StartFullScan()
    if not ok and reason then print(ns.PREFIX .. reason) end
end

local function ScanLabel(status)
    if status.state == "waiting" or status.state == "reading" or status.state == "saving" then
        return "Scan " .. math.floor((status.progress or 0) * 100) .. "%"
    end
    if (status.cooldown or 0) > 0 then return "Scan in " .. math.ceil(status.cooldown / 60) .. "m" end
    return "RulZ Scan"
end

local function UpdateScan()
    local status = ns.GetScanStatus() or {}
    if auctionButton then
        auctionButton:SetText(ScanLabel(status))
        auctionButton:SetEnabled(status.state == "idle")
    end
    if frame and frame:IsShown() then
        local summary = ns.GetSummary() or {}
        footer:SetText((status.text or "Ready") .. "  |  " .. tostring(summary.items or 0) .. " items  |  Last full scan: "
            .. (summary.lastFull and ns.FormatAge(summary.lastFull) or "never"))
        scanButton:SetEnabled(status.state == "idle")
        scanButton:SetText(ScanLabel(status))
        if dirty and not searchDelay and status.state == "idle" then RefreshItems() end
    end
    scanDirty = false
end

function ns.EnsureAuctionButton()
    if not AuctionHouseFrame then return end
    if not auctionButton then
        auctionButton = CreateFrame("Button", "RulZAuctionPriceTrackerAuctionButton", AuctionHouseFrame, "UIPanelButtonTemplate")
        auctionButton:SetSize(100, 20)
        auctionButton:SetPoint("TOPLEFT", AuctionHouseFrame, "TOPLEFT", 64, -1)
        -- The tooltip explains why it is disabled, so it must show then too.
        auctionButton:SetMotionScriptsWhileDisabled(true)
        auctionButton:SetScript("OnClick", ScanClick)
        auctionButton:SetScript("OnEnter", function(self)
            local status = ns.GetScanStatus() or {}
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText("RulZ full scan")
            GameTooltip:AddLine(status.text or "Record auction prices for this realm.", 1, 1, 1, true)
            GameTooltip:AddLine("Full scans are limited by the auction house.", 1, 1, 1, true)
            GameTooltip:Show()
        end)
        auctionButton:SetScript("OnLeave", function() GameTooltip:Hide() end)
    end
    UpdateScan()
end

local function CreateRow(index)
    local row = CreateFrame("Button", nil, frame)
    row:SetSize(557, ROW_HEIGHT)
    row:SetPoint("TOPLEFT", 12, -105 - (index - 1) * ROW_HEIGHT)
    row.tint = row:CreateTexture(nil, "BACKGROUND")
    row.tint:SetAllPoints()
    row.tint:SetColorTexture(0.929, 0, 0.051, 0.12)
    row.marker = row:CreateTexture(nil, "ARTWORK")
    row.marker:SetPoint("TOPLEFT", 0, -2)
    row.marker:SetPoint("BOTTOMLEFT", 0, 2)
    row.marker:SetWidth(3)
    row.marker:SetColorTexture(0.929, 0, 0.051, 1)
    row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetSize(22, 22)
    row.icon:SetPoint("LEFT", 5, 0)
    row.cells = {}
    for i, col in ipairs(columns) do
        local inset = i == 1 and 28 or 2
        row.cells[i] = Text(row, nil, col.x - 12 + inset, -6, col.width - inset - 4, i == 1 and "LEFT" or "RIGHT")
    end
    row:SetScript("OnClick", function(self)
        if not self.item then return end
        local link = LinkFor(self.item)
        if IsShiftKeyDown() and link and ChatEdit_InsertLink then ChatEdit_InsertLink(link)
        else
            selected, selectedItem = self.item.key, self.item
            UpdateRows()
            UpdateHistory()
        end
    end)
    row:SetScript("OnEnter", function(self)
        if not self.item then return end
        self.tipKey = self.item.key
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        local link = LinkFor(self.item)
        if link then GameTooltip:SetHyperlink(link)
        elseif self.item.id and GameTooltip.SetItemByID then GameTooltip:SetItemByID(self.item.id)
        else GameTooltip:SetText(self.item.name or "Item") end
        GameTooltip:Show()
    end)
    row:SetScript("OnLeave", function() GameTooltip:Hide() end)
    return row
end

local function CreatePanel()
    local wasShown = ns.db.shown
    frame = CreateFrame("Frame", "RulZAuctionPriceTrackerFrame", UIParent, "BackdropTemplate")
    frame:SetSize(590, 620)
    frame:SetScale(ns.db.scale)
    frame:SetFrameStrata("MEDIUM")
    frame:SetToplevel(true)
    frame:SetClampedToScreen(true)
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", function(self) self:StartMoving() end)
    frame:SetScript("OnDragStop", function(self) self:StopMovingOrSizing(); SavePosition() end)
    frame:SetBackdrop({ bgFile = "Interface\\Tooltips\\UI-Tooltip-Background", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", edgeSize = 16, insets = { left = 4, right = 4, top = 4, bottom = 4 } })
    frame:SetBackdropColor(unpack(PANEL_COLOR))
    frame:SetBackdropBorderColor(unpack(BORDER_COLOR))
    PlaceFrame()
    local mark = frame:CreateTexture(nil, "ARTWORK")
    mark:SetTexture(MARK); mark:SetSize(20, 20); mark:SetPoint("TOPLEFT", 10, -8)
    Text(frame, "GameFontNormal", 35, -12):SetText("Auction and Price Tracker")
    local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
    close:SetSize(24, 24); close:SetPoint("TOPRIGHT", -3, -3)
    close:SetScript("OnClick", function() ns.SetPanelShown(false) end)
    search = CreateFrame("EditBox", nil, frame, "InputBoxTemplate")
    search:SetSize(300, 22); search:SetPoint("TOPLEFT", 20, -42); search:SetAutoFocus(false)
    local hint = search:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    hint:SetPoint("LEFT", 4, 0)
    hint:SetText("Search saved items")
    search:SetScript("OnTextChanged", function(self)
        hint:SetShown((self:GetText() or "") == "")
        searchDelay = 0.2
    end)
    search:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    search:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    local clear = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    clear:SetSize(50, 21); clear:SetPoint("LEFT", search, "RIGHT", 8, 0); clear:SetText("Clear")
    clear:SetScript("OnClick", function() search:SetText(""); search:ClearFocus() end)
    for _, col in ipairs(columns) do
        local header = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
        header:SetSize(col.width - 2, 20); header:SetPoint("TOPLEFT", col.x, -81)
        header.key, header.label = col.key, col.label
        header:SetScript("OnClick", function()
            if ns.db.sortKey == col.key then ns.db.sortAscending = not ns.db.sortAscending
            else ns.db.sortKey = col.key; ns.db.sortAscending = true end
            offset = 0; dirty = true; RefreshItems()
        end)
        headers[#headers + 1] = header
    end
    for i = 1, ROW_COUNT do rows[i] = CreateRow(i) end
    slider = CreateFrame("Slider", nil, frame)
    slider:SetOrientation("VERTICAL")
    slider:SetSize(10, ROW_COUNT * ROW_HEIGHT)
    slider:SetPoint("TOPRIGHT", -8, -105)
    local track = slider:CreateTexture(nil, "BACKGROUND")
    track:SetAllPoints()
    track:SetColorTexture(1, 1, 1, 0.08)
    local thumb = slider:CreateTexture(nil, "ARTWORK")
    thumb:SetSize(10, 40)
    thumb:SetColorTexture(0.639, 0.639, 0.671, 0.8)
    slider:SetThumbTexture(thumb)
    slider:SetMinMaxValues(0, 0)
    slider:SetValueStep(1)
    slider:SetObeyStepOnDrag(true)
    slider:SetScript("OnValueChanged", function(_, value)
        local nextOffset = math.floor(value + 0.5)
        if nextOffset ~= offset then offset = nextOffset; UpdateRows() end
    end)
    frame:EnableMouseWheel(true)
    frame:SetScript("OnMouseWheel", function(_, delta)
        offset = math.max(0, math.min(math.max(0, #items - ROW_COUNT), offset - delta * 3)); UpdateRows()
    end)
    emptyText = Text(frame, "GameFontHighlightSmall", 20, -145, 530)
    historyTitle = Text(frame, "GameFontNormal", 14, -425, 550)
    historySummary = Text(frame, "GameFontHighlightSmall", 14, -447, 550)
    historySummary:SetWordWrap(true)
    for i = 1, 30 do
        local bar = CreateFrame("Frame", nil, frame)
        bar:SetSize(16, 76); bar:SetPoint("BOTTOMLEFT", 14 + (i - 1) * 18, 54)
        bar:EnableMouse(true)
        bar.fill = bar:CreateTexture(nil, "ARTWORK")
        bar.fill:SetPoint("BOTTOMLEFT"); bar.fill:SetPoint("BOTTOMRIGHT"); bar.fill:SetColorTexture(0.929, 0, 0.051, 1)
        bar:SetScript("OnEnter", function(self)
            if not self.data then return end
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText(date("!%Y-%m-%d", self.data.day * 86400))
            GameTooltip:AddLine("Lowest: " .. Money(self.data.low), 1, 1, 1)
            GameTooltip:AddLine("Market: " .. Money(self.data.market), 1, 1, 1)
            GameTooltip:Show()
        end)
        bar:SetScript("OnLeave", function() GameTooltip:Hide() end)
        bars[i] = bar
    end
    footer = Text(frame, "GameFontHighlightSmall", 14, -588, 435)
    scanButton = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    scanButton:SetSize(110, 22); scanButton:SetPoint("BOTTOMRIGHT", -12, 12); scanButton:SetScript("OnClick", ScanClick)
    frame:SetScript("OnShow", function() ns.db.shown = true; RefreshItems(); UpdateScan() end)
    frame:SetScript("OnHide", function(self) if not self:IsShown() then ns.db.shown = false end end)
    tinsert(UISpecialFrames, "RulZAuctionPriceTrackerFrame")
    frame:Hide()
    if wasShown then frame:Show() end
end

-- Minimap button -------------------------------------------------------------
local function PlaceMinimapButton()
    local angle = math.rad(ns.db.minimapAngle)
    local radius = Minimap:GetWidth() / 2 + 8
    minimapButton:ClearAllPoints()
    minimapButton:SetPoint("CENTER", Minimap, "CENTER", math.cos(angle) * radius, math.sin(angle) * radius)
end

function ns.SetMinimapShown(shown)
    ns.db.minimapHidden = not shown
    if minimapButton then minimapButton:SetShown(shown) end
end

local function CreateMinimapButton()
    minimapButton = CreateFrame("Button", "RulZAuctionPriceTrackerMinimapButton", Minimap)
    minimapButton:SetSize(31, 31); minimapButton:SetFrameStrata("MEDIUM"); minimapButton:SetFrameLevel(8)
    minimapButton:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
    minimapButton:RegisterForClicks("LeftButtonUp", "RightButtonUp"); minimapButton:RegisterForDrag("LeftButton")
    local bg = minimapButton:CreateTexture(nil, "BACKGROUND")
    bg:SetTexture("Interface\\Minimap\\UI-Minimap-Background"); bg:SetVertexColor(0, 0, 0, 1); bg:SetSize(20, 20); bg:SetPoint("TOPLEFT", 6, -5)
    local icon = minimapButton:CreateTexture(nil, "ARTWORK")
    icon:SetTexture(MARK); icon:SetSize(16, 16); icon:SetPoint("TOPLEFT", 8, -7)
    local border = minimapButton:CreateTexture(nil, "OVERLAY")
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder"); border:SetSize(53, 53); border:SetPoint("TOPLEFT")
    minimapButton:SetScript("OnClick", function(_, button) if button == "RightButton" then ns.OpenOptions() else TogglePanel() end end)
    minimapButton:SetScript("OnDragStart", function(self)
        self:SetScript("OnUpdate", function()
            local x, y = Minimap:GetCenter(); local cx, cy = GetCursorPosition(); local scale = Minimap:GetEffectiveScale()
            if x and y and scale and scale ~= 0 then ns.db.minimapAngle = math.deg(math.atan2(cy / scale - y, cx / scale - x)); PlaceMinimapButton() end
        end)
    end)
    minimapButton:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)
    minimapButton:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT"); GameTooltip:SetText("RulZ Auction and Price Tracker")
        GameTooltip:AddLine("Left-click: show or hide", 1, 1, 1); GameTooltip:AddLine("Right-click: settings", 1, 1, 1)
        GameTooltip:AddLine("Drag: move this button", 1, 1, 1); GameTooltip:Show()
    end)
    minimapButton:SetScript("OnLeave", function() GameTooltip:Hide() end)
    PlaceMinimapButton(); minimapButton:SetShown(not ns.db.minimapHidden)
end

function ns.CreateUI()
    CreatePanel()
    if Minimap then CreateMinimapButton() end
    local driver = CreateFrame("Frame")
    driver:SetScript("OnUpdate", function(_, elapsed)
        if searchDelay and frame:IsShown() then
            searchDelay = searchDelay - elapsed
            if searchDelay <= 0 then searchDelay = nil; offset = 0; dirty = true; RefreshItems() end
        end
        ageElapsed = ageElapsed + elapsed
        if ageElapsed >= AGE_INTERVAL then
            ageElapsed = 0
            if frame:IsShown() then UpdateRows() end
            scanDirty = true
        end
        scanElapsed = scanElapsed + elapsed
        auctionElapsed = auctionElapsed + elapsed
        if (scanDirty and scanElapsed >= 0.2) or (ns.IsAuctionOpen() and auctionElapsed >= 1) then
            scanElapsed, auctionElapsed = 0, 0
            -- Also adds the button when the game's window loaded late.
            if ns.IsAuctionOpen() and not auctionButton then ns.EnsureAuctionButton() end
            UpdateScan()
        end
    end)
    ns.RegisterCallback("PRICES", function()
        dirty = true
        -- A scan saves prices for many seconds; the list is rebuilt once at its end.
        if frame:IsShown() and ns.GetScanStatus().state == "idle" then
            RefreshItems()
            UpdateScan()
        end
    end)
    ns.RegisterCallback("SCAN", function() scanDirty = true end)
    ns.RegisterCallback("AUCTION", function() scanDirty = true end)
end

SLASH_RULZAUCTIONPRICETRACKER1 = "/rulzah"
SLASH_RULZAUCTIONPRICETRACKER2 = "/rah"
SlashCmdList["RULZAUCTIONPRICETRACKER"] = function(input)
    local command = strtrim(input or ""):lower()
    if command == "" then TogglePanel()
    elseif command == "scan" then ScanClick()
    elseif command == "minimap" or command == "minimap show" or command == "minimap hide" then
        local shown = command == "minimap show" or (command == "minimap" and ns.db.minimapHidden)
        ns.SetMinimapShown(shown)
        print(ns.PREFIX .. (shown and "minimap button shown." or "minimap button hidden."))
    elseif command == "reset" then ns.db.position = nil; PlaceFrame(); print(ns.PREFIX .. "window moved back to its starting place.")
    elseif command == "status" then
        for _, line in ipairs(ns.GetDiagnostics()) do print(ns.PREFIX .. line) end
    elseif command == "config" then ns.OpenOptions()
    else print(ns.PREFIX .. "/rah toggles the window. Also: scan, status, minimap [show|hide], reset, config, help.") end
end
