local pblite = require "pblite"
local history = require "lp.history"

local function rect(cnv, x1, y1, x2, y2, color)
    local yl, yh
    if y1 < y2 then
        yl = y1
        yh = y2
    else
        yl = y2
        yh = y1
    end

    local xl, xh
    if x1 < x2 then
        xl = x1
        xh = x2
    else
        xl = x2
        xh = x1
    end

    for y = yl, yh do
        local row = cnv[y] or {}
        for x = xl, xh do
            row[x] = color
        end
    end
end

local function drawChart(cv, ch)
    local w = #cv[1]
    local h = #cv
    local min = 1 / 0
    local max = -1 / 0
    for i = 1, #ch do
        local _, _, low, high = table.unpack(ch[i])
        max = math.max(max, high)
        min = math.min(min, low)
    end

    local scale = h / (max - min)
    for i = #ch, 1, -1 do
        local open, close, low, high = table.unpack(ch[i])
        local mopen = math.floor(0.5 + scale * (open - min))
        local mclose = math.floor(0.5 + scale * (close - min))
        local mlow = math.floor(0.5 + scale * (low - min))
        local mhigh = math.floor(0.5 + scale * (high - min))
        local c = close >= open and colors.green or colors.red
        local x0 = 4 * i - 3 + w - 4 * #ch
        local x1 = x0 + 1
        local x2 = x1 + 1
        local y0 = h + 1 - mlow
        local y1 = h + 1 - mclose
        local y2 = h + 1 - mopen
        local y3 = h + 1 - mhigh
        rect(cv, x0, y1, x2, y2, c)
        rect(cv, x1, y0, x1, y3, c)
    end

    return min, max
end

local TIME_TICK_SPACING = 3

local function drawPoolChart(frame, poolId, stickInterval)
    local sframe = frame:addFrame()
        :setPosition(2, "parent.h")
        :setSize("parent.w - 7", 1)
        :setForeground(colors.black)
        :setBackground(colors.white)
    local swidth = sframe:getSize()

    local cframe = frame:addImage()
        :setPosition(2, 2)
        :setSize("parent.w - 7", "parent.h - 3")
    local cw, ch = cframe:getSize()

    local pframe = frame:addFrame()
        :setPosition("parent.w - 5", 2)
        :setSize(7, "parent.h - 3")
        :setBackground(colors.white)
    local pwidth, pheight = pframe:getSize()

    local prices = {}
    for j = 1, pheight, 2 do
        prices[j] = pframe:addLabel()
            :setPosition(1, j)
            :setForeground(colors.black)
            :setBackground(colors.white)
    end

    local function update(finish)
        local numSticks = math.floor(cframe:getSize() / 2)
        local start = finish - numSticks * stickInterval
        start = math.floor(start / stickInterval) * stickInterval

        local chart = {}
        for i = start, start + stickInterval * numSticks, stickInterval do
            chart[#chart + 1] = history.getCandlestick(poolId, i, i + stickInterval)
        end

        local prevDay = nil
        local tick = 0
        while tick < swidth do
            local tickMark = #("03:45") / 2 + tick
            local tickMs = start + tickMark * stickInterval * numSticks / swidth

            local str = nil
            if not prevDay or prevDay ~= os.date("*t", tickMs / 1000).day then
                tickMark = #("Jul 23 11:23") / 2 + tick
                tickMs = start + tickMark * stickInterval * numSticks / swidth
                str = os.date("%h %d %H:%M", tickMs / 1000) --[[@as string]]
                prevDay = os.date("*t", tickMs / 1000).day
            else
                str = os.date("%H:%M", tickMs / 1000) --[[@as string]]
            end

            if tick + #str + 1 < swidth then
                sframe:addLabel()
                    :setText(str)
                    :setPosition(tick + 1, 1)
                    :setForeground(colors.black)
                    :setBackground(colors.white)
            end

            tick = tick + #str + TIME_TICK_SPACING
        end

        local cv = pblite.new(cw, ch, colors.white)
        local min, max = drawChart(cv.CANVAS, chart)
        cframe:setImage(cv:render())

        for j = 1, pheight, 2 do
            local price = (pheight - 1 - j) * (max - min) / (pheight - 1) + min
            prices[j]:setText(tostring(price):sub(1, pwidth - 1))
        end
    end

    return update
end

return {
    drawPoolChart = drawPoolChart,
}
