--[[
main.lua -- entry point for the auto_brightness script bundle.

Owns: options, DisplayServices FFI, shared brightness setter/getter, shared
caches, target-peak sync, hdr-compute-peak policy, is_hdr_video /
is_window_active detection, blocking-sleep helper for the shutdown fade, and
all mpv wiring (observers, events, hotkeys).

Brightness policy lives in siblings loaded via loadfile():

  sdr.lua  -- desktop / SDR / inverse-TM / HDR static state machine
  cabc.lua -- dynamic per-scene backlight + shader-gain compensation

mpv only auto-loads one file per scripts/<subdir>/, so the siblings are
pulled in explicitly. They receive a shared `ctx` and can reach each other
via ctx.sdr / ctx.cabc for hand-offs.

Module interface contract (each sibling returns a factory taking ctx):

  on_property_changed()      -- reconcile, called on shared property changes
  on_file_loaded()           -- new file started
  on_session_end()           -- file ended (may or may not be quitting)
  on_options_updated(list)   -- script-opts changed at runtime
  on_shutdown()              -- mpv is quitting (final cleanup)

  sdr additionally provides:
    update_now()             -- immediate reconcile
    reset_state()            -- clear bl_state and reconcile (used when
                             -- CABC toggles on/off mid-playback)
    get_state()              -- short debug string

  cabc additionally provides:
    reapply_current()        -- force immediate reapply (sdr hand-off)
    suspend()                -- reset gain to 1.0 but stay engaged
    get_state()
    toggle_hud / toggle_gain / adjust_min_nits(delta) /
    toggle_highlight_mode / trigger_export(is_auto) / toggle_live_cabc
    adjust_decay_rate(delta)

Hotkeys: Alt+b (HUD) | Ctrl+g (gain bypass) | Alt+h (highlight mode) |
Alt+[ / Alt+] (floor -/+) | Alt+- / Alt+= (decay -/+) | Alt+x (force curve
export) | Alt+l (toggle live CABC) | Alt+c (toggle hdr-compute-peak override)
--]]

local utils = require("mp.utils")
local msg   = require("mp.msg")
local opt   = require("mp.options")
local ffi   = require("ffi")

local SCRIPT_DIR  = mp.get_script_directory()
    or (os.getenv("HOME") .. "/.config/mpv/scripts/auto_brightness")
local CACHE_DIR   = os.getenv("HOME") .. "/.config/mpv/cache/scripts/hdr_analysis/"
local SHADER_PATH = SCRIPT_DIR .. "/cabc_gain.hook"

