local mp = require("mp")

local is_pip = false
local saved = {fs = false, max = false, ontop = false, keepaspect = true, border = true,
               w = 1280, h = 720, x = 100, y = 100}
local saved_uosc_controls = nil

local PIP_GEOM = "30%-25-25"
local PIP_CONTROLS = "cycle:repeat:loop-file:no/inf!?Loop File,command:shuffle:playlist-shuffle?Shuffle Playlist,space,prev,<has_chapter>command:fast_rewind:add chapter -1?Prev Chapter,play-pause,<has_chapter>command:fast_forward:add chapter 1?Next Chapter,next,space,command:picture_in_picture_alt:script-message toggle-pip?PiP Mode,fullscreen"

local function set_uosc_controls(controls)
    local opts = mp.get_property_native("script-opts") or {}
    opts["uosc-controls"] = controls
    mp.set_property_native("script-opts", opts)
end

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
    set_uosc_controls(PIP_CONTROLS)
    is_pip = true
end

local function restore_window()
    mp.set_property("geometry", string.format("%dx%d+%d+%d", saved.w, saved.h, saved.x, saved.y))
    mp.set_property_native("keepaspect-window", saved.keepaspect)
    mp.set_property_native("border", saved.border)
    set_uosc_controls(saved_uosc_controls)
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
        saved_uosc_controls = (mp.get_property_native("script-opts") or {})["uosc-controls"]

        mp.set_property_native("border", false)
        mp.set_property("geometry", PIP_GEOM)

        if saved.fs or saved.max then
            mp.set_property_native("fullscreen", false)
            mp.set_property_native("window-maximized", false)
            mp.add_timeout(0.3, function()
                enter_pip()
                mp.add_timeout(0.2, show_osd)
            end)
        else
            enter_pip()
            mp.add_timeout(0.2, show_osd)
        end
    else
        is_pip = false
        mp.set_property_native("ontop", saved.ontop)

        if saved.fs or saved.max then
            if saved.max then mp.set_property_native("window-maximized", true) end
            if saved.fs then mp.set_property_native("fullscreen", true) end
            mp.add_timeout(0.3, function()
                restore_window()
                mp.add_timeout(0.2, show_osd)
            end)
        else
            restore_window()
            mp.add_timeout(0.2, show_osd)
        end
    end
end)

-- If the user manually double-clicks to fullscreen, exit PiP logically
mp.observe_property("fullscreen", "bool", function(name, value)
    if is_pip and value == true then
        is_pip = false
        mp.set_property_native("ontop", saved.ontop)
        set_uosc_controls(saved_uosc_controls)
        mp.set_property_native("keepaspect-window", saved.keepaspect)
        mp.set_property_native("border", saved.border)
    end
end)