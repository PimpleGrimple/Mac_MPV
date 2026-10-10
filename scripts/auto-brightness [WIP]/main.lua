--[[
main.lua -- entry point for the auto-brightness script bundle.

Owns shared display services/brightness plumbing, static SDR/inverse-TM/HDR
brightness, HDR detection, target-peak synchronization, and mpv wiring.
Optional dynamic display-control integration is isolated in a removable section at the end of this file.
]]

local msg   = require("mp.msg")
local opt   = require("mp.options")
local ffi   = require("ffi")

-- ── Options ────────────────────────────────────────────────────────────────
local options = {
    -- Shared display calibration. This is the physical peak the panel can
    -- produce and is available to optional modules and future models.
    display_peak_nits        = 500.0,
    display_id               = 1,

    -- Static HDR/SDR brightness. Each value is a string with a unit:
    --   "203nits"  (also "203 nits" / "203n")  absolute brightness
    --   "10/16"    a position on macOS's 16-step brightness scale; fractions
    --              work ("10.25/16" = the Option+Shift quarter steps)
    -- A bare number is rejected on purpose (it could be a pre-nits slider
    -- float from an old config). These stay independent of optional modules.
    hdr_brightness           = "500nits",
    inv_tm_brightness        = "140nits",
    sdr_brightness           = "120nits",
    -- Apply the configured SDR brightness while ordinary SDR content is active.
    -- Kept under the existing option name for config compatibility.
    jump_to_sdr_on_start     = true,
    remember_sdr_adjustments = false,
    fade                     = true,
    fade_duration            = 0.15,
    only_when_focused        = true,
}


-- Backlight levels in the LINEAR register (0-1, fraction of display_peak_nits),
-- derived from the *_brightness options by apply_static_levels(). Not
-- options: the controller below and cabc.lua read them from here.
options.hdr_linear    = 1.0
options.inv_tm_linear = 0.22
options.sdr_linear    = 0.41

local ctx = {}
local brightness = nil

-- Forward declarations for the shared target-peak and calibration callbacks.
local sync_target_peak
local apply_static_levels

opt.read_options(options, "auto-brightness", function(list)
    if list and apply_static_levels then
        for _, k in ipairs({ "display_peak_nits", "hdr_brightness",
                             "inv_tm_brightness", "sdr_brightness" }) do
            if list[k] then
                apply_static_levels()
                -- Tell the controller below that the derived levels changed.
                list["hdr_linear"], list["inv_tm_linear"], list["sdr_linear"] = true, true, true
                break
            end
        end
    end
    local owner = ctx.hdr_owner
    if owner and owner.on_options_updated then owner.on_options_updated(list) end
    if brightness and brightness.on_options_updated then brightness.on_options_updated(list) end
    if list and list["display_peak_nits"] and sync_target_peak then
        sync_target_peak()
    end
    if ctx.apply_dynamic_peak_policy then ctx.apply_dynamic_peak_policy() end
    if ctx.reset_brightness_state then ctx.reset_brightness_state() end
end)

-- ── DisplayServices FFI ────────────────────────────────────────────────────
ffi.cdef[[
    int DisplayServicesGetBrightness(uint32_t display, float *brightness);
    int DisplayServicesSetBrightness(uint32_t display, float brightness);
    int DisplayServicesGetLinearBrightness(uint32_t display, float *brightness);
    int DisplayServicesSetLinearBrightness(uint32_t display, float brightness);
    char *realpath(const char *path, char *resolved_path);
    unsigned char *CC_MD5(const void *data, uint32_t len, unsigned char *md);
    struct timespec {
        long tv_sec;
        long tv_nsec;
    };
    int nanosleep(const struct timespec *req, struct timespec *rem);
]]
local ds_ok, ds = pcall(ffi.load,
    "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices")
local b_buf   = ffi.new("float[1]")
local lin_buf = ffi.new("float[1]")

local function resolve_ds_symbol(name)
    if not ds_ok then return nil end
    local ok, fn = pcall(function() return ds[name] end)
    return ok and fn or nil
end

local ds_get_brightness = resolve_ds_symbol("DisplayServicesGetBrightness")
local ds_set_brightness = resolve_ds_symbol("DisplayServicesSetBrightness")
local ds_get_linear_brightness = resolve_ds_symbol("DisplayServicesGetLinearBrightness")
local ds_set_linear_brightness = resolve_ds_symbol("DisplayServicesSetLinearBrightness")
local ds_slider_ok = ds_get_brightness ~= nil and ds_set_brightness ~= nil
local ds_linear_ok = ds_get_linear_brightness ~= nil and ds_set_linear_brightness ~= nil
local ds_warned = false

local function warn_ds_unavailable()
    if ds_warned then return end
    ds_warned = true
    if not ds_ok then
        msg.warn("auto-brightness: DisplayServices.framework could not be loaded; brightness control is disabled")
    elseif not ds_slider_ok then
        msg.warn("auto-brightness: DisplayServices slider brightness API is unavailable; static brightness writes are disabled")
    elseif not ds_linear_ok then
        msg.warn("auto-brightness: DisplayServices linear brightness API is unavailable; linear HDR display control is disabled")
    end
