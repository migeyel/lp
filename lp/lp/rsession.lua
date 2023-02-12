local sessions = require "lp.sessions"
local threads = require "lp.threads"
local log = require "lp.log"
local util = require "lp.util"
local pools = require "lp.pools"
local echest = require "lp.echest"
local chapoly = require "chapoly"
local proto = require "lp.proto"
local sha256 = require "sha256"
local chaskey = require "chaskey"

local LISTEN_CHANNEL = 19260
local startupTime = os.epoch("utc")

local modem = nil
for _, v in ipairs { peripheral.find("modem") } do
    if v.isWireless() then
        modem = v
        modem.open(19260)
        break
    end
end

assert(modem, "wireless modem not found")

---@type table<string, RSListener?>
local listeners = {}

---@type table<Account, string?>
local acctListeners = {}

---@class RSListener
---@field serverPrefix string
---@field clientPrefix string
---@field serverMac function
---@field clientMac function
---@field serverDataKey string
---@field clientDataKey string
---@field lastTimestamp number
---@field username string
local RSListener = {}

---@param key string
---@return string prefix, function mac, string dataKey
local function deriveKeys(key)
    local nonce = ("\0"):rep(12)
    local message = ("\0"):rep(16 + 16 + 32)
    local expanded = chapoly.crypt(key, nonce, message)
    local prefix, tagKey, dataKey = ("c16c16c32"):unpack(expanded) --[[@as string]]
    local mac = chaskey(tagKey)
    return prefix, mac, dataKey
end

---@param account Account
---@return RSListener?
local function makeListener(account)
    local token = account.remoteToken
    if not token then return end
    local masterKey = sha256(token)
    local nonce = ("\0"):rep(12)
    local message = ("\0"):rep(64)
    local expandedMk = chapoly.crypt(masterKey, nonce, message)
    local serverSubKey, clientSubKey = ("c32c32"):unpack(expandedMk) --[[@as string]]

    local out = {} ---@type RSListener
    out.serverPrefix, out.serverMac, out.serverDataKey = deriveKeys(serverSubKey)
    out.clientPrefix, out.clientMac, out.clientDataKey = deriveKeys(clientSubKey)
    out.lastTimestamp = startupTime
    out.username = account.username
    return setmetatable(out, { __index = RSListener })
end

for _, account in sessions.accounts() do
    local listener = makeListener(account)
    if listener then
        listeners[listener.serverPrefix] = listener
        acctListeners[account] = listener.serverPrefix
    end
end

--- Switches the listener in an account after a token update.
--- Note that the old listener may still be held by other threads until they
--- reply to their messages and drop their references.
---@param account Account
local function updateListener(account)
    local oldPrefix = acctListeners[account]
    if oldPrefix then
        listeners[oldPrefix] = nil
    end

    local newListener = makeListener(account)
    if newListener then
        listeners[newListener.serverPrefix] = newListener
        acctListeners[account] = newListener.serverPrefix
    else
        acctListeners[account] = nil
    end
end

