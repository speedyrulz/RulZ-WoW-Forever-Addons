-- RulZ Level Up Tracker: hunter pet XP.
-- Each pet is tracked by name, since hunters swap pets and each has its own level.
local _, ns = ...

local active -- tracker of the pet that's out
local lastXP, lastMax, lastLevel

function ns.IsHunter()
    local _, class = UnitClass("player")
    return class == "HUNTER"
end

-- Returns nothing without a pet that earns XP. A pet can be out before its
-- details arrive, and charmed creatures have no XP to read.
local function ReadPet()
    if not UnitExists("pet") then return end
    local name = UnitName("pet")
    local cur, max = GetPetExperience()
    local level = UnitLevel("pet")
    if ns.IsSecret(name) or ns.IsSecret(cur) or ns.IsSecret(max) or ns.IsSecret(level) then return end
    if not name or name == UNKNOWNOBJECT or not cur or not max or max <= 0 then return end
    return name, cur, max, level
end

-- Pets can't pass the hunter's level.
local function CanLevel(level)
    return level < UnitLevel("player")
end

local function EnterLevel(pet, level)
    if pet.currentLevel.level ~= level then
        pet.currentLevel = ns.NewCounter()
        pet.currentLevel.level = level
    end
end

local function TrackGain(pet, cur, level)
    local gained = level > lastLevel and (lastMax - lastXP + cur) or (cur - lastXP)
    if gained > 0 then
        ns.AddTrackerXP(pet, gained)
    end
end

-- Read about once a second rather than on an event, which also catches a pet
-- whose details arrive late.
function ns.UpdatePet(elapsed)
    if not ns.IsHunter() then return end
    local name, cur, max, level = ReadPet()
    if not name then
        active = nil
        return
    end

    local pet = ns.db.pets[name]
    if not pet then
        pet = ns.NewTracker()
        ns.db.pets[name] = pet
    end
    if pet == active then
        TrackGain(pet, cur, level)
    end
    active = pet
    lastXP, lastMax, lastLevel = cur, max, level
    EnterLevel(pet, level)

    if CanLevel(level) and not ns.IsPaused() then
        ns.AddTrackerSeconds(pet, elapsed)
    end
end

function ns.StartPetSession()
    for _, pet in pairs(ns.db.pets) do
        pet.session = ns.NewCounter()
    end
end

function ns.ResetPets(mode)
    for _, pet in pairs(ns.db.pets) do
        ns.ResetTracker(pet, mode)
    end
end

-- Returns nil without a tracked pet out. secondsLeft is nil without enough data.
function ns.GetPetStatus(mode)
    local name, cur, max, level = ReadPet()
    if not name or not active then return nil end
    local _, _, perSecond = ns.GetStats(mode, active)
    local canLevel = CanLevel(level)
    return {
        name = name,
        level = level,
        cur = cur,
        max = max,
        canLevel = canLevel,
        perSecond = perSecond,
        secondsLeft = canLevel and perSecond and (max - cur) / perSecond or nil,
    }
end
