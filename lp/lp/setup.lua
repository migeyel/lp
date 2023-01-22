local state = require "lp.state".open "lp.config"
local log = require "lp.log"
local k = require "k"

if state.pkey then
    log:info("Address: " .. k.makev2address(state.pkey))
else
    print("\n- Private Key")
    print("The main wallet private key holds all of the shop's Krist.")
    print("It MUST be used exclusively by the shop. Transacting with it " ..
          "will cause an emergency lockdown.")
    repeat
        write("Main wallet pkey: ")
        state.pkey = read()
        print("Address:", k.makev2address(state.pkey))
        write("Is this correct? [yN] ")
    until read():lower() == "y"
end

state.name = state.name or false

state.commit()

return state
