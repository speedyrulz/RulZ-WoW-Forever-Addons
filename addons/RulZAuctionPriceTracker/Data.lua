-- RulZ Auction and Price Tracker: item keys, saved records, price maths and search.
local ADDON_NAME, ns = ...

local floor, ceil = math.floor, math.ceil
local strmatch, strfind, strsub, strlower, strbyte = string.match, string.find, string.sub, string.lower, string.byte
local tconcat, tsort, tinsert = table.concat, table.sort, table.insert

local DAY_SECONDS = 86400
local HISTORY_DAYS = 30          -- today and the 29 days before
local MARKET_DAYS = 14           -- market = median of the newest 14 days of an item
local MARKET_FRACTION = 0.25     -- day market = price at this share of the quantity
local DIGITS = "0123456789abcdefghijklmnopqrstuvwxyz"
local MAX_DIGITS = 10
local LOAD_REQUEST_GAP = 10      -- seconds before the same item data is asked for again
local CLASS_WEAPON, CLASS_ARMOR = 2, 4

local IsSecret = ns.IsSecret

-- Base 36 numbers ------------------------------------------------------------

local function Encode(n)
    n = floor(n)
    if n <= 0 then return "0" end
    local out = ""
    while n > 0 do
        local digit = n % 36
        out = strsub(DIGITS, digit + 1, digit + 1) .. out
        n = (n - digit) / 36
    end
    return out
end

local function Decode(text)
    local length = #text
    if length == 0 or length > MAX_DIGITS then return nil end
    if strfind(text, "[^0-9a-z]") then return nil end
    -- tonumber(text, 36) is quick but goes through a C long, which is 32 bits on
    -- Windows; six digits always fit. Longer numbers are added up by hand.
    if length <= 6 then return tonumber(text, 36) end
    local n = 0
    for index = 1, length do
        local byte = strbyte(text, index)
        local digit
        if byte >= 48 and byte <= 57 then
            digit = byte - 48
        elseif byte >= 97 and byte <= 122 then
            digit = byte - 87
        else
            return nil
        end
        n = n * 36 + digit
    end
    return n
end

ns.EncodeBase36 = Encode
ns.DecodeBase36 = Decode

-- A number from the game or a caller: whole, finite, not secret. nil otherwise.
local function Num(value)
    if type(value) ~= "number" or IsSecret(value) then return nil end
    if value ~= value or value == math.huge or value == -math.huge then return nil end
    return floor(value)
end

-- Records --------------------------------------------------------------------
-- "low|seen|qty|market|history"; history is "day,low,market,qty" joined by ";".

-- low, seen, qty, market (nil when empty); nothing when the record is corrupt.
local function ParseHeader(record)
    if type(record) ~= "string" then return nil end
    local a, b, c, d, rest = strmatch(record, "^([0-9a-z]+)|([0-9a-z]+)|([0-9a-z]+)|([0-9a-z]*)([^|]?)")
    if not a or rest ~= "" then return nil end
    -- Short numbers (the usual case) skip the checked decoder: the pattern has
    -- already shown they are lowercase base 36 digits.
    local low = #a <= 6 and tonumber(a, 36) or Decode(a)
    local seen = #b <= 6 and tonumber(b, 36) or Decode(b)
    local qty = #c <= 6 and tonumber(c, 36) or Decode(c)
    if not low or not seen or not qty or low < 1 then return nil end
    local market
    if d ~= "" then
        market = #d <= 6 and tonumber(d, 36) or Decode(d)
        if not market then return nil end
    end
    return low, seen, qty, market
end

local function ByDay(a, b)
    return a.day < b.day
end

-- Days ascending, one entry per day. Entries that don't parse are left out.
local function ParseHistory(record)
    local list, count = {}, 0
    local text = strmatch(record, "^[^|]*|[^|]*|[^|]*|[^|]*|(.*)$")
    if not text or text == "" then return list end
    local sorted = true
    for entry in string.gmatch(text, "[^;]+") do
        local a, b, c, d = strmatch(entry, "^([0-9a-z]+),([0-9a-z]+),([0-9a-z]*),([0-9a-z]+)$")
        if a then
            local day, low, qty = Decode(a), Decode(b), Decode(d)
            local market
            if c ~= "" then market = Decode(c) end
            if day and low and qty and (c == "" or market) then
                count = count + 1
                if count > 1 and day <= list[count - 1].day then sorted = false end
                list[count] = { day = day, low = low, market = market, qty = qty }
            end
        end
    end
    if not sorted then
        tsort(list, ByDay)
        -- One entry per day: the later one in the sorted order wins.
        local out, n = {}, 0
        for index = 1, #list do
            if n > 0 and out[n].day == list[index].day then
                out[n] = list[index]
            else
                n = n + 1
                out[n] = list[index]
            end
        end
        list = out
    end
    return list