-- ── Options ────────────────────────────────────────────────────────────────
local options = {
    -- Panel geometry
    panel_peak_nits       = 500.0,
    min_panel_nits        = 50.0,

    -- Highlight blend
    preserve_highlights   = true,
    avg_nits_weight       = 0.3,

    -- Write gating
    nits_delta_threshold  = 0.25,
    osd_update_interval   = 0.067,

    -- Mode enable
    enable_hdr_cabc       = true,
    enable_live_hdr_cabc  = true,
    auto_export_hdr_curve = false,
    failure_retry_sec     = 604800,
    show_hud              = true,

    -- Static HDR brightness used ONLY when enable_hdr_cabc is false, or when
    -- CABC is disabled at runtime via Alt+l. Raw slider value in [0, 1].
    hdr_brightness        = 1.0,

    -- When CABC is enabled, force `hdr-compute-peak=no` for the duration of
    -- playback (restored on shutdown, or immediately when CABC is disabled).
    -- When CABC is disabled (static HDR path), your mpv.conf value is left
    -- untouched.
    --
    -- Rationale: hdr-compute-peak=yes makes libplacebo per-frame-normalize
    -- its tone-mapped output -- a 20-nit scene's peak gets stretched to SDR
    -- code 1.0. CABC's curve-mode gain was computed against the file's true
    -- 20-nit peak, so the shader then multiplies an already-stretched
    -- midtone past the ceiling and clips ("blown faces"). With it off, the
    -- tone mapper uses static file metadata and the SDR image stays a
    -- fixed-luminance representation, so CABC's linear math is correct.
    --
    -- Caveat: live mode (DV / static HDR10 files with no cached curve) reads
    -- video-out-params/max-pq-y, which libplacebo only populates when
    -- hdr-compute-peak is on. With this override enabled, live mode falls
    -- back to max-luma / 203 nits. Curve mode covers the common case.
    cabc_force_hdr_compute_peak_off = true,

    -- ── CABC-local HDR peak conditioning ──────────────────────────────────
    -- Named after mpv's equivalents to make the *purpose* obvious, but
    -- entirely independent in implementation and scale. mpv's versions drive
    -- libplacebo's tone mapping; these drive only CABC's backlight +
    -- shader-gain path. Changing one has no effect on the other.

    -- Two-tier scene-change hysteresis (dB) for CABC's input IIR. Below low:
    -- full smoothing at cabc_hdr_peak_decay_rate's tau. Between low and high:
    -- tau shrinks toward zero (tracks the change faster). At/above high:
    -- instant snap. Deliberately wider than mpv's 1.0/3.0 defaults, because
    -- backlight changes are far more visible than tone-mapping changes -- a
    -- 3 dB backlight jump reads as a flash.
    cabc_hdr_scene_threshold_low  = 3.0,
    cabc_hdr_scene_threshold_high = 12.0,

    -- Temporal percentile of the trailing peak window. 100 = max (identical
    -- to the old despike behavior). Lower values filter out isolated bright
    -- frames so a single specular glint can't drive the backlight.
    --
    -- NOTE: this is a *temporal* percentile across frames, not mpv's
    -- *spatial* per-frame pixel-histogram percentile -- CABC's extraction
    -- backends emit one peak value per frame, so a true spatial percentile
    -- isn't available without changing them.
    cabc_hdr_peak_percentile      = 100.0,

    -- Trailing window (seconds) for the percentile filter above. Raise if
    -- brief flashes still pulse; lower if genuine short dark beats feel
    -- sluggish.
    despike_window                = 0.15,

    -- Input-side IIR low-pass on the peak, as a direct time constant in
    -- milliseconds. 0 = disabled. Scale is deliberately NOT the same as
    -- mpv's --hdr-peak-decay-rate (which is 0-1000 tied to their
    -- peak-detection formula); ours is just tau in ms.
    --
    -- Keep this short (20-50 ms): it exists only to remove frame-to-frame
    -- jitter that survived the percentile filter. Perceptual smoothing of
    -- the physical backlight is the runtime envelope's job (live mode) or
    -- the comfort stage's job (curve mode), not this one.
    cabc_hdr_peak_decay_rate      = 0.0,

    -- ── CABC backlight envelope (live mode) ───────────────────────────────
    -- Curve mode bakes its own envelope into the cached curve; live mode has
    -- no future to look at and runs this at 60 Hz instead.
    cabc_rise_tau                 = 0.15,   -- s; attack time constant
    cabc_backlight_decay_rate     = 10.0,   -- dB/s; release speed

    -- Predictive lookahead baked into the curve (curve mode only). Live mode
    -- has no future, so it never uses this. For net-zero perceived lag in
    -- curve mode, keep this ≈ cabc_rise_tau: the envelope lags by rise_tau,
    -- the baked lookahead shifts earlier by lead_time, so total lag ≈
    -- rise_tau - lead_time.
    cabc_lead_time                = 0.15,   -- s

    -- Cut confirmation (live mode). An inferred cut (delta > high threshold)
    -- must be observed for N consecutive samples before snapping, and no
    -- snap may occur within cabc_cut_min_interval seconds of the previous
    -- one. Encoder-tagged cuts (from dovi_tool / hdr10plus_tool) bypass
    -- both checks -- they're ground truth, not inferred.
    cabc_cut_confirm_samples      = 2,
    cabc_cut_min_interval         = 0.3,    -- s
    
    -- Runtime smoother time constant (seconds). The shader gain and the
    -- linear backlight value are both ramped toward their per-frame
    -- targets with this time constant, applied every frame, so the two
    -- actuators move together and any residual one-frame latency mismatch
    -- between them is imperceptible. 0 = disabled (direct write).
    cabc_runtime_smooth_tau      = 0.04,

    -- For deltas larger than ~30% of the target value, the smoother uses
    -- base_tau * this scale, so cut-level jumps and gain toggles still
    -- land fast. 1.0 = always use base_tau; 0.05 = near-instant snaps.
    cabc_runtime_cut_tau_scale   = 0.15,

    -- Static fallback targets (0.0 to 1.0)
    inv_tm_brightness     = 0.492531,
    sdr_brightness        = 0.470376,
    jump_to_sdr_on_start  = true,
    remember_sdr_adjustments = false,
    fade                  = true,
    fade_duration         = 0.15,
}

