-- RulZ Equipment Tracker: saved variables, events and reading the equipped gear.
local ADDON_NAME, ns = ...

local REFRESH_DELAY = 0.2         -- seconds; bursts of events become one refresh
local UPGRADE_COUNT = 3           -- this many of the lowest item levels are marked for upgrade
local DEFAULT_MINIMAP_ANGLE = 245 -- the Level Up Tracker's button sits at 215
local TWO_HAND_LOC = "INVTYPE_2HWEAPON"
local EQUIP_TRIGGER_FALLBACK = "Equip:"
local EQUIP_COLOR = "|cff1eff00"

ns.SORT_MODES = {
    { key = "slot", label = "Slot order" },
    { key = "ilvl", label = "Lowest ilvl first" },
}

-- Rows follow this order. Shirt and tabard are left out: they carry no stats.
local SLOT_DEFINITIONS = {
    { name = "HeadSlot",          label = "Head" },
    { name = "NeckSlot",          label = "Neck" },
    { name = "ShoulderSlot",      label = "Shoulder" },
    { name = "BackSlot",          label = "Back" },
    { name = "ChestSlot",         label = "Chest" },
    { name = "WristSlot",         label = "Wrist" },
    { name = "HandsSlot",         label = "Hands" },
    { name = "WaistSlot",         label = "Waist" },
    { name = "LegsSlot",          label = "Legs" },
    { name = "FeetSlot",          label = "Feet" },
    { name = "Finger0Slot",       label = "Finger 1" },
    { name = "Finger1Slot",       label = "Finger 2" },
    { name = "Trinket0Slot",      label = "Trinket 1" },
    { name = "Trinket1Slot",      label = "Trinket 2" },
    { name = "MainHandSlot",      label = "Main Hand", mainHand = true },
    { name = "SecondaryHandSlot", label = "Off Hand",  offHand = true },
    { name = "RangedSlot",        label = "Ranged/Relic" },
}

-- Stats shown first, in this order, with short names. Anything else the item
-- has follows, sorted by its localized name. "plain" skips the plus sign and
-- "decimals" keeps one decimal place.
local STAT_ORDER = {
    { key = "ITEM_MOD_STRENGTH_SHORT",      short = "Str" },
    { key = "ITEM_MOD_AGILITY_SHORT",       short = "Agi" },
    { key = "ITEM_MOD_STAMINA_SHORT",       short = "Sta" },
    { key = "ITEM_MOD_INTELLECT_SHORT",     short = "Int" },
    { key = "ITEM_MOD_SPIRIT_SHORT",        short = "Spi" },
    { key = "RESISTANCE0_NAME",             short = "Armor", plain = true },
    { key = "ITEM_MOD_ARMOR_SHORT",         short = "Armor", plain = true },
    { key = "RESISTANCE1_NAME",             short = "Holy Res" },
    { key = "RESISTANCE2_NAME",             short = "Fire Res" },
    { key = "RESISTANCE3_NAME",             short = "Nature Res" },
    { key = "RESISTANCE4_NAME",             short = "Frost Res" },
    { key = "RESISTANCE5_NAME",             short = "Shadow Res" },
    { key = "RESISTANCE6_NAME",             short = "Arcane Res" },
    { key = "ITEM_MOD_ATTACK_POWER_SHORT",  short = "AP" },
    { key = "ITEM_MOD_RANGED_ATTACK_POWER_SHORT", short = "RAP" },
    { key = "ITEM_MOD_SPELL_POWER_SHORT",   short = "SP" },
    { key = "ITEM_MOD_SPELL_DAMAGE_DONE_SHORT", short = "Spell Dmg" },
    { key = "ITEM_MOD_HEALING_DONE_SHORT",  short = "Healing" },
    { key = "ITEM_MOD_CRIT_RATING_SHORT",   short = "Crit" },
    { key = "ITEM_MOD_HIT_RATING_SHORT",    short = "Hit" },
    { key = "ITEM_MOD_DEFENSE_SKILL_RATING_SHORT", short = "Defense" },
    { key = "ITEM_MOD_DODGE_RATING_SHORT",  short = "Dodge" },
    { key = "ITEM_MOD_PARRY_RATING_SHORT",  short = "Parry" },
    { key = "ITEM_MOD_BLOCK_RATING_SHORT",  short = "Block" },
    { key = "ITEM_MOD_MANA_REGENERATION_SHORT", short = "MP5" },
    { key = "ITEM_MOD_HEALTH_REGENERATION_SHORT", short = "HP5" },
    { key = "ITEM_MOD_DAMAGE_PER_SECOND_SHORT", short = "DPS", plain = true, decimals = true },
}