end

local function BuildRecord(low, seen, qty, market, history)
    local parts = {}
    for index = 1, #history do
        local e = history[index]
        parts[index] = Encode(e.day) .. "," .. Encode(e.low) .. ","
            .. (e.market and Encode(e.market) or "") .. "," .. Encode(e.qty)
    end
    return Encode(low) .. "|" .. Encode(seen) .. "|" .. Encode(qty) .. "|"
        .. (market and Encode(market) or "") .. "|" .. tconcat(parts, ";")
end

-- Drops days older than the window (ascending list). Returns how many went.
local function TrimList(history, today)
    local oldest = today - HISTORY_DAYS + 1
    local first = 1
    local count = #history
    while first <= count and history[first].day < oldest do
        first = first + 1
    end
    local removed = first - 1
    if removed > 0 then
        for index = 1, count - removed do
            history[index] = history[index + removed]
        end
        for index = count - removed + 1, count do
            history[index] = nil
        end
    end
    return removed
end

-- Median of the day values (market, else low) of the newest 14 days.
local function ComputeMarket(history)
    local count = #history
    if count == 0 then return nil end
    local newest = history[count].day
    local values, n = {}, 0
    for index = count, 1, -1 do
        local e = history[index]
        if newest - e.day >= MARKET_DAYS then break end
        n = n + 1
        values[n] = e.market or e.low
    end
    tsort(values)
    if n % 2 == 1 then
        return values[(n + 1) / 2]
    end
    return floor((values[n / 2] + values[n / 2 + 1]) / 2)
end

local function ByPrice(a, b)
    return a[1] < b[1]
end

-- listings = array of { unitPrice, quantity }. Returns the lowest price, the
-- total quantity and the price at the 25% point; nothing when no listing is usable.
local function Summarize(listings)
    if type(listings) ~= "table" then return nil end
    local list, n = {}, 0
    local total, low = 0, nil
    local sorted, previous = true, 0
    for index = 1, #listings do
        local listing = listings[index]
        if type(listing) == "table" then
            local price = Num(listing.unitPrice)
            local quantity = Num(listing.quantity)
            if price and quantity and price >= 1 and quantity >= 1 then
                n = n + 1
                list[n] = { price, quantity }
                total = total + quantity
                if not low or price < low then low = price end
                if price < previous then sorted = false end
                previous = price
            end
        end
    end
    if n == 0 then return nil end
    if n > 1 and not sorted then tsort(list, ByPrice) end
    local target = ceil(total * MARKET_FRACTION)
    local running = 0
    local point = list[n][1]
    for index = 1, n do
        running = running + list[index][2]
        if running >= target then
            point = list[index][1]
            break
        end
    end
    return low, total, point
end

-- Scope ----------------------------------------------------------------------

local scopeCache

function ns.GetScope()
    if scopeCache then return scopeCache end
    local realm
    if GetNormalizedRealmName then realm = GetNormalizedRealmName() end
    if (not realm or realm == "") and GetRealmName then realm = GetRealmName() end
    if type(realm) ~= "string" or realm == "" or IsSecret(realm) then return nil end
    local faction = UnitFactionGroup and UnitFactionGroup("player")
    local known = type(faction) == "string" and faction ~= "" and not IsSecret(faction)
    local scope = realm .. "-" .. (known and faction or "Neutral")
    if known then scopeCache = scope end   -- the faction may only be known after login
    return scope
end

function ns.GetScopeLabel()
    local scope = ns.GetScope()
    if not scope then return "Unknown realm" end
    local realm, faction = strmatch(scope, "^(.*)%-([^%-]*)$")
    local display = GetRealmName and GetRealmName()
    if type(display) == "string" and display ~= "" and not IsSecret(display) then
        realm = display
    end
    return (realm or scope) .. " (" .. (faction or "?") .. ")"
end

-- The saved table of the current realm and faction; nil while the scope or the
-- saved variable isn't ready.
function ns.GetScopeData(create)
    local root = ns.root
    if not root then return nil end
    local scope = ns.GetScope()
    if not scope then return nil end
    local data = root.realms[scope]
    if type(data) ~= "table" then
        if not create then return nil end
        data = { items = {} }
        root.realms[scope] = data
    end
    if type(data.items) ~= "table" then data.items = {} end
    return data