local ctx = {}   -- forward-declared so option callback can reach modules later

-- Forward declaration -- defined below, once mp/msg are in scope. The
-- option callback fires both at config-load time (before this is assigned)
-- and at runtime (after), so it has to be nil-safe.
local apply_hdr_compute_peak_policy

opt.read_options(options, "auto_brightness", function(list)
    if apply_hdr_compute_peak_policy then apply_hdr_compute_peak_policy() end
    if ctx.cabc and ctx.cabc.on_options_updated then ctx.cabc.on_options_updated(list) end
    if ctx.sdr  and ctx.sdr.on_options_updated  then ctx.sdr.on_options_updated(list)  end
end)

-- ── DisplayServices FFI ────────────────────────────────────────────────────
ffi.cdef[[
    int DisplayServicesGetBrightness(uint32_t display, float *brightness);
    int DisplayServicesSetBrightness(uint32_t display, float brightness);
    int DisplayServicesGetLinearBrightness(uint32_t display, float *brightness);
    int DisplayServicesSetLinearBrightness(uint32_t display, float brightness);
    char *realpath(const char *path, char *resolved_path);
    unsigned char *CC_MD5(const void *data, uint32_t len, unsigned char *md);
    int usleep(unsigned int usec);
]]
local ds_ok, ds = pcall(ffi.load,
    "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices")
local b_buf   = ffi.new("float[1]")
local lin_buf = ffi.new("float[1]")
local DISPLAY_ID = 1

-- ── Shared state ──────────────────────────────────────────────────────────
local orig_target_peak       = nil
local saved_hdr_compute_peak = nil
local last_applied_linear = -1
local last_applied_slider = -1

local function invalidate_caches()
    last_applied_linear = -1
    last_applied_slider = -1
end

-- Falls back to sdr_brightness on API failure. That's the value the user
-- configured for desktop-like content; it's a much closer restore target
-- than an arbitrary 0.5, especially when the failure happens right at module
-- init (bl_desktop would then be wrong for the entire session).
local function get_slider_brightness()
    if ds_ok and ds.DisplayServicesGetBrightness(DISPLAY_ID, b_buf) == 0 then
        return b_buf[0]
    end
    return options.sdr_brightness
end

-- The linear brightness coordinate. This is the one CABC writes to; on
-- macOS these are independent of the slider (SetBrightness) path -- a read
-- of the wrong coordinate reflects a stale value and produces a fade that
-- snaps at the first step instead of ramping. sdr.lua uses this to find the
-- fade start point, so the fade begins from what the panel is actually
-- showing rather than from the slider's stale setting.
local function get_linear_brightness()
    if ds_ok and ds.DisplayServicesGetLinearBrightness(DISPLAY_ID, lin_buf) == 0 then
        return lin_buf[0]
    end
    return options.sdr_brightness
end

