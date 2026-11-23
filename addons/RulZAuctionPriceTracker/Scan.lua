-- RulZ Auction and Price Tracker: the full scan and passive recording at the auction house.
local ADDON_NAME, ns = ...

local floor, min = math.floor, math.min
local strmatch = string.match

local REQUEST_COOLDOWN = 900       -- the server allows one ReplicateItems about every 15 minutes
local NO_ANSWER_TIMEOUT = 30       -- seconds without an answer
local RETRY_AFTER_TIMEOUT = 60     -- seconds before another try after no answer
local SETTLE_SECONDS = 2           -- the list must keep its size this long
local QUIET_SECONDS = 10           -- no event, but the list stopped growing this long ago
local SETTLE_MAX = 120             -- ...but we read anyway after this long
local FRAME_BUDGET_MS = 8          -- scan work per frame
local PASSIVE_BUDGET_MS = 3        -- passive recording work per frame
local CHECK_EVERY = 32             -- rows between clock checks
local MAX_RETRY_PASSES = 8
local PASS_INTERVAL = 1            -- seconds between retry passes
local READ_SHARE = 0.6             -- share of the progress bar used by reading
local MAX_PENDING_NAMES = 5000
local STATE_IDLE, STATE_WAITING, STATE_READING, STATE_SAVING = "idle", "waiting", "reading", "saving"

local RETRY, SKIP = 1, 2

local IsSecret = ns.IsSecret

local scan = { state = STATE_IDLE }
local auctionOpen = false
local retryNotBefore = 0           -- GetTime() value; set after a scan that got no answer
local previousRequest              -- lastRequest before the running scan's request
local pendingNames = {}            -- itemID -> key whose name is still being loaded
local pendingNameCount = 0

-- Passive recording state
local browseDirty, browseList, browseCursor = false, nil, 1
local browsePrice, browseQty = {}, {}
local commodityJob, itemJob

local frame = CreateFrame("Frame")
local ticking = false

-- Small helpers --------------------------------------------------------------

local function Say(text)
    if type(print) == "function" then
        print(ns.PREFIX .. text)
    end
end

local function Millis()
    return debugprofilestop and debugprofilestop() or 0
end

local function Seconds()
    return GetTime and GetTime() or 0
end

local function Api()
    return C_AuctionHouse
end

local function NumReplicate()
    local api = Api()
    if not (api and api.GetNumReplicateItems) then return 0 end
    local ok, n = pcall(api.GetNumReplicateItems)
    if ok and type(n) == "number" and not IsSecret(n) then return n end
    return 0
end

local function Duration(seconds)
    if seconds >= 60 then return math.ceil(seconds / 60) .. " min" end
    return seconds .. " s"
end

local function CooldownLeft()
    local left = 0
    local root = ns.root
    local last = root and root.lastRequest
    if type(last) == "number" then
        left = min(REQUEST_COOLDOWN, last + REQUEST_COOLDOWN - ns.Now())
    end
    local retry = retryNotBefore - Seconds()
    if retry > left then left = retry end
    if left <= 0 then return 0 end
    return math.ceil(left)
end

local function PassiveActive()
    return ns.db and ns.db.passive and scan.state == STATE_IDLE
end

local Step, UpdateTicking

local function OnUpdate()
    local ok, err = pcall(Step)
    if ok then return end
    if scan.state ~= STATE_IDLE then
        scan.state = STATE_IDLE
        scan.groups, scan.order, scan.work, scan.retry = nil, nil, nil, nil
        Say("The scan stopped because of an unexpected error: " .. tostring(err))
        ns.Fire("SCAN")
    else
        -- Passive work that fails is dropped rather than tried every frame.
        browseDirty, browseList, commodityJob, itemJob = false, nil, nil, nil
    end
    UpdateTicking()
end

UpdateTicking = function()
    local on = scan.state ~= STATE_IDLE or browseDirty or browseList ~= nil
        or commodityJob ~= nil or itemJob ~= nil
    if on == ticking then return end
    ticking = on
    frame:SetScript("OnUpdate", on and OnUpdate or nil)
