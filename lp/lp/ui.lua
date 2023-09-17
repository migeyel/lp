local pools = require "lp.pools"
local sessions = require "lp.sessions"
local basalt = require "basalt"
local event = require "lp.event"
local threads = require "lp.threads"
local util= require "lp.util"
local graph  = require "lp.graph"
local history= require "lp.history"

local mon = peripheral.find("monitor")

local gray99 = colors.cyan
local redlite = colors.blue
local greenlite = colors.brown

mon.setPaletteColor(gray99, 200 / 255, 200 / 255, 200 / 255)
mon.setPaletteColor(redlite, 255 / 255, 175 / 255, 175 / 255)
mon.setPaletteColor(greenlite, 184 / 255, 255 / 255, 176 / 255)

local main = basalt.createFrame():setMonitor(peripheral.getName(mon), 0.5)

local MID_FRAME_SIZE = 34
local PRICE_WIDTH = 10
local AMOUNTS_TO_QUOTE_PRICES_AT = { 1, 8, 64, 512, 4096 }
local CANDLESTICK_MS = 3600000
local CHART_UPDATE_SECS = 30

local titleBar = main:addFrame("titleBar")
    :setSize("parent.w", 5)

titleBar:addLabel()
    :setText("PG231's Liquidity Pools")
    :setForeground(colors.white)
    :setBackground(colors.gray)
    :setFontSize(2)
    :setPosition("(parent.w - self.w) / 2", 2)

local topBar = main:addFrame("topBar")
    :setPosition(1, "titleBar.h + 1")
    :setSize("parent.w", 6)

local buyBar = topBar:addFrame("buyBar")
    :setBackground(colors.green)
    :setSize("parent.w / 2 - 1", "parent.h")

buyBar:addLabel()
    :setText("BUY")
    :setBackground(colors.green)
    :setForeground(colors.white)
    :setFontSize(2)
    :setPosition(
        "(parent.w - self.w) / 2",
        "parent.h / 2 - 1")

buyBar:addLabel()
    :setText("Use \\lp buy <item> <amount>")
    :setBackground(colors.green)
    :setForeground(colors.white)
    :setPosition(
        "(parent.w - self.w) / 2",
        "parent.h / 2 + 2")

local sellBar = topBar:addFrame()
    :setBackground(colors.red)
    :setSize("parent.w - buyBar.w", "parent.h")
    :setPosition("buyBar.w + 1")

sellBar:addLabel()
    :setText("SELL")
    :setBackground(colors.red)
    :setForeground(colors.white)
    :setFontSize(2)
    :setPosition(
        "parent.w / 2 - self.w / 2",
        "parent.h / 2 - 1")

sellBar:addLabel()
    :setText("Drop above the Turtle")
    :setBackground(colors.red)
    :setForeground(colors.white)
    :setPosition(
        "(parent.w - self.w) / 2",
        "parent.h / 2 + 2")

local bottomBar = main:addFrame("bottomBar")
    :setSize("parent.w", 4)
    :setPosition(1, "parent.h - self.h + 1")

local sectionStartBottomFrame = bottomBar:addFrame()

sectionStartBottomFrame:addLabel()
    :setText("Begin by using \\lp start")
    :setForeground(colors.white)
    :setBackground(colors.gray)
    :setPosition(2, 2)
    :setFontSize(2)

local sectionOngoingBottomFrame = bottomBar:addFrame()

local sectionOngoingBottomLabel = sectionOngoingBottomFrame:addLabel()
    :setForeground(colors.white)
    :setBackground(colors.gray)
    :setPosition(2, 2)
    :setFontSize(2)

local updateBottomBar = nil

sectionOngoingBottomFrame:addLabel("exitLabel")
    :setText("Exit with \\lp exit")
    :setForeground(colors.lightGray)
    :setBackground(colors.gray)
    :setPosition("parent.w - self.w - 1", 2)

local sessionAddressLabel = sectionOngoingBottomFrame:addLabel()
    :setText("Session")
    :setForeground(colors.white)
    :setBackground(colors.gray)
    :setPosition("exitLabel.x - self.w - 1", 2)
    :setSize(nil, 1)

sectionOngoingBottomFrame:addLabel("deposits")
    :setText("Deposit at lp.kst")
    :setForeground(colors.lightGray)
    :setBackground(colors.gray)
    :setPosition("parent.w - self.w - 1", 3)