local function set_linear_brightness(lin, force)
    lin = math.max(0.01, math.min(1.0, lin))
    local min_delta = (options.nits_delta_threshold or 0.25) / options.panel_peak_nits
    if force or math.abs(lin - last_applied_linear) > min_delta then
        last_applied_linear = lin
        if ds_ok then
            ds.DisplayServicesSetLinearBrightness(DISPLAY_ID, lin)
        end
    end
end

local function set_slider_brightness(slider, force)
    slider = math.max(0.0, math.min(1.0, slider))
    if force or math.abs(slider - last_applied_slider) > 0.002 then
        last_applied_slider = slider
        if ds_ok then
            ds.DisplayServicesSetBrightness(DISPLAY_ID, slider)
        end
    end
end

-- Blocking sleep used by sdr.lua for the shutdown fade. mpv does not wait
-- for async callbacks (including mp.add_periodic_timer ticks) once the
-- shutdown event handler returns -- confirmed in testing, the process can
-- exit before a single tick fires. A synchronous usleep loop inside the
-- handler does complete, because mpv waits for the handler body itself.
-- Wrapped in pcall because usleep is technically deprecated in POSIX and a
-- future libSystem could drop it; failing silently degrades to an instant
-- snap rather than an error during shutdown.
local function sleep_us(us)
    if us <= 0 then return end
    pcall(function() ffi.C.usleep(us) end)
end

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
    if (vparams["sig-peak"] or 1) > 1.05 then return true end
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
    return mp.get_property_bool("focused", false)
        and not mp.get_property_bool("idle-active", false)
end

-- ── target-peak sync (shared concern) ─────────────────────────────────────
local function sync_target_peak()
    if not is_hdr_video() then return end
    if not orig_target_peak then
        orig_target_peak = mp.get_property("target-peak")
    end
    mp.set_property_number("target-peak", options.panel_peak_nits)
end

local function restore_target_peak()
    if orig_target_peak then
        mp.set_property("target-peak", orig_target_peak)
        orig_target_peak = nil
    end
end

-- ── hdr-compute-peak policy ───────────────────────────────────────────────
-- Behaviour driven by options.enable_hdr_cabc and
-- options.cabc_force_hdr_compute_peak_off:
--
--   CABC on  + override on  -> hdr-compute-peak=no, user's value saved
--   CABC off + any override -> user's saved value restored
--   override off            -> never touch the property
--
-- Idempotent -- safe to call repeatedly. Only writes on a real state change.
apply_hdr_compute_peak_policy = function()
    local want_off = options.enable_hdr_cabc
        and options.cabc_force_hdr_compute_peak_off

    if want_off then
        if not saved_hdr_compute_peak then
            saved_hdr_compute_peak = mp.get_property("hdr-compute-peak")
        end
        if mp.get_property("hdr-compute-peak") ~= "no" then
            msg.info(string.format(
                "auto_brightness: CABC enabled -- forcing hdr-compute-peak=no (user config was '%s')",
                tostring(saved_hdr_compute_peak)))
            mp.set_property("hdr-compute-peak", "no")
        end
    else
        if saved_hdr_compute_peak then
            msg.info(string.format(
                "auto_brightness: CABC disabled -- restoring hdr-compute-peak='%s'",
                tostring(saved_hdr_compute_peak)))
            mp.set_property("hdr-compute-peak", saved_hdr_compute_peak)
            saved_hdr_compute_peak = nil
        end
    end
end

-- ── Build ctx ─────────────────────────────────────────────────────────────
ctx.options               = options
ctx.mp                    = mp
ctx.msg                   = msg
ctx.utils                 = utils
ctx.ffi                   = ffi
ctx.SCRIPT_DIR            = SCRIPT_DIR
ctx.CACHE_DIR             = CACHE_DIR
ctx.SHADER_PATH           = SHADER_PATH
ctx.pq_to_nits            = pq_to_nits
ctx.is_hdr_video          = is_hdr_video
ctx.is_window_active      = is_window_active
ctx.get_slider_brightness = get_slider_brightness
ctx.get_linear_brightness = get_linear_brightness
ctx.set_linear_brightness = set_linear_brightness
ctx.set_slider_brightness = set_slider_brightness
ctx.invalidate_caches     = invalidate_caches
ctx.sync_target_peak      = sync_target_peak
ctx.restore_target_peak   = restore_target_peak
ctx.sleep_us              = sleep_us
ctx.apply_hdr_compute_peak_policy = apply_hdr_compute_peak_policy

