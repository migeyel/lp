Options:Default "trace"

Tasks:clean()

Tasks:minify "unetcbundle:minify" {
    input = "build/unetcbundle.lua",
    output = "build/unetcbundle.min.lua",
}

Tasks:require "unetcbundle:main" {
    output = "build/unetcbundle.lua",
    startup = "unetcbundle.lua",
    include = {
        "unetcbundle.lua",
        "lproto.lua",
        "redrun.lua",
        "unet/common/*.lua",
        "unet/client/*.lua",
        "ccryptolib/*.lua",
    },
}

Tasks:Task "unetcbundle:build" {
    "clean",
    "unetcbundle:minify",
} :Description "unetcbundle build task"
