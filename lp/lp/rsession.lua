local sessions = require "lp.sessions"
local threads = require "lp.threads"
local util = require "lp.util"
local pools = require "lp.pools"
local echest = require "lp.echest"
local proto = require "lp.proto"
local unetc = require "unet.client"
local log = require "lp.log"
local wallet = require "lp.wallet"

local UNET_TOKEN = "ace7a585-396f-407a-a0ea-55585a7b7805"
local UNET_CHANNEL = "lp"

---@param uss unetc.Session
---@param rch string
---@param uuid string
---@param m string
local function send(uss, rch, uuid, m)
    uss:send(uuid, rch, UNET_CHANNEL, m)
end

---@param uss unetc.Session
---@param id number?
---@param rch string
---@param uuid string
---@param parameter string
local function sendMissingParameter(uss, id, rch, uuid, parameter)
    return send(uss, rch, uuid, proto.Response.serialize {
        id = id,
        failure = {
            missingParameter = {
                parameter = parameter,
            },
        },
    })
end

---@param uss unetc.Session
---@param id number?
---@param rch string
---@param uuid string
---@param info ProtoRequestInfo
local function handleInfo(uss, id, rch, uuid, info)
    if not info.label then
        return sendMissingParameter(uss, id, rch, uuid, "label")
    end

    local pool = pools.getByTag(info.label)
    if not pool then
        return send(uss, rch, uuid, proto.Response.serialize {
            id = id,
            failure = {
                noSuchPoolLabel = {
                    label = info.label,
                },
            },
        })
    end

    return send(uss, rch, uuid, proto.Response.serialize {
        id = id,
        success = {
            info = {
                label = pool.label,
                item = pool.item,
                nbt = pool.nbt ~= "NONE" and pool.nbt or nil,
                allocatedItems = pool.allocatedItems,
                allocatedKrist = pool.allocatedKrist,
                feeRate = pool:getFeeRate(),
            }
        }
    })
end

