local pools = require "lp.pools"

local args = { ... }

local subcommand = args[1]

local function input(query)
    write(query)
    return read()
end

local function audit()
    local wallet = require "lp.wallet"
    local sessions = require "lp.sessions"
    local inventory = require "lp.inventory"

    local f = fs.open("/audit.txt", "wb")
    local function putStr(s)
        print(s)
        f.write(s .. "\n")
    end

    putStr("Starting new audit")

    local roundingFund = wallet.getRoundingFund()
    putStr("Withdrawal rounding fund: " .. roundingFund .. " KST")

    local kristTotal = roundingFund
    for _, account in sessions.accounts() do
        putStr(("Allocation for %s: %g"):format(account.username, account.balance))
        kristTotal = kristTotal + account.balance
    end

    local ok = true
    local underAllocations = {}
    local overAllocations = {}
    for poolId, pool in pools.pools() do
        local item, nbt = poolId:match("([^~]+)~([^~]+)")
        local allocated = pool.allocatedItems
        local stored = inventory.get().getCount(item, nbt)
        kristTotal = kristTotal + pool.allocatedKrist
        putStr("Pool " .. pool.label)
        putStr("\tItems: " .. allocated)
        putStr("\tStored: " .. stored)
        putStr("\tKST: " .. pool.allocatedKrist)
        putStr("\tPrice: " .. pool.allocatedKrist / allocated)
        putStr("\tk = " .. allocated * pool.allocatedKrist)
        if allocated > stored then
            putStr("Storage doesn't meet allocation for pool ".. poolId)
            overAllocations[#overAllocations + 1] = {
                pool.label,
                allocated,
                stored,
            }
            ok = false
        elseif allocated < stored then
            underAllocations[#underAllocations + 1] = {
                pool.label,
                allocated,
                stored,
            }
        end
    end

    putStr(("%g Under-allocations"):format(#underAllocations))
    for _, v in pairs(underAllocations) do
        putStr(("Pool %s: %d allocated, %d stored"):format(unpack(v)))
    end

    putStr(("%g Over-allocations"):format(#overAllocations))
    for _, v in pairs(overAllocations) do
        putStr(("Pool %s: %d allocated, %d stored"):format(unpack(v)))
    end

    while not wallet.getIsKristUp() do sleep(5) end -- Dirty dirty hack
    local balance = wallet.fetchBalance()
    local unallocatedKrist = balance - kristTotal
    if unallocatedKrist >= 0 then
        putStr(unallocatedKrist .. " unallocated KST")
    else
        putStr(("Wrong KST allocation: %g allocated, %g stored"):format(
            kristTotal,
            balance
        ))
        ok = false
    end

    putStr("Audit done")
    putStr("Status: " .. (ok and "SOLVENT" or "INSOLVENT"))
end

if subcommand == "mkpool" then
    print("Using slot 1 as the item selection")
    if turtle.getItemCount(1) == 0 then print("Put the target item into the first slot") end
    while turtle.getItemCount(1) == 0 do os.pullEvent("turtle_inventory") end
    local item = turtle.getItemDetail(1, true)
    local items = assert(tonumber(args[2] or input("Initial item allocation? ")), "invalid number")
    local kst = assert(tonumber(args[3] or input("Initial KST allocation? ")), "invalid number")
    local label = args[6] or input("Label for the UI entry? ")
    assert(pools.create(label, item.name, item.nbt or "NONE", items, kst, true))
elseif subcommand == "rmpool" then
    local pool = assert(pools.getByTag(args[2] or input("Pool label? ")), "the pool doesn't exist")
    pool:remove(true)
elseif subcommand == "kst" then
    local pool = assert(pools.getByTag(args[2] or input("Pool label? ")), "the pool doesn't exist")
    print("Pool has " .. pool.allocatedItems .. " allocated items")
    print("Pool has " .. pool.allocatedKrist .. " allocated KST")
    print("Price: " .. pool.allocatedKrist / pool.allocatedItems)
    local delta = assert(tonumber(args[3] or input("Change KST alloc by how much? ")), "invalid number")
    assert(pool.allocatedKrist > -delta, "Can't reallocate to 0 KST or less")
    pool:reallocKst(delta, true)
elseif subcommand == "item" then
    local pool = assert(pools.getByTag(args[2] or input("Pool label? ")), "the pool doesn't exist")
    print("Pool has " .. pool.allocatedItems .. " allocated items")
    print("Pool has " .. pool.allocatedKrist .. " allocated KST")
    print("Price: " .. pool.allocatedKrist / pool.allocatedItems)
    local delta = assert(tonumber(args[3] or input("Change item alloc by how much? ")), "invalid number")
    delta = math.floor(delta)
    assert(pool.allocatedItems > -delta, "Can't reallocate to 0 items or less")
    pool:reallocItems(delta, true)
elseif subcommand == "realloc" then
    local pool = assert(pools.getByTag(args[2] or input("Pool label? ")), "the pool doesn't exist")
    print("Pool has " .. pool.allocatedItems .. " allocated items")
    print("Pool has " .. pool.allocatedKrist .. " allocated KST")
    print("Price: " .. pool.allocatedKrist / pool.allocatedItems)
    local delta = assert(tonumber(args[3] or input("Change balanced alloc by how many items? ")), "invalid number")
    delta = math.floor(delta)
    assert(pool.allocatedItems > -delta, "Can't reallocate to 0 items or less")
    pool:reallocBalanced(delta, true)
elseif subcommand == "info" then
    local pool = assert(pools.getByTag(args[2] or input("Pool label? ")), "the pool doesn't exist")
    print("Pool has " .. pool.allocatedItems .. " allocated items")
    print("Pool has " .. pool.allocatedKrist .. " allocated KST")
    print("Price: " .. pool.allocatedKrist / pool.allocatedItems)
elseif subcommand == "list" then
    for _, pool in pools.pools() do print(pool.label) end
elseif subcommand == "audit" then
    audit()
elseif subcommand == "round" then
    local delta = assert(tonumber(args[2] or input("Change rounding fund by how much? ")), "invalid number")
    local wallet = require "lp.wallet"
    local final = wallet.reallocateRounding(delta, true)
    print("Rounding fund now at " .. final)
elseif subcommand == "categorize" then
    local pool = assert(pools.getByTag(args[2] or input("Pool label? ")), "the pool doesn't exist")
    local new = pool:toggleCategory(args[3] or input("Category? "), true)
    if new then
        print("Pool added to category")
    else
        print("Pool removed from category")
    end
elseif subcommand == "lost" then
    local tracked = {}
    for cat in pools.categories() do
        for id in pools.pools(cat) do
            tracked[id] = true
        end
    end
    local untracked = {} ---@type table<string, Pool>
    local nUntracked = 0
    for id, pool in pools.pools() do
        if not tracked[id] then
            untracked[id] = pool
            nUntracked = nUntracked + 1
        end
    end
    print("Found " .. nUntracked .. " uncategorized pools:")
    for _, pool in pairs(untracked) do
        print("\t" .. pool.label)
    end
else
    print("Valid subcommands: mkpool rmpool kst item realloc info list audit round categorize lost")
end