end

local function get_display_id()
    local id = tonumber(options.display_id)
    if not id or id < 0 then return 1 end
    return math.floor(id)
end

-- ── Shared state ──────────────────────────────────────────────────────────
local orig_target_peak = nil

local function get_display_peak_nits()
    local peak = tonumber(options.display_peak_nits)
    if peak and peak > 0 then return peak end
    return 0
end

local function hdr_owner_enabled()
    local owner = ctx.hdr_owner
    if not owner or not owner.is_enabled or not owner.is_enabled() then
        return false
    end
    if owner.is_active then
        return owner.is_active() == true
    end
    return true
end
local last_applied_linear = -1
local last_applied_slider = -1

-- Write caches intentionally persist between reconciles; call this whenever
-- ownership or an externally controlled brightness path changes so a near-identical
-- target is not incorrectly suppressed by the epsilon write gate.
local function invalidate_caches()
    last_applied_linear = -1
    last_applied_slider = -1
end

local function get_slider_brightness()
    if ds_slider_ok then
        local rc = ds_get_brightness(get_display_id(), b_buf)
        if rc == 0 then return tonumber(b_buf[0]) end
    end
    warn_ds_unavailable()
    return nil
end

local function get_linear_brightness()
    if ds_linear_ok then
        local rc = ds_get_linear_brightness(get_display_id(), lin_buf)
        if rc == 0 then return tonumber(lin_buf[0]) end
    end
    warn_ds_unavailable()
    return nil
end

local function set_linear_brightness(lin, force)
    if not ds_linear_ok then
        warn_ds_unavailable()
        return false
    end
    lin = math.max(0.01, math.min(1.0, lin))
    if force or math.abs(lin - last_applied_linear) > 0.002 then
        last_applied_linear = lin
        return ds_set_linear_brightness(get_display_id(), lin) == 0
    end
    return true
end

local function set_slider_brightness(slider, force)
    if not ds_slider_ok then
        warn_ds_unavailable()
        return false
    end
    slider = math.max(0.0, math.min(1.0, slider))
    if force or math.abs(slider - last_applied_slider) > 0.002 then
        last_applied_slider = slider
        return ds_set_brightness(get_display_id(), slider) == 0
    end
    return true
end

local function sleep_us(us)
    if us <= 0 then return end
    local sec = math.floor(us / 1000000)
    local nsec = (us - sec * 1000000) * 1000
    local req = ffi.new("struct timespec")
    req.tv_sec = sec
    req.tv_nsec = nsec
    pcall(function() ffi.C.nanosleep(req, nil) end)
end

