local wallet = require "lp.wallet"
local pools = require "lp.pools"
local util = require "lp.util"
local threads = require "lp.threads"
local event = require "lp.event"

local MEAN_ALLOCATION_TIME = 60
local ALLOCATION_RATE = 0.006
local ALLOCATION_KRIST_MIN = 0.5
local LIQ_RATE = 5.93e-7

local globalReallocEvent = event.register()

local function computeTargetDeltas()
    -- Sum of all dynamic allocated pools' Krist
    local dynSum = wallet.getDynFund()
    for _, pool in pools.pools() do
        if pool.dynAlloc then
            if pool.dynAlloc.type == "fixed_rate" then
                local feeRate = pool.dynAlloc.rate / 2
                local feeShare = feeRate / (1 - feeRate) * wallet.getFeeFund()
                dynSum = dynSum + pool.allocatedKrist - feeShare
            else
                dynSum = dynSum + pool.allocatedKrist
            end
        end
    end

    local positiveDeltas = {} ---@type table<string, number>
    local negativeDeltas = {} ---@type table<string, number>

    -- Sum of all fixed rate pools' Krist, after correction
    local fixedRateSum = 0
    for id, pool in pools.pools() do
        local alloc = pool.dynAlloc
        if alloc then
            if alloc.type == "fixed_rate" then
                ---@cast alloc FixedRateScheme
                local capitalShare = dynSum * alloc.rate
                local feeRate = alloc.rate / 2
                local feeShare = feeRate / (1 - feeRate) * wallet.getFeeFund()
                local target = math.max(0, util.mFloor(capitalShare + feeShare))
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

    -- Sum of all weighted remainder pools' Krist
    local wremSum = 0
    for _, pool in pools.pools() do
        local alloc = pool.dynAlloc
        if alloc then
            if alloc.type == "weighted_remainder" then
                ---@cast alloc WeightedRemainderScheme
                wremSum = wremSum + pool.allocatedKrist
            end
        end
    end

    -- Amount of krist needed (< 0) or available (> 0) to allocate into the
    -- weighted remainder pools
    local remainder = util.mRound(dynSum - fixedRateSum - wremSum)

    -- Weight sum and count
    local weightSum = 0
    local wremCount = 0
    for _, pool in pools.pools() do
        local alloc = pool.dynAlloc
        if alloc then
            if alloc.type == "weighted_remainder" then
                ---@cast alloc WeightedRemainderScheme
                weightSum = weightSum + alloc.weight
                wremCount = wremCount + 1
            end
        end
    end

    -- Weight average
    -- Pools with a weight larger than average will expand
    -- Pools with a weight smaller than the average will contract
    local weightAvg =  weightSum / wremCount
    if wremCount == 0 then return positiveDeltas, negativeDeltas end

    -- The remainder gets distributed evenly among all pools
    -- After that, pools will reallocate accorting to their weight. Pools with a
    -- weight equal to twice the average will double in size, while pools with a
    -- weight equal to half the average will halve in size.
    for id, pool in pools.pools() do
        local alloc = pool.dynAlloc
        if alloc then
            if alloc.type == "weighted_remainder" then
                ---@cast alloc WeightedRemainderScheme
                local myKstRatio = pool.allocatedKrist / wremSum
                local remTarget = pool.allocatedKrist + remainder * myKstRatio
                local allTarget = (alloc.weight / weightAvg) * remTarget
                local delta = util.mFloor(allTarget - pool.allocatedKrist)
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

--- @param rate number
--- @param commit boolean
local function rebalance(rate, commit)
    rate = math.max(0, math.min(1, rate))

    local positiveDeltas, negativeDeltas = computeTargetDeltas()

    local total = 0
    for _, amt in pairs(positiveDeltas) do total = total + amt end
    for _, amt in pairs(negativeDeltas) do total = total - amt end

    local minRate = math.min(1, ALLOCATION_KRIST_MIN / total)
    rate = math.max(rate, minRate)

    local kstToMove = util.mFloor(rate * total)

    local positiveKeys = shuffledKeys(positiveDeltas)
    local negativeKeys = shuffledKeys(negativeDeltas)

    local negRemaining = kstToMove
    for i = 1, #negativeKeys do
        if negRemaining <= 0 then break end
        local id = negativeKeys[i]
        local pool = pools.get(id)
        if pool then
            local delta = math.max(-negRemaining, negativeDeltas[id] * rate)
            pool:reallocKst(delta, false, true)
            wallet.reallocateDyn(-delta, false)
            negRemaining = util.mFloor(negRemaining + delta)
            if pool.dynAlloc.type == "weighted_remainder" then
                local weight = pool.dynAlloc.weight
                local target = pool.allocatedKrist + delta
                pool.dynAlloc.weight = weight * pool.allocatedKrist / target
            end
        end
    end

    local posRemaining = math.min(kstToMove, wallet.getDynFund())
    for i = 1, #positiveKeys do
        if posRemaining <= 0 then break end
        local id = positiveKeys[i]
        local pool = pools.get(id)
        if pool then
            local delta = math.min(posRemaining, positiveDeltas[id] * rate)
            pool:reallocKst(delta, false, true)
            wallet.reallocateDyn(-delta, false)
            posRemaining = util.mFloor(posRemaining - delta)
            if pool.dynAlloc.type == "weighted_remainder" then
                local weight = pool.dynAlloc.weight
                local target = pool.allocatedKrist + delta
                pool.dynAlloc.weight = weight * pool.allocatedKrist / target
            end
        end
    end

    globalReallocEvent.queue()
    if commit then pools.state:commitMany(wallet.state) end
end

threads.register(function()
    while true do
        sleep(math.random(0, 2 * MEAN_ALLOCATION_TIME))
        rebalance(ALLOCATION_RATE, true)
    end
end)

threads.register(function()
    local c = math.floor(math.random() * 6000 + 6000.5) / 20
    sleep(c)
    local liq = 1 - (1 - LIQ_RATE) ^ c
    for _, pool in pools.pools() do
        if pool.liquidating then
            local delta = util.mCeil(liq * pool.allocatedKrist)
            pool:reallocKst(-delta, false, true)
            wallet.reallocateFee(delta, false)
            pools.state:commitMany(wallet.state)
        end
    end
    globalReallocEvent.queue()
end)

return {
    globalReallocEvent = globalReallocEvent,
    computeTargetDeltas = computeTargetDeltas,
    rebalance = rebalance,
}