function updateBottomBar()
    local session = sessions.get()
    if session then
        sectionOngoingBottomFrame:show()
        sectionStartBottomFrame:hide()
        sectionOngoingBottomLabel
            :setText(("Balance: \164%g"):format(session:balance()))
        sessionAddressLabel
            :setText(session:account().username)
            :setSize(#session:account().username, 1)
            :setPosition("exitLabel.x - self.w - 1", 2)
    else
        sectionStartBottomFrame:show()
        sectionOngoingBottomFrame:hide()
    end
end

updateBottomBar()

local listingFrames = {}

local function openListingFrame(index)
    if listingFrames[index] then
        for _, v in pairs(listingFrames)do v:hide() end
        listingFrames[index]:show()
    end
end

local menubar = main:addMenubar("menubar")
    :setPosition(1, "bottomBar.y - 1")
    :setSize("parent.w", 1)
    :setForeground(colors.white)
    :onChange(function(self) openListingFrame(self:getItemIndex()) end)
    :setSelectedItem(colors.white, colors.black)

local function addListingFrame(label)
    local listingFrame = main:addFrame()
        :setPosition(1, "header.y + header.h")
        :setSize("parent.w", "menubar.y - header.y + header.h - 2")
        :setBackground(colors.white)
        :hide()
    menubar:addItem(label)
    listingFrames[#listingFrames + 1] = listingFrame
    return listingFrame
end

local header = main:addFrame("header")
    :setPosition(1, "topBar.y + topBar.h")
    :setSize("parent.w", 1)
    :setBackground(colors.gray)

local headerMidframe = header:addFrame("headerMidframe")
    :setSize(MID_FRAME_SIZE, 1)
    :setPosition("(parent.w - self.w) / 2", 1)

headerMidframe:addLabel()
    :setText("Item")
    :setPosition("(parent.w - self.w) / 2 + 1")
    :setForeground(colors.white)

for i, amount in ipairs(AMOUNTS_TO_QUOTE_PRICES_AT) do
    local offset = i * PRICE_WIDTH - PRICE_WIDTH + 1
    header:addLabel()
        :setPosition("headerMidframe.x + headerMidframe.w + " .. offset, 1)
        :setText("\215" .. amount)
        :setForeground(colors.white)

    header:addLabel()
        :setPosition("headerMidframe.x - self.w - " .. offset, 1)
        :setText("\215" .. amount)
        :setForeground(colors.white)
end

local function listingPriceFg(p1, p2)
    if p1 > p2 then
        return colors.red
    elseif p1 < p2 then
        return colors.green
    else
        return colors.black
    end
end

local function listingPriceBg(p1, p2, index)
    if p1 > p2 then
        return redlite
    elseif p1 < p2 then
        return greenlite
    else
        if index % 2 == 0 then
            return colors.white
        else
            return gray99
        end
    end
end

local chart

local function rmChart()
    if chart then
        chart.obj:remove()
        chart.listing:setPosition(1, 2 * chart.index - 1)
        chart = nil
    end
end

---@param pool Pool
---@param index number
local function addListing(listingFrame, pool, index)
    local listing = listingFrame:addFrame()
        :setPosition(1, 2 * index - 1)
        :setSize("parent.w", 2)
        :setBackground(listingPriceBg(0, 0, index))

    local myChart

    local lsButton = listing:addButton()
        :setSize("parent.w", "parent.h")
        :setZIndex(0)
        :setBackground(listingPriceBg(0, 0, index))
        :onClick(function()
            if chart then return end
            rmChart()
            listing:setPosition(1, 1)
            local obj = listingFrame:addFrame()
                :setPosition(1, 3)
                :setSize("parent.w", "parent.h - 2")
                :setBackground(colors.white)
            chart = {
                obj = obj,
                index = index,
                listing = listing,
                update = graph.drawPoolChart(obj, pool:id(), CANDLESTICK_MS),
            }
            chart.update(os.epoch("utc"))
            myChart = chart
        end)

    local midframe = listing:addFrame("midframe")
        :setSize(MID_FRAME_SIZE, 2)
        :setBackground(listingPriceBg(0, 0, index))
        :setPosition("(parent.w - self.w) / 2", 1)

    midframe:addLabel()
        :setText(pool.label)
        :setForeground(colors.gray)
        :setPosition("(parent.w - self.w) / 2 + 1", 1)

    local priceLabel = midframe:addLabel()
        :setText(("\164%g"):format(pool:midPrice()))
        :setForeground(colors.black)
        :setPosition("(parent.w - self.w) / 2 + 1", 2)

    if #pool.label > MID_FRAME_SIZE then
        priceLabel:hide()
    end

    local updateListing = nil
    local quoteLabels = {}
    for i, amt in ipairs(AMOUNTS_TO_QUOTE_PRICES_AT) do
        local session = sessions.get()
        local buyPrice, sellPrice
        if session then
            buyPrice = session:buyPriceWithFee(pool, amt)
            sellPrice = session:sellPriceWithFee(pool, amt)
        else
            buyPrice = pool:buyPrice(amt) + pool:buyFee(amt)
            sellPrice = pool:sellPrice(amt) - pool:sellFee(amt)
        end

        local avgBuyPrice = util.mCeil(buyPrice / amt)
        local avgSellPrice = util.mFloor(sellPrice / amt)

        local offset = i * PRICE_WIDTH - PRICE_WIDTH + 1
        local sellLabel = listing:addLabel()
            :setPosition("midframe.x + midframe.w + " .. offset, 1)
            :setText(("\164%g"):format(sellPrice))
            :setForeground(listingPriceFg(0, 0))

        local avgSellLabel = listing:addLabel()
            :setPosition("midframe.x + midframe.w + " .. offset, 2)
            :setText(("\164%g/i"):format(avgSellPrice))
            :setForeground(listingPriceFg(0, 0))

        local buyLabel = listing:addLabel()
            :setPosition("midframe.x - self.w - " .. offset, 1)
            :setText(("\164%g"):format(buyPrice))

        local avgBuyLabel = listing:addLabel()
            :setPosition("midframe.x - self.w - " .. offset, 2)
            :setText(("\164%g/i"):format(avgBuyPrice))

        buyLabel:setForeground(listingPriceFg(0, 0))
        avgBuyLabel:setForeground(listingPriceFg(0, 0))

        quoteLabels[i] = {
            sell = sellLabel,
            avgSell = avgSellLabel,
            buy = buyLabel,
            avgBuy = avgBuyLabel
        }
    end

    local timer = nil
    local unroundedPrice = pool:midPriceUnrounded()

    function updateListing(secondIter)
        if chart and chart == myChart then chart.update(os.epoch("utc")) end

        local newUnroundedPrice = pool:midPriceUnrounded()

        local bg = listingPriceBg(unroundedPrice, newUnroundedPrice, index)
        listing:setBackground(bg)
        lsButton:setBackground(bg)
        midframe:setBackground(bg)

        local fg = listingPriceFg(unroundedPrice, newUnroundedPrice)
        priceLabel:setText(("\164%g"):format(pool:midPrice()))
            :setForeground(fg)

        for i, amt in ipairs(AMOUNTS_TO_QUOTE_PRICES_AT) do
            local session = sessions.get()
            local buyPrice, sellPrice
            if session then
                buyPrice = session:buyPriceWithFee(pool, amt)
                sellPrice = session:sellPriceWithFee(pool, amt)
            else
                buyPrice = pool:buyPrice(amt) + pool:buyFee(amt)
                sellPrice = pool:sellPrice(amt) - pool:sellFee(amt)
            end

            local avgBuyPrice = util.mCeil(buyPrice / amt)
            local avgSellPrice = util.mFloor(sellPrice / amt)

            quoteLabels[i].sell:setText(("\164%g"):format(sellPrice))
                :setForeground(fg)
            quoteLabels[i].avgSell:setText(("\164%g/i"):format(avgSellPrice))
                :setForeground(fg)
            quoteLabels[i].buy:setText(("\164%g"):format(buyPrice))
                :setForeground(fg)
            quoteLabels[i].avgBuy:setText(("\164%g/i"):format(avgBuyPrice))
                :setForeground(fg)
        end

        if not secondIter then
            if timer then timer:cancel() end
            timer = listing:addTimer()
                :setTime(0.5, 1)
                :onCall(function() updateListing(true) timer = nil end)
                :start()
        end

        unroundedPrice = newUnroundedPrice
    end

    return updateListing
end

local updateListings = {}

local categories = {}
for cat in pools.categories() do
    categories[#categories + 1] = cat
end
table.sort(categories)

for _, cat in ipairs(categories) do
    local ids = {}
    for id in pools.pools(cat) do
        ids[#ids + 1] = id
    end
    table.sort(ids)

    local lf = addListingFrame(cat)
    for i, id in ipairs(ids) do
        updateListings[id] = addListing(lf, assert(pools.get(id)), i)
    end
end

menubar:selectItem(1)
openListingFrame(1)

threads.register(function()
    while true do
        local e, id = event.pull()
        if e == sessions.startEvent or e == sessions.endEvent or e == sessions.sessionBalChangeEvent then
            updateBottomBar()
        elseif e == pools.priceChangeEvent then
            updateListings[id]()
        end
    end
end)

threads.register(function()
    while true do
        os.pullEvent("monitor_touch")
        if chart then
            sleep()
            rmChart()
        end
    end
end)

threads.register(function()
    while true do
        sleep(CHART_UPDATE_SECS)
        if chart then chart.update(os.epoch("utc")) end
    end
end)

threads.register(function()
    while true do
        local id = pools.priceChangeEvent.pull()
        local pool = assert(pools.get(id))
        history.addPriceEntry(pool:id(), {
            timestamp = os.epoch("utc"),
            items = pool.allocatedItems,
            mKst = pool.allocatedKrist * 1000,
        })
    end
end)

threads.register(basalt.autoUpdate)
