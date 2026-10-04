local mp = require("mp")

local is_pip = false
local saved = {
    fs = false, max = false, ontop = false, keepaspect = true, border = true,
    w = 1280, h = 720, x = 100, y = 100
}

local PIP_GEOM = "30%-25-25"

local function hide_osd()
    mp.commandv("script-message", "modernx-hide")
end

local function show_osd()
    mp.commandv("script-message", "modernx-show")
end

local function enter_pip()
    mp.set_property_native("border", false)
    mp.set_property_native("keepaspect-window", true)
    mp.set_property("geometry", PIP_GEOM)
    mp.set_property_native("ontop", true)
    is_pip = true
end

local function restore_window()
    mp.set_property("geometry", string.format("%dx%d+%d+%d", saved.w, saved.h, saved.x, saved.y))
    mp.set_property_native("keepaspect-window", saved.keepaspect)
    mp.set_property_native("border", saved.border)
end

mp.register_script_message("toggle-pip", function()
    hide_osd()

    if not is_pip then
        saved.fs = mp.get_property_native("fullscreen")
        saved.max = mp.get_property_native("window-maximized")
        saved.ontop = mp.get_property_native("ontop")
        saved.w = mp.get_property_number("osd-width") or 1280
        saved.h = mp.get_property_number("osd-height") or 720
        saved.x = mp.get_property_number("window-pos/x") or 0
        saved.y = mp.get_property_number("window-pos/y") or 0
        
        saved.keepaspect = mp.get_property_native("keepaspect-window")
        if saved.keepaspect == nil then saved.keepaspect = true end
        
        saved.border = mp.get_property_native("border")
        if saved.border == nil then saved.border = true end

        -- Setting geometry before exiting fullscreen allows the OS to animate smoothly
        mp.set_property_native("border", false)
        mp.set_property("geometry", PIP_GEOM)

        if saved.fs or saved.max then
            mp.set_property_native("fullscreen", false)
            mp.set_property_native("window-maximized", false)
        end
        
        enter_pip()
        show_osd()
    else
        is_pip = false
        mp.set_property_native("ontop", saved.ontop)

        if saved.fs or saved.max then
            if saved.max then mp.set_property_native("window-maximized", true) end
            if saved.fs then mp.set_property_native("fullscreen", true) end
        end
        
        restore_window()
        show_osd()
    end
end)

-- If the user manually double-clicks to fullscreen, exit PiP logically
mp.observe_property("fullscreen", "bool", function(name, value)
    if is_pip and value == true then
        is_pip = false
        mp.set_property_native("ontop", saved.ontop)
        mp.set_property_native("keepaspect-window", saved.keepaspect)
        mp.set_property_native("border", saved.border)
    end
end)