-- ── Load sibling modules ──────────────────────────────────────────────────
local function load_module(name)
    local path = SCRIPT_DIR .. "/" .. name
    local chunk, err = loadfile(path)
    if not chunk then
        msg.error(string.format("auto_brightness: failed to load %s: %s", name, tostring(err)))
        return nil
    end
    local ok, factory = pcall(chunk)
    if not ok then
        msg.error(string.format("auto_brightness: error running %s: %s", name, tostring(factory)))
        return nil
    end
    if type(factory) ~= "function" then
        msg.error(string.format("auto_brightness: %s did not return a factory function", name))
        return nil
    end
    local ok2, mod = pcall(factory, ctx)
    if not ok2 then
        msg.error(string.format("auto_brightness: error constructing %s: %s", name, tostring(mod)))
        return nil
    end
    return mod
end

local cabc = load_module("cabc.lua")
local sdr  = load_module("sdr.lua")
ctx.cabc = cabc
ctx.sdr  = sdr

-- ── Wiring: property observers ────────────────────────────────────────────
local function fan_out()
    if cabc and cabc.on_property_changed then cabc.on_property_changed() end
    if sdr  and sdr.on_property_changed  then sdr.on_property_changed()  end
end

mp.observe_property("video-params",         "native", fan_out)
mp.observe_property("vo-configured",        "bool",   fan_out)
mp.observe_property("focused",              "bool",   fan_out)
mp.observe_property("inverse-tone-mapping", "bool",   fan_out)
mp.observe_property("idle-active",          "bool",   fan_out)

-- ── Wiring: events ────────────────────────────────────────────────────────
-- start-file fires before file-loaded, so the hdr-compute-peak policy is
-- settled before file-loaded's sync_target_peak() / restore_target_peak()
-- and before either module's on_file_loaded reconcile runs. This ordering
-- matters because sync_target_peak reads is_hdr_video(), which can be
-- influenced by properties that hdr-compute-peak populates.
mp.register_event("start-file", function()
    apply_hdr_compute_peak_policy()
end)

mp.register_event("file-loaded", function()
    restore_target_peak()
    sync_target_peak()
    -- sdr first, synchronously, so it can capture the pre-HDR desktop slider
    -- value before CABC's engage path dims the panel. See sdr.on_file_loaded.
    if sdr  and sdr.on_file_loaded  then sdr.on_file_loaded()  end
    if cabc and cabc.on_file_loaded then cabc.on_file_loaded() end
end)

mp.register_event("end-file", function()
    if cabc and cabc.on_session_end then cabc.on_session_end() end
    if sdr  and sdr.on_session_end  then sdr.on_session_end()  end
end)

mp.register_event("shutdown", function()
    if cabc and cabc.on_shutdown then cabc.on_shutdown() end
    if sdr  and sdr.on_shutdown  then sdr.on_shutdown()  end
    restore_target_peak()
    -- Unconditional restore: whatever hdr-compute-peak was when the script
    -- first forced it off goes back, regardless of what state we're in.
    if saved_hdr_compute_peak then
        mp.set_property("hdr-compute-peak", saved_hdr_compute_peak)
        saved_hdr_compute_peak = nil
    end
end)