end

local function Finish(message)
    scan.state = STATE_IDLE
    scan.groups, scan.order, scan.work, scan.retry, scan.linkKeys = nil, nil, nil, nil, nil
    if message then Say(message) end
    ns.Fire("SCAN")
    UpdateTicking()
end

-- Status ---------------------------------------------------------------------

-- The game's own window counts too, in case an event was missed.
local function AuctionFrameShown()
    local window = AuctionHouseFrame
    if type(window) ~= "table" or not window.IsShown then return false end
    local ok, shown = pcall(window.IsShown, window)
    return ok and not IsSecret(shown) and shown == true
end

function ns.IsAuctionOpen()
    return auctionOpen or AuctionFrameShown()
end

-- What the scan button depends on, for /rah status.
function ns.GetDiagnostics()
    local api = Api()
    return {
        "auction house: " .. (ns.IsAuctionOpen() and "open" or "closed")
            .. " (event " .. (auctionOpen and "yes" or "no")
            .. ", window " .. (AuctionFrameShown() and "yes" or "no") .. ")",
        "realm: " .. tostring(ns.GetScope() or "unknown"),
        "full scan function: " .. ((api and api.ReplicateItems) and "found" or "missing"),
        "scan: " .. scan.state .. ", next scan in " .. CooldownLeft() .. " s, "
            .. NumReplicate() .. " auctions in the list",
    }
end

function ns.GetScanStatus()
    local state = scan.state
    local cooldown = 0
    local progress, text = 0, ""
    if state == STATE_IDLE then
        cooldown = CooldownLeft()
        if not ns.IsAuctionOpen() then
            text = "Open the auction house to scan."
        elseif cooldown > 0 then
            text = "Next full scan in " .. Duration(cooldown) .. "."
        else
            text = "Ready to scan."
        end
    elseif state == STATE_WAITING then
        if scan.answered or scan.growing then
            text = "Receiving auctions (" .. (scan.lastCount or 0) .. ")..."
        else
            text = "Waiting for the auction house..."
        end
    elseif state == STATE_READING then
        if scan.phase == "main" then
            local total = scan.total > 0 and scan.total or 1
            progress = READ_SHARE * (scan.pos / total)
            text = "Reading auctions " .. floor(100 * scan.pos / total) .. "%"
        else
            progress = READ_SHARE
            text = "Waiting for item data (" .. (scan.pass + 1) .. " of " .. MAX_RETRY_PASSES .. ")"
        end
    else
        local total = scan.order and #scan.order or 0
        local share = total > 0 and (scan.savePos - 1) / total or 1
        progress = READ_SHARE + (1 - READ_SHARE) * share
        text = "Saving prices " .. floor(100 * share) .. "%"
    end
    local canScan = state == STATE_IDLE and ns.IsAuctionOpen() and cooldown <= 0
        and ns.root ~= nil and ns.GetScope() ~= nil
        and Api() ~= nil and Api().ReplicateItems ~= nil
    return {
        state = state, progress = progress, text = text,
        canScan = canScan and true or false, cooldown = cooldown,
    }
end

-- Saving ---------------------------------------------------------------------

local function QueueName(id, key)
    if pendingNames[id] or pendingNameCount >= MAX_PENDING_NAMES then return end
    pendingNames[id] = key
    pendingNameCount = pendingNameCount + 1
end

local function ApiQuality(id)
    if C_Item and C_Item.GetItemQualityByID then
        local quality = C_Item.GetItemQualityByID(id)
        if type(quality) == "number" and not IsSecret(quality) then return quality end
    end
    return nil
end