end

-- The item count is kept up to date by the writers; it is only counted from
-- scratch when it isn't known for this table or the table is empty.
local countFor, countValue

local function CountItems(items)
    if countFor == items and next(items) ~= nil then return countValue end
    local n = 0
    for _ in pairs(items) do n = n + 1 end
    countFor, countValue = items, n
    return n
end

-- Item data ------------------------------------------------------------------

local classCache = {}     -- itemID -> true when weapon or armour
local baseNames = {}      -- itemID -> name
local idKeys = {}         -- itemID -> "itemID"
local loadAsked = {}      -- itemID -> time of the last request

local function IdKey(id)
    local key = idKeys[id]
    if not key then
        key = tostring(id)
        idKeys[id] = key
    end
    return key
end

function ns.RequestItemLoad(id)
    if not (C_Item and C_Item.RequestLoadItemDataByID) then return end
    local now = GetTime and GetTime() or 0
    local last = loadAsked[id]
    if last and now - last < LOAD_REQUEST_GAP then return end
    loadAsked[id] = now
    pcall(C_Item.RequestLoadItemDataByID, id)
end

-- true for weapons and armour (they can have random suffixes), false for the
-- rest, nil while the game doesn't know the item yet.
function ns.IsGearItem(id)
    local known = classCache[id]
    if known ~= nil then return known end
    local instant = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant
    if not instant then return nil end
    local _, _, _, _, _, classID = instant(id)
    if type(classID) ~= "number" or IsSecret(classID) then return nil end
    local gear = classID == CLASS_WEAPON or classID == CLASS_ARMOR
    classCache[id] = gear
    return gear
end

local function GetItemInfoName(what)
    local fetch = (C_Item and C_Item.GetItemInfo) or GetItemInfo
    if not fetch then return nil end
    local name = fetch(what)
    if type(name) == "string" and name ~= "" and not IsSecret(name) then return name end
    return nil
end

local function BaseName(id)
    local name = baseNames[id]
    if name then return name end
    if C_Item and C_Item.GetItemNameByID then
        name = C_Item.GetItemNameByID(id)
    end
    if type(name) ~= "string" or name == "" or IsSecret(name) then
        name = GetItemInfoName(id)
    end
    if name then baseNames[id] = name end
    return name
end

-- key | nil, pending. pending is true while the game still has to load something.
function ns.KeyFromLink(linkOrID)
    local id, link
    if type(linkOrID) == "number" then
        if IsSecret(linkOrID) then return nil, false end
        id = floor(linkOrID)
    elseif type(linkOrID) == "string" then
        if IsSecret(linkOrID) then return nil, false end
        id = strmatch(linkOrID, "item:(%d+)")
        if id then
            link = linkOrID
        else
            id = strmatch(linkOrID, "^%d+$")
        end
        id = id and tonumber(id)
    end
    if not id or id <= 0 then return nil, false end

    local gear = ns.IsGearItem(id)
    if gear == nil then
        ns.RequestItemLoad(id)
        return nil, true
    end
    if not gear or not link then return IdKey(id), false end

    local base = BaseName(id)
    local full = GetItemInfoName(link) or strmatch(link, "|h%[(.*)%]|h")
    if not base or not full or full == "" then
        ns.RequestItemLoad(id)
        return nil, true
    end
    if full == base then return IdKey(id), false end
    return IdKey(id) .. ":" .. full, false
end

-- Names ----------------------------------------------------------------------

function ns.RememberName(key, name, quality)
    local root = ns.root
    if not root or type(key) ~= "string" then return end
    if type(name) ~= "string" or name == "" or IsSecret(name) then return end
    quality = Num(quality) or 1
    if quality < 0 or quality > 9 then quality = 1 end
    local text = quality .. ":" .. name
    if root.names[key] ~= text then root.names[key] = text end
end

-- Writing --------------------------------------------------------------------

local function Store(key, low, qty, dayMarket)
    local data = ns.GetScopeData(true)
    if not data or type(key) ~= "string" or key == "" then return false end
    local items = data.items
    local now = ns.Now()
    local today = floor(now / DAY_SECONDS)

    local history
    local existing = items[key]
    if existing ~= nil and ParseHeader(existing) then
        history = ParseHistory(existing)
    else
        history = {}
    end

    -- Today's entry keeps the day's lowest low and the latest quantity.
    local index = #history
    while index >= 1 and history[index].day > today do index = index - 1 end
    local entry = history[index]
    if entry and entry.day == today then
        if low < entry.low then entry.low = low end
        entry.qty = qty
        if dayMarket then entry.market = dayMarket end
    else
        tinsert(history, index + 1, { day = today, low = low, market = dayMarket, qty = qty })
    end
    TrimList(history, today)

    if existing == nil and countFor == items then
        if next(items) == nil then countValue = 0 end
        countValue = countValue + 1
    end
    items[key] = BuildRecord(low, now, qty, ComputeMarket(history), history)
    ns.Fire("PRICES")
    return true
