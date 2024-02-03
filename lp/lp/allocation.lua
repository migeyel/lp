local wallet = require "lp.wallet"
local pools = require "lp.pools"
local util = require "lp.util"
local threads = require "lp.threads"

local MEAN_ALLOCATION_TIME = 300
local KRIST_RATE = 1 / 3

local function computeTargetDeltas()
    local dynSum = wallet.getDynFund()
    for _, pool in pools.pools() do
        if pool.dynAlloc then
            dynSum = dynSum + pool.allocatedKrist
        end
    end

    local positiveDeltas = {} ---@type table<string, number>
    local negativeDeltas = {} ---@type table<string, number>

    local fixedRateSum = 0
    for id, pool in pools.pools() do
        local alloc = pool.dynAlloc
        if alloc then
            if alloc.type == "fixed_rate" then
                ---@cast alloc FixedRateScheme
                local target = math.max(0, util.mFloor(dynSum * alloc.rate))
                fixedRateSum = util.mCeil(fixedRateSum + target)
                local delta = util.mFloor(target - pool.allocatedKrist)
                if delta > 0 then
                    positiveDeltas[id] = delta
                elseif delta < 0 then
                    negativeDeltas[id] = delta
                end
            end
        end
    end

    local remainder = util.mFloor(dynSum - fixedRateSum)

    local weightSum = 0
    for _, pool in pools.pools() do
        local alloc = pool.dynAlloc
        if alloc then
            if alloc.type == "weighted_remainder" then
                ---@cast alloc WeightedRemainderScheme
                weightSum = weightSum + alloc.weight
            end
        end
    end

    for id, pool in pools.pools() do
        local alloc = pool.dynAlloc
        if alloc then
            if alloc.type == "weighted_remainder" then
                ---@cast alloc WeightedRemainderScheme
                local rate = alloc.weight / weightSum
                local target = math.max(0, util.mFloor(remainder * rate))
                local delta = util.mFloor(target - pool.allocatedKrist)
                if delta > 0 then
                    positiveDeltas[id] = delta
                elseif delta < 0 then
                    negativeDeltas[id] = delta
                end
            end
        end
    end

    return positiveDeltas, negativeDeltas
end

local function shuffledKeys(table)
    local pad = {}
    for k in pairs(table) do pad[#pad + 1] = k end
    for i = #pad, 2, -1 do
        local j = math.random(1, i)
        pad[i], pad[j] = pad[j], pad[i]
    end
    return pad
end

--- @param kstToMove number
--- @param commit boolean
local function rebalance(kstToMove, commit)
    kstToMove = util.mFloor(kstToMove)

    local positiveDeltas, negativeDeltas = computeTargetDeltas()
    local positiveKeys = shuffledKeys(positiveDeltas)
    local negativeKeys = shuffledKeys(negativeDeltas)

    local negRemaining = kstToMove
    for i = 1, #negativeKeys do
        if negRemaining <= 0 then break end
        local id = negativeKeys[i]
        local pool = pools.get(id)
        if pool then
            local delta = math.max(-negRemaining, negativeDeltas[id])
            pool:reallocKst(delta, false)
            wallet.reallocateDyn(-delta, false)
            negRemaining = util.mFloor(negRemaining + delta)
        end
    end

    local posRemaining = math.min(kstToMove, wallet.getDynFund())
    for i = 1, #positiveKeys do
        if posRemaining <= 0 then break end
        local id = positiveKeys[i]
        local pool = pools.get(id)
        if pool then
            local delta = math.min(posRemaining, positiveDeltas[id])
            pool:reallocKst(delta, false)
            wallet.reallocateDyn(-delta, false)
            posRemaining = util.mFloor(posRemaining - delta)
        end
    end

    if commit then wallet.state:commitMany(pools.state) end
end

threads.register(function()
    while true do
        sleep(math.random(0, 2 * MEAN_ALLOCATION_TIME))
        local amt = -1 / KRIST_RATE * math.log(1 - math.random())
        rebalance(amt, true)
    end
end)

return {
    computeTargetDeltas = computeTargetDeltas,
    rebalance = rebalance,
}