---@param uss unetc.Session
---@param id number
---@param rch string
---@param uuid string
---@param buy ProtoRequestBuy
local function handleBuy(uss, id, rch, uuid, buy)
    if not buy.label then
        return sendMissingParameter(uss, id, rch, uuid, "label")
    end

    if not buy.slot then
        return sendMissingParameter(uss, id, rch, uuid, "slot")
    end

    if not buy.amount then
        return sendMissingParameter(uss, id, rch, uuid, "amount")
    end

    if not buy.maxPerItem then
        return sendMissingParameter(uss, id, rch, uuid, "maxPerItem")
    end

    local account = sessions.getAcctByUuid(uuid)
    if not account then
        return send(uss, rch, uuid, proto.Response.serialize {
            id = id,
            failure = {
                noSuchAccount = {},
            },
        })
    end

    local freq = account.storageFrequency
    if not freq then
        return send(uss, rch, uuid, proto.Response.serialize {
            id = id,
            failure = {
                noFrequency = {},
            }
        })
    end

    local pool = pools.getByTag(buy.label)
    if not pool then
        return send(uss, rch, uuid, proto.Response.serialize {
            id = id,
            failure = {
                noSuchPoolLabel = {
                    label = buy.label,
                },
            },
        })
    end

    local poolId = pool:id()
    local buyPriceNoFee = pool:buyPrice(buy.amount)
    local buyFee = pool:buyFee(buy.amount)
    local buyPriceWithFee = util.mCeil(buyPriceNoFee + buyFee)
    if buyPriceWithFee > account.balance then
        return send(uss, rch, uuid, proto.Response.serialize {
            id = id,
            failure = {
                notEnoughFunds = {
                    balance = account.balance,
                    needed = buyPriceWithFee,
                }
            }
        })
    end

    if buyPriceWithFee / buy.amount > buy.maxPerItem then
        return send(uss, rch, uuid, proto.Response.serialize {
            id = id,
            failure = {
                priceLimitExceeded = {
                    specified = buy.maxPerItem,
                    actual = buyPriceWithFee / buy.amount,
                }
            }
        })
    end

    local pushTransfer = echest.preparePush(
        account.storageFrequency,
        pool.item,
        pool.nbt,
        buy.amount,
        buy.slot
    )

    if pushTransfer == "NONEMPTY" then
        return send(uss, rch, uuid, proto.Response.serialize {
            failure = {
                buySlotOccupied = {
                    slot = buy.slot,
                },
            },
        })
    end

    -- preparePush() yields, so the account may have been deleted in the
    -- meantime by another thread. Check that it hasn't.
    account = sessions.getAcctByUuid(uuid)
    if not account then
        pushTransfer.rollback() --[[yield]] account, pool = nil, nil
        return send(uss, rch, uuid, proto.Response.serialize {
            id = id,
            failure = {
                noSuchAccount = {},
            },
        })
    end

    -- Check that the frequency hasn't changed.
    if freq ~= account.storageFrequency then
        pushTransfer.rollback() --[[yield]] account, pool = nil, nil
        return send(uss, rch, uuid, proto.Response.serialize {
            id = id,
            failure = {
                noFrequency = {},
            },
        })
    end

    -- preparePush() yields, so the pool may have been deleted in the
    -- meantime by another thread. Check that it hasn't.
    -- Note that the pool id is equivalent only for the same item and NBT.
    -- So it isn't possible for the pool to have changed its item/nbt value
    -- between yields without ceasing to exist from our perspective.
    pool = pools.get(poolId)
    if not pool then
        pushTransfer.rollback() --[[yield]] account, pool = nil, nil
        return send(uss, rch, uuid, proto.Response.serialize {
            id = id,
            failure = {
                noSuchPoolLabel = {
                    label = buy.label,
                },
            },
        })
    end

    -- Redo balance calculations for post-yield values.
    buyPriceNoFee = pool:buyPrice(pushTransfer.amount)
    buyFee = pool:buyFee(pushTransfer.amount)
    buyPriceWithFee = util.mCeil(buyPriceNoFee + buyFee)
    if buyPriceWithFee > account.balance then
        local balance = account.balance
        pushTransfer.rollback() --[[yield]] account, pool = nil, nil
        return send(uss, rch, uuid, proto.Response.serialize {
            id = id,
            failure = {
                notEnoughFunds = {
                    balance = balance,
                    needed = buyPriceWithFee,
                }
            }
        })
    end

    if buyPriceWithFee / buy.amount > buy.maxPerItem then
        return send(uss, rch, uuid, proto.Response.serialize {
            id = id,
            failure = {
                priceLimitExceeded = {
                    specified = buy.maxPerItem,
                    actual = buyPriceWithFee / buy.amount,
                }
            }
        })
    end

    -- Execute the transaction.
    account:transfer(-buyPriceWithFee, false)
    pool:reallocItems(-pushTransfer.amount, false)
    pool:reallocKst(buyPriceNoFee, false)
    wallet.reallocateFee(buyFee, false)

    local orderExecution = {
        amount = pushTransfer.amount,
        spent = buyPriceWithFee,
        fees = buyFee,
        balance = account.balance,
        allocatedItems = pool.allocatedItems,
        allocatedKrist = pool.allocatedKrist,
    }

    local dumpAmt = pushTransfer.commit(sessions.state, pools.state, wallet.state) --[[yield]] account, pool = nil, nil
    send(uss, rch, uuid, proto.Response.serialize {
        id = id,
        success = dumpAmt == 0 and {
            buy = orderExecution,
        } or nil,
        failure = dumpAmt ~= 0 and {
            buyImproperRace = {
                order = orderExecution,
                dumped = dumpAmt,
                slot = buy.slot,
            },
        } or nil,
    })

    sessions.buyEvent.queue()
end

