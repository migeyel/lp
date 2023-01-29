-- An example program for how to use lppf.lua.

assert(shell, "example program must be run in shell")

if not fs.exists(shell.resolve("lppf.lua")) then
    local h = assert(http.get("https://p.sc3.io/api/v1/pastes/m8rRGqEttm/raw"))
    local s = h.readAll()
    h.close()

    local f = assert(fs.open(shell.resolve("lppf.lua"), "wb"))
    f.write(s)
    f.close()
end

local lppf = require "lppf"

parallel.waitForAll(
    lppf.listen,
    function()
        while true do
            local _, t = os.pullEvent("lppf_price_update")
            for _, item in ipairs(t.items) do
                print(item.item.displayName)
                local cur, price = lppf.getPrice(item, 10)
                if item.shopBuysItem then
                    print("\tSell 10:", price, cur)
                else
                    print("\tBuy 10:", price, cur)
                end
            end
        end
    end
)