-- "Equip:" lines are shortened when they match a known English sentence. Any
-- other line (or another language) is kept whole and cut by the row's width.
local EFFECT_RULES = {
    { "^Increases damage and healing done by magical spells and effects by up to (%d+)%.?$", "+%1 Spell Dmg" },
    { "^Increases healing done by spells and effects by up to (%d+)%.?$", "+%1 Healing" },
    { "^Increases damage done by (%a+) spells and effects by up to (%d+)%.?$", "+%2 %1 Dmg" },
    { "^Improves your chance to get a critical strike with spells by (%d+)%%%.?$", "+%1%% Spell Crit" },
    { "^Improves your chance to get a critical strike by (%d+)%%%.?$", "+%1%% Crit" },
    { "^Improves your chance to hit with spells by (%d+)%%%.?$", "+%1%% Spell Hit" },
    { "^Improves your chance to hit by (%d+)%%%.?$", "+%1%% Hit" },
    { "^Increases your chance to dodge an attack by (%d+)%%%.?$", "+%1%% Dodge" },
    { "^Increases your chance to parry an attack by (%d+)%%%.?$", "+%1%% Parry" },
    { "^Increases your chance to block attacks with a shield by (%d+)%%%.?$", "+%1%% Block" },
    { "^Increases the block value of your shield by (%d+)%.?$", "+%1 Block Value" },
    { "^Restores (%d+) mana per 5 sec%.?$", "+%1 MP5" },
    { "^Restores (%d+) health per 5 sec%.?$", "+%1 HP5" },
    { "^Increases attack power by (%d+)%.?$", "+%1 AP" },
    { "^%+(%d+) Attack Power%.?$", "+%1 AP" },
    { "^Increases defense by (%d+)%.?$", "+%1 Defense" },
}

local db
local slots              -- resolved lazily: { label, id, emptyTexture, mainHand, offHand }
local statCache = {}     -- item link -> finished stat line
local scanTip
local refreshQueued = false
ns.hasPending = false    -- true while some item's data hasn't arrived yet

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

local function InitDB()
    RulZEquipmentTrackerCharDB = RulZEquipmentTrackerCharDB or {}
    db = RulZEquipmentTrackerCharDB
    if db.shown == nil then db.shown = false end
    db.sortMode = db.sortMode or "slot"
    db.minimapAngle = db.minimapAngle or DEFAULT_MINIMAP_ANGLE
    db.minimapHidden = db.minimapHidden == true
    db.scale = db.scale or 1
    ns.db = db
end

-- Slot IDs come from the game, never from fixed numbers. A slot this client
-- doesn't have is skipped.
function ns.GetSlots()
    if slots then
        return slots
    end
    slots = {}
    for _, definition in ipairs(SLOT_DEFINITIONS) do
        local ok, id, emptyTexture = pcall(GetInventorySlotInfo, definition.name)
        if ok and type(id) == "number" then
            slots[#slots + 1] = {
                label = definition.label,
                id = id,
                emptyTexture = emptyTexture,
                mainHand = definition.mainHand,
                offHand = definition.offHand,
            }
        end
    end
    return slots
end

