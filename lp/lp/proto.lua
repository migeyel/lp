local lproto = require "lproto"

local proto = {}

---@class ProtoRequest
---@field id number?
---@field info ProtoRequestInfo?
---@field buy ProtoRequestBuy?
---@field sell ProtoRequestSell?

---@class ProtoRequestInfo
---@field label string?

---@class ProtoRequestBuy
---@field label string?
---@field slot number?
---@field amount number?
---@field maxPerItem number?

---@class ProtoRequestSell
---@field slot number?
---@field minPerItem string?

-- A request from a client to the LP server.
proto.Request = lproto.message {
    -- An ID to distinguish between several responses.
    id = lproto.uint53 (2);

    -- A query on information about an item.
    info = lproto.message {
        -- The item pool's label.
        label = lproto.bytes (1);
    } (1);

    -- An order to buy an item.
    buy = lproto.message {
        -- The item pool's label.
        label = lproto.bytes (1);

        -- The ender storage slot to put items into.
        slot = lproto.uint53 (3);

        -- The amount of items to buy, up to the stacking limit of the item.
        amount = lproto.uint53 (2);

        -- The maximum amount of Krist to spend per item.
        -- If the price rises to above this limit, the order fails even when it
        -- would otherwise succeed.
        maxPerItem = lproto.double (4);
    } (3);

    -- An order to sell an item.
    sell = lproto.message {
        -- The ender storage slot to take items from.
        slot = lproto.uint53 (1);

        -- The minimum amount of Krist earned per item.
        -- If the price falls to below this limit, the order fails even when it
        -- would otherwise succeed.
        minPerItem = lproto.double (2);
    } (4);
}

-- A successful buy order.
proto.BuyOrderExecution = lproto.message {
    -- The amount of items bought, may be less than requested.
    amount = lproto.uint53 (1);

    -- The amount of Krist spent in the order, including fees.
    spent = lproto.double (2);

    -- The amount of Krist spent on fees.
    fees = lproto.double (3);

    -- The remaining balance immediately after order execution.
    balance = lproto.double (4);

    -- The amount of allocated items in the pool immediately after order
    -- execution
    allocatedItems = lproto.uint53 (5);

    -- The amount of allocated Krist in the pool immediately after order
    -- execution
    allocatedKrist = lproto.double (6);
}

-- A successful sell order.
proto.SellOrderExecution = lproto.message {
    -- The amount of items sold, may be less than requested.
    amount = lproto.uint53 (1);

    -- The amount of Krist earned in the order, including fees.
    earned = lproto.double (2);

    -- The amount of Krist spent on fees.
    fees = lproto.double (3);

    -- The remaining balance immediately after order execution.
    balance = lproto.double (4);

    -- The amount of allocated items in the pool immediately after order
    -- execution.
    allocatedItems = lproto.uint53 (5);

    -- The amount of allocated Krist in the pool immediately after order
    -- execution.
    allocatedKrist = lproto.double (6);
}

-- A failed request response.
proto.FailureReason = lproto.message {
    -- A required parameter is missing.
    missingParameter = lproto.message {
        parameter = lproto.bytes (1);
    } (10);

    -- The account has no ender storage frequency associated with it. Or the
    -- associated frequency has changed mid-operation.
    noFrequency = lproto.message {} (11);

    -- The stored balance wasn't enough to execute a buy order.
    notEnoughFunds = lproto.message {
        balance = lproto.double (1);
        needed = lproto.double (2);
    } (1);

    -- The maxPerItem/minPerItem price limit has been exceeded.
    priceLimitExceeded = lproto.message {
        specified = lproto.double (2);
        actual = lproto.double (1);
    } (2);

    -- When buying and querying, the specified label didn't point to any pool.
    noSuchPoolLabel = lproto.message {
        label = lproto.bytes (1);
    } (3);

    -- When selling, the slot specified didn't match any pool.
    noSuchPoolItem = lproto.message {
        item = lproto.bytes (1);
        nbt = lproto.bytes (2);
    } (4);

    -- Your account has been deleted mid-transfer.
    noSuchAccount = lproto.message {} (12);

    -- When buying, the slot specified in the order wasn't empty.
    buySlotOccupied = lproto.message {
        slot = lproto.uint53 (1);
    } (5);

    -- When selling, the slot specified in the order was empty.
    sellSlotEmpty = lproto.message {
        slot = lproto.uint53 (1);
    } (6);

    -- When buying, the slot changed mid-operation, causing an unexpected race
    -- condition. THE BUY ORDER WAS STILL EXECUTED, but ITEMS MAY HAVE BEEN
    -- DESTROYED as a result.
    buyImproperRace = lproto.message {
        order = proto.BuyOrderExecution (1);
        dumped = lproto.uint53 (2);
        slot = lproto.uint53 (3);
    } (7);

    -- When selling, the slot changed mid-operation, causing an unexpected race
    -- condition. ITEMS MAY HAVE BEEN DESTROYED as a result.
    sellImproperRace = lproto.message {
        dumped = lproto.uint53 (1);
        slot = lproto.uint53 (2);
    } (8);
}

-- A response from the LP server to a client.
proto.Response = lproto.message {
    -- An ID matching the request's id field.
    id = lproto.uint53 (3);

    -- A request has been successful.
    success = lproto.message {
        -- Information about an item
        info = lproto.message {
            -- The item pool's label
            label = lproto.bytes (1);

            -- The item's id
            item = lproto.bytes (2);

            -- The item's NBT data hash, in hexadecimal, or nil if none
            nbt = lproto.bytes (3);

            -- The amount of allocated items in this pool
            allocatedItems = lproto.uint53 (4);

            -- The amount of allocated krist in this pool
            allocatedKrist = lproto.double (5);
        } (1);

        -- A buy order has succeeded.
        buy = proto.BuyOrderExecution (2);

        -- A sell order has succeeded.
        sell = proto.SellOrderExecution (3);
    } (1);

    -- A request has failed.
    failure = proto.FailureReason (2);
}

return proto
