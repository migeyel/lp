Options:Default "trace"

Tasks:clean()

Tasks:minify "lpc:minify" {
    input = "build/lpc.lua",
    output = "build/lpc.min.lua",
}

Tasks:require "lpc:main" {
    output = "build/lpc.lua",
    startup = "lpc/lpc.lua",
    include = {
        "lpc/*.lua",
        "lproto.lua",
        "redrun.lua",
        "unet/common/*.lua",
        "unet/client/*.lua",
        "ccryptolib/*.lua",
    },
}

Tasks:Task "lpc:build" { "clean", "lpc:minify" } :Description "LPC build task"