-- ── Static levels -> linear register ──────────────────────────────────────
-- Everything the controller writes for SDR / inverse-TM / static HDR goes to
-- the LINEAR register, the same one CABC uses. A level given in nits is just
-- nits / display_peak_nits, so no macOS query is needed. Only a level given
-- on the 16-step scale has to ask the OS what linear value that slider
-- position is; that is a single set-slider/get-linear round trip, after which
-- the panel is put back where it was (well under a millisecond, far below the
-- backlight's physical response time). With only nits configured, startup
-- touches DisplayServices not at all.
local STEPS = 16

-- "203nits" -> "nits", 203 | "10/16" -> "step", 10 | anything else -> nil
local function parse_level(v)
    if type(v) ~= "string" then return nil end
    v = v:lower():gsub("%s+", "")
    local n = v:match("^([%d%.]+)n[a-z]*$")
    if n and tonumber(n) and tonumber(n) > 0 then return "nits", tonumber(n) end
    local st = v:match("^([%d%.]+)/" .. STEPS .. "$")
    if st and tonumber(st) and tonumber(st) > 0 then return "step", tonumber(st) end
    return nil
end

apply_static_levels = function()
    local peak = get_display_peak_nits()
    local levels = {}
    local need_query = false
    for _, key in ipairs({ "sdr", "inv_tm", "hdr" }) do
        local kind, value = parse_level(options[key .. "_brightness"])
        levels[#levels + 1] = { key, kind, value }
        if kind == "step" then need_query = true end
    end

    local id = get_display_id()
    local orig = ffi.new("float[1]")
    local can_query = need_query and ds_slider_ok and ds_linear_ok
        and ds_get_brightness(id, orig) == 0
    if need_query and not can_query then
        warn_ds_unavailable()
        msg.warn("auto-brightness: cannot query macOS for 16-step levels; "
            .. "using a gamma 2.2 estimate (can be ~5-20 nits off)")
    end

    local buf = ffi.new("float[1]")
    local ok, err = pcall(function()
        for _, l in ipairs(levels) do
            local key, kind, value = l[1], l[2], l[3]
            local name = key .. "_brightness"
            local lin
            if kind == "step" then
                local slider = math.max(0.0, math.min(1.0, value / STEPS))
                if can_query and ds_set_brightness(id, slider) == 0
                    and ds_get_linear_brightness(id, buf) == 0 then
                    lin = tonumber(buf[0])
                else
                    lin = slider ^ 2.2
                    msg.warn("auto-brightness: " .. name .. ": step query failed; gamma estimate used")
                end
            elseif kind == "nits" and peak > 0 then
                lin = value / peak
            end
            if lin then
                options[key .. "_linear"] = math.max(0.01, math.min(1.0, lin))
                msg.info(string.format("auto-brightness: %s = %s -> linear %.6f (%.1f nits)",
                    name, tostring(options[name]), options[key .. "_linear"],
                    options[key .. "_linear"] * peak))
            else
                msg.warn(string.format(
                    "auto-brightness: %s = %q is not a valid level (use e.g. \"203nits\" or \"10/16\"); keeping linear %.3f",
                    name, tostring(options[name]), options[key .. "_linear"]))
            end
        end
    end)

    -- Always put the panel back exactly where we found it.
    if can_query and ds_set_brightness(id, orig[0]) ~= 0 then
        msg.warn("auto-brightness: failed to restore original brightness after step query")
    end
    if not ok then
        msg.error("auto-brightness: level calculation error: " .. tostring(err))
    end
end

apply_static_levels()

-- ── Shared detection helpers ──────────────────────────────────────────────
local function pq_to_nits(pq)
    if not pq or pq <= 0 then return 0.0 end
    local m1 = 0.1593017578125
    local m2 = 78.84375
    local c1 = 0.8359375
    local c2 = 18.8515625
    local c3 = 18.6875
    local pq_m2 = pq ^ (1.0 / m2)
    local num = math.max(pq_m2 - c1, 0.0)
    local den = c2 - c3 * pq_m2
    if den <= 0 then return 10000.0 end
    return 10000.0 * (num / den) ^ (1.0 / m1)
end

local function is_hdr_video(vparams)
    vparams = vparams or mp.get_property_native("video-params")
    if not vparams then return false end
    -- mpv exposes sig-peak in cd/m² (nits). SDR is nominally 100 nits;
    -- use a small margin to avoid float-rounding around the SDR reference.
    if (vparams["sig-peak"] or 100.0) > 101.0 then return true end
    if vparams["gamma"] == "pq" or vparams["gamma"] == "hlg" then return true end
    if vparams["colormatrix"] == "dolbyvision" then return true end
    -- scene-* live on video-out-params, populated by libplacebo when
    -- hdr-compute-peak is enabled -- not on video-params.
    local vo = mp.get_property_native("video-out-params")
    if vo and (vo["scene-max-r"] or 0) > 0 then return true end
    local path = mp.get_property("path", ""):lower()
    if path:find("dovi") or path:find("dolbyvision") or path:find("dolby.vision")
        or path:match("[%.%-_]dv[%.%-_]") then
        return true
    end
    return false
end

-- Returns true only when mpv has an actual, focused, rendering window.
--
-- The vo-configured check is what fixes "extension launches mpv and the panel
-- brightens while Chrome is still foreground": focused can stick at its
-- default during startup, so during the interval between "spawn" and "window
-- exists and grabs focus" the old check said "active." vo-configured only
-- becomes true once the video output is actually configured, which requires
-- the window to exist. focused defaults to false so an unset property can't
-- be mistaken for a focused window.
local function is_window_active()
    local vo_conf = mp.get_property_native("vo-configured")
    if vo_conf ~= nil and not vo_conf then return false end
    if mp.get_property_bool("idle-active", false) then return false end
    if options.only_when_focused ~= false then
        return mp.get_property_bool("focused", false)
    end
    return true
end

-- ── target-peak sync (shared concern) ─────────────────────────────────────
local forced_target_peak = nil

sync_target_peak = function()
    if not is_hdr_video() then return end
    if orig_target_peak == nil then
        orig_target_peak = mp.get_property("target-peak")
    end
    forced_target_peak = get_display_peak_nits()
    if forced_target_peak > 0 then
        mp.set_property_number("target-peak", forced_target_peak)
    end
end

local function restore_target_peak()
    if orig_target_peak == nil then return end
    local current = mp.get_property_number("target-peak")
    local same_forced_value = current and forced_target_peak
        and math.abs(current - forced_target_peak) < 0.01
    if same_forced_value then
        mp.set_property("target-peak", orig_target_peak)
    else
        msg.info("auto-brightness: not restoring target-peak (current value differs or is unreadable)")
    end
    orig_target_peak = nil
    forced_target_peak = nil
end

-- ── Baseline brightness controller ───────────────────────────────────────
-- Desktop / SDR / inverse-tone-mapped / static-HDR brightness.
local function create_brightness_controller(ctx)
    local mp      = ctx.mp
    local options = ctx.options

    local bl_state         = nil      -- nil ("desktop") | "hdr" | "inv_tm" | "sdr"
    local bl_current_sdr   = options.sdr_linear      -- linear coordinate
    local bl_current_invtm = options.inv_tm_linear   -- linear coordinate
    local bl_fade_timer    = nil
    local bl_last_use_linear = false
    -- True only while reset_state() re-runs the "entering a managed state"
    -- branch from a state that was already managed: the panel is then at a
    -- managed level, so it must not be re-read as the user's desktop level.
    local bl_reentering = false
    local bl_desktop_captured = false
    local bl_capture_attempts = 0
    local BL_CAPTURE_MAX_ATTEMPTS = 3

    -- Capture both the slider and linear register values before any file
    -- has loaded and before an external HDR owner can touch the panel.
    -- These are the only reliable reads of the user's desktop brightness --
    -- during HDR playback, the slider and linear control paths report
    -- independently and neither reflects what the user set at the desktop.
    --
    -- Both coordinates are captured because an external HDR owner may drive the panel via the
    -- LINEAR register (SetLinearBrightness), so when leaving HDR the fade
    -- has to write to linear, and its target must be in linear coordinates.
    -- Writing the slider-coordinate value to the linear register produces a
    -- visibly wrong brightness: 0.75 in slider space is not 0.75 in linear
    -- space on macOS.
    --
    -- The >0.999 check on the slider read is deliberately tight: it catches
    -- only the exact spurious 1.0 that some macOS versions return while a
    -- display is settling, and leaves a legitimate user-set value of 0.96 or
    -- 0.99 alone.
    local bl_desktop = nil
    local bl_desktop_lin = nil

    local function capture_desktop_brightness()
        if bl_desktop_captured or bl_capture_attempts >= BL_CAPTURE_MAX_ATTEMPTS then
            return bl_desktop_captured
        end
        bl_capture_attempts = bl_capture_attempts + 1

        local slider = ctx.get_slider_brightness()
        if slider and slider <= 0.999 then
            bl_desktop = slider
            bl_capture_attempts = 0
            bl_desktop_captured = true
        end
        local linear = ctx.get_linear_brightness()
        if linear and linear > 0.0 then
            bl_desktop_lin = linear
        end
        if not bl_desktop_captured and bl_capture_attempts == BL_CAPTURE_MAX_ATTEMPTS then
            msg.warn("auto-brightness: could not capture desktop slider brightness after 3 attempts; will restore via the linear register instead")
            bl_desktop_captured = true
        end
        return bl_desktop_captured
    end

    capture_desktop_brightness()

    -- ── Write-path selection ──────────────────────────────────────────────
    -- The write path is passed EXPLICITLY by every call site, as a boolean.
    -- The previous version inferred it from the outgoing state name, which
    -- caused the reported bug: when leaving HDR, `from_state == "hdr"`
    -- selected the linear write path, but the caller was still passing
    -- `bl_desktop` (a slider-space value). An explicit boolean makes that
    -- mismatch impossible to reintroduce.
    local function bl_write(v, use_linear)
        if use_linear then
            ctx.set_linear_brightness(v, false)
        else
            ctx.set_slider_brightness(v, false)
        end
    end

    local function panel_start_value(use_linear)
        if use_linear then
            return ctx.get_linear_brightness()
        end
        return ctx.get_slider_brightness()
    end

    -- ── Async fade (normal transitions) ───────────────────────────────────
    local function bl_set(target, do_fade, use_linear)
        if bl_fade_timer then bl_fade_timer:kill(); bl_fade_timer = nil end
        if not do_fade or not options.fade then
            bl_write(target, use_linear)
            return
        end
        local start = panel_start_value(use_linear)
        if start == nil then
            bl_write(target, use_linear)
            return
        end
        local steps = 12
        local i = 0
        bl_fade_timer = mp.add_periodic_timer((options.fade_duration or 0.15) / steps, function()
            i = i + 1
            bl_write(start + (target - start) * (i / steps), use_linear)
            if i >= steps then
                if bl_fade_timer then bl_fade_timer:kill() end
                bl_fade_timer = nil
            end
        end)
    end

    -- ── Blocking fade (shutdown only) ─────────────────────────────────────
    -- The event loop is held for the duration; that's fine because mpv is
    -- quitting. Fewer steps than the async version so total time stays close
    -- to options.fade_duration regardless of scheduling jitter.
    local function bl_set_blocking(target, duration, use_linear)
        duration = duration or (options.fade_duration or 0.15)
        if bl_fade_timer then bl_fade_timer:kill(); bl_fade_timer = nil end

        if not options.fade or duration <= 0 then
            bl_write(target, use_linear)
            return
        end

        local start = panel_start_value(use_linear)
        if start == nil then
            bl_write(target, use_linear)
            return
        end
        local steps = 8
        local step_us = math.max(1, math.floor(duration * 1000000 / (steps - 1)))
        for i = 1, steps do
            bl_write(start + (target - start) * (i / steps), use_linear)
            if i < steps then
                ctx.sleep_us(step_us)
            end
        end
    end

    -- ── State machine ─────────────────────────────────────────────────────
    -- Returns (target, state). `target` is `true` (sentinel) for the "hdr"
    -- state when an external HDR owner is enabled and will own the actual value; it's a real
    -- linear value (options.hdr_linear) when no external HDR owner is active and this
    -- module has to set the panel itself.
    local function bl_get_target()
        if ctx.is_hdr_video() then
            if hdr_owner_enabled() then
                return true, "hdr"                    -- external owner owns the value
            end
            return options.hdr_linear, "hdr"         -- static HDR fallback
        elseif mp.get_property_bool("inverse-tone-mapping", false) then
            return bl_current_invtm, "inv_tm"
        elseif options.jump_to_sdr_on_start then
            return bl_current_sdr, "sdr"
        end
        return nil, "desktop"
    end

    -- Notify the optional HDR owner before the baseline controller takes the
    -- panel back through the desktop/slider path.
    local function notify_hdr_owner_leave()
        local owner = ctx.hdr_owner
        if owner and owner.suspend then owner.suspend() end
    end

    local function owner_uses_linear()
        local owner = ctx.hdr_owner
        if owner and owner.uses_linear_write then
            return owner.uses_linear_write() == true
        end
        return ctx.linear_brightness_available()
    end

    -- Apply the "hdr" target. If `target` is the sentinel `true`, the optional
    -- HDR owner controls the panel and is prompted to reapply. Otherwise the
    -- baseline controller writes the static-HDR brightness itself.
    local function apply_hdr_target(target, fade)
        if target == true then
            if bl_fade_timer then bl_fade_timer:kill(); bl_fade_timer = nil end
            bl_last_use_linear = owner_uses_linear()
            ctx.invalidate_caches()
            local owner = ctx.hdr_owner
            if owner and owner.reapply_current then owner.reapply_current() end
        else
            -- Static HDR fallback: linear register, like every static level.
            if bl_last_use_linear then
                notify_hdr_owner_leave()
            end
            bl_last_use_linear = false
            bl_set(target, fade, true)
        end
    end

    -- mode: "instant" | "async_fade" | "blocking_fade"
    local function bl_restore(mode)
        local from = bl_state
        if from == "sdr" and options.remember_sdr_adjustments then
            bl_current_sdr = ctx.get_linear_brightness() or bl_current_sdr
        end
        if from == "hdr" and bl_last_use_linear then
            notify_hdr_owner_leave()
        end

        -- Write path and target coordinate must agree. Leaving HDR with
        -- an external linear owner uses the saved linear desktop coordinate;
        -- static HDR and all non-linear paths stay on the slider register.
        local use_linear = (from == "hdr" and bl_last_use_linear
            and ctx.linear_brightness_available() and bl_desktop_lin ~= nil)
        local target = use_linear and bl_desktop_lin or bl_desktop
        if target == nil then
            -- Slider capture failed; fall back to the linear capture if any.
            use_linear = bl_desktop_lin ~= nil and ctx.linear_brightness_available()
            target = use_linear and bl_desktop_lin or nil
        end

        if target then
            if mode == "blocking_fade" then
                bl_set_blocking(target, options.fade_duration or 0.15, use_linear)
            elseif mode == "async_fade" then
                bl_set(target, true, use_linear)
            else
                bl_set(target, false, use_linear)
            end
        end
        bl_last_use_linear = false
        bl_state = nil
    end

    local function bl_update_now()
        local target, target_state = bl_get_target()

        if not ctx.is_window_active() then
            target, target_state = nil, "desktop"
        end

        if target then
            if not bl_state then
                -- Entering a managed state from desktop. The panel may have
                -- been changed behind our back (user, restore via the other
                -- register), so never let the write gate suppress this write.
                ctx.invalidate_caches()
                local owner = ctx.hdr_owner
                local owner_active = owner and owner.is_active and owner.is_active() or false
                if not bl_desktop_captured and not owner_active then
                    capture_desktop_brightness()
                end
                --
                -- For non-HDR states (sdr/inv_tm), refresh bl_desktop from
                -- the panel: the panel is at desktop at this moment, so the
                -- read is reliable, and this respects any manual brightness
                -- change the user made while we were at desktop.
                --
                -- For HDR, do not re-read here: the optional HDR owner may
                -- already have dimmed the panel, so that read could capture
                -- the owner's value rather than the user's desktop level.
                if target_state ~= "hdr" and not bl_reentering then
                    local captured = ctx.get_slider_brightness()
                    if captured and captured <= 0.999 then
                        bl_desktop = captured
                    end
                end

                if target_state == "hdr" then
                    apply_hdr_target(target, false)
                else
                    bl_set(target, false, true)
                    bl_last_use_linear = false
                end
                bl_state = target_state
            elseif bl_state ~= target_state then
                -- Managed-state-to-managed-state transition without passing
                -- through desktop (e.g. HDR file ends, SDR file starts next).
                -- Instant, no fade. `bl_state` is still the outgoing state
                -- here -- bl_set / apply_hdr_target use it for
                -- notify_hdr_owner_leave and write-path selection before we
                -- overwrite it at the end of the block.
                local leaving_hdr = (bl_state == "hdr")
                if bl_state == "sdr" and options.remember_sdr_adjustments then
                    bl_current_sdr = ctx.get_linear_brightness() or bl_current_sdr
                end
                if target_state == "sdr"    then target = bl_current_sdr    end
                if target_state == "inv_tm" then target = bl_current_invtm end

                if leaving_hdr and bl_last_use_linear then
                    notify_hdr_owner_leave()
                end

                if target_state == "hdr" then
                    apply_hdr_target(target, false)
                else
                    -- sdr/inv_tm targets are slider-coordinate values.
                    bl_set(target, false, true)
                    bl_last_use_linear = false
                end
                bl_state = target_state
            else
                -- Same state name -- but the target may have changed from the
                -- sentinel to a real value or vice versa (e.g. user toggled
                -- live owner mid-playback without changing file). Re-run the
                -- apply path if so.
                if target_state == "hdr" and target ~= true then
                    apply_hdr_target(target, false)
                end
            end
        elseif bl_state then
            -- Was in a managed state, now should be back at desktop
            -- (unfocused, idle, or no video loaded).
            bl_restore(options.fade and "async_fade" or "instant")
        end
    end

    -- ── Public interface ──────────────────────────────────────────────────
    local M = {}

    function M.on_property_changed()
        bl_update_now()
    end

    function M.update_now()
        bl_update_now()
    end

    -- Clears bl_state so the next reconcile re-runs the "entering a managed
    -- state" branch (without re-reading the desktop level; see bl_reentering). Used when the optional HDR owner toggles on/off mid-playback: the state
    -- name ("hdr") doesn't change, but the target source does (sentinel vs
    -- options.hdr_linear), and the normal `bl_state == target_state`
    -- short-circuit would skip the reapply.
    function M.reset_state()
        bl_reentering = bl_state ~= nil
        bl_state = nil
        bl_last_use_linear = false
        M.update_now()
        bl_reentering = false
    end

    function M.on_file_loaded()
        -- The core calls this before the optional owner is given on_file_loaded(),
        -- so a first/uncaptured desktop read is still safe here.
        if not bl_desktop_captured then
            capture_desktop_brightness()
        end
        M.update_now()
    end

    -- end-file: mpv may keep the window up (playlist, idle screen) or close
    -- it. focused/idle-active observers will react either way; this nudges
    -- the reconcile for the case where neither property actually changes.
    function M.on_session_end()
        M.on_property_changed()
    end

    function M.on_options_updated(list)
        if not list then return end
        if list["sdr_linear"] then
            bl_current_sdr = options.sdr_linear
            if bl_state == "sdr" and not options.remember_sdr_adjustments then
                bl_set(bl_current_sdr, false, true)
            end
        end
        if list["inv_tm_linear"] then
            bl_current_invtm = options.inv_tm_linear
            if bl_state == "inv_tm" then
                bl_set(bl_current_invtm, false, true)
            end
        end
        if list["hdr_linear"] and not hdr_owner_enabled() then
            if bl_state == "hdr" then
                bl_set(options.hdr_linear, false, true)
            end
        end
    end

    -- Shutdown: blocking fade is what makes the panel return smoothly to
    -- desktop brightness when the user closes the mpv window, instead of
    -- snapping. The event loop is held for ~fade_duration; that's the only
    -- way this completes reliably, because mpv doesn't wait for async
    -- callbacks scheduled from the shutdown handler.
    function M.on_shutdown()
        bl_restore("blocking_fade")
    end

    function M.get_state()
        return string.format(
            "state=%s desktop_saved=%s desktop=%.3f desktop_lin=%.3f sdr=%.3f invtm=%.3f hdr=%.3f owner=%s",
            tostring(bl_state),
            tostring(bl_desktop ~= nil),
            bl_desktop or 0.0, bl_desktop_lin or 0.0,
            bl_current_sdr, bl_current_invtm, options.hdr_linear,
            tostring(hdr_owner_enabled()))
    end

    return M
end
-- ── Build ctx ─────────────────────────────────────────────────────────────
ctx.options                    = options
ctx.get_display_peak_nits     = get_display_peak_nits
ctx.get_static_hdr_linear     = function() return options.hdr_linear end
ctx.pq_to_nits                = pq_to_nits
ctx.mp                         = mp
ctx.msg                        = msg
ctx.ffi                        = ffi
ctx.is_hdr_video               = is_hdr_video
ctx.is_window_active           = is_window_active
ctx.get_slider_brightness      = get_slider_brightness
ctx.get_linear_brightness      = get_linear_brightness
ctx.set_linear_brightness      = set_linear_brightness
ctx.set_slider_brightness      = set_slider_brightness
ctx.invalidate_caches          = invalidate_caches
ctx.linear_brightness_available = function() return ds_linear_ok end
ctx.sleep_us                   = sleep_us

brightness = create_brightness_controller(ctx)
ctx.reset_brightness_state = function()
    if brightness and brightness.reset_state then brightness.reset_state() end
end

ctx.on_owner_active_changed = function()
    if ctx.apply_dynamic_peak_policy then ctx.apply_dynamic_peak_policy() end
    if ctx.reset_brightness_state then ctx.reset_brightness_state() end
end

-- ── Core wiring ───────────────────────────────────────────────────────────
local function fan_out()
    local owner = ctx.hdr_owner
    if owner and owner.on_property_changed then owner.on_property_changed() end
    if brightness and brightness.on_property_changed then brightness.on_property_changed() end
end

mp.observe_property("video-params",         "native", fan_out)
mp.observe_property("vo-configured",        "bool",   fan_out)
mp.observe_property("focused",              "bool",   fan_out)
mp.observe_property("inverse-tone-mapping", "bool",   fan_out)
mp.observe_property("idle-active",          "bool",   function(_, v)
    if v then restore_target_peak() end
    fan_out()
end)

mp.register_event("start-file", function()
    if ctx.apply_dynamic_peak_policy then ctx.apply_dynamic_peak_policy() end
end)

mp.register_event("file-loaded", function()
    restore_target_peak()
    sync_target_peak()
    if brightness and brightness.on_file_loaded then brightness.on_file_loaded() end

    local owner = ctx.hdr_owner
    if owner and owner.on_file_loaded then owner.on_file_loaded() end
    if ctx.reset_brightness_state then ctx.reset_brightness_state() end
end)

mp.register_event("end-file", function()
    local owner = ctx.hdr_owner
    if owner and owner.on_session_end then owner.on_session_end() end
    if brightness and brightness.on_session_end then brightness.on_session_end() end
end)

mp.register_event("shutdown", function()
    local owner = ctx.hdr_owner
    if owner and owner.on_shutdown then owner.on_shutdown() end
    if brightness and brightness.on_shutdown then brightness.on_shutdown() end
    restore_target_peak()
end)

mp.register_script_message("auto-brightness-debug", function()
    local lines = {}
    lines[#lines+1] = string.format(
        "focused=%s vo-configured=%s idle=%s is_hdr=%s target-peak=%s hdr-compute-peak=%s",
        tostring(mp.get_property_native("focused")),
        tostring(mp.get_property_native("vo-configured")),
        tostring(mp.get_property_native("idle-active")),
        tostring(is_hdr_video()),
        tostring(mp.get_property_native("target-peak")),
        tostring(mp.get_property_native("hdr-compute-peak")))
    if brightness and brightness.get_state then lines[#lines+1] = "brightness: " .. brightness.get_state() end
    local owner = ctx.hdr_owner
    if owner and owner.get_state then lines[#lines+1] = "dynamic: " .. owner.get_state() end
    local s = table.concat(lines, "  |  ")
    msg.info("auto-brightness: " .. s)
    mp.osd_message("auto-brightness: " .. s, 6.0)
end)

msg.info(string.format("auto-brightness: loaded (baseline=%s)", tostring(brightness ~= nil)))

-- ============================================================================
-- OPTIONAL CABC INTEGRATION
-- DELETE FROM THIS LINE TO THE END OF THE FILE TO REMOVE CABC.
-- The code above intentionally contains no CABC-specific configuration.
-- ============================================================================

local utils = require("mp.utils")
local HOME = os.getenv("HOME") or ""
local SCRIPT_DIR = mp.get_script_directory()
    or (HOME .. "/.config/mpv/scripts/auto-brightness")
local CACHE_DIR = mp.command_native({"expand-path", "~~/cache/scripts/hdr_analysis/"})
if type(CACHE_DIR) ~= "string" or CACHE_DIR == "" then
    CACHE_DIR = HOME .. "/.config/mpv/cache/scripts/hdr_analysis/"
end
local SHADER_PATH = SCRIPT_DIR .. "/cabc_gain.hook"
local saved_hdr_compute_peak = nil
local forced_hdr_compute_peak = nil

ctx.apply_dynamic_peak_policy = function()
    local owner = ctx.hdr_owner
    local want_off = owner
        and owner.is_enabled and owner.is_enabled()
        and owner.is_active and owner.is_active()
        and owner.force_hdr_compute_peak_off
        and owner.force_hdr_compute_peak_off()

    if want_off then
        if saved_hdr_compute_peak == nil then
            saved_hdr_compute_peak = mp.get_property("hdr-compute-peak")
        end
        local current = mp.get_property("hdr-compute-peak")
        forced_hdr_compute_peak = "no"
        if current ~= "no" then
            mp.set_property("hdr-compute-peak", "no")
            msg.info(string.format(
                "auto-brightness: CABC enabled -- forcing hdr-compute-peak=no (user config was '%s')",
                tostring(saved_hdr_compute_peak)))
        end
    elseif saved_hdr_compute_peak ~= nil then
        local current = mp.get_property("hdr-compute-peak")
        if current == forced_hdr_compute_peak then
            mp.set_property("hdr-compute-peak", saved_hdr_compute_peak)
            msg.info(string.format(
                "auto-brightness: CABC disabled -- restoring hdr-compute-peak='%s'",
                tostring(saved_hdr_compute_peak)))
        else
            msg.info(string.format(
                "auto-brightness: preserving user-changed hdr-compute-peak='%s'",
                tostring(current)))
        end
        saved_hdr_compute_peak = nil
        forced_hdr_compute_peak = nil
    end
end

local function load_cabc()
    local path = SCRIPT_DIR .. "/cabc.lua"
    local chunk, err = loadfile(path)
    if not chunk then
        msg.error(string.format("auto-brightness: failed to load cabc.lua: %s", tostring(err)))
        return nil
    end
    local ok, factory = pcall(chunk)
    if not ok then
        msg.error(string.format("auto-brightness: error running cabc.lua: %s", tostring(factory)))
        return nil
    end
    if type(factory) ~= "function" then
        msg.error("auto-brightness: cabc.lua did not return a factory function")
        return nil
    end
    ctx.utils = utils
    ctx.SCRIPT_DIR = SCRIPT_DIR
    ctx.CACHE_DIR = CACHE_DIR
    ctx.SHADER_PATH = SHADER_PATH
    local ok2, mod = pcall(factory, ctx)
    if not ok2 then
        msg.error(string.format("auto-brightness: error constructing cabc.lua: %s", tostring(mod)))
        return nil
    end
    return mod
end

local cabc = load_cabc()
ctx.hdr_owner = cabc
if cabc and ctx.on_owner_active_changed then
    ctx.on_owner_active_changed()
end

if cabc then
    local function bind_cabc_key(key, name, fn)
        if type(fn) == "function" then
            mp.add_forced_key_binding(key, name, fn)
        else
            msg.warn("auto-brightness: CABC binding '" .. name .. "' unavailable")
        end
    end

    local function register_cabc_message(name, fn)
        if type(fn) == "function" then
            mp.register_script_message(name, fn)
        else
            msg.warn("auto-brightness: CABC message '" .. name .. "' unavailable")
        end
    end

    bind_cabc_key("Alt+b", "toggle-cabc-hud", cabc.toggle_hud)
    register_cabc_message("toggle-cabc-hud", cabc.toggle_hud)
    bind_cabc_key("Ctrl+g", "toggle-cabc-gain", cabc.toggle_gain)
    register_cabc_message("toggle-cabc-gain", cabc.toggle_gain)
    bind_cabc_key("Alt+[", "cabc-floor-down", function() cabc.adjust_min_nits(-10) end)
    bind_cabc_key("Alt+]", "cabc-floor-up", function() cabc.adjust_min_nits(10) end)
    register_cabc_message("cabc-floor-down", function() cabc.adjust_min_nits(-10) end)
    register_cabc_message("cabc-floor-up", function() cabc.adjust_min_nits(10) end)
    bind_cabc_key("Alt+-", "cabc-decay-slower", function() cabc.adjust_decay_rate(-2) end)
    bind_cabc_key("Alt+=", "cabc-decay-faster", function() cabc.adjust_decay_rate(2) end)
    register_cabc_message("cabc-decay-slower", function() cabc.adjust_decay_rate(-2) end)
    register_cabc_message("cabc-decay-faster", function() cabc.adjust_decay_rate(2) end)
    bind_cabc_key("Alt+h", "cabc-toggle-highlights", cabc.toggle_highlight_mode)
    bind_cabc_key("Alt+H", "cabc-toggle-highlights-upper", cabc.toggle_highlight_mode)
    register_cabc_message("cabc-toggle-highlights", cabc.toggle_highlight_mode)
    bind_cabc_key("Alt+x", "cabc-export-metadata", function() cabc.trigger_export(false) end)
    register_cabc_message("cabc-export-metadata", function() cabc.trigger_export(false) end)
    local function wrap_owner_toggle(fn)
        return function(...)
            if type(fn) == "function" then fn(...) end
            if ctx.on_owner_active_changed then
                ctx.on_owner_active_changed()
            end
        end
    end

    local toggle_live_cabc = wrap_owner_toggle(cabc.toggle_live_cabc)
    bind_cabc_key("Alt+l", "cabc-toggle-live", toggle_live_cabc)
    register_cabc_message("cabc-toggle-live", toggle_live_cabc)
    bind_cabc_key("Alt+c", "cabc-toggle-peak-override", cabc.toggle_peak_override)
    register_cabc_message("cabc-toggle-peak-override", cabc.toggle_peak_override)
    mp.register_script_message("auto-brightness-cabc-debug", function()
        local lines = {
            string.format("cabc_shader_path=%s", SHADER_PATH),
            "cabc: " .. (cabc.get_state and cabc.get_state() or "unknown"),
        }
        local shaders = mp.get_property_native("glsl-shaders") or {}
        lines[#lines+1] = "glsl-shaders=[" .. table.concat(shaders, ", ") .. "]"
        local s = table.concat(lines, "  |  ")
        msg.info("auto-brightness: " .. s)
        mp.osd_message("auto-brightness: " .. s, 6.0)
    end)
else
    msg.error("auto-brightness: cabc.lua not loaded -- dynamic backlight disabled")
end

mp.register_event("shutdown", function()
    if saved_hdr_compute_peak ~= nil then
        if mp.get_property("hdr-compute-peak") == forced_hdr_compute_peak then
            mp.set_property("hdr-compute-peak", saved_hdr_compute_peak)
        end
        saved_hdr_compute_peak = nil
        forced_hdr_compute_peak = nil
    end
end)