-- Saves the display name of a key; asks the game for it when it isn't known.
local function SaveName(key, id, rowName, rowQuality)
    local suffixed = strmatch(key, "^%d+:(.*)$")
    local name
    if suffixed then
        name = suffixed
    elseif type(rowName) == "string" and rowName ~= "" and not IsSecret(rowName) then
        name = rowName
    elseif C_Item and C_Item.GetItemNameByID then
        name = C_Item.GetItemNameByID(id)
    end
    if type(name) ~= "string" or name == "" or IsSecret(name) then
        if not suffixed then
            ns.RequestItemLoad(id)
            QueueName(id, key)
        end
        return
    end
    local quality = type(rowQuality) == "number" and not IsSecret(rowQuality) and rowQuality or nil
    ns.RememberName(key, name, quality or ApiQuality(id) or 1)
end

local function SaveGroup(key, group)
    local listings = {}
    for index = 1, group.n do
        listings[index] = { unitPrice = group.p[index], quantity = group.q[index] }
    end
    ns.RecordFull(key, listings)
    SaveName(key, group.id, group.name, group.quality)
end

local function StepSaving()
    local order, groups = scan.order, scan.groups
    local count = #order
    local started = Millis()
    local index = scan.savePos
    local done = 0
    while index <= count do
        local key = order[index]
        local ok = pcall(SaveGroup, key, groups[key])
        if not ok then scan.failed = scan.failed + 1 end
        groups[key] = nil
        index = index + 1
        done = done + 1
        if done % 2 == 0 and Millis() - started >= FRAME_BUDGET_MS then break end
    end
    scan.savePos = index
    if index <= count then return end

    local data = ns.GetScopeData(true)
    if data then
        data.lastFull = ns.Now()
        data.lastFullCount = count
    end
    local line = "Full scan done: " .. (count - scan.failed) .. " items from " .. scan.listings .. " listings"
    local skipped = scan.skipped + scan.failed
    if skipped > 0 then
        line = line .. ", " .. skipped .. " skipped (item data was not ready)"
    end
    Finish(line .. ".")
    ns.Fire("PRICES")
end

local function BeginSaving()
    scan.state = STATE_SAVING
    scan.savePos = 1
    scan.failed = 0
    scan.retry, scan.work, scan.linkKeys = nil, nil, nil
end

-- Reading --------------------------------------------------------------------

