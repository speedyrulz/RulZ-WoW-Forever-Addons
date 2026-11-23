-- RulZ Auction and Price Tracker: settings page under Options > AddOns.
local ADDON_NAME, ns = ...
local CATEGORY_NAME = "RulZ Auction and Price Tracker"
local category
local syncFunctions = {}

local function NewCheckbox(parent, label, y, isChecked, setChecked)
    local box = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    box:SetPoint("TOPLEFT", 16, y)
    local text = box:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    text:SetPoint("LEFT", box, "RIGHT", 4, 0)
    text:SetText(label)
    box:SetScript("OnClick", function(self) setChecked(self:GetChecked() and true or false) end)
    syncFunctions[#syncFunctions + 1] = function() box:SetChecked(isChecked()) end
end

local function NewScaleSlider(parent, y)
    local label = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    label:SetPoint("TOPLEFT", 20, y); label:SetText("Window size")
    local slider = CreateFrame("Slider", nil, parent, "BackdropTemplate")
    slider:SetOrientation("HORIZONTAL"); slider:SetSize(220, 17)
    slider:SetPoint("TOPLEFT", label, "BOTTOMLEFT", 0, -8)
    slider:SetMinMaxValues(ns.MIN_SCALE_PERCENT, ns.MAX_SCALE_PERCENT)
    slider:SetValueStep(5); slider:SetObeyStepOnDrag(true)
    slider:SetThumbTexture("Interface\\Buttons\\UI-SliderBar-Button-Horizontal")
    slider:SetBackdrop({ bgFile = "Interface\\Buttons\\UI-SliderBar-Background", edgeFile = "Interface\\Buttons\\UI-SliderBar-Border", tile = true, tileSize = 8, edgeSize = 8, insets = { left = 3, right = 3, top = 6, bottom = 6 } })
    local value = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    value:SetPoint("LEFT", slider, "RIGHT", 10, 0)
    slider:SetScript("OnValueChanged", function(_, percent, userInput)
        value:SetText(string.format("%d%%", percent))
        if userInput then ns.SetScalePercent(percent) end
    end)
    syncFunctions[#syncFunctions + 1] = function()
        local percent = math.floor(ns.db.scale * 100 + 0.5)
        slider:SetValue(percent)
        -- Set here too: the slider says nothing when its value didn't change.
        value:SetText(string.format("%d%%", percent))
    end
end

function ns.CreateOptions()
    local page = CreateFrame("Frame")
    local title = page:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16); title:SetText(CATEGORY_NAME)
    NewCheckbox(page, "Show the price window", -44, function() return ns.db.shown end, ns.SetPanelShown)
    NewCheckbox(page, "Show the minimap button", -72, function() return not ns.db.minimapHidden end, ns.SetMinimapShown)
    local fields = {
        { "Show lowest buyout in tooltips", "tipLow" },
        { "Show market price in tooltips", "tipMarket" },
        { "Show vendor price in tooltips", "tipVendor" },
        { "Record prices while browsing", "passive" },
        { "Scan when the auction house opens", "autoScan" },
    }
    for index, entry in ipairs(fields) do
        local key = entry[2]
        NewCheckbox(page, entry[1], -72 - index * 28, function() return ns.db[key] end, function(on) ns.db[key] = on end)
    end
    NewScaleSlider(page, -238)
    page:SetScript("OnShow", function() for _, sync in ipairs(syncFunctions) do sync() end end)
    category = Settings.RegisterCanvasLayoutCategory(page, CATEGORY_NAME)
    Settings.RegisterAddOnCategory(category)
end

function ns.OpenOptions()
    if category then Settings.OpenToCategory(category:GetID()) end
end
