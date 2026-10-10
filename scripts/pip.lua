-- Picture-in-Picture for mpv (macOS)
--
-- alt+p (input.conf: `script-message toggle-pip`) moves the window into the
-- bottom-right corner, on top, without borders; toggling again restores the
-- window state that was active before.
--
-- macOS details this relies on:
--   * The fullscreen enter/exit animation glides towards the "unfullscreened"
--     window frame mpv stored when fullscreen was entered
--     (Window.unfsContentFrame -> calculateWindowPosition()). While the window is
--     still fullscreen, changing `geometry` only rewrites that stored frame, so
--     the exit animation can be aimed at the PiP corner *before* leaving
--     fullscreen. Writing the geometry after the exit has started would instead
--     cancel the animation and snap the window into place.
--   * That requires `force-window-position=yes` (mpv.conf). Without it, a runtime
--     geometry change applies the size only (since mpv commit 7466a9f9) and the
--     VO calls updateSize() instead of updateFrame().
--   * `macos-fs-animation-duration=0` (mpv.conf) keeps initial placement instant.
--     The script uses "default" for its PiP transition, then restores the value
--     that was configured before the script changed it.
local mp = require("mp")
local options = require("mp.options")
local configured_fs_animation_duration = mp.get_property_native("macos-fs-animation-duration")

-- Read mpv's effective --geometry option (from mpv.conf, a profile, or the
-- command line). If it is unset, use mpv's normal centred-window default.
-- This is intentionally NOT a script-opts setting.
local configured_geometry = mp.get_property("geometry")
local NORMAL_GEOM = (configured_geometry and configured_geometry ~= "")
    and configured_geometry or "50%:50%"

-- Script-specific options remain in ~/.config/mpv/script-opts/pip.conf.
local opts = {
    hide_ui = true, -- hide ModernX's UI while in PiP
}
options.read_options(opts, "pip")

local PIP_GEOM = "30%-25-25"   -- 30% of the screen wide, 25px from right/bottom
local HIDE_UI = opts.hide_ui

-- State
local is_pip                       = false  -- PiP is active
local entering_pip_from_fullscreen = false  -- PiP entered from fs, waiting for fs=false
local pip_cancelled_by_fullscreen  = false  -- fs session that was entered from PiP
local ui_hidden                    = false
local fs_animation_armed           = false
local saved_title                  = nil

-- Windowed state, tracked while not in PiP or fullscreen
local normal = {
    max          = false,
    ontop        = false,
    keepaspect   = true,
    border       = false,
    geometry     = "",
    geometry_is_fallback = false,
    window_scale = nil,
}

-- Snapshot taken when PiP is entered
local saved = {
    fs           = false,
    max          = false,
    ontop        = false,
    keepaspect   = true,
    border       = false,
    geometry     = "",
    geometry_is_fallback = false,
    window_scale = nil,
}

-- ===== Helpers ===========================================================

local function set_ui_hidden(hidden)
    if HIDE_UI and ui_hidden ~= hidden then
        ui_hidden = hidden
        mp.commandv("script-message", hidden and "modernx-hide" or "modernx-show")
    end
end

-- modernx derives its PiP button state and tooltip from title == "mpv-pip-mode".
local function set_pip_title(in_pip)
    if in_pip then
        saved_title = mp.get_property("title")
        mp.set_property("title", "mpv-pip-mode")
    else
        local title = saved_title
        if not title or title == "" then
            title = mp.get_property("media-title")
        end
        if title and title ~= "" then
            mp.set_property("title", title)
        end
        saved_title = nil
    end
end

local function set_fs_animation_default()
    mp.set_property_native("macos-fs-animation-duration", "default")
end

local function restore_fs_animation_duration()
    -- The property may be unavailable on unusual builds; default is the safe fallback.
    mp.set_property_native(
        "macos-fs-animation-duration",
        configured_fs_animation_duration ~= nil and configured_fs_animation_duration or "default"
    )
end

local function arm_fs_animation()
    if fs_animation_armed then return end
    fs_animation_armed = true
    set_fs_animation_default()
end

-- Keep fallback geometry distinct from a genuine user/configured geometry.
-- mpv reports the fallback back through the geometry property after restoration;
-- that must not make the next PiP cycle mistake it for an original geometry.
local function track_normal_geometry(value)
    local geometry = value or ""
    if normal.geometry_is_fallback and geometry == normal.geometry then
        return
    end
    normal.geometry = geometry
    normal.geometry_is_fallback = false
end

local function restore_geometry(geometry, is_fallback)
    normal.geometry = geometry
    normal.geometry_is_fallback = is_fallback
    mp.set_property("geometry", geometry)
    -- Store mpv's canonical spelling, since it may normalize geometry strings.
    normal.geometry = mp.get_property("geometry") or geometry
    normal.geometry_is_fallback = is_fallback
end