-- Item data ------------------------------------------------------------------

-- name, link, quality, item level, required level, ..., equip location
local function FetchItemInfo(link)
    local fetch = GetItemInfo or (C_Item and C_Item.GetItemInfo)
    if not fetch then return end
    return fetch(link)
end

local function ItemLevel(link, fallback)
    local level
    if C_Item and C_Item.GetDetailedItemLevelInfo then
        level = C_Item.GetDetailedItemLevelInfo(link)
    elseif GetDetailedItemLevelInfo then
        level = GetDetailedItemLevelInfo(link)
    end
    level = Clean(level)
    if type(level) ~= "number" or level <= 0 then
        level = Clean(fallback)
    end
    if type(level) ~= "number" then
        return nil
    end
    return level
end

-- Available straight away, with no wait for the item to be cached.
local function EquipLocation(link)
    local instant = GetItemInfoInstant or (C_Item and C_Item.GetItemInfoInstant)
    if not instant then return nil end
    return Clean((select(4, instant(link))))
end

local function ReadStatTable(link)
    local fetch = (C_Item and C_Item.GetItemStats) or GetItemStats
    if not fetch then return {} end
    local ok, stats = pcall(fetch, link)
    if ok and type(stats) == "table" then
        return stats
    end
    return {}
end

local function LocalizedStatName(key)
    local text = _G[key]
    if type(text) == "string" then
        return text
    end
    local words = key:gsub("^ITEM_MOD_", ""):gsub("_SHORT$", ""):gsub("_", " "):lower()
    return (words:gsub("(%a)(%w*)", function(first, rest) return first:upper() .. rest end))
end

local function FormatStat(entry, value)
    if entry.decimals then
        return string.format("%.1f %s", value, entry.short)
    end
    local rounded = math.floor(value + 0.5)
    if entry.plain then
        return string.format("%d %s", rounded, entry.short)
    end
    return string.format("+%d %s", rounded, entry.short)
end