-- ── Wiring: hotkeys and script messages ───────────────────────────────────
if cabc then
    mp.add_forced_key_binding("Alt+b", "toggle-cabc-hud", cabc.toggle_hud)
    mp.register_script_message("toggle-cabc-hud", cabc.toggle_hud)

    -- Single binding. mpv's key parser is case-insensitive on modifier
    -- names, so "Ctrl+g" and "ctrl+g" name the same physical combo and
    -- registering both would have the second silently overwrite the
    -- first in the input-binding table. The Alt+h / Alt+H pattern is
    -- legitimate because the base key is what differs there.
    mp.add_forced_key_binding("Ctrl+g", "toggle-cabc-gain", cabc.toggle_gain)
    mp.register_script_message("toggle-cabc-gain", cabc.toggle_gain)

    mp.add_forced_key_binding("Alt+[", "cabc-floor-down", function() cabc.adjust_min_nits(-10) end)
    mp.add_forced_key_binding("Alt+]", "cabc-floor-up",   function() cabc.adjust_min_nits( 10) end)
    mp.register_script_message("cabc-floor-down", function() cabc.adjust_min_nits(-10) end)
    mp.register_script_message("cabc-floor-up",   function() cabc.adjust_min_nits( 10) end)

    mp.add_forced_key_binding("Alt+-", "cabc-decay-slower", function() cabc.adjust_decay_rate(-2) end)
    mp.add_forced_key_binding("Alt+=", "cabc-decay-faster", function() cabc.adjust_decay_rate( 2) end)
    mp.register_script_message("cabc-decay-slower", function() cabc.adjust_decay_rate(-2) end)
    mp.register_script_message("cabc-decay-faster", function() cabc.adjust_decay_rate( 2) end)

    mp.add_forced_key_binding("Alt+h", "cabc-toggle-highlights",       cabc.toggle_highlight_mode)
    mp.add_forced_key_binding("Alt+H", "cabc-toggle-highlights-upper", cabc.toggle_highlight_mode)
    mp.register_script_message("cabc-toggle-highlights", cabc.toggle_highlight_mode)

    mp.add_forced_key_binding("Alt+x", "cabc-export-metadata",
        function() cabc.trigger_export(false) end)
    mp.register_script_message("cabc-export-metadata",
        function() cabc.trigger_export(false) end)

    mp.add_forced_key_binding("Alt+l", "cabc-toggle-live", cabc.toggle_live_cabc)
    mp.register_script_message("cabc-toggle-live", cabc.toggle_live_cabc)

    -- Toggle the hdr-compute-peak override at runtime without editing config.
    local function toggle_peak_override()
        options.cabc_force_hdr_compute_peak_off =
            not options.cabc_force_hdr_compute_peak_off
        apply_hdr_compute_peak_policy()
        mp.osd_message(string.format(
            "CABC hdr-compute-peak override: %s",
            options.cabc_force_hdr_compute_peak_off
                and "forced OFF while CABC active"
                or "user config respected"), 2.5)
    end
    mp.add_forced_key_binding("Alt+c", "cabc-toggle-peak-override", toggle_peak_override)
    mp.register_script_message("cabc-toggle-peak-override", toggle_peak_override)
end

-- Debug: `script-message auto-brightness-debug` prints player state plus each
-- module's state string. One message, whole picture.
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
    if cabc and cabc.get_state then lines[#lines+1] = "cabc: " .. cabc.get_state() end
    if sdr  and sdr.get_state  then lines[#lines+1] = "sdr: "  .. sdr.get_state()  end
    local shaders = mp.get_property_native("glsl-shaders") or {}
    local shader_list = {}
    for i, s in ipairs(shaders) do shader_list[i] = s end
    lines[#lines+1] = string.format("cabc_shader_path=%s glsl-shaders=[%s]",
        SHADER_PATH, table.concat(shader_list, ", "))
    local s = table.concat(lines, "  |  ")
    msg.info("auto_brightness: " .. s)
    mp.osd_message("auto_brightness: " .. s, 6.0)
end)

if not cabc then
    msg.error("auto_brightness: cabc.lua not loaded -- dynamic backlight disabled")
end
if not sdr then
    msg.error("auto_brightness: sdr.lua not loaded -- static brightness switching disabled")
end

msg.info(string.format("auto_brightness: loaded (cabc=%s, sdr=%s)",
    tostring(cabc ~= nil), tostring(sdr ~= nil)))