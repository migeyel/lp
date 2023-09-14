local pools = require "lp.pools"
local threads = require "lp.threads"

local MEAN_DRIP_SECONDS = 60

threads.register(function()
    while true do
        sleep(math.random(0, 2 * MEAN_DRIP_SECONDS))
        for id, pool in pools.pools() do
            if pool.drip then
                pool:tickDrip(false)
                pools.priceChangeEvent.queue(id)
            end
        end
        pools.state.commit()
    end
end)
