-- RulZ Level Up Tracker: settings page under Options > AddOns.
-- Uses a canvas page with the game's standard controls.
local ADDON_NAME, ns = ...

local CATEGORY_NAME = "RulZ Level Up Tracker"
local SCALE_STEP_PERCENT = 5

local category
local syncFunctions = {}

local function NewCheckbox(parent, label, y, isChecked, setChecked)
    local box = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    box:SetPoint("TOPLEFT", 16, y)
    local text = box:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    text:SetPoint("LEFT", box, "RIGHT", 4, 0)
    text:SetText(label)
    box:SetScript("OnClick", function(self) setChecked(self:GetChecked()) end)
    syncFunctions[#syncFunctions + 1] = function() box:SetChecked(isChecked()) end
end

local function NewScaleSlider(parent, y)
    local label = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    label:SetPoint("TOPLEFT", 20, y)
    label:SetText("Panel size")

    local slider = CreateFrame("Slider", nil, parent, "BackdropTemplate")
    slider:SetOrientation("HORIZONTAL")
    slider:SetSize(220, 17)
    slider:SetPoint("TOPLEFT", label, "BOTTOMLEFT", 0, -8)
    slider:SetMinMaxValues(ns.MIN_SCALE_PERCENT, ns.MAX_SCALE_PERCENT)
    slider:SetValueStep(SCALE_STEP_PERCENT)
    slider:SetObeyStepOnDrag(true)
    slider:SetThumbTexture("Interface\\Buttons\\UI-SliderBar-Button-Horizontal")
    slider:SetBackdrop({
        bgFile = "Interface\\Buttons\\UI-SliderBar-Background",
        edgeFile = "Interface\\Buttons\\UI-SliderBar-Border",
        tile = true,
        tileSize = 8,
        edgeSize = 8,
        insets = { left = 3, right = 3, top = 6, bottom = 6 },
    })

    local value = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    value:SetPoint("LEFT", slider, "RIGHT", 10, 0)

    slider:SetScript("OnValueChanged", function(_, percent, userInput)
        value:SetText(string.format("%d%%", percent))
        if userInput then
            ns.SetScalePercent(percent)
        end
    end)
    syncFunctions[#syncFunctions + 1] = function()
        slider:SetValue(math.floor(ns.db.scale * 100 + 0.5))
    end
end

function ns.CreateOptions()
    local page = CreateFrame("Frame")

    local title = page:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText(CATEGORY_NAME)

    NewCheckbox(page, "Show the tracker panel", -44,
        function() return ns.db.shown end, ns.SetPanelShown)
    NewCheckbox(page, "Compact mode (just the progress bar)", -72,
        function() return ns.db.compact end, ns.SetCompact)
    NewCheckbox(page, "Lock the panel in place", -100,
        function() return ns.db.locked end, ns.SetLocked)
    NewScaleSlider(page, -138)

    page:SetScript("OnShow", function()
        for _, sync in ipairs(syncFunctions) do
            sync()
        end
    end)

    category = Settings.RegisterCanvasLayoutCategory(page, CATEGORY_NAME)
    Settings.RegisterAddOnCategory(category)
end

function ns.OpenOptions()
    Settings.OpenToCategory(category:GetID())
end
