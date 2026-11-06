-- RulZ Level Up Tracker: XP tracking and rate calculations.
local ADDON_NAME, ns = ...

local HOUR_BUCKETS = 60       -- the past hour is stored as one bucket per minute
local MIN_SAMPLE_SECONDS = 60 -- below this an estimate would be mostly noise
local FALLBACK_MAX_LEVEL = 60
local PLAYED_REQUEST_DELAY = 3
local PLAYED_REPLY_TIMEOUT = 10
local LEVEL_UP_XP_WAIT = 1     -- seconds to wait for the XP update after a level-up
local COMPLETE_LEVEL_SHARE = 0.98 -- below this, a level wasn't fully tracked

-- A typical same-level quest's XP at levels 1 to 59, from Wowhead's WoW Forever
-- experience calculator.
local QUEST_XP = {
    80, 170, 250, 360, 450, 540, 630, 700, 780, 840,
    880, 910, 910, 980, 1050, 1150, 1250, 1350, 1450, 1550,
    1650, 1750, 1850, 1950, 2000, 2100, 2200, 2300, 2350, 2450,
    2500, 2550, 2650, 2700, 2750, 2800, 2850, 2850, 3000, 3150,
    3300, 3450, 3600, 3750, 3900, 4050, 4200, 4400, 4550, 4700,
    4900, 5100, 5250, 5450, 5650, 5800, 6000, 6200, 6400,
}

ns.MODES = {
    { key = "hour",    label = "1 Hour" },
    { key = "session", label = "Session" },
    { key = "level",   label = "Level" },
    { key = "alltime", label = "All Time" },
}

local db
local ready = false
local pendingLevel -- set when PLAYER_LEVEL_UP arrives before the matching XP update
local tickElapsed = 0
local mutedChatFrames = {}

local function NewCounter()
    return { xp = 0, seconds = 0, bonus = 0 }
end

-- Versions before bonusFixed recorded the full pool drop as bonus, twice the
-- true amount, which could leave a normal pace of zero.
local function FixDoubledBonus()
    if db.bonusFixed then return end
    local function halve(counter)
        counter.bonus = (counter.bonus or 0) / 2
    end
    halve(db.session)
    halve(db.currentLevel)
    halve(db.allTime)
    for _, bucket in pairs(db.hour) do
        halve(bucket)
    end
    db.restedSample.bonus = db.restedSample.bonus / 2
    db.restedSample.base = db.restedSample.base + db.restedSample.bonus
    db.bonusFixed = true
end

local function InitDB()
    RulZLevelUpTrackerCharDB = RulZLevelUpTrackerCharDB or {}
    db = RulZLevelUpTrackerCharDB
    if db.shown == nil then db.shown = true end
    db.mode = db.mode or "session"
    db.minimapAngle = db.minimapAngle or 215
    db.scale = db.scale or 1
    db.session = db.session or NewCounter()
    db.currentLevel = db.currentLevel or NewCounter()
    db.allTime = db.allTime or NewCounter()
    db.hour = db.hour or {}
    db.restedSample = db.restedSample or { base = 0, bonus = 0 }
    db.history = db.history or {}
    FixDoubledBonus()
    ns.db = db
end

-- Values are checked in case the client marks them as secret; arithmetic or a
-- boolean test on a secret value raises an error.
local function IsSecret(value)
    return issecretvalue and issecretvalue(value)
end

local function ReadXP()
    local cur, max = UnitXP("player"), UnitXPMax("player")
    if IsSecret(cur) or IsSecret(max) then
        return nil
    end
    return cur, max
end

local function ReadRested()
    local rested = GetXPExhaustion()
    if not rested or IsSecret(rested) then
        return 0
    end
    return rested
end

local function IsAFK()
    local afk = UnitIsAFK("player")
    return not IsSecret(afk) and afk == true
end

local function MaxLevel()
    return GetMaxPlayerLevel and GetMaxPlayerLevel() or FALLBACK_MAX_LEVEL
end

local function IsAtMaxLevel()
    return UnitLevel("player") >= MaxLevel()
end

local function SameLevelKillXP(level)
    return level * 5 + 45
end

