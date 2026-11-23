-- RulZ Auction and Price Tracker: saved variables, callbacks and shared helpers.
local ADDON_NAME, ns = ...

local DB_VERSION = 1
local DEFAULT_MINIMAP_ANGLE = 275
local PRICES_INTERVAL = 1             -- seconds; "PRICES" is sent at most this often
local SORT_KEYS = { name = true, low = true, market = true, qty = true, seen = true }

ns.PREFIX = "|cffed0a14RulZ:|r "

-- Values are checked in case the client marks them as secret; arithmetic or a
-- boolean test on a secret value raises an error.
local function IsSecret(value)
    return issecretvalue and issecretvalue(value)
end
ns.IsSecret = IsSecret

local function Clean(value)
    if IsSecret(value) then
        return nil
    end
    return value
end
ns.Clean = Clean

-- Saved variables ------------------------------------------------------------

local DEFAULTS = {
    shown = false,
    minimapAngle = DEFAULT_MINIMAP_ANGLE,
    minimapHidden = false,
    scale = 1,
    sortKey = "name",
    sortAscending = true,
    tipLow = true,
    tipMarket = true,
    tipVendor = true,
    passive = true,
    autoScan = false,
}

local function InitDB()
    local root = RulZAuctionPriceTrackerDB
    if type(root) ~= "table" then
        root = {}
        RulZAuctionPriceTrackerDB = root
    end
    if type(root.version) ~= "number" then root.version = DB_VERSION end
    if type(root.settings) ~= "table" then root.settings = {} end
    if type(root.names) ~= "table" then root.names = {} end
    if type(root.realms) ~= "table" then root.realms = {} end
    if type(root.lastRequest) ~= "number" then root.lastRequest = nil end

    local settings = root.settings
    for key, default in pairs(DEFAULTS) do
        if type(settings[key]) ~= type(default) then
            settings[key] = default
        end
    end
    if not SORT_KEYS[settings.sortKey] then settings.sortKey = DEFAULTS.sortKey end
    if type(settings.position) ~= "table" then settings.position = nil end

    ns.root = root
    ns.db = settings
end

-- Callbacks ------------------------------------------------------------------

local callbacks = {}
local pricesLast = -1000
local pricesPending = false