-- Keeps track of the windowed state. Called with no arguments for a full
-- refresh, or from a property observer with that property's new value (so the
-- common case reads one property instead of all of them).
local function update_normal_state(prop, value)
    if is_pip or entering_pip_from_fullscreen or pip_cancelled_by_fullscreen then return end
    if mp.get_property_native("fullscreen") then return end

    if prop == nil then
        normal.max        = mp.get_property_native("window-maximized") or false
        normal.ontop      = mp.get_property_native("ontop") or false
        normal.keepaspect = mp.get_property_native("keepaspect-window") ~= false
        normal.border     = mp.get_property_native("border") ~= false
        track_normal_geometry(mp.get_property("geometry"))
        local ws = mp.get_property_native("current-window-scale")
        if ws and ws > 0 then normal.window_scale = ws end
        return
    end

    if prop == "geometry" then
        -- mpv normalises this value ("30%-25-25" -> "30%x0-25-25"), so it must
        -- never be compared against PIP_GEOM; the guards above are what keep PiP
        -- values out of the "normal" state.
        track_normal_geometry(value)
    elseif prop == "current-window-scale" then
        if value and value > 0 then normal.window_scale = value end
    elseif prop == "window-maximized" then
        normal.max = value or false
    elseif prop == "keepaspect-window" then
        normal.keepaspect = value ~= false
    elseif prop == "border" then
        normal.border = value ~= false
    elseif prop == "ontop" then
        normal.ontop = value or false
    end
end

local function save_pip_state()
    saved.fs = mp.get_property_native("fullscreen") or false

    -- A live `false` is a real value, not a missing property. Fall back to the
    -- last windowed snapshot only when the property is unavailable, or when
    -- fullscreen has hidden a previously maximized/ontop window state.
    local maximized = mp.get_property_native("window-maximized")
    if maximized == nil or (saved.fs and maximized == false and normal.max) then
        maximized = normal.max
    end
    saved.max = maximized or false

    local ontop = mp.get_property_native("ontop")
    if ontop == nil or (saved.fs and ontop == false and normal.ontop) then
        ontop = normal.ontop
    end
    saved.ontop = ontop or false

    saved.keepaspect = normal.keepaspect
    saved.border     = normal.border
    saved.geometry   = normal.geometry_is_fallback and "" or (normal.geometry or "")
    saved.geometry_is_fallback = false

    -- mpv documents current-window-scale as the last windowed size even while
    -- fullscreen. Capture it before changing the fullscreen window's target frame.
    local ws = mp.get_property_native("current-window-scale")
    if ws and ws > 0 then normal.window_scale = ws end
    saved.window_scale = normal.window_scale

    if saved.geometry == "" and not saved.fs and not normal.geometry_is_fallback then
        local g = mp.get_property("geometry")
        if g and g ~= "" then saved.geometry = g end
    end

    -- With fs=yes at startup, an unset geometry is still a known default: mpv
    -- places an ordinary window in the centre. Make that position explicit so
    -- the PiP geometry cannot become the only saved windowed position.
    if saved.geometry == "" then
        saved.geometry = NORMAL_GEOM
        saved.geometry_is_fallback = true
    end
end

local function restore_window_state()
    mp.set_property_native("ontop", saved.ontop)
    mp.set_property_native("keepaspect-window", saved.keepaspect)
    mp.set_property_native("border", saved.border)

    -- Unmaximize before restoring geometry, otherwise the geometry update may
    -- be applied to the maximized frame and discarded by the window manager.
    if not saved.max and mp.get_property_native("window-maximized") == true then
        mp.set_property_native("window-maximized", false)
    end

    -- Restore the last real windowed size before applying geometry. This matters
    -- when mpv.conf specifies position only (e.g. geometry=50%:30%): applying that
    -- position does not restore the size that PiP changed. If geometry also sets
    -- a size, the geometry assignment below takes precedence.
    if saved.window_scale then
        mp.set_property_native("window-scale", saved.window_scale)
    end

    if saved.geometry and saved.geometry ~= "" then
        -- Position updates require force-window-position=yes on affected mpv builds.
        restore_geometry(saved.geometry, saved.geometry_is_fallback)
    elseif saved.window_scale then
        mp.set_property_native("window-scale", saved.window_scale)
    end

    if saved.max and mp.get_property_native("window-maximized") ~= true then
        mp.set_property_native("window-maximized", true)
    end
end

local function apply_pip_geometry(geometry_already_set)
    if saved.max then
        mp.set_property_native("window-maximized", false)
    end

    mp.set_property_native("border", false)
    mp.set_property_native("keepaspect-window", true)
    -- When coming out of fullscreen the geometry was primed *before* leaving
    -- fullscreen (see enter_pip); writing it again here would cancel the running
    -- exit animation and snap the window into place.
    if not geometry_already_set then
        mp.set_property("geometry", PIP_GEOM)
    end
    mp.set_property_native("ontop", true)
    set_ui_hidden(true)
end

-- ===== PiP transitions ===================================================

