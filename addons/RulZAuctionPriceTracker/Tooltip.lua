-- RulZ Auction and Price Tracker: price lines on item tooltips.
local ADDON_NAME, ns = ...

local floor = math.floor
local strmatch = string.match

local HEADER_COLOR = { 1, 0.42, 0.45 }   -- accent-text
local LABEL_COLOR = { 0.64, 0.64, 0.67 } -- muted
local FAINT = "|cff82828c"
local MAX_STACK = 100000

local IsSecret = ns.IsSecret

-- Stack counts ---------------------------------------------------------------

local function Whole(value)
    if type(value) ~= "number" or IsSecret(value) then return nil end
    if value ~= value or value < 1 or value > MAX_STACK then return nil end
    return floor(value)
end

-- Each getter the game uses to fill a tooltip, with the call that gives the
-- stack size for the same arguments. Anything unknown counts as one item.
local COUNT_READERS = {
    GetBagItem = function(bag, slot)
        local info = C_Container and C_Container.GetContainerItemInfo and C_Container.GetContainerItemInfo(bag, slot)
        return type(info) == "table" and info.stackCount
    end,
    GetInventoryItem = function(unit, slot)
        return GetInventoryItemCount and GetInventoryItemCount(unit, slot)
    end,
    GetLootItem = function(slot)
        if not GetLootSlotInfo then return nil end
        local _, _, quantity = GetLootSlotInfo(slot)
        return quantity
    end,
    GetQuestItem = function(kind, index)
        if not GetQuestItemInfo then return nil end
        local _, _, count = GetQuestItemInfo(kind, index)
        return count
    end,
    GetInboxItem = function(mail, attachment)
        if not GetInboxItem then return nil end
        local _, _, _, count = GetInboxItem(mail, attachment)
        return count
    end,
    GetMerchantItem = function(index)
        if not GetMerchantItemInfo then return nil end
        local _, _, _, quantity = GetMerchantItemInfo(index)
        return quantity
    end,
    GetSendMailItem = function(index)
        if not GetSendMailItem then return nil end
        local _, _, _, count = GetSendMailItem(index)
        return count
    end,
    GetTradePlayerItem = function(index)
        if not GetTradePlayerItemInfo then return nil end
        local _, _, count = GetTradePlayerItemInfo(index)
        return count
    end,
    GetTradeTargetItem = function(index)
        if not GetTradeTargetItemInfo then return nil end
        local _, _, count = GetTradeTargetItemInfo(index)
        return count
    end,
}

local function StackCount(tooltip)
    local info = tooltip and tooltip.processingInfo
    if type(info) ~= "table" or IsSecret(info) then return 1 end
    local getter = info.getterName
    if type(getter) ~= "string" or IsSecret(getter) then return 1 end
    local read = COUNT_READERS[getter]
    if not read then return 1 end
    local args = info.getterArgs
    if type(args) ~= "table" or IsSecret(args) then return 1 end
    local ok, count = pcall(read, args[1], args[2], args[3])
    return ok and Whole(count) or 1
end
ns.GetTooltipStackCount = StackCount

-- Lines ----------------------------------------------------------------------

local function SellPrice(link, id)
    local fetch = (C_Item and C_Item.GetItemInfo) or GetItemInfo
    if not fetch then return nil end
    local ok, _, _, _, _, _, _, _, _, _, _, price = pcall(fetch, link or id)
    if not ok or type(price) ~= "number" or IsSecret(price) or price ~= price or price <= 0 then
        return nil
    end
    return floor(price)
end

local function AddValue(lines, label, unit, count, suffix)
    lines[#lines + 1] = { label, ns.FormatMoney(unit) .. (suffix or "") }
    if count > 1 then
        lines[#lines + 1] = { label .. " x" .. count, ns.FormatMoney(unit * count) }
    end
end

-- Lines for one item: { { left, right }, ... }, empty when nothing is known.
-- key may be nil (not known yet); the vendor price needs only the link or id.
function ns.GetTooltipLines(key, count, link, id)
    local lines = {}
    local db = ns.db
    if not db then return lines end
    count = Whole(count) or 1

    local price = key and ns.GetPrice(key)
    if price then
        if db.tipLow and price.low then
            local age = ns.FormatAge(price.seen)
            AddValue(lines, "Lowest buyout", price.low, count,
                age ~= "" and (" " .. FAINT .. "(" .. age .. ")|r") or nil)
        end
        if db.tipMarket and price.market then
            AddValue(lines, "Market price", price.market, count)
        end
    end
    if db.tipVendor then
        local vendor = SellPrice(link, id)
        if vendor then AddValue(lines, "Vendor price", vendor, count) end
    end
    return lines
end

local function Decorate(tooltip, data)
    if tooltip ~= GameTooltip and tooltip ~= ItemRefTooltip then return end
    if tooltip == nil or type(data) ~= "table" or IsSecret(data) then return end
    if not ns.db then return end

    local id, link = data.id, data.hyperlink
    if IsSecret(id) then id = nil end
    if IsSecret(link) or type(link) ~= "string" then link = nil end
    if type(id) ~= "number" then id = nil end
    if not link and tooltip.GetItem then
        local _, itemLink = tooltip:GetItem()
        if type(itemLink) == "string" and not IsSecret(itemLink) then link = itemLink end
    end
    if not id and link then id = tonumber(strmatch(link, "item:(%d+)")) end
    if not link and not id then return end

    -- Without a link the random suffix of a weapon or armour isn't known, so an
    -- item known only by its ID gets no auction price unless it can't have one.
    local key
    if link then
        key = ns.KeyFromLink(link)
    elseif ns.IsGearItem(id) == false then
        key = ns.KeyFromLink(id)
    end
    local lines = ns.GetTooltipLines(key, StackCount(tooltip), link, id)
    if #lines == 0 then return end

    tooltip:AddLine("RulZ", HEADER_COLOR[1], HEADER_COLOR[2], HEADER_COLOR[3])
    for index = 1, #lines do
        local line = lines[index]
        tooltip:AddDoubleLine(line[1], line[2],
            LABEL_COLOR[1], LABEL_COLOR[2], LABEL_COLOR[3], 1, 1, 1)
    end
end

-- Never lets an error reach the tooltip, whatever the game hands over.
local function OnTooltipItem(tooltip, data)
    pcall(Decorate, tooltip, data)
end
ns.DecorateTooltip = OnTooltipItem

if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall
    and Enum and Enum.TooltipDataType and Enum.TooltipDataType.Item then
    TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, OnTooltipItem)
end