function ns.RegisterCallback(event, fn)
    if type(event) ~= "string" or type(fn) ~= "function" then return end
    local list = callbacks[event]
    if not list then
        list = {}
        callbacks[event] = list
    end
    list[#list + 1] = fn
end

-- One failing callback must not stop the others; the error goes to the
-- game's own error handler.
local function Dispatch(event, ...)
    local list = callbacks[event]
    if not list then return end
    for index = 1, #list do
        local ok, err = pcall(list[index], ...)
        if not ok and geterrorhandler then
            local handler = geterrorhandler()
            if handler then handler(err) end
        end
    end
end

local function Seconds()
    return GetTime and GetTime() or 0
end

function ns.Fire(event, ...)
    if event ~= "PRICES" then
        Dispatch(event, ...)
        return
    end
    -- A scan saves thousands of prices; the window hears about it about once
    -- a second, and always once more after the last change.
    if pricesPending then return end
    local now = Seconds()
    local wait = PRICES_INTERVAL - (now - pricesLast)
    if wait <= 0 or not (C_Timer and C_Timer.After) then
        pricesLast = now
        Dispatch("PRICES")
        return
    end
    pricesPending = true
    C_Timer.After(wait, function()
        pricesPending = false
        pricesLast = Seconds()
        Dispatch("PRICES")
    end)
end

-- Time and text --------------------------------------------------------------

function ns.Now()
    if GetServerTime then return GetServerTime() end
    return time()
end

function ns.Today()
    return math.floor(ns.Now() / 86400)
end

local function PlainMoney(copper)
    local gold = math.floor(copper / 10000)
    local silver = math.floor((copper % 10000) / 100)
    local rest = copper % 100
    local parts = {}
    if gold > 0 then parts[#parts + 1] = gold .. "g" end
    if silver > 0 then parts[#parts + 1] = silver .. "s" end
    if rest > 0 or #parts == 0 then parts[#parts + 1] = rest .. "c" end
    return table.concat(parts, " ")
end

function ns.FormatMoney(copper)
    if type(copper) ~= "number" or IsSecret(copper) or copper ~= copper or copper < 0
        or copper == math.huge then
        copper = 0
    end
    copper = math.floor(copper)
    if type(GetMoneyString) == "function" then
        local ok, text = pcall(GetMoneyString, copper, true)
        if ok and type(text) == "string" and text ~= "" then return text end
    end
    if C_CurrencyInfo and C_CurrencyInfo.GetCoinTextureString then
        local ok, text = pcall(C_CurrencyInfo.GetCoinTextureString, copper)
        if ok and type(text) == "string" and text ~= "" then return text end
    end
    return PlainMoney(copper)
end

function ns.FormatAge(timestamp)
    if type(timestamp) ~= "number" or IsSecret(timestamp) then return "" end
    local seconds = ns.Now() - timestamp
    if seconds < 60 then return "just now" end
    if seconds < 3600 then
        return math.floor(seconds / 60) .. " min ago"
    end
    if seconds < 86400 then
        return math.floor(seconds / 3600) .. " h ago"
    end
    local days = math.floor(seconds / 86400)
    return days .. (days == 1 and " day ago" or " days ago")
end

-- Events ---------------------------------------------------------------------

local function SafeCall(fn, ...)
    if type(fn) ~= "function" then return end
    local ok, err = pcall(fn, ...)
    if not ok and geterrorhandler then
        local handler = geterrorhandler()
        if handler then handler(err) end
    end
end

local function OnAuctionShow()
    SafeCall(ns.OnAuctionShow)
    ns.Fire("AUCTION", true)
    if C_Timer and C_Timer.After then
        C_Timer.After(0, function() SafeCall(ns.EnsureAuctionButton) end)
    else
        SafeCall(ns.EnsureAuctionButton)
    end
end

local function OnAuctionClosed()
    SafeCall(ns.OnAuctionClosed)
    ns.Fire("AUCTION", false)
end

local function IsAuctioneer(interaction)
    local kinds = Enum and Enum.PlayerInteractionType
    return kinds and kinds.Auctioneer ~= nil and not IsSecret(interaction)
        and interaction == kinds.Auctioneer
end

local engine = CreateFrame("Frame")
engine:RegisterEvent("ADDON_LOADED")
engine:SetScript("OnEvent", function(self, event, ...)
    if event == "ADDON_LOADED" then
        if ... == ADDON_NAME then
            self:UnregisterEvent("ADDON_LOADED")
            InitDB()
            self:RegisterEvent("AUCTION_HOUSE_SHOW")
            self:RegisterEvent("AUCTION_HOUSE_CLOSED")
            self:RegisterEvent("PLAYER_ENTERING_WORLD")
            -- The newer way the game says that a window opened at an auctioneer.
            pcall(self.RegisterEvent, self, "PLAYER_INTERACTION_MANAGER_FRAME_SHOW")
            pcall(self.RegisterEvent, self, "PLAYER_INTERACTION_MANAGER_FRAME_HIDE")
            SafeCall(ns.CreateUI)
            SafeCall(ns.CreateOptions) -- last, so a settings error can't stop the window
        end
    elseif event == "PLAYER_ENTERING_WORLD" then
        -- The realm and faction may only be known now, after the window was
        -- already filled.
        ns.Fire("PRICES")
    elseif event == "AUCTION_HOUSE_SHOW" then
        OnAuctionShow()
    elseif event == "AUCTION_HOUSE_CLOSED" then
        OnAuctionClosed()
    elseif event == "PLAYER_INTERACTION_MANAGER_FRAME_SHOW" then
        if IsAuctioneer(...) then OnAuctionShow() end
    elseif event == "PLAYER_INTERACTION_MANAGER_FRAME_HIDE" then
        if IsAuctioneer(...) then OnAuctionClosed() end
    end
end)

-- Tests call this to start from the saved variable as the game would hand it over.
ns.InitDB = InitDB