local function enter_pip()
    save_pip_state()

    is_pip = true
    pip_cancelled_by_fullscreen = false
    set_pip_title(true)

    if saved.fs then
        entering_pip_from_fullscreen = true
        -- Animate, and aim the animation at the PiP corner: while the window is
        -- still fullscreen a geometry change only rewrites the stored windowed
        -- frame the exit animation glides towards, it does not move the window.
        -- (A previous PiP-to-fullscreen session may have disabled the animation.)
        set_fs_animation_default()
        mp.set_property("geometry", PIP_GEOM)
        mp.set_property_native("fullscreen", false)
    else
        entering_pip_from_fullscreen = false
        apply_pip_geometry()
    end
end

local function exit_pip()
    entering_pip_from_fullscreen = false
    is_pip = false
    pip_cancelled_by_fullscreen = false

    set_pip_title(false)

    if saved.fs then
        -- PiP was entered from fullscreen: go back to fullscreen, straight from
        -- the corner.
        pip_cancelled_by_fullscreen = true
        mp.set_property_native("ontop", saved.ontop)
        mp.set_property_native("keepaspect-window", saved.keepaspect)
        mp.set_property_native("border", saved.border)
        mp.set_property_native("fullscreen", true)
    else
        restore_window_state()
    end

    set_ui_hidden(false)
end

mp.register_script_message("toggle-pip", function()
    if is_pip then
        exit_pip()
    else
        enter_pip()
    end
end)

-- ===== Observers =========================================================

for _, prop in ipairs({
    "current-window-scale", "window-maximized", "keepaspect-window",
    "border", "ontop", "geometry",
}) do
    mp.observe_property(prop, "native", function(name, value)
        update_normal_state(name, value)
    end)
end

mp.observe_property("fullscreen", "bool", function(_, value)
    if value == true then
        if is_pip then
            -- User pressed 'f' / double-clicked in PiP: leave PiP but stay in the
            -- corner; the fullscreen enter animation has already started.
            entering_pip_from_fullscreen = false
            is_pip = false
            pip_cancelled_by_fullscreen = true

            mp.set_property_native("ontop", saved.ontop)
            mp.set_property_native("keepaspect-window", saved.keepaspect)
            mp.set_property_native("border", saved.border)
            set_pip_title(false)
            set_ui_hidden(false)
        end

        if pip_cancelled_by_fullscreen then
            -- This fullscreen session was entered from PiP, so the frame its exit
            -- animation glides towards is the PiP corner, while the session has to
            -- end at the normal windowed rect. Retargeting it here would mean
            -- resizing the window while fullscreen, so make this one exit instant
            -- instead of gliding to the wrong corner. Delayed, because the "enter
            -- fullscreen" animation is starting right now and must not be cut short.
            mp.add_timeout(0.6, function()
                if pip_cancelled_by_fullscreen and mp.get_property_native("fullscreen") then
                    mp.set_property_native("macos-fs-animation-duration", 0)
                end
            end)
        end
        return
    end

    if entering_pip_from_fullscreen then
        entering_pip_from_fullscreen = false
        apply_pip_geometry(true)
        return
    end

    if pip_cancelled_by_fullscreen then
        -- Left the fullscreen session that was entered from PiP.
        pip_cancelled_by_fullscreen = false
        restore_window_state()
        restore_fs_animation_duration()
        return
    end

    -- Plain return to windowed mode: re-read the state we should restore to.
    update_normal_state()
end)

-- ===== Startup ===========================================================

-- Arm the fullscreen animation once startup is over: mpv.conf's fs=yes and the
-- initial placement must stay instant, every later transition should animate.
-- playback-restart fires when the first frame is up, i.e. after that placement.
local function arm_later(delay)
    mp.add_timeout(delay, arm_fs_animation)
end

mp.register_event("playback-restart", function() arm_later(0.3) end)

mp.observe_property("vo-configured", "bool", function(_, value)
    if value then arm_later(1.5) end
end)

if mp.get_property_native("vo-configured") then
    arm_later(1.5)
end

-- Safety net, in case neither of the above fires.
arm_later(8.0)

-- Seed properties that remain meaningful while fullscreen. The full refresh
-- below deliberately skips fullscreen because its geometry may be the PiP target.
local initial_max = mp.get_property_native("window-maximized")
local initial_ontop = mp.get_property_native("ontop")
local initial_keepaspect = mp.get_property_native("keepaspect-window")
local initial_border = mp.get_property_native("border")
local initial_scale = mp.get_property_native("current-window-scale")

if initial_max ~= nil then normal.max = initial_max end
if initial_ontop ~= nil then normal.ontop = initial_ontop end
if initial_keepaspect ~= nil then normal.keepaspect = initial_keepaspect end
if initial_border ~= nil then normal.border = initial_border end
if initial_scale and initial_scale > 0 then normal.window_scale = initial_scale end
track_normal_geometry(mp.get_property("geometry"))
update_normal_state()