---@param uss unetc.Session
---@param id number
---@param rch string
---@param uuid string
---@param sell ProtoRequestSell
local function handleSell(uss, id, rch, uuid, sell)
    if not sell.slot then
        return sendMissingParameter(uss, id, rch, uuid, "slot")
    end

    if not sell.minPerItem then
        return sendMissingParameter(uss, id, rch, uuid, "minPerItem")
    end

    local account = sessions.getAcctByUuid(uuid)
    if not account then
        return send(uss, rch, uuid, proto.Response.serialize {
            id = id,
            failure = {
                noSuchAccount = {},
            },
        })
    end

    local freq = account.storageFrequency
    if not freq then
        return send(uss, rch, uuid, proto.Response.serialize {
            id = id,
            failure = {
                noFrequency = {},
            }
        })
    end

    local ok, detail = echest.getItemDetail(freq, sell.slot) --[[yield]] account = nil
    if not ok or not detail then
        return send(uss, rch, uuid, proto.Response.serialize {
            id = id,
            failure = {
                sellSlotEmpty = {
                    slot = sell.slot,
                },
            },
        })
    end

    local item, nbt = detail.name, detail.nbt or "NONE"
    local poolId = item .. "~" .. nbt
    local pool = pools.get(poolId)
    if not pool then
        return send(uss, rch, uuid, proto.Response.serialize {
            id = id,
            failure = {
                noSuchPoolItem = {
                    item = item,
                    nbt = nbt ~= "NONE" and nbt or nil,
                },
            },
        })
    end

    local sellPriceNoFee = pool:sellPrice(detail.count)
    local sellFee = pool:sellFee(detail.count)
    local sellPriceWithFee = util.mFloor(sellPriceNoFee - sellFee)
    if sellPriceWithFee / detail.count < sell.minPerItem then
        return send(uss, rch, uuid, proto.Response.serialize {
            id = id,
            failure = {
                priceLimitExceeded = {
                    specified = sell.minPerItem,
                    actual = sellPriceWithFee / detail.count,
                }
            }
        })
    end

    local pullTransfer = echest.preparePull(
        freq,
        sell.slot,
        pool.item,
        pool.nbt
    ) --[[yield]] account, pool = nil, nil

    if type(pullTransfer) == "number" then
        return send(uss, rch, uuid, proto.Response.serialize {
            id = id,
            failure = {
                sellImproperRace = {
                    dumped = pullTransfer,
                    slot = sell.slot,
                },
            },
        })
    end

    -- preparePull() yields, so the account may have been deleted in the
    -- meantime by another thread. Check that it hasn't.
    account = sessions.getAcctByUuid(uuid)
    if not account then
        local dumpAmt = pullTransfer.rollback() --[[yield]] account, pool = nil, nil
        return send(uss, rch, uuid, proto.Response.serialize {
            id = id,
            failure = {
                noSuchAccount = dumpAmt == 0 and {} or nil,
                sellImproperRace = dumpAmt ~= 0 and {
                    dumped = dumpAmt,
                    slot = sell.slot,
                } or nil,
            },
        })
    end

    -- Check that the frequency hasn't changed.
    if freq ~= account.storageFrequency then
        local dumpAmt = pullTransfer.rollback() --[[yield]] account, pool = nil, nil
        return send(uss, rch, uuid, proto.Response.serialize {
            id = id,
            failure = {
                noFrequency = dumpAmt == 0 and {} or nil,
                sellImproperRace = dumpAmt ~= 0 and {
                    dumped = dumpAmt,
                    slot = sell.slot,
                } or nil,
            }
        })
    end

    -- preparePull() yields, so the pool may have been deleted in the
    -- meantime by another thread. Check that it hasn't.
    -- Note that the pool id is equivalent only for the same item and NBT.
    -- So it isn't possible for the pool to have changed its item/nbt value
    -- between yields without ceasing to exist from our perspective.
    pool = pools.get(poolId)
    if not pool then
        local dumpAmt = pullTransfer.rollback() --[[yield]] account, pool = nil, nil
        return send(uss, rch, uuid, proto.Response.serialize {
            id = id,
            failure = {
                noSuchPoolItem = dumpAmt == 0 and {
                    item = detail.name,
                    nbt = detail.nbt ~= "NONE" and detail.nbt or nil,
                } or nil,
                sellImproperRace = dumpAmt ~= 0 and {
                    dumped = dumpAmt,
                    slot = sell.slot,
                } or nil,
            },
        })
    end

    -- Redo limit calculations for post-yield values.
    sellPriceNoFee = pool:sellPrice(pullTransfer.amount)
    sellFee = pool:sellFee(pullTransfer.amount)
    sellPriceWithFee = util.mFloor(sellPriceNoFee - sellFee)
    if sellPriceWithFee / detail.count < sell.minPerItem then
        local dumpAmt = pullTransfer.rollback() --[[yield]] account, pool = nil, nil
        return send(uss, rch, uuid, proto.Response.serialize {
            id = id,
            failure = {
                priceLimitExceeded = dumpAmt == 0 and {
                    specified = sell.minPerItem,
                    actual = sellPriceWithFee / detail.count,
                } or nil,
                sellImproperRace = dumpAmt ~= 0 and {
                    dumped = dumpAmt,
                    slot = sell.slot,
                } or nil,
            },
        })
    end

    account:transfer(sellPriceWithFee, false)
    pool:reallocItems(pullTransfer.amount, false)
    pool:reallocKst(-sellPriceNoFee, false)
    wallet.reallocateFee(sellFee, false)

    local response = proto.Response.serialize {
        id = id,
        success = {
            sell = {
                amount = pullTransfer.amount,
                earned = sellPriceWithFee,
                fees = sellFee,
                balance = account.balance,
                allocatedItems = pool.allocatedItems,
                allocatedKrist = pool.allocatedKrist,
            },
        },
    }

    pullTransfer.commit(sessions.state, pools.state, wallet.state) --[[yield]] account, pool = nil, nil

    send(uss, rch, uuid, response)

    sessions.sellEvent.queue()