local function SameLevelQuestXP(level)
    return QUEST_XP[math.min(level, #QUEST_XP)]
end

local function HourBucket()
    local key = math.floor(time() / 60)
    local bucket = db.hour[key]
    if not bucket then
        bucket = NewCounter()
        db.hour[key] = bucket
        for k in pairs(db.hour) do
            if k <= key - HOUR_BUCKETS then
                db.hour[k] = nil
            end
        end
    end
    return bucket
end

local function ForEachCounter(apply)
    apply(db.session)
    apply(db.currentLevel)
    apply(db.allTime)
    apply(HourBucket())
end

local function AddXP(amount, bonus)
    ForEachCounter(function(counter)
        counter.xp = counter.xp + amount
        counter.bonus = (counter.bonus or 0) + bonus
    end)
end

local function AddSeconds(amount)
    ForEachCounter(function(counter)
        counter.seconds = counter.seconds + amount
    end)
end

local function SyncBaseline()
    local cur, max = ReadXP()
    if cur then
        db.lastXP, db.lastMax = cur, max
    end
    db.lastRested = ReadRested()
end

-- Rested doubles kill XP, and the pool shrinks by the whole doubled amount, so
-- half of the drop across an XP gain is bonus. The same gain also shows how
-- much of the XP you earn qualifies for rested (kills do, quests don't).
local function TakeRestedBonus(gained)
    local before = db.lastRested or 0
    local after = ReadRested()
    db.lastRested = after
    local bonus = math.min(math.max(before - after, 0), gained) / 2
    if before > 0 and gained > 0 then
        db.restedSample.base = db.restedSample.base + gained - bonus
        db.restedSample.bonus = db.restedSample.bonus + bonus
    end
    return bonus
end

local function RestedShare()
    local sample = db.restedSample
    if sample.base <= 0 then
        return 1
    end
    return math.min(sample.bonus / sample.base, 1)
end

-- /played backfill -----------------------------------------------------------

local function LevelMissingHistory()
    local cur = ReadXP()
    return cur and cur > db.currentLevel.xp
        and not db.currentLevel.noBackfill
        and not IsAtMaxLevel()
end

local function RestoreChatFrames()
    for index, chatFrame in ipairs(mutedChatFrames) do
        chatFrame:RegisterEvent("TIME_PLAYED_MSG")
        mutedChatFrames[index] = nil
    end
end

local function RequestPlayedQuietly()
    for index = 1, NUM_CHAT_WINDOWS or 10 do
        local chatFrame = _G["ChatFrame" .. index]
        if chatFrame and chatFrame:IsEventRegistered("TIME_PLAYED_MSG") then
            chatFrame:UnregisterEvent("TIME_PLAYED_MSG")
            mutedChatFrames[#mutedChatFrames + 1] = chatFrame
        end
    end
    C_Timer.After(PLAYED_REPLY_TIMEOUT, RestoreChatFrames)
    RequestTimePlayed()
end

local function OnTimePlayed(secondsThisLevel)
    -- Wait a frame so the chat frames don't receive this same reply.
    C_Timer.After(0, RestoreChatFrames)
    if LevelMissingHistory() then
        db.currentLevel.xp = ReadXP()
        db.currentLevel.seconds = secondsThisLevel
        ns.Refresh()
    end
end

-- Events ---------------------------------------------------------------------

local function OnEnteringWorld(isLogin, isReload)
    if isLogin or isReload then
        if isLogin then
            db.session = NewCounter()
        end
        local level = UnitLevel("player")
        if db.currentLevel.level ~= level then
            db.currentLevel = NewCounter()
            db.currentLevel.level = level
        end
        ready = true
    end
    SyncBaseline()
    if (isLogin or isReload) and LevelMissingHistory() then
        C_Timer.After(PLAYED_REQUEST_DELAY, RequestPlayedQuietly)
    end
    ns.Refresh()
end

local function FinishLevel(counter, required, overflow)
    local xp = counter.xp - overflow
    local entry = {
        level = counter.level,
        seconds = counter.seconds,
        xp = xp,
        partial = xp < required * COMPLETE_LEVEL_SHARE or counter.seconds <= 0,
        finishedAt = time(),
    }
    db.history[#db.history + 1] = entry
    ns.AnnounceLevel(entry)
end

local function OnXPUpdate()
    local cur, max = ReadXP()
    if not cur or not db.lastXP then
        SyncBaseline()
        return
    end

    -- Levelling up restarts the XP count, and overflow from a large reward can
    -- leave it above the old value, so a changed requirement also counts.
    local required = db.lastMax
    local wrapped = pendingLevel or cur < db.lastXP or max ~= required
    local gained = wrapped and (required - db.lastXP + cur) or (cur - db.lastXP)
    db.lastXP, db.lastMax = cur, max

    local bonus = TakeRestedBonus(gained)
    if gained > 0 then
        AddXP(gained, bonus)
    end
    if wrapped then
        local finished = db.currentLevel
        FinishLevel(finished, required, cur)
        db.currentLevel = NewCounter()
        db.currentLevel.level = pendingLevel or (finished.level + 1)
        db.currentLevel.xp = cur
        pendingLevel = nil
    end
    ns.Refresh()
end

local function OnLevelUp(newLevel)
    if (db.currentLevel.level or 0) < newLevel then
        pendingLevel = newLevel
        -- The last XP update can be skipped, such as on reaching the level cap.
        C_Timer.After(LEVEL_UP_XP_WAIT, function()
            if pendingLevel then OnXPUpdate() end
        end)
    end
    ns.Refresh()
end

-- The pool only grows on its own (resting). Drops are left for the next XP
-- update so that they can be matched to the gain that caused them.
local function OnExhaustionUpdate()
    db.lastRested = math.max(db.lastRested or 0, ReadRested())
    ns.Refresh()
end

-- Public API -----------------------------------------------------------------

function ns.GetStats(mode)
    local xp, seconds, bonus = 0, 0, 0
    if mode == "hour" then
        local oldest = math.floor(time() / 60) - HOUR_BUCKETS
        for key, bucket in pairs(db.hour) do
            if key > oldest then
                xp = xp + bucket.xp
                seconds = seconds + bucket.seconds
                bonus = bonus + (bucket.bonus or 0)
            end
        end
    else
        local counter = (mode == "session" and db.session)
            or (mode == "level" and db.currentLevel)
            or db.allTime
        xp, seconds, bonus = counter.xp, counter.seconds, counter.bonus or 0
    end
    local perSecond
    if xp > 0 and seconds >= MIN_SAMPLE_SECONDS then
        perSecond = xp / seconds
    end
    return xp, seconds, perSecond, bonus
end

-- Seconds to earn `remaining` XP, or nil without enough data. Your underlying
-- pace excludes past rested bonus; the rested pool you still have then covers
-- part of the remaining XP. Unrested, this is remaining / pace.
function ns.GetEstimate(mode, remaining)
    local xp, seconds, perSecond, bonus = ns.GetStats(mode)
    if not perSecond then
        return nil
    end
    local toEarn = math.max(remaining / (1 + RestedShare()), remaining - ReadRested() / 2)
    return toEarn / ((xp - bonus) / seconds)
end

-- Same-level kills left, and quests left, if all of `remaining` came from one
-- of them. Each kill pays double while the rested pool lasts; quests never do.
function ns.GetKillsAndQuestsLeft(remaining, level)
    local killXP = SameLevelKillXP(level)
    local rested = math.min(ReadRested(), remaining)
    local kills = rested / (2 * killXP) + (remaining - rested) / killXP
    return math.ceil(kills), math.ceil(remaining / SameLevelQuestXP(level))
end

function ns.GetProgress()
    local cur, max = ReadXP()
    local level = UnitLevel("player")
    return cur or db.lastXP or 0, max or db.lastMax or 0, level, IsAtMaxLevel()
end

ns.GetRested = ReadRested
ns.IsPaused = IsAFK

function ns.SetMode(mode)
    db.mode = mode
    ns.Refresh()
end

function ns.Reset(mode)
    if mode == "hour" then
        db.hour = {}
    elseif mode == "session" then
        db.session = NewCounter()
    elseif mode == "level" then
        local level = db.currentLevel.level
        db.currentLevel = NewCounter()
        db.currentLevel.level = level
        db.currentLevel.noBackfill = true
    elseif mode == "alltime" then
        db.allTime = NewCounter()
    end
    ns.Refresh()
end

local engine = CreateFrame("Frame")
engine:RegisterEvent("ADDON_LOADED")
engine:SetScript("OnEvent", function(self, event, ...)
    if event == "ADDON_LOADED" then
        if ... == ADDON_NAME then
            self:UnregisterEvent("ADDON_LOADED")
            InitDB()
            ns.CreateUI()
            self:RegisterEvent("PLAYER_ENTERING_WORLD")
            self:RegisterEvent("PLAYER_XP_UPDATE")
            self:RegisterEvent("PLAYER_LEVEL_UP")
            self:RegisterEvent("UPDATE_EXHAUSTION")
            self:RegisterEvent("TIME_PLAYED_MSG")
            ns.CreateOptions() -- last, so a settings error can't stop tracking
        end
    elseif event == "PLAYER_ENTERING_WORLD" then
        OnEnteringWorld(...)
    elseif not ready then
        return
    elseif event == "PLAYER_XP_UPDATE" then
        if ... == "player" then OnXPUpdate() end
    elseif event == "PLAYER_LEVEL_UP" then
        OnLevelUp((...))
    elseif event == "UPDATE_EXHAUSTION" then
        OnExhaustionUpdate()
    elseif event == "TIME_PLAYED_MSG" then
        OnTimePlayed(select(2, ...))
    end
end)

engine:SetScript("OnUpdate", function(_, elapsed)
    if not ready then return end
    tickElapsed = tickElapsed + elapsed
    if tickElapsed >= 1 then
        if not IsAtMaxLevel() and not IsAFK() then
            AddSeconds(tickElapsed)
        end
        tickElapsed = 0
        ns.Refresh()
    end
end)