end

function ns.RecordFull(key, listings)
    local low, total, point = Summarize(listings)
    if not low then return false end
    return Store(key, low, total, point)
end

function ns.RecordLow(key, low, qty)
    low = Num(low)
    if not low or low < 1 then return false end
    qty = Num(qty) or 0
    if qty < 0 then qty = 0 end
    return Store(key, low, qty, nil)
end

-- Reading --------------------------------------------------------------------

function ns.GetPrice(key)
    local data = ns.GetScopeData(false)
    if not data or type(key) ~= "string" then return nil end
    local low, seen, qty, market = ParseHeader(data.items[key])
    if not low then return nil end
    return { low = low, seen = seen, qty = qty, market = market }
end

function ns.GetHistory(key)
    local data = ns.GetScopeData(false)
    if not data or type(key) ~= "string" then return {} end
    local record = data.items[key]
    if not ParseHeader(record) then return {} end
    local history = ParseHistory(record)
    TrimList(history, floor(ns.Now() / DAY_SECONDS))
    return history
end

function ns.GetSummary()
    local data = ns.GetScopeData(false)
    if not data then return { items = 0, lastFull = nil } end
    local lastFull = data.lastFull
    if type(lastFull) ~= "number" then lastFull = nil end
    return { items = CountItems(data.items), lastFull = lastFull }
end

-- Rows are sorted as numbers (positions in parallel arrays) and the row tables
-- are only built afterwards, in their final order: about half the cost of
-- sorting the tables themselves.
local function MakeComparator(values, lowerNames, keys, ascending)
    return function(a, b)
        local x, y = values[a], values[b]
        if x ~= y then
            if x == nil then return false end   -- missing values go last
            if y == nil then return true end
            if ascending then return x < y end
            return x > y
        end
        local nameA, nameB = lowerNames[a], lowerNames[b]
        if nameA ~= nameB then return nameA < nameB end
        return keys[a] < keys[b]
    end
end

-- The history of every item is left unparsed here; only the first four fields
-- of each record are read.
function ns.GetItems(searchText, sortKey, ascending)
    local data = ns.GetScopeData(false)
    if not data then return {} end
    local names = ns.root.names

    local needle
    if type(searchText) == "string" and not IsSecret(searchText) then
        needle = strlower(strmatch(searchText, "^%s*(.-)%s*$"))
        if needle == "" then needle = nil end
    end

    local n = 0
    local keys, ids, shown, qualities, lowerNames = {}, {}, {}, {}, {}
    local lows, markets, qtys, seens = {}, {}, {}, {}
    for key, record in pairs(data.items) do
        local low, seen, qty, market = ParseHeader(record)
        local id = low and type(key) == "string" and strmatch(key, "^(%d+)")
        if id then
            local stored = names[key]
            local quality, name
            if type(stored) == "string" then
                quality, name = strmatch(stored, "^(%d+):(.*)$")
            end
            if name then
                quality = tonumber(quality)
            else
                name = "Item " .. id
                quality = 1
            end
            local lower = strlower(name)
            if not needle or strfind(lower, needle, 1, true) then
                n = n + 1
                keys[n], ids[n], shown[n], qualities[n], lowerNames[n] = key, tonumber(id), name, quality, lower
                lows[n], markets[n], qtys[n], seens[n] = low, market, qty, seen
            end
        end
    end

    local values = lowerNames
    if sortKey == "low" then values = lows
    elseif sortKey == "market" then values = markets
    elseif sortKey == "qty" then values = qtys
    elseif sortKey == "seen" then values = seens end
    local order = {}
    for index = 1, n do order[index] = index end
    tsort(order, MakeComparator(values, lowerNames, keys, ascending ~= false))

    local out = {}
    for position = 1, n do
        local i = order[position]
        out[position] = {
            key = keys[i], id = ids[i], name = shown[i], quality = qualities[i],
            low = lows[i], market = markets[i], qty = qtys[i], seen = seens[i],
        }
    end
    return out
end