end

---@param uss unetc.Session
---@param id number
---@param rch string
---@param uuid string
local function handleAccount(uss, id, rch, uuid)
    local account = sessions.getAcctByUuid(uuid)
    if not account then
        return send(uss, rch, uuid, proto.Response.serialize {
            id = id,
            failure = {
                noSuchAccount = {},
            },
        })
    end

    return send(uss, rch, uuid, proto.Response.serialize {
        id = id,
        success = {
            account = {
                balance = account.balance,
            },
        },
    })
end

---@param uss unetc.Session
---@param rch string
---@param uuid string
---@param m string
local function handleValidMessage(uss, rch, uuid, m)
    local ok, root = pcall(proto.Request.deserialize, m)
    if not ok then return end

    root = root ---@type ProtoRequest

    if root.info then
        return handleInfo(uss, root.id, rch, uuid, root.info)
    elseif root.buy then
        return handleBuy(uss, root.id, rch, uuid, root.buy)
    elseif root.sell then
        return handleSell(uss, root.id, rch, uuid, root.sell)
    elseif root.account then
        return handleAccount(uss, root.id, rch, uuid)
    end
end

local function handleUnetSession()
    local uss = unetc.connect(UNET_TOKEN, nil, 10)
    if not uss then return end
    uss:open(UNET_CHANNEL)
    while true do
        local e, sid, uuid, _, rch, m = os.pullEvent()
        if e == "unet_closed" and sid == uss:id() then return end
        if e == "unet_message" and sid == uss:id() then
            local ok, err = pcall(handleValidMessage, uss, rch, uuid, m)
            if not ok then log:error(err) end
        end
    end
end

threads.register(function()
    while true do
        handleUnetSession()
        log:error("unet session was closed")
    end
end)
