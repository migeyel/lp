local ldir = fs.getDir(select(2, ...))

local t = {}

function t.basalt()
    print("Fetch basalt")
    local h = http.get("https://basalt.madefor.cc/install.lua")
    local s = h.readAll()
    h.close()
    local fn, e = load(s)
    if fn then
        return fn, fs.combine(ldir, "basalt/init.lua")
    else
        return nil, e
    end
end

local function mkUrlLoader(filename, url)
    local path = fs.combine(ldir, filename)
    return function()
        if not fs.exists(path) then
            print("Fetch " .. filename)
            local h = http.get(url)
            local f = fs.open(path, "wb")
            f.write(h.readAll())
            f.close()
            h.close()
        end
        local fn, e = loadfile(path, nil, _ENV)
        if fn then return fn, path else return nil, e end
    end
end

t.k = mkUrlLoader(
    "k.lua",
    "https://github.com/tmpim/k.lua/raw/master/k.lua"
)

t.r = mkUrlLoader(
    "r.lua",
    "https://github.com/tmpim/r.lua/raw/master/r.lua"
)

t.w = mkUrlLoader(
    "w.lua",
    "https://github.com/tmpim/w.lua/raw/master/w.lua"
)

t.jua = mkUrlLoader(
    "jua.lua",
    "https://github.com/tmpim/jua/raw/master/jua.lua"
)

t.abstractInvLib = mkUrlLoader(
    "abstractInvLib.lua",
    "https://gist.githubusercontent.com/MasonGulu/57ef0f52a93304a17a9eaea21f431de6/raw/e604740f9c05140d239901d87c1a43cdc8d16000/abstractInvLib.lua"
)

t.logging = mkUrlLoader(
    "logging.lua",
    "https://gist.githubusercontent.com/Ale32bit/df1d9d455b0b82702308099ba4ea2e0d/raw/74f63f322e207adf26f42b8f0a13227c72f8d248/logger.lua"
)

package.loaders[#package.loaders + 1] = function(name)
    if t[name] then
        return t[name]()
    else
        return nil, "no field " .. name
    end
end