---@param input string
---@param len number
---@return string
local function pad(input, len)
    return input .. "\x80" .. ("\0"):rep(len - #input - 1)
end

---@param input string
---@return string
local function unpad(input)
    for i = -1, -#input, -1 do
        if input:byte(i) == 0x80 then
            return input:sub(1, i - 1)
        end
    end
    return ""
end

---@param rch number
---@param listener RSListener
---@param m string
local function send(rch, listener, m)
    local timestamp = ("<I8"):pack(os.epoch("utc"))
    local timestampTag = listener.clientMac(timestamp)
    local nonce = util.randomBytes(12)
    local ctx, dataTag = chapoly.encrypt(
        listener.clientDataKey,
        nonce,
        pad(m, 0),
        "",
        8
    )

    local packet = ("c16c8c16c12c16"):pack(
        listener.clientPrefix,
        timestamp,
        timestampTag,
        nonce,
        dataTag
    ) .. ctx

    modem.transmit(rch, LISTEN_CHANNEL, packet)
end

---@param id number
---@param rch number
---@param listener RSListener
---@param parameter string
local function sendMissingParameter(id, rch, listener, parameter)
    return send(rch, listener, proto.Response.serialize {
        id = id,
        failure = {
            missingParameter = {
                parameter = parameter,
            },
        },
    })
end

---@param id number?
---@param rch number
---@param listener RSListener
---@param info ProtoRequestInfo
local function handleInfo(id, rch, listener, info)
    if not info.label then
        return sendMissingParameter(id, rch, listener, "label")
    end

    local pool = pools.getByTag(info.label)
    if not pool then
        return send(rch, listener, proto.Response.serialize {
            id = id,
            failure = {
                noSuchPoolLabel = {
                    label = info.label,
                },
            },
        })
    end

    return send(rch, listener, proto.Response.serialize {
        id = id,
        success = {
            info = {
                label = pool.label,
                item = pool.item,
                nbt = pool.nbt ~= "NONE" and pool.nbt or nil,
                allocatedItems = pool.allocatedItems,
                allocatedKrist = pool.allocatedKrist,
            }
        }
    })
end

---@param id number
---@param rch number
---@param listener RSListener
---@param buy ProtoRequestBuy
local function handleBuy(id, rch, listener, buy)
    if not buy.label then
        return sendMissingParameter(id, rch, listener, "label")
    end

    if not buy.slot then
        return sendMissingParameter(id, rch, listener, "slot")
    end

    if not buy.amount then
        return sendMissingParameter(id, rch, listener, "amount")
    end

    if not buy.maxPerItem then
        return sendMissingParameter(id, rch, listener, "maxPerItem")
    end

    local account = sessions.getAcct(listener.username)
    if not account then
        return send(rch, listener, proto.Response.serialize {
            id = id,
            failure = {
                noSuchAccount = {},
            },
        })
    end

    local freq = account.storageFrequency
    if not freq then
        return send(rch, listener, proto.Response.serialize {
            id = id,
            failure = {
                noFrequency = {},
            }
        })
    end

    local pool = pools.getByTag(buy.label)
    if not pool then
        return send(rch, listener, proto.Response.serialize {
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
        return send(rch, listener, proto.Response.serialize {
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
        return send(rch, listener, proto.Response.serialize {
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
        return send(rch, listener, proto.Response.serialize {
            failure = {
                buySlotOccupied = {
                    slot = buy.slot,
                },
            },
        })
    end

    -- preparePush() yields, so the account may have been deleted in the
    -- meantime by another thread. Check that it hasn't.
    account = sessions.getAcct(listener.username)
    if not account then
        pushTransfer.rollback() --[[yield]] account, pool = nil, nil
        return send(rch, listener, proto.Response.serialize {
            id = id,
            failure = {
                noSuchAccount = {},
            },
        })
    end

    -- Check that the frequency hasn't changed.
    if freq ~= account.storageFrequency then
        pushTransfer.rollback() --[[yield]] account, pool = nil, nil
        return send(rch, listener, proto.Response.serialize {
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
        return send(rch, listener, proto.Response.serialize {
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
        return send(rch, listener, proto.Response.serialize {
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
        return send(rch, listener, proto.Response.serialize {
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
    pool:reallocKst(buyPriceWithFee, false) -- Auto-realloc

    local orderExecution = {
        amount = pushTransfer.amount,
        spent = buyPriceWithFee,
        fees = buyFee,
        balance = account.balance,
        allocatedItems = pool.allocatedItems,
        allocatedKrist = pool.allocatedKrist,
    }

    local ok, dumpAmt = pushTransfer.commit(sessions.state, pools.state) --[[yield]] account, pool = nil, nil

    if ok then
        send(rch, listener, proto.Response.serialize {
            id = id,
            success = {
                buy = orderExecution,
            },
        })
    else
        send(rch, listener, proto.Response.serialize {
            id = id,
            failure = {
                buyTransferBlocked = {
                    order = orderExecution,
                },
                blockedPull = {
                    originalSlot = buy.slot,
                    destroyedAmount = dumpAmt,
                },
            },
        })
    end

    sessions.buyEvent.queue()
end

---@param id number
---@param rch number
---@param listener RSListener
---@param sell ProtoRequestSell
local function handleSell(id, rch, listener, sell)
    if not sell.slot then
        return sendMissingParameter(id, rch, listener, "slot")
    end

    if not sell.minPerItem then
        return sendMissingParameter(id, rch, listener, "minPerItem")
    end

    local account = sessions.getAcct(listener.username)
    if not account then
        return send(rch, listener, proto.Response.serialize {
            id = id,
            failure = {
                noSuchAccount = {},
            },
        })
    end

    local freq = account.storageFrequency
    if not freq then
        return send(rch, listener, proto.Response.serialize {
            id = id,
            failure = {
                noFrequency = {},
            }
        })
    end

    local detail = echest.getItemDetail(freq, sell.slot) --[[yield]] account = nil
    if not detail then
        return send(rch, listener, proto.Response.serialize {
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
        return send(rch, listener, proto.Response.serialize {
            id = id,
            failure = {
                noSuchPoolItem = {
                    item = item,
                    nbt = nbt,
                },
            },
        })
    end

    local sellPriceNoFee = pool:sellPrice(detail.count)
    local sellFee = pool:sellFee(detail.count)
    local sellPriceWithFee = util.mFloor(sellPriceNoFee - sellFee)
    if sellPriceWithFee / detail.count < sell.minPerItem then
        return send(rch, listener, proto.Response.serialize {
            id = id,
            failure = {
                priceLimitExceeded = {
                    specified = sell.minPerItem,
                    actual = sellPriceWithFee / detail.count,
                }
            }
        })
    end

    local status, pullTransfer = echest.preparePull(
        freq,
        sell.slot,
        pool.item,
        pool.nbt
    ) --[[yield]] account, pool = nil, nil

    if status ~= "OK" then
        return send(rch, listener, proto.Response.serialize {
            id = id,
            failure = {
                sellTransferMismatch = {
                    expectedItem = detail.name,
                    expectedNbt = detail.nbt,
                },
                blockedPull = status == "MISMATCH_BLOCKED" and {
                    originalSlot = sell.slot,
                    destroyedAmount = pullTransfer --[[@as number]],
                } or nil,
            },
        })
    end

    -- Status is "OK" so pullTransfer is a table.
    pullTransfer = pullTransfer --[[@as table]]

    -- preparePull() yields, so the account may have been deleted in the
    -- meantime by another thread. Check that it hasn't.
    account = sessions.getAcct(listener.username)
    if not account then
        local ok, dumpAmt = pullTransfer.rollback() --[[yield]] account, pool = nil, nil
        return send(rch, listener, proto.Response.serialize {
            id = id,
            failure = {
                noSuchAccount = {},
                blockedPull = not ok and {
                    originalSlot = sell.slot,
                    destroyedAmount = dumpAmt,
                } or nil,
            },
        })
    end

    -- Check that the frequency hasn't changed.
    if freq ~= account.storageFrequency then
        local ok, dumpAmt = pullTransfer.rollback() --[[yield]] account, pool = nil, nil
        return send(rch, listener, proto.Response.serialize {
            id = id,
            failure = {
                noFrequency = {},
                blockedPull = not ok and {
                    originalSlot = sell.slot,
                    destroyedAmount = dumpAmt,
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
        local ok, dumpAmt = pullTransfer.rollback() --[[yield]] account, pool = nil, nil
        return send(rch, listener, proto.Response.serialize {
            id = id,
            failure = {
                noSuchPoolItem = {
                    item = detail.name,
                    nbt = detail.nbt,
                },
                blockedPull = not ok and {
                    originalSlot = sell.slot,
                    destroyedAmount = dumpAmt,
                } or nil,
            },
        })
    end

    -- Redo limit calculations for post-yield values.
    sellPriceNoFee = pool:sellPrice(pullTransfer.amount)
    sellFee = pool:sellFee(pullTransfer.amount)
    sellPriceWithFee = util.mFloor(sellPriceNoFee - sellFee)
    if sellPriceWithFee / detail.count < sell.minPerItem then
        local ok, dumpAmt = pullTransfer.rollback() --[[yield]] account, pool = nil, nil
        return send(rch, listener, proto.Response.serialize {
            id = id,
            failure = {
                priceLimitExceeded = {
                    specified = sell.minPerItem,
                    actual = sellPriceWithFee / detail.count,
                },
                blockedPull = not ok and {
                    originalSlot = sell.slot,
                    destroyedAmount = dumpAmt,
                } or nil,
            },
        })
    end

    account:transfer(sellPriceWithFee, false)
    pool:reallocItems(pullTransfer.amount, false)
    pool:reallocKst(-sellPriceWithFee, false) -- Auto-realloc

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

    pullTransfer.commit(sessions.state, pools.state) --[[yield]] account, pool = nil, nil

    send(rch, listener, response)

    sessions.sellEvent.queue()
end

---@param rch number
---@param listener RSListener
---@param m string
local function handleValidMessage(rch, listener, m)
    local ok, root = pcall(proto.Request.deserialize, m)
    if not ok then return end

    root = root ---@type ProtoRequest

    if root.info then
        return handleInfo(root.id, rch, listener, root.info)
    elseif root.buy then
        return handleBuy(root.id, rch, listener, root.buy)
    elseif root.sell then
        return handleSell(root.id, rch, listener, root.sell)
    end
end

local function handleModemMessage(_, _, ch, rch, m)
    -- Basic checks
    if ch ~= LISTEN_CHANNEL then return end
    if type(m) ~= "string" then return end
    if #m < 16 + 8 + 16 + 12 + 16 then return end

    -- Check if listener exists
    local listener = listeners[m:sub(1, 16)]
    if not listener then return end

    -- Decode
    local timestamp, timestampTag, nonce, dataTag, ctxPos =
        ("c8c16c12c16"):unpack(m, 17)

    -- Check timestamp tag
    if timestampTag ~= listener.serverMac(timestamp) then return end

    -- Check timestamp
    timestamp = ("<I8"):unpack(timestamp)
    if timestamp <= listener.lastTimestamp then return end
    listener.lastTimestamp = timestamp

    log:info(("Received %d bytes from %s"):format(#m, listener.username))

    -- Decrypt
    local plaintext = chapoly.decrypt(
        listener.serverDataKey,
        nonce,
        dataTag,
        m:sub(ctxPos),
        "",
        8
    )

    if plaintext then
        return handleValidMessage(rch, listener, unpad(plaintext))
    end
end

threads.register(function()
    log:info("Remote session listener is up")
    while true do
        handleModemMessage(os.pullEvent("modem_message"))
    end
end)

return {
    updateListener = updateListener,
}