local function StatParts(link)
    local stats = ReadStatTable(link)
    local parts, used = {}, {}
    for _, entry in ipairs(STAT_ORDER) do
        local value = stats[entry.key]
        if type(value) == "number" and value ~= 0 and not used[entry.short] then
            used[entry.short] = true
            parts[#parts + 1] = FormatStat(entry, value)
        end
    end
    local others = {}
    for key, value in pairs(stats) do
        if type(key) == "string" and type(value) == "number" and value ~= 0
            and not key:find("^EMPTY_SOCKET") then
            local known = false
            for _, entry in ipairs(STAT_ORDER) do
                if entry.key == key then known = true break end
            end
            if not known then
                others[#others + 1] = { name = LocalizedStatName(key), value = value }
            end
        end
    end
    table.sort(others, function(a, b) return a.name < b.name end)
    for _, other in ipairs(others) do
        parts[#parts + 1] = string.format("+%d %s", math.floor(other.value + 0.5), other.name)
    end
    return parts
end

-- Tooltip text -----------------------------------------------------------------

local function StripColors(text)
    return (text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""))
end

local function TooltipLinesFromData(slot)
    if not (C_TooltipInfo and C_TooltipInfo.GetInventoryItem) then
        return nil
    end
    local data = C_TooltipInfo.GetInventoryItem("player", slot)
    if type(data) ~= "table" or type(data.lines) ~= "table" then
        return nil
    end
    local texts = {}
    for _, line in ipairs(data.lines) do
        local text = line and line.leftText
        if not IsSecret(text) and type(text) == "string" then
            texts[#texts + 1] = StripColors(text)
        end
    end
    return #texts > 0 and texts or nil
end

local function TooltipLinesFromScan(slot)
    if not scanTip then
        scanTip = CreateFrame("GameTooltip", "RulZEquipmentTrackerScanTip", nil, "GameTooltipTemplate")
    end
    scanTip:SetOwner(WorldFrame, "ANCHOR_NONE")
    scanTip:ClearLines()
    scanTip:SetInventoryItem("player", slot)
    local texts = {}
    for index = 1, scanTip:NumLines() do
        local region = _G["RulZEquipmentTrackerScanTipTextLeft" .. index]
        local text = region and region:GetText()
        if not IsSecret(text) and type(text) == "string" then
            texts[#texts + 1] = StripColors(text)
        end
    end
    return #texts > 0 and texts or nil
end

local function ShortenEffect(text)
    for _, rule in ipairs(EFFECT_RULES) do
        local result, count = text:gsub(rule[1], rule[2])
        if count > 0 then
            return result
        end
    end
    return (text:gsub("%.$", ""))
end

-- Green "Equip:" lines of the item in a slot, shortened. Returns nil while the
-- tooltip has no text yet (item data still loading).
local function EquipEffects(slot)
    local texts = TooltipLinesFromData(slot) or TooltipLinesFromScan(slot)
    if not texts then
        return nil
    end
    local trigger = ITEM_SPELL_TRIGGER_ONEQUIP
    if type(trigger) ~= "string" or trigger == "" then
        trigger = EQUIP_TRIGGER_FALLBACK
    end
    local effects = {}
    for _, text in ipairs(texts) do
        if text:sub(1, #trigger) == trigger then
            local body = text:sub(#trigger + 1):match("^%s*(.-)%s*$")
            if body ~= "" then
                effects[#effects + 1] = EQUIP_COLOR .. ShortenEffect(body) .. "|r"
            end
        end
    end
    return effects
end

-- Returns the compact stat line and whether it is final (cached by link).
local function StatLine(link, slot)
    local cached = statCache[link]
    if cached then
        return cached, true
    end
    local effects = EquipEffects(slot)
    local parts = StatParts(link)
    local text = table.concat(parts, "  ")
    if effects and #effects > 0 then
        text = text .. (text ~= "" and "  " or "") .. table.concat(effects, "  ")
    end
    if effects then
        statCache[link] = text
        return text, true
    end
    return text, false
end

-- Reading the gear -------------------------------------------------------------

local function ReadSlot(slotInfo, index)
    local row = {
        index = index, label = slotInfo.label, slot = slotInfo.id, emptyTexture = slotInfo.emptyTexture,
        mainHand = slotInfo.mainHand, offHand = slotInfo.offHand,
    }
    local link = GetInventoryItemLink("player", slotInfo.id)
    if IsSecret(link) then
        row.pending = true
        return row
    end
    if not link then
        row.empty = true
        return row
    end

    row.link = link
    row.icon = Clean(GetInventoryItemTexture("player", slotInfo.id))
    local name, _, quality, baseLevel, requiredLevel = FetchItemInfo(link)
    name, quality, requiredLevel = Clean(name), Clean(quality), Clean(requiredLevel)
    row.name = name or link:match("%[(.-)%]") or "Unknown item"
    row.quality = quality or Clean(GetInventoryItemQuality("player", slotInfo.id))
    row.requiredLevel = type(requiredLevel) == "number" and requiredLevel or nil
    row.ilvl = ItemLevel(link, baseLevel)
    row.twoHand = slotInfo.mainHand and EquipLocation(link) == TWO_HAND_LOC
    local statLine, statsFinal = StatLine(link, slotInfo.id)
    row.stats = statLine
    if not name or not row.ilvl or not statsFinal then
        row.pending = true
    end
    return row
end

-- How the numbers are worked out:
--  * The average counts equipped items that have a known item level. Empty
--    slots are left out of it (an empty slot would drag it to zero and hide
--    how good the worn gear is); they are counted and flagged separately.
--  * A two-hander counts twice, as the game's own average does, because it
--    fills the Off Hand too. That Off Hand row is not "empty" and is never
--    marked.
--  * Upgrade marks: every empty slot, plus the UPGRADE_COUNT lowest item
--    levels among the filled slots, as long as the item is below the average
--    (so a set of equal items doesn't get arbitrary marks).
local function Analyse(rows)
    local mainHand, offHand
    for _, row in ipairs(rows) do
        if row.mainHand then mainHand = row end
        if row.offHand then offHand = row end
    end
    if mainHand and offHand and mainHand.twoHand and offHand.empty then
        offHand.empty = nil
        offHand.twoHandFill = true
    end

    local sum, count, empty = 0, 0, 0
    local candidates = {}
    for _, row in ipairs(rows) do
        if row.empty then
            empty = empty + 1
            row.upgrade = true
        elseif row.ilvl then
            sum = sum + row.ilvl
            count = count + 1
            if row.twoHand and offHand and offHand.twoHandFill then
                sum = sum + row.ilvl
                count = count + 1
            end
            candidates[#candidates + 1] = row
        end
    end
    local average = count > 0 and sum / count or nil

    table.sort(candidates, function(a, b)
        if a.ilvl ~= b.ilvl then return a.ilvl < b.ilvl end
        return a.index < b.index
    end)
    for position = 1, math.min(UPGRADE_COUNT, #candidates) do
        local row = candidates[position]
        if average and row.ilvl < average then
            row.upgrade = true
        end
    end
    return { average = average, emptyCount = empty }
end

-- Ordering for "Lowest ilvl first": empty slots, then rising item level, then
-- items still loading, then the Off Hand a two-hander fills.
local function SortGroup(row)
    if row.empty then return 0 end
    if row.twoHandFill then return 3 end
    if row.ilvl then return 1 end
    return 2
end

function ns.GetGear()
    local rows = {}
    for index, slotInfo in ipairs(ns.GetSlots()) do
        rows[index] = ReadSlot(slotInfo, index)
    end
    local summary = Analyse(rows)
    local pending = false
    for _, row in ipairs(rows) do
        if row.pending then pending = true end
    end
    ns.hasPending = pending

    if db.sortMode == "ilvl" then
        table.sort(rows, function(a, b)
            local groupA, groupB = SortGroup(a), SortGroup(b)
            if groupA ~= groupB then return groupA < groupB end
            if groupA == 1 and a.ilvl ~= b.ilvl then return a.ilvl < b.ilvl end
            return a.index < b.index
        end)
    end
    return rows, summary
end

function ns.SetSortMode(mode)
    db.sortMode = mode
    ns.Refresh()
end

-- Events ---------------------------------------------------------------------

-- Many events can arrive together (a full gear swap, item data loading), so
-- they are folded into one refresh.
function ns.RequestRefresh()
    if refreshQueued then return end
    refreshQueued = true
    local function run()
        refreshQueued = false
        ns.Refresh()
    end
    if C_Timer and C_Timer.After then
        C_Timer.After(REFRESH_DELAY, run)
    else
        run()
    end
end

local engine = CreateFrame("Frame")
engine:RegisterEvent("ADDON_LOADED")
engine:SetScript("OnEvent", function(self, event, ...)
    if event == "ADDON_LOADED" then
        if ... == ADDON_NAME then
            self:UnregisterEvent("ADDON_LOADED")
            InitDB()
            ns.CreateUI()
            self:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
            self:RegisterEvent("PLAYER_ENTERING_WORLD")
            self:RegisterEvent("PLAYER_LEVEL_UP")
            self:RegisterEvent("GET_ITEM_INFO_RECEIVED")
            ns.CreateOptions() -- last, so a settings error can't stop the window
        end
    elseif event == "GET_ITEM_INFO_RECEIVED" then
        -- Fires for every item the game loads; only matters while we wait.
        if ns.hasPending then ns.RequestRefresh() end
    else
        if event == "PLAYER_ENTERING_WORLD" then
            ns.EnsureCharacterButton()
        end
        ns.RequestRefresh()
    end
end)
