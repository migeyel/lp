local state = require "lp.state".open "lp.questions"
local secprice = require "lp.secprice"
local sessions = require "lp.sessions"
local threads = require "lp.threads"
local cbb = require "cbb"

---@type table<number, Proposition?>
state.propositions = state.propositions or {}

---@type number
state.nextId = state.nextId or 1

local TALLY_GRAPHIC_WIDTH = 150

---@class Proposition
---@field id number
---@field authorUuid string
---@field title string
---@field expired boolean
---@field sharesFor number
---@field sharesAgainst number
---@field sharesNone number
---@field created number
---@field expiry number
---@field description string
---@field votes table<string, number> Map of UUIDs to voting portions.
local Proposition = {}

---@param author Account
---@param title string
---@param description string
---@param expiry number
---@param commit boolean
---@return Proposition
local function create(author, title, description, expiry, commit)
    local prop = { ---@type Proposition
        id = state.nextId,
        authorUuid = author.uuid,
        title = title,
        expired = false,
        sharesFor = 0,
        sharesAgainst = 0,
        sharesNone = 0,
        description = description,
        created = os.epoch("utc"),
        expiry = expiry,
        votes = {},
    }

    state.propositions[prop.id] = prop
    state.nextId = state.nextId + 1

    if commit then state.commit() end

    return setmetatable(prop, { __index = Proposition })
end

---@param id number
---@return Proposition?
local function get(id)
    local prop = state.propositions[id]
    if not prop then return end
    return setmetatable(prop, { __index = Proposition })
end

local function propositions()
    local function pnext(_, k0)
        local k1, p = next(state.propositions, k0)
        if p then return k1, setmetatable(p, { __index = Proposition }) end
    end

    return pnext, nil, nil
end

local function expireProps()
    for _, prop in propositions() do
        prop:tryExpire(true)
    end
end

---@param commit boolean
function Proposition:delete(commit)
    state.propositions[self.id] = nil
    if commit then state.commit() end
end

---@return { yes: number, no: number, none: number }
function Proposition:computeTally()
    local pool = secprice.getSecPool()
    local yes = 0
    local no = 0
    for id, part in pairs(self.votes) do
        local acct = sessions.getAcctByUuid(id)
        if acct then
            local shares = acct:getAsset("lp:security~NONE")
            local sharesFor = math.min(shares, math.floor(0.5 + shares * part))
            local sharesAgainst = shares - sharesFor
            yes = yes + sharesFor
            no = no + sharesAgainst
        end
    end
    local total = sessions.totalAssets(pool:id()) + pool.allocatedItems
    return { yes = yes, no = no, none = total - yes - no }
end

---@param commit boolean
function Proposition:tryExpire(commit)
    if not self.expired and os.epoch("utc") >= self.expiry then
        local tally = self:computeTally()
        self.sharesFor = tally.yes
        self.sharesAgainst = tally.no
        self.sharesNone = tally.none
        self.expired = true
        if commit then state.commit() end
    end
end

---@return { yes: number, no: number, none: number }
function Proposition:getTally()
    if self.expired then
        return {
            yes = self.sharesFor,
            no = self.sharesAgainst,
            none = self.sharesNone,
        }
    else
        return self:computeTally()
    end
end

function Proposition:isExpired()
    return os.epoch("utc") >= self.expiry
end

---@return { yes: string, no: string, none: string }
function Proposition:tallyGraph()
    local tally = self:getTally()
    local total = tally.yes + tally.no + tally.none
    local scaleFactor = TALLY_GRAPHIC_WIDTH / total
    local wYes = math.floor(0.5 + tally.yes * scaleFactor)
    local wNo = math.floor(0.5 + tally.no * scaleFactor)
    local wNone = TALLY_GRAPHIC_WIDTH - wYes - wNo
    return {
        yes = ("i"):rep(wYes),
        no = ("!"):rep(wNo),
        none = ("."):rep(wNone),
    }
end

---@param account Account
---@param amt number
---@param commit boolean
function Proposition:cast(account, amt, commit)
    expireProps()
    self.votes[account.uuid] = amt
    if commit then state.commit() end
end

function Proposition:render()
    local tally = self:getTally()
    local graph = self:tallyGraph()
    local acct = sessions.getAcctByUuid(self.authorUuid)
    local author = acct and acct.username or self.authorUuid
    return { ---@type cbb.FormattedBlock[]
        {
            text = ("LP PROPOSITION %d"):format(self.id),
            formats = { cbb.formats.BOLD },
        },
        {
            text = ("\n%s"):format(self.title),
            formats = { cbb.formats.BOLD },
        },
        {
            text = ("\n%s"):format(self.description),
        },
        {
            text = ("\nAuthor: %s"):format(author),
        },
        {
            text = ("\nStatus: %s"):format(self.expired and "Expired" or "Active"),
        },
        {
            text = os.date("\nExpires: %Y-%m-%d %H:%M:%S UTC", self.expiry / 1000) --[[@as string]],
        },
        {
            text = "\nVotes for: ",
            color = cbb.colors.GREEN,
        },
        {
            text = ("%d"):format(tally.yes),
        },
        {
            text = "\nVotes against: ",
            color = cbb.colors.RED,
        },
        {
            text = ("%d"):format(tally.no),
        },
        {
            text = "\nNon-votes: ",
            color = cbb.colors.GRAY,
        },
        {
            text = ("%d"):format(tally.none),
        },
        {
            text = ("\n[")
        },
        {
            text = graph.yes,
            color = cbb.colors.GREEN,
        },
        {
            text = graph.no,
            color = cbb.colors.RED,
        },
        {
            text = graph.none,
            color = cbb.colors.GRAY,
        },
        {
            text = "]",
        },
    }
end

threads.register(function()
    while true do
        sleep(math.random(0, 20))
        expireProps()
    end
end)

return {
    state = state,
    create = create,
    get = get,
    propositions = propositions,
}