-- Reads one row into the groups. Returns RETRY when the game doesn't know
-- enough yet, SKIP for a row that isn't usable, nothing when it was added.
local function ProcessRow(index)
    local name, _, count, quality, _, _, _, _, _, buyout, _, _, _, _, _, _, itemID, hasAll =
        C_AuctionHouse.GetReplicateItemInfo(index)
    if IsSecret(buyout) or IsSecret(itemID) or IsSecret(count) then return SKIP end
    if type(buyout) ~= "number" or buyout <= 0 then
        -- No buyout on a row that isn't complete yet may still become one.
        if hasAll == false then return RETRY end
        return SKIP -- bid only
    end
    if type(itemID) ~= "number" or itemID <= 0 then return RETRY end
    if type(count) ~= "number" or count < 1 then count = 1 end

    local key
    local gear = ns.IsGearItem(itemID)
    if gear == nil then
        ns.RequestItemLoad(itemID)
        return RETRY
    elseif gear then
        -- Only weapons and armour need the link: it carries the random suffix.
        local link = C_AuctionHouse.GetReplicateItemLink(index)
        if type(link) ~= "string" or IsSecret(link) then return RETRY end
        key = scan.linkKeys[link]
        if not key then
            local found, pending = ns.KeyFromLink(link)
            if pending then return RETRY end
            if not found then return SKIP end
            scan.linkKeys[link] = found
            key = found
        end
    else
        key = scan.idKeys[itemID]
        if not key then
            key = ns.KeyFromLink(itemID)
            if not key then return SKIP end
            scan.idKeys[itemID] = key
        end
    end

    local unit = floor(buyout / count)
    if unit < 1 then unit = 1 end
    local group = scan.groups[key]
    if not group then
        group = { id = itemID, n = 0, p = {}, q = {}, at = {} }
        scan.groups[key] = group
        scan.order[#scan.order + 1] = key
    end
    if group.name == nil and type(name) == "string" and not IsSecret(name) then
        group.name = name
        if type(quality) == "number" and not IsSecret(quality) then group.quality = quality end
    end
    -- Listings at one price are added up, so a common item stays quick to save.
    local n = group.at[unit]
    if n then
        group.q[n] = group.q[n] + floor(count)
    else
        n = group.n + 1
        group.n = n
        group.at[unit] = n
        group.p[n] = unit
        group.q[n] = floor(count)
    end
    scan.listings = scan.listings + 1
    return nil
end

local function BeginReading(total)
    scan.state = STATE_READING
    scan.phase = "main"
    scan.total = total
    scan.pos = 0
    scan.groups, scan.order = {}, {}
    scan.linkKeys, scan.idKeys = {}, {}
    scan.retry = {}
    scan.pass = 0
    scan.listings = 0
    scan.skipped = 0
end

-- After a pass: another pass for the rows still unknown, or on to saving.
local function EndPass(still)
    if #still == 0 then
        BeginSaving()
    elseif scan.pass >= MAX_RETRY_PASSES then
        scan.skipped = #still
        BeginSaving()
    else
        scan.retry = still
        scan.phase = "retry"
        scan.work = nil
        scan.nextPassAt = Seconds() + PASS_INTERVAL
    end
end

local function StepReading(now)
    local available = NumReplicate()
    if available == 0 then
        Finish("Scan stopped: the auction list was cleared. Nothing was saved.")
        return
    end
    if available > scan.total and not scan.work then
        -- More auctions arrived after reading began. The main pass just runs on;
        -- during the retries the new rows join the next pass.
        if scan.phase ~= "main" then
            for index = scan.total, available - 1 do
                scan.retry[#scan.retry + 1] = index
            end
        end
        scan.total = available
    end
    local started = Millis()
    if scan.phase == "main" then
        local index, total = scan.pos, scan.total
        local retry = scan.retry
        local done = 0
        while index < total do
            if ProcessRow(index) == RETRY then retry[#retry + 1] = index end
            index = index + 1
            done = done + 1
            if done % CHECK_EVERY == 0 and Millis() - started >= FRAME_BUDGET_MS then break end
        end
        scan.pos = index
        if index >= total then
            if #retry > 0 then
                scan.pass = 0
                scan.phase = "retry"
                scan.nextPassAt = Seconds() + PASS_INTERVAL
            else
                BeginSaving()
            end
        end
        return
    end

    -- Retry passes, one second apart.
    if not scan.work then
        if now < scan.nextPassAt then return end
        scan.work = scan.retry
        scan.still = {}
        scan.workPos = 1
    end
    local work, still = scan.work, scan.still
    local count = #work
    local index = scan.workPos
    local done = 0
    while index <= count do
        local row = work[index]
        if ProcessRow(row) == RETRY then still[#still + 1] = row end
        index = index + 1
        done = done + 1
        if done % CHECK_EVERY == 0 and Millis() - started >= FRAME_BUDGET_MS then break end
    end
    scan.workPos = index
    if index > count then
        scan.pass = scan.pass + 1
        EndPass(still)
    end
end

-- Waiting --------------------------------------------------------------------

local function StepWaiting(now)
    if not scan.answered then
        -- The list can grow for a minute before the event comes, so a change in
        -- its size counts as an answer too.
        local count = NumReplicate()
        if count ~= scan.lastCount then
            scan.lastCount, scan.changedAt = count, now
            scan.growing = count > 0
        elseif scan.growing then
            if now - scan.changedAt >= QUIET_SECONDS then scan.answered = true end
        elseif now - scan.changedAt >= NO_ANSWER_TIMEOUT then
            -- The server ignored the request, so it didn't use up the allowance.
            if ns.root then ns.root.lastRequest = previousRequest end
            retryNotBefore = now + RETRY_AFTER_TIMEOUT
            Finish("The auction house gave no answer in " .. NO_ANSWER_TIMEOUT .. " seconds. "
                .. "The server allows a full scan only about every 15 minutes. "
                .. "Try again in a minute.")
        end
        return
    end
    local count = NumReplicate()
    if count ~= scan.lastCount then
        scan.lastCount = count
        scan.changedAt = now
        if count == 0 then
            -- The old list was cleared for the new one; keep waiting for that.
            scan.answered, scan.growing = false, false
        end
        return
    end
    if count > 0 and (now - scan.changedAt >= SETTLE_SECONDS or now - scan.startedAt >= SETTLE_MAX) then
        BeginReading(count)
    end
end

-- The frame's main loop ------------------------------------------------------

local ProcessBrowseResult, PassiveStep

Step = function()
    local now = Seconds()
    local state = scan.state
    if state == STATE_WAITING then
        StepWaiting(now)
    elseif state == STATE_READING then
        StepReading(now)
    elseif state == STATE_SAVING then
        StepSaving()
    else
        PassiveStep()
    end
    if scan.state ~= STATE_IDLE then ns.Fire("SCAN") end
    UpdateTicking()
end

-- Starting -------------------------------------------------------------------

function ns.StartFullScan()
    if scan.state ~= STATE_IDLE then return false, "A scan is already running." end
    if not ns.IsAuctionOpen() then return false, "Open the auction house first." end
    local api = Api()
    if not (api and api.ReplicateItems) then return false, "This game client has no full scan." end
    if not ns.root or not ns.GetScope() then return false, "The realm isn't known yet. Try again in a moment." end
    local cooldown = CooldownLeft()
    if cooldown > 0 then return false, "The next full scan is possible in " .. Duration(cooldown) .. "." end

    previousRequest = ns.root.lastRequest
    local ok = pcall(api.ReplicateItems)
    if not ok then return false, "The auction house refused the request." end
    ns.root.lastRequest = ns.Now()

    commodityJob, itemJob, browseList, browseDirty = nil, nil, nil, false
    scan.state = STATE_WAITING
    scan.startedAt = Seconds()
    scan.answered = false
    scan.lastCount = NumReplicate()   -- may still be the list of an earlier scan
    scan.growing = false
    scan.changedAt = scan.startedAt
    ns.Fire("SCAN")
    UpdateTicking()
    return true
end

function ns.OnAuctionShow()
    auctionOpen = true
    browsePrice, browseQty = {}, {}
    if ns.db and ns.db.autoScan then
        local status = ns.GetScanStatus()
        if status.canScan then ns.StartFullScan() end
    end
end

function ns.OnAuctionClosed()
    auctionOpen = false
    browseDirty, browseList, commodityJob, itemJob = false, nil, nil, nil
    browsePrice, browseQty = {}, {}
    local state = scan.state
    if state == STATE_WAITING or state == STATE_READING then
        Finish("Scan stopped: the auction house was closed. Nothing was saved.")
    else
        UpdateTicking()
    end
end

-- Passive recording ----------------------------------------------------------

local function KeyName(key, id)
    local suffixed = strmatch(key, "^%d+:(.*)$")
    if suffixed then
        ns.RememberName(key, suffixed, ApiQuality(id) or 1)
        return
    end
    if C_Item and C_Item.GetItemNameByID then
        ns.RememberName(key, C_Item.GetItemNameByID(id), ApiQuality(id) or 1)
    end
end

ProcessBrowseResult = function(result)
    if type(result) ~= "table" then return end
    local itemKey = result.itemKey
    if type(itemKey) ~= "table" then return end
    local id, minPrice, quantity = itemKey.itemID, result.minPrice, result.totalQuantity
    if IsSecret(id) or IsSecret(minPrice) or IsSecret(quantity) then return end
    if type(id) ~= "number" or type(minPrice) ~= "number" or type(quantity) ~= "number" then return end
    if minPrice <= 0 or quantity <= 0 then return end
    -- The same result delivered again costs one comparison.
    if browsePrice[id] == minPrice and browseQty[id] == quantity then return end
    local info = C_AuctionHouse.GetItemKeyInfo(itemKey)
    if type(info) ~= "table" then return end -- not loaded yet; a later update brings it
    -- For other items minPrice can be a bid, so only commodities are recorded here.
    if info.isCommodity ~= true then
        browsePrice[id], browseQty[id] = minPrice, quantity
        return
    end
    local key = ns.KeyFromLink(id)
    if not key then return end -- not marked as seen: a later delivery tries again
    browsePrice[id], browseQty[id] = minPrice, quantity
    ns.RecordLow(key, minPrice, quantity)
    local quality = info.quality
    if type(quality) ~= "number" or IsSecret(quality) then quality = nil end
    ns.RememberName(key, info.itemName, quality or ApiQuality(id) or 1)
end

local function StartCommodityJob(itemID)
    local api = Api()
    if type(itemID) ~= "number" or IsSecret(itemID) then return end
    if not (api.HasFullCommoditySearchResults and api.HasFullCommoditySearchResults(itemID)) then return end
    local total = api.GetNumCommoditySearchResults(itemID)
    if type(total) ~= "number" or IsSecret(total) or total <= 0 then return end
    commodityJob = { id = itemID, total = total, pos = 1, list = {} }
end

local function StepCommodityJob(started)
    local job = commodityJob
    local api = Api()
    local list = job.list
    local done = 0
    while job.pos <= job.total do
        local row = api.GetCommoditySearchResultInfo(job.id, job.pos)
        job.pos = job.pos + 1
        if type(row) == "table" then
            local price, quantity = row.unitPrice, row.quantity
            if type(price) == "number" and type(quantity) == "number"
                and not IsSecret(price) and not IsSecret(quantity) and price > 0 and quantity > 0 then
                list[#list + 1] = { unitPrice = price, quantity = quantity }
            end
        end
        done = done + 1
        if done % CHECK_EVERY == 0 and Millis() - started >= PASSIVE_BUDGET_MS then return end
    end
    commodityJob = nil
    local key = ns.KeyFromLink(job.id)
    if key and #list > 0 and ns.RecordFull(key, list) then
        KeyName(key, job.id)
    end
end

local function StartItemJob(itemKey)
    local api = Api()
    if type(itemKey) ~= "table" then return end
    local id = itemKey.itemID
    if type(id) ~= "number" or IsSecret(id) then return end
    if not (api.HasFullItemSearchResults and api.HasFullItemSearchResults(itemKey)) then return end
    local total = api.GetNumItemSearchResults(itemKey)
    if type(total) ~= "number" or IsSecret(total) or total <= 0 then return end
    itemJob = {
        key = itemKey, id = id, total = total, pos = 1,
        groups = {}, order = {}, linkKeys = {}, unknown = false,
    }
end

local function StepItemJob(started)
    local job = itemJob
    local api = Api()
    local done = 0
    while job.pos <= job.total do
        local row = api.GetItemSearchResultInfo(job.key, job.pos)
        job.pos = job.pos + 1
        if type(row) == "table" then
            local buyout, quantity, link = row.buyoutAmount, row.quantity, row.itemLink
            if IsSecret(buyout) or IsSecret(quantity) or IsSecret(link) then
                job.unknown = true
            elseif type(buyout) == "number" and buyout > 0 then
                if type(quantity) ~= "number" or quantity < 1 then quantity = 1 end
                local key
                if type(link) == "string" then
                    key = job.linkKeys[link]
                    if not key then
                        local found = ns.KeyFromLink(link)
                        if found then
                            job.linkKeys[link] = found
                            key = found
                        end
                    end
                end
                if not key then
                    job.unknown = true     -- some auctions couldn't be placed, so no list is complete
                else
                    local unit = floor(buyout / quantity)
                    if unit < 1 then unit = 1 end
                    local group = job.groups[key]
                    if not group then
                        group = { low = unit, quantity = 0, list = {} }
                        job.groups[key] = group
                        job.order[#job.order + 1] = key
                    end
                    if unit < group.low then group.low = unit end
                    group.quantity = group.quantity + floor(quantity)
                    group.list[#group.list + 1] = { unitPrice = unit, quantity = floor(quantity) }
                end
            end
        end
        done = done + 1
        if done % CHECK_EVERY == 0 and Millis() - started >= PASSIVE_BUDGET_MS then return end
    end
    itemJob = nil
    for index = 1, #job.order do
        local key = job.order[index]
        local group = job.groups[key]
        if job.unknown then
            ns.RecordLow(key, group.low, group.quantity)
        else
            ns.RecordFull(key, group.list)
        end
        local id = tonumber(strmatch(key, "^(%d+)"))
        if id then KeyName(key, id) end
    end
end

PassiveStep = function()
    local started = Millis()
    if browseDirty then
        browseDirty = false
        local list = Api().GetBrowseResults and Api().GetBrowseResults()
        if type(list) == "table" then
            browseList, browseCursor = list, 1
        end
    end
    if browseList then
        local list = browseList
        local count = #list
        local done = 0
        while browseCursor <= count do
            local result = list[browseCursor]
            browseCursor = browseCursor + 1
            ProcessBrowseResult(result)
            done = done + 1
            if done % 16 == 0 and Millis() - started >= PASSIVE_BUDGET_MS then break end
        end
        if browseCursor > count then browseList = nil end
    end
    if Millis() - started >= PASSIVE_BUDGET_MS then return end
    if commodityJob then StepCommodityJob(started) end
    if Millis() - started >= PASSIVE_BUDGET_MS then return end
    if itemJob then StepItemJob(started) end
end

-- Events ---------------------------------------------------------------------

local function OnBrowse()
    if PassiveActive() then
        browseDirty = true
        UpdateTicking()
    end
end

local function OnItemDataLoaded(itemID)
    if type(itemID) ~= "number" or IsSecret(itemID) then return end
    local key = pendingNames[itemID]
    if not key then return end
    local name = C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(itemID)
    if type(name) == "string" and name ~= "" and not IsSecret(name) then
        pendingNames[itemID] = nil
        pendingNameCount = pendingNameCount - 1
        ns.RememberName(key, name, ApiQuality(itemID) or 1)
    end
end

local function OnEvent(event, arg1)
    if event == "REPLICATE_ITEM_LIST_UPDATE" then
        local state = scan.state
        if state == STATE_WAITING then
            local count = NumReplicate()
            if count > 0 then
                if not scan.answered then
                    scan.answered = true
                    scan.lastCount = count
                    scan.changedAt = Seconds()
                elseif count ~= scan.lastCount then
                    scan.lastCount = count
                    scan.changedAt = Seconds()
                end
            end
        end
        -- While reading, the events carry nothing new: the row count was fixed
        -- when reading began and the frame loop notices an emptied list.
    elseif event == "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED"
        or event == "AUCTION_HOUSE_BROWSE_RESULTS_ADDED" then
        OnBrowse()
    elseif event == "COMMODITY_SEARCH_RESULTS_UPDATED" then
        if PassiveActive() then
            StartCommodityJob(arg1)
            UpdateTicking()
        end
    elseif event == "ITEM_SEARCH_RESULTS_UPDATED" then
        if PassiveActive() then
            StartItemJob(arg1)
            UpdateTicking()
        end
    elseif event == "ITEM_DATA_LOAD_RESULT" then
        OnItemDataLoaded(arg1)
    end
end

-- Whatever the game hands over, an event never raises an error.
frame:SetScript("OnEvent", function(_, event, arg1)
    pcall(OnEvent, event, arg1)
end)

for _, event in ipairs({
    "REPLICATE_ITEM_LIST_UPDATE",
    "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED",
    "AUCTION_HOUSE_BROWSE_RESULTS_ADDED",
    "COMMODITY_SEARCH_RESULTS_UPDATED",
    "ITEM_SEARCH_RESULTS_UPDATED",
    "ITEM_DATA_LOAD_RESULT",
}) do
    pcall(frame.RegisterEvent, frame, event)
end
