--[[
cabc.lua -- Content-Adaptive Backlight Control.

Two modes, one application path:

  Mode A ("curve"): plays back a pre-analyzed per-frame nits series from
  hdr_analyse.py. Every smoothing and conditioning stage is baked into the
  curve at build time: percentile denoise -> cut detection -> input IIR ->
  comfort envelope (rise/decay, snaps at cuts) -> lookahead -> hardware
  smoothing. The runtime frame_timer just samples and applies. Rebuilding
  is cheap (~10 ms for ~100k points) and triggered by any option change
  that would affect the bake, so live tuning works without re-running the
  Python extraction.

  Mode B ("live"): reacts to Dolby Vision RPU / HDR10+ tags via the
  video-out-params observer. Has no future to look at, so the smoothing
  stages that curve mode bakes in are applied at runtime instead:
  percentile -> cut detection -> input IIR -> 60 Hz envelope (rise/decay,
  snaps at confirmed cuts).

Both modes funnel through apply_backlight_and_gain(target_nits), which
computes a gain target and a linear backlight target from ONE nits value
and stores them. A separate step_runtime_smoothing -- called every frame
from the same timer that produces the targets -- ramps the actual shader
gain and backlight value toward those targets. Both actuators are written
in the same tick with the same relative change, so a residual one-frame
latency mismatch between them is a fraction of a percent instead of a
full jump.

Loaded via loadfile() from main.lua. Returns a factory function taking ctx.
]]

return function(ctx)
    local mp      = ctx.mp
    local msg     = ctx.msg
    local utils   = ctx.utils
    local options = ctx.options

    -- ── CABC-local state ──────────────────────────────────────────────────
    local active_cabc     = false
    local cabc_mode       = nil       -- "curve" | "live"
    local last_nits       = 500.0
    local last_gain       = -1.0
    local last_linear_target = -1.0
    local live_hdr_label  = nil
    local cached_initial_nits = nil
    local raw_series      = nil
    local recompute_timer = nil
    local curve           = nil
    local n_points        = 0
    local gain_enabled    = true
    local frame_timer     = nil
    local in_flight_exports = {}

    -- Runtime smoother state. Both actuators are ramped toward their
    -- per-frame targets with a small time constant, so any residual timing
    -- mismatch between the shader write (one-frame latency to visible
    -- output) and the backlight write (immediate) is imperceptible. This
    -- replaces the older estimated-frame-number deferral, which was
    -- unreliable because that property is a time-based estimate rather
    -- than a real swap counter.
    local rt_gain_target  = 1.0
    local rt_gain_current = 1.0
    local rt_linear_target  = 1.0
    local rt_linear_current = 1.0
    local rt_last_step_t = 0.0

    -- One-shot flag so a "CABC engaged but the backlight never moves"
    -- report has a breadcrumb in the log. Set when the HDR gate fires
    -- while CABC is nominally engaged; cleared on full_disengage and on
    -- re-engage.
    local hdr_gate_warned = false

    -- Frame-level cache for ctx.is_hdr_video(). The tick bodies call
    -- apply_backlight_and_gain and step_runtime_smoothing back-to-back,
    -- and both need to check is_hdr_video() for the HDR gate. Without
    -- this cache that's two full property-marshaling reads per 60 Hz
    -- tick. The cache TTL is shorter than one frame at 60 Hz (8 ms vs
    -- 16.7 ms), so it always expires between ticks and a real signal
    -- change can never be masked for longer than one frame.
    local hdr_cache_t = 0.0
    local hdr_cache_v = false
    local HDR_CACHE_TTL = 0.008

    -- Give-up timer for the HDR gate. If the gate stays tripped while
    -- CABC is nominally engaged for longer than HDR_GATE_GIVEUP_S
    -- seconds, disengage entirely rather than idle forever with the
    -- shader attached and a frozen HUD.
    local HDR_GATE_GIVEUP_S = 2.0
    local hdr_gate_timer = nil

    -- Live-mode runtime envelope state. Curve mode bakes its envelope into
    -- the curve, so these are only used when cabc_mode == "live".
    local live_envelope_current = 0.0
    local live_envelope_target  = 0.0
    local live_envelope_is_cut  = false
    local live_envelope_last_t  = 0.0

    -- Live-mode input-conditioning state.
    local live_despike_buf      = {}   -- rolling {t, p} window for percentile
    local live_peak_smoothed    = nil  -- input IIR state
    local live_peak_last_t      = nil
    local live_cut_pending      = 0
    local live_cut_last_time    = 0
    local live_cut_ref          = nil  -- reference value for cut detection

    local show_hud        = options.show_hud
    local live_debug_logged = false

    -- ── HUD overlay ───────────────────────────────────────────────────────
    local overlay = mp.create_osd_overlay("ass-events")
    local last_osd_update_time = 0

    local function make_bar(frac, length, fill_color, track_color)
        length = length or 22
        frac = math.max(0, math.min(1, frac))
        local filled = math.floor(frac * length + 0.5)
        local empty = length - filled
        fill_color = fill_color or "{\\c&H00FF66&}"
        track_color = track_color or "{\\c&H252525&}"
        return fill_color .. string.rep("█", filled) .. track_color .. string.rep("█", empty)
    end

    local function update_osd(nits, gain)
        if not show_hud or not active_cabc then
            overlay:remove()
            return
        end
        local now = mp.get_time()
        if now - last_osd_update_time < (options.osd_update_interval or 0.067) then
            return
        end
        last_osd_update_time = now

        if not nits or nits < 0 then nits = 0 end
        if not gain or gain < 1 then gain = 1 end

        local min_n = math.max(10.0, options.min_panel_nits)
        local max_n = options.panel_peak_nits
        local max_g = max_n / min_n

        local nits_frac = math.max(0, math.min(1, (nits - min_n) / math.max(1.0, max_n - min_n)))
        local bar_nits = make_bar(nits_frac, 22, "{\\c&H00FF66&}", "{\\c&H252525&}")
        local pct = nits_frac * 100

        local gain_frac = math.max(0, math.min(1, (gain - 1.0) / math.max(0.1, max_g - 1.0)))
        local bar_gain = make_bar(gain_frac, 22, "{\\c&H00CCFF&}", "{\\c&H252525&}")

        local db = 20 * math.log10(math.max(gain, 1.0))
        local status_str = gain_enabled and "{\\c&H00FF66&}[Active]" or "{\\c&H0000FF&}[Bypassed]"

        local header
        if cabc_mode == "curve" then
            header = string.format("● HDR Dynamic Backlight [Curve | %d pts | Peak %.0fn]",
                n_points or 0, options.panel_peak_nits)
        elseif cabc_mode == "live" then
            header = string.format("● HDR Dynamic Backlight [%s | Peak %.0fn]",
                live_hdr_label or "Live Dynamic", options.panel_peak_nits)
        else
            header = "● HDR Dynamic Backlight (CABC)"
        end

        local hl_mode = options.preserve_highlights and "Preserve"
            or string.format("Blend %.0f%%avg", (options.avg_nits_weight or 0.3) * 100)

        local ass = {}
        table.insert(ass, "{\\an7\\pos(30,30)\\fnMenlo\\bord2\\shad1\\3c&H000000&\\b1}")
        table.insert(ass, string.format("{\\fs15\\c&H00E5FF&}%s\\N", header))
        table.insert(ass, string.format(
            "{\\fs13\\c&HCCCCCC&}Backlight:  {\\c&HFFFFFF&}%3.0f nits {\\c&H888888&}[%s] {\\c&H00FF66&}%3.0f%%\\N",
            nits, bar_nits, pct))
        table.insert(ass, string.format(
            "{\\fs13\\c&HCCCCCC&}Gain Boost: {\\c&HFFFFFF&}%4.2fx    {\\c&H888888&}(%+4.1fdB)[%s] %s\\N",
            gain, db, bar_gain, status_str))
        table.insert(ass, string.format(
            "{\\fs11\\c&H888888&}Floor %.0fn  Peak %.0fn  Highlights: %s\\N",
            options.min_panel_nits, options.panel_peak_nits, hl_mode))
        table.insert(ass, string.format(
            "{\\fs11\\c&H888888&}CABC Peak: Pct %.0f  Decay %.0fms  Scene %.0f/%.0f dB  Rise %.0fms  Lead %.0fms\\N",
            options.cabc_hdr_peak_percentile or 100.0,
            options.cabc_hdr_peak_decay_rate or 0.0,
            options.cabc_hdr_scene_threshold_low or 5.0,
            options.cabc_hdr_scene_threshold_high or 12.0,
            (options.cabc_rise_tau or 0.15) * 1000,
            (options.cabc_lead_time or 0.15) * 1000))
        table.insert(ass,
            "{\\fs11\\c&H666666&}[Alt+b HUD] [Ctrl+g Gain] [Alt+h Highlights] [Alt+[ / Alt+] Floor] [Alt+- / Alt+= Decay] [Alt+x Export] [Alt+l Live] [Alt+c PeakCalc]")

        overlay.res_x = 1280
        overlay.res_y = 720
        overlay.data = table.concat(ass, "")
        overlay:update()
    end

    -- ── Shader attach/detach ──────────────────────────────────────────────

    -- Single point of truth for every glsl-shader-opts write.
    local function push_shader_opts(gain)
        mp.commandv("change-list", "glsl-shader-opts", "set",
            string.format("cabc_gain=%.4f", gain))
    end

    local function is_shader_present()
        local shaders = mp.get_property_native("glsl-shaders") or {}
        for _, s in ipairs(shaders) do
            if s == ctx.SHADER_PATH then return true end
        end
        return false
    end

    local function attach_shader()
        if not utils.file_info(ctx.SHADER_PATH) then
            msg.error("CABC: shader not found at " .. ctx.SHADER_PATH
                .. " -- CABC will not engage")
            return false
        end
        if not is_shader_present() then
            mp.commandv("change-list", "glsl-shaders", "append", ctx.SHADER_PATH)
        end
        push_shader_opts(1.0)
        last_gain = 1.0000
        return true
    end

    local function detach_shader()
        if is_shader_present() then
            push_shader_opts(1.0)
            mp.commandv("change-list", "glsl-shaders", "remove", ctx.SHADER_PATH)
        end
        last_gain = -1
    end

    mp.observe_property("glsl-shaders", "native", function(_, shaders)
        if not active_cabc or not options.enable_hdr_cabc then return end
        shaders = shaders or {}
        local found = false
        for _, s in ipairs(shaders) do
            if s == ctx.SHADER_PATH then found = true; break end
        end
        if not found then
            if not utils.file_info(ctx.SHADER_PATH) then return end
            mp.commandv("change-list", "glsl-shaders", "append", ctx.SHADER_PATH)
            if last_gain > 0 then
                push_shader_opts(last_gain)
            end
        end
    end)

    -- ── Forward declarations ──────────────────────────────────────────────
    local update_cabc_curve_playback
    local on_live_metadata_update
    local advance_live_envelope
    local engage_curve_mode
    local engage_live_mode
    local disengage_live_mode
    local try_load_curve
    local trigger_metadata_export
    local sample_curve
    local live_metadata_observer
    local time_pos_observer
    local full_disengage

    -- ── Peak-conditioning helpers ─────────────────────────────────────────
    local function windowed_percentile(vals, times, window_s, pct)
        local n = #vals
        if n == 0 then return vals end
        local out = {}
        local win = {}
        for i = 1, n do
            win[#win + 1] = { t = times[i], v = vals[i] }
            while #win > 0 and times[i] - win[1].t > window_s do
                table.remove(win, 1)
            end
            local sorted = {}
            for _, e in ipairs(win) do sorted[#sorted + 1] = e.v end
            table.sort(sorted)
            local idx = math.max(1, math.min(#sorted,
                math.floor(#sorted * pct / 100.0 + 0.5)))
            out[i] = sorted[idx]
        end
        return out
    end

    local function is_confirmed_jump(vals, i, prev_val, threshold_db, confirm_n)
        local n = #vals
        local need = math.min(confirm_n, n - i + 1)
        local hold = 0
        for k = i, math.min(n, i + confirm_n - 1) do
            local v = vals[k]
            if v <= 0 or prev_val <= 0 then break end
            local dk = 20.0 * math.abs(math.log10(v / prev_val))
            if dk >= threshold_db then
                hold = hold + 1
            else
                break
            end
        end
        return hold >= need
    end

    local function iir_smooth(vals, times, is_cut, tau, low_db, high_db)
        local n = #vals
        if n == 0 then return vals end
        local out = {}
        local smoothed = vals[1]
        out[1] = smoothed
        for i = 2, n do
            local dt = math.max(0.001, times[i] - times[i - 1])
            local target = vals[i]
            if is_cut[i] then
                smoothed = target
            else
                local delta_db = 0.0
                if smoothed > 0 and target > 0 then
                    delta_db = 20.0 * math.abs(math.log10(target / smoothed))
                end
                local factor = 0.0
                if high_db > low_db and delta_db > low_db then
                    factor = math.min(1.0, (delta_db - low_db) / (high_db - low_db))
                end
                if factor >= 1.0 then
                    smoothed = target
                else
                    local eff_tau = tau * (1.0 - factor * 0.9)
                    local alpha = 1.0 - math.exp(-dt / math.max(0.0001, eff_tau))
                    smoothed = smoothed + alpha * (target - smoothed)
                end
            end
            out[i] = smoothed
        end
        return out
    end

    -- ── Curve building ────────────────────────────────────────────────────
    local function build_curve_from_raw_series(series, floor_nits, max_nits)
        local n_pts = #series
        if n_pts == 0 then return {} end

        floor_nits = math.max(10.0, floor_nits or 80.0)
        max_nits = math.max(floor_nits + 10.0, max_nits or 500.0)

        local avg_weight   = options.preserve_highlights and 0.0 or (options.avg_nits_weight or 0.3)
        local lead_time    = options.cabc_lead_time or 0.15
        local rise_tau     = options.cabc_rise_tau or 0.15
        local decay_rate   = math.max(1.0, options.cabc_backlight_decay_rate or 10.0)
        -- Hardware-smoothing time constant baked into the curve's final
        -- stage. Raised from 0.035s to 0.06s so the baked curve is slightly
        -- smoother before the runtime smoother touches it; the runtime
        -- smoother then only has to bridge the last few percent of motion,
        -- which keeps per-tick deltas tiny and any residual actuator
        -- mismatch invisible.
        local hw_tau       = 0.06
        local low_db       = options.cabc_hdr_scene_threshold_low  or 5.0
        local high_db      = options.cabc_hdr_scene_threshold_high or 12.0
        local confirm_n    = math.max(1, options.cabc_cut_confirm_samples or 2)
        local input_tau    = (options.cabc_hdr_peak_decay_rate or 0.0) / 1000.0
        local pct          = options.cabc_hdr_peak_percentile or 100.0
        local window_s     = options.despike_window or 0.15

        -- Step 1: extract raw peaks and times
        local raw_p, times = {}, {}
        for i = 1, n_pts do
            local pt = series[i]
            raw_p[i] = pt.p or pt.scene_peak or pt.nits or 203.0
            times[i] = pt.t
        end

        -- Step 2: percentile denoise
        local pct_vals = windowed_percentile(raw_p, times, window_s, pct)

        -- Step 3: cut detection on post-percentile, pre-IIR values
        local is_cut = {}
        local prev_for_cut = pct_vals[1]
        for i = 1, n_pts do
            local this_cut = series[i].cut or false
            if not this_cut and i > 1 and prev_for_cut > 0 and pct_vals[i] > 0 then
                if is_confirmed_jump(pct_vals, i, prev_for_cut, high_db, confirm_n) then
                    this_cut = true
                end
            end
            is_cut[i] = this_cut
            prev_for_cut = pct_vals[i]
        end

        -- Step 4: input IIR
        local iir_vals
        if input_tau > 0 then
            iir_vals = iir_smooth(pct_vals, times, is_cut, input_tau, low_db, high_db)
        else
            iir_vals = pct_vals
        end

        -- Step 5: blend with frame average
        local eff = {}
        for i = 1, n_pts do
            local a = series[i].a or series[i].scene_avg or iir_vals[i]
            eff[i] = (1.0 - avg_weight) * iir_vals[i] + avg_weight * a
        end

        -- Step 6: comfort envelope (rise/decay, snap at cuts)
        local comfort = {}
        local cur = math.max(floor_nits, math.min(max_nits, eff[1]))
        comfort[1] = cur
        for i = 2, n_pts do
            local dt = math.max(0.001, times[i] - times[i - 1])
            local target = math.max(floor_nits, math.min(max_nits, eff[i]))
            if is_cut[i] then
                cur = target
            elseif target > cur then
                local alpha = 1.0 - math.exp(-dt / rise_tau)
                cur = cur + alpha * (target - cur)
            else
                local drop_factor = 10.0 ^ (-(decay_rate * dt) / 20.0)
                cur = math.max(target, cur * drop_factor)
            end
            comfort[i] = cur
        end

        -- Step 7: predictive lookahead
        local ahead = {}
        local k = 1
        for i = 1, n_pts do
            local max_val = comfort[i]
            if k < i then k = i end
            while k <= n_pts and times[k] <= times[i] + lead_time do
                if comfort[k] > max_val then max_val = comfort[k] end
                k = k + 1
            end
            ahead[i] = max_val
        end

        -- Step 8: hardware smoothing
        local hw_cmd = {}
        cur = ahead[1]
        hw_cmd[1] = cur
        for i = 2, n_pts do
            local dt = math.max(0.001, times[i] - times[i - 1])
            local target = ahead[i]
            if target > cur then
                local alpha = 1.0 - math.exp(-dt / hw_tau)
                cur = cur + alpha * (target - cur)
            else
                local drop_factor = 10.0 ^ (-(decay_rate * dt) / 20.0)
                cur = math.max(target, cur * drop_factor)
            end
            hw_cmd[i] = cur
        end

        -- Step 9: output
        local res_curve = {}
        for i = 1, n_pts do
            res_curve[i] = {
                t          = times[i],
                nits       = hw_cmd[i],
                scene_peak = raw_p[i],
                cut        = is_cut[i],
            }
        end
        return res_curve
    end

    local function schedule_curve_recompute()
        if cabc_mode ~= "curve" or not raw_series or #raw_series == 0 then return end
        if recompute_timer then recompute_timer:kill(); recompute_timer = nil end
        recompute_timer = mp.add_timeout(0.15, function()
            recompute_timer = nil
            if cabc_mode ~= "curve" or not raw_series or #raw_series == 0 then return end
            local t0 = mp.get_time()
            curve = build_curve_from_raw_series(raw_series, options.min_panel_nits, options.panel_peak_nits)
            n_points = #curve
            msg.info(string.format("CABC curve recomputed (floor=%.0f, peak=%.0f, decay=%.1f dB/s) in %.2f ms",
                options.min_panel_nits, options.panel_peak_nits, options.cabc_backlight_decay_rate,
                (mp.get_time() - t0) * 1000))
            last_nits = -1
            ctx.invalidate_caches()
            local cur_t = mp.get_property_number("time-pos", 0)
            if cur_t then update_cabc_curve_playback(cur_t) end
        end)
    end

    -- ── MD5 of resolved path (matches hdr_analyse.py's file_md5) ──────────
    local function get_path_md5(path)
        if not path or path == "" then return nil end
        local resolved = path
        local buf = ctx.ffi.new("char[4096]")

        local test_path = path
        if test_path:sub(1, 1) ~= "/" then
            local cwd = mp.get_property("working-directory")
            if cwd and cwd ~= "" then
                test_path = utils.join_path(cwd, test_path)
            end
        end

        local ptr = ctx.ffi.C.realpath(test_path, buf)
        if ptr ~= nil then
            resolved = ctx.ffi.string(ptr)
        else
            resolved = test_path
        end

        local digest = ctx.ffi.new("unsigned char[16]")
        ctx.ffi.C.CC_MD5(resolved, #resolved, digest)
        local hex = {}
        for i = 0, 15 do
            hex[#hex + 1] = string.format("%02x", digest[i])
        end
        return table.concat(hex)
    end

    -- ── Curve sampling ────────────────────────────────────────────────────
    sample_curve = function(t)
        if not curve or n_points == 0 then return nil end
        if t <= curve[1].t then return curve[1].nits end
        if t >= curve[n_points].t then return curve[n_points].nits end

        local low, high = 1, n_points
        while low <= high do
            local mid = math.floor((low + high) / 2)
            local pt = curve[mid]
            if pt.t < t then
                low = mid + 1
            elseif pt.t > t then
                high = mid - 1
            else
                return pt.nits
            end
        end

        local p1 = curve[high] or curve[1]
        local p2 = curve[low] or curve[n_points]
        local dt = p2.t - p1.t
        if dt <= 0.0001 then
            return p1.nits
        end

        local w = (t - p1.t) / dt
        return p1.nits + w * (p2.nits - p1.nits)
    end

    -- ── sRGB EOTF (slider -> linear) ──────────────────────────────────────
    -- hdr_brightness is a slider-space value: that's what the option means,
    -- and what sdr.lua writes when it drives the panel via
    -- SetBrightness. CABC's backlight writes go through
    -- SetLinearBrightness instead, so when gain is disabled and we hand
    -- off to the static HDR brightness, the value needs converting. The
    -- user's panel is driven with target-trc=srgb, so the sRGB EOTF is the
    -- right perceptual-to-linear curve (macOS's slider is close to sRGB
    -- and drifts from a pure 2.2 power law at the bottom end).
    local function srgb_to_linear(c)
        c = math.max(0.0, math.min(1.0, c))
        if c <= 0.04045 then return c / 12.92 end
        return ((c + 0.055) / 1.055) ^ 2.4
    end

    -- ── Cached HDR check ──────────────────────────────────────────────────
    -- See the comment on hdr_cache_t for why this exists. Deliberately
    -- does NOT invalidate eagerly on property changes -- the TTL is short
    -- enough that the next tick after any real change picks up the new
    -- value. Eager invalidation would defeat the purpose.
    local function is_hdr_cached()
        local now = mp.get_time()
        if now - hdr_cache_t < HDR_CACHE_TTL then
            return hdr_cache_v
        end
        hdr_cache_v = ctx.is_hdr_video()
        hdr_cache_t = now
        return hdr_cache_v
    end

    -- ── Application path ──────────────────────────────────────────────────
    -- Computes target gain and target linear backlight from ONE nits value
    -- and stores them for step_runtime_smoothing. Does NOT write to the
    -- shader or the panel directly -- the smoother does, every tick, so the
    -- two actuators move together with the same relative change.
    local function apply_backlight_and_gain(target_nits)
        if not active_cabc or not options.enable_hdr_cabc then return end
        -- Gate on the current video being HDR. Handles the mid-file
        -- hdr -> sdr / hdr -> inv_tm transition (track switch, or
        -- inverse-tone-mapping toggled on) where sdr.lua calls suspend()
        -- but keeps CABC engaged. Without this gate, the next 60 Hz tick
        -- recomputes from the still-live curve/envelope and immediately
        -- overwrites the neutral value suspend() just wrote -- while
        -- sdr.lua is mid-fade on the same linear register. Two writers,
        -- one register.
        --
        -- Engagement is also gated on HDR (see try_engage), so a mismatch
        -- here is a runtime state change, not a stale-cache engage. The
        -- warn below is therefore log-only: the give-up timer's OSD is
        -- the user-visible notification, and it only fires if the
        -- condition actually persists past HDR_GATE_GIVEUP_S. A trip
        -- that self-corrects within that window (brief video-params nil
        -- during a seek, vo reconfigure at a resolution change) stays
        -- silent on-screen.
        if not is_hdr_cached() then
            if active_cabc and not hdr_gate_warned then
                hdr_gate_warned = true
                msg.warn(string.format(
                    "CABC: engaged as %s but is_hdr_video() is false -- "
                    .. "backlight paused, will disengage in %.1fs if not restored",
                    tostring(cabc_mode), HDR_GATE_GIVEUP_S))
            end
            -- Arm the give-up timer once. If the signal comes back before
            -- it fires, the callback re-checks and no-ops.
            if hdr_gate_timer == nil then
                hdr_gate_timer = mp.add_timeout(HDR_GATE_GIVEUP_S, function()
                    hdr_gate_timer = nil
                    if not active_cabc then return end
                    if is_hdr_cached() then return end
                    msg.warn(string.format(
                        "CABC: HDR signal did not return after %.1fs -- disengaging",
                        HDR_GATE_GIVEUP_S))
                    mp.osd_message("CABC: disengaged (no HDR signal)", 3.0)
                    full_disengage(false)
                    if ctx.sdr and ctx.sdr.reset_state then
                        ctx.sdr.reset_state()
                    end
                end)
            end
            return
        end
        hdr_gate_warned = false
        if hdr_gate_timer then
            hdr_gate_timer:kill()
            hdr_gate_timer = nil
        end

        local min_nits = math.max(10.0, options.min_panel_nits)
        target_nits = math.max(min_nits, math.min(options.panel_peak_nits, target_nits))

        local target_gain
        local target_linear

        if gain_enabled then
            -- Normal CABC path: dim backlight to target_nits, boost via
            -- shader. physical_out = target_linear * target_gain * signal
            -- = signal (exact unity), which is the whole point of CABC.
            local max_gain = options.panel_peak_nits / min_nits
            target_gain = math.max(1.0,
                math.min(max_gain, options.panel_peak_nits / math.max(target_nits, 1.0)))
            target_linear = target_nits / options.panel_peak_nits
        else
            -- Gain boost disabled: undo CABC's backlight dimming entirely
            -- and skip the shader compensation, so the panel sits at the
            -- user's static HDR brightness with flat 1.0x gain.
            -- hdr_brightness is slider-space; convert to linear before it
            -- lands in SetLinearBrightness so the result matches what
            -- sdr.lua would set for the same option value.
            target_gain = 1.0
            target_linear = math.max(0.01, srgb_to_linear(options.hdr_brightness or 1.0))
        end

        rt_gain_target = target_gain
        rt_linear_target = target_linear
        last_nits = target_nits

        -- HUD shows targets, not the smoothed intermediates -- the user
        -- wants to see where the controller is heading.
        update_osd(target_linear * options.panel_peak_nits, target_gain)
    end

    -- ── Runtime smoother ──────────────────────────────────────────────────
    -- Moves the actual shader gain and backlight value toward their targets
    -- by a bounded amount per tick. Called every frame from the same timer
    -- that produces the targets, so the two actuators are always applied
    -- in the same tick with the same relative change -- sync is inherent,
    -- not attempted.
    --
    -- Adaptive tau: for small deltas (curve-following during a calm scene),
    -- use the base time constant so motion is smooth. For large deltas
    -- (cut-level jumps or a gain toggle), taper tau aggressively so the
    -- change still lands fast -- snapping at cuts is deliberate, and the
    -- smoother must not undo it.
    local function step_runtime_smoothing()
        -- Required, not defensive: both frame_timer bodies (curve mode's
        -- tick, and advance_live_envelope) call this unconditionally
        -- after their mode-specific update. If apply_backlight_and_gain
        -- returned early due to the HDR gate above, the smoother's
        -- targets are still whatever suspend() last set (neutral 1.0),
        -- and without this gate the smoother would write toward those
        -- on the same linear register sdr.lua is fading. Same two-writers
        -- problem, different wrong value.
        if not is_hdr_cached() then return end

        local now = mp.get_time()
        local dt = now - rt_last_step_t
        if dt <= 0.0 or dt > 0.25 then dt = 1.0 / 60.0 end
        rt_last_step_t = now

        local base_tau = options.cabc_runtime_smooth_tau or 0.04
        local cut_scale = options.cabc_runtime_cut_tau_scale or 0.15

        local function pick_tau(gap, reference)
            local rel = math.abs(gap) / math.max(math.abs(reference), 0.001)
            if rel > 0.30 then
                return base_tau * cut_scale
            end
            return base_tau
        end

        -- Gain ramp
        local dg = rt_gain_target - rt_gain_current
        if math.abs(dg) > 1e-6 then
            local tau = pick_tau(dg, rt_gain_target)
            local alpha = 1.0 - math.exp(-dt / math.max(1e-6, tau))
            rt_gain_current = rt_gain_current + alpha * dg
        else
            rt_gain_current = rt_gain_target
        end

        -- Backlight ramp (linear coordinate)
        local dl = rt_linear_target - rt_linear_current
        if math.abs(dl) > 1e-6 then
            local tau = pick_tau(dl, rt_linear_target)
            local alpha = 1.0 - math.exp(-dt / math.max(1e-6, tau))
            rt_linear_current = rt_linear_current + alpha * dl
        else
            rt_linear_current = rt_linear_target
        end

        -- Apply shader gain. change-list has one-frame latency to the
        -- visible image, but the smoother's per-tick delta is small so the
        -- mismatch with the immediate backlight write is imperceptible.
        if math.abs(rt_gain_current - last_gain) > 1e-4 then
            push_shader_opts(rt_gain_current)
            last_gain = rt_gain_current
        end

        -- Apply backlight
        local delta_linear = (options.nits_delta_threshold or 0.25) / options.panel_peak_nits
        if math.abs(rt_linear_current - last_linear_target) > delta_linear then
            ctx.set_linear_brightness(rt_linear_current, true)
            last_linear_target = rt_linear_current
        end
    end

    -- ── Curve playback ────────────────────────────────────────────────────
    update_cabc_curve_playback = function(t)
        if not ctx.is_window_active() then return end
        if not active_cabc or cabc_mode ~= "curve"
            or not options.enable_hdr_cabc or not t then return end
        local nits = sample_curve(t)
        if not nits then return end
        apply_backlight_and_gain(nits)
    end

    -- ── Live metadata read and apply ──────────────────────────────────────
    on_live_metadata_update = function()
        if not ctx.is_window_active() then return end
        if not active_cabc or cabc_mode ~= "live" or not options.enable_hdr_cabc then return end

        local vo = mp.get_property_native("video-out-params")
        local vp = mp.get_property_native("video-params")
        if not vo and not vp then return end

        local raw_target = nil
        local label = "HDR Live"

        -- 1. HDR10+ dynamic scene tags
        local s_r = (vo and vo["scene-max-r"]) or (vp and vp["scene-max-r"])
        local s_g = (vo and vo["scene-max-g"]) or (vp and vp["scene-max-g"])
        local s_b = (vo and vo["scene-max-b"]) or (vp and vp["scene-max-b"])
        if s_r and s_r > 0 then
            raw_target = math.max(s_r, s_g or 0, s_b or 0)
            label = "HDR10+ Live"
        end

        -- 2. Dolby Vision RPU / live PQ peak
        if not raw_target then
            local is_dv = (vo and vo["colormatrix"] == "dolbyvision")
                or (vp and vp["colormatrix"] == "dolbyvision")
            local pq = (vo and vo["max-pq-y"]) or (vp and vp["max-pq-y"])
            if pq and pq > 0 then
                raw_target = ctx.pq_to_nits(pq)
                label = is_dv and "Dolby Vision Live" or "HDR Dynamic Live"
            end
        end

        -- 3. Fallback: mastering display luminance, then reference white
        if not raw_target or raw_target <= 0 then
            local max_luma = (vo and vo["max-luma"]) or (vp and vp["max-luma"])
            if max_luma and max_luma > 0 then
                raw_target = max_luma
                label = "HDR10 Static"
            else
                raw_target = 203.0
            end
        end

        if not live_debug_logged then
            live_debug_logged = true
            msg.info(string.format(
                "CABC live probe: label=%s target=%.0f | vo.max-pq-y=%s vp.max-pq-y=%s vo.max-luma=%s vo.scene-max-r=%s vo.colormatrix=%s vp.colormatrix=%s",
                label, raw_target,
                tostring(vo and vo["max-pq-y"]),
                tostring(vp and vp["max-pq-y"]),
                tostring(vo and vo["max-luma"]),
                tostring(vo and vo["scene-max-r"]),
                tostring(vo and vo["colormatrix"]),
                tostring(vp and vp["colormatrix"])))
        end

        if label ~= live_hdr_label then
            live_hdr_label = label
            msg.info(string.format("HDR Dynamic Metadata detected: %s (target ~%.0f nits)",
                label, raw_target))
        end

        -- Input conditioning
        local now_t = mp.get_time()
        table.insert(live_despike_buf, { t = now_t, p = raw_target })
        local window_s = options.despike_window or 0.15
        while #live_despike_buf > 0 and (now_t - live_despike_buf[1].t) > window_s do
            table.remove(live_despike_buf, 1)
        end

        local pct = options.cabc_hdr_peak_percentile or 100.0
        local filtered
        if pct < 100.0 and #live_despike_buf > 1 then
            local sorted = {}
            for _, e in ipairs(live_despike_buf) do sorted[#sorted + 1] = e.p end
            table.sort(sorted)
            local idx = math.max(1, math.min(#sorted,
                math.floor(#sorted * pct / 100.0 + 0.5)))
            filtered = sorted[idx]
        else
            filtered = raw_target
            for _, e in ipairs(live_despike_buf) do
                if e.p > filtered then filtered = e.p end
            end
        end

        local high_db = options.cabc_hdr_scene_threshold_high or 12.0
        local confirm_n = math.max(1, options.cabc_cut_confirm_samples or 2)
        local cooldown = options.cabc_cut_min_interval or 0.3
        local is_cut = false
        if live_cut_ref and live_cut_ref > 0 and filtered > 0 then
            local delta_db = 20.0 * math.abs(math.log10(filtered / live_cut_ref))
            if delta_db >= high_db then
                live_cut_pending = live_cut_pending + 1
            else
                live_cut_pending = 0
            end
            if live_cut_pending >= confirm_n and (now_t - live_cut_last_time) >= cooldown then
                is_cut = true
                live_cut_pending = 0
                live_cut_last_time = now_t
            end
        else
            live_cut_pending = 0
        end
        live_cut_ref = filtered

        local input_tau = (options.cabc_hdr_peak_decay_rate or 0.0) / 1000.0
        local low_db = options.cabc_hdr_scene_threshold_low or 5.0
        local smoothed
        if input_tau <= 0 then
            smoothed = filtered
        else
            local prev = live_peak_smoothed or filtered
            if is_cut then
                smoothed = filtered
            else
                local dt = now_t - (live_peak_last_t or now_t)
                if dt <= 0.0001 or dt > 0.5 then dt = 1.0 / 60.0 end
                local delta_db = 0.0
                if prev > 0 and filtered > 0 then
                    delta_db = 20.0 * math.abs(math.log10(filtered / prev))
                end
                local factor = 0.0
                if high_db > low_db and delta_db > low_db then
                    factor = math.min(1.0, (delta_db - low_db) / (high_db - low_db))
                end
                if factor >= 1.0 then
                    smoothed = filtered
                else
                    local eff_tau = input_tau * (1.0 - factor * 0.9)
                    local alpha = 1.0 - math.exp(-dt / math.max(0.0001, eff_tau))
                    smoothed = prev + alpha * (filtered - prev)
                end
            end
        end
        live_peak_smoothed = smoothed
        live_peak_last_t = now_t

        local min_nits = math.max(10.0, options.min_panel_nits)
        live_envelope_target = math.max(min_nits,
            math.min(options.panel_peak_nits, smoothed))
        live_envelope_is_cut = is_cut
    end

    -- ── Live envelope advance (60 Hz) ─────────────────────────────────────
    advance_live_envelope = function()
        if not ctx.is_window_active() then return end
        if not active_cabc or cabc_mode ~= "live" then return end
        if mp.get_property_bool("pause", false) then return end

        local now = mp.get_time()
        local dt = now - live_envelope_last_t
        if dt <= 0.0001 or dt > 0.25 then dt = 1.0 / 60.0 end
        live_envelope_last_t = now

        if live_envelope_is_cut then
            live_envelope_current = live_envelope_target
            live_envelope_is_cut = false
        else
            local target = live_envelope_target
            local cur = live_envelope_current
            if target > cur then
                local tau = math.max(0.0001, options.cabc_rise_tau or 0.15)
                local alpha = 1.0 - math.exp(-dt / tau)
                cur = cur + alpha * (target - cur)
            else
                local rate = math.max(1.0, options.cabc_backlight_decay_rate or 10.0)
                local drop = 10.0 ^ (-(rate * dt) / 20.0)
                cur = math.max(target, cur * drop)
            end
            live_envelope_current = cur
        end

        apply_backlight_and_gain(live_envelope_current)
        step_runtime_smoothing()
    end

    -- ── Engage / disengage ────────────────────────────────────────────────
    engage_curve_mode = function(series_or_curve, curve_path, is_hot_swap)
        if not attach_shader() then return end
        mp.unobserve_property(live_metadata_observer)
        mp.unobserve_property(time_pos_observer)

        raw_series = series_or_curve
        curve = build_curve_from_raw_series(raw_series, options.min_panel_nits, options.panel_peak_nits)
        n_points = #curve
        active_cabc = true
        cabc_mode = "curve"
        live_debug_logged = true
        last_nits = -1
        last_gain = -1.0
        last_linear_target = -1.0
        hdr_gate_warned = false
        if hdr_gate_timer then hdr_gate_timer:kill(); hdr_gate_timer = nil end
        hdr_cache_t = 0.0

        -- Seed the runtime smoother at neutral; the first apply call will
        -- set proper targets from the curve, and the smoother ramps from
        -- 1.0x / full backlight to the current scene over the base tau
        -- (short enough to be imperceptible; avoids a cold-start fade).
        rt_gain_target  = 1.0
        rt_gain_current = 1.0
        rt_linear_target  = 1.0
        rt_linear_current = 1.0
        rt_last_step_t = mp.get_time()

        ctx.invalidate_caches()

        msg.info(string.format("CABC engaged: CURVE mode, %d points from %s (floor=%.0f, peak=%.0f)",
            n_points, curve_path or "memory", options.min_panel_nits, options.panel_peak_nits))

        if is_hot_swap then
            mp.osd_message(string.format("HDR Curve Applied (%d points)", n_points), 3.0)
        end

        local cur_t = mp.get_property_number("time-pos", 0)
        if cur_t then update_cabc_curve_playback(cur_t) end

        mp.observe_property("time-pos", "number", time_pos_observer)

        if frame_timer then frame_timer:kill(); frame_timer = nil end
        frame_timer = mp.add_periodic_timer(1.0 / 60.0, function()
            if not ctx.is_window_active() then return end
            if not active_cabc or cabc_mode ~= "curve" then return end
            if mp.get_property_bool("pause", false) then return end
            local t = mp.get_property_number("time-pos", nil)
            if t then update_cabc_curve_playback(t) end
            step_runtime_smoothing()
        end)
    end

    try_load_curve = function(path, is_hot_swap)
        local finfo = utils.file_info(path)
        local md5 = get_path_md5(path)
        if not md5 then return false end
        local curve_path = ctx.CACHE_DIR .. md5 .. ".curve.json"
        local file = io.open(curve_path, "r")
        if not file then return false end
        local content = file:read("*all")
        file:close()
        local data = utils.parse_json(content)
        if not data then return false end

        if data.src_mtime and data.src_size and finfo then
            if math.abs(data.src_mtime - finfo.mtime) > 1.0 or data.src_size ~= finfo.size then
                msg.warn(string.format(
                    "Cached curve invalid (source modified): size %s vs %s, mtime %.0f vs %.0f",
                    tostring(data.src_size), tostring(finfo.size), data.src_mtime, finfo.mtime))
                os.remove(curve_path)
                os.remove(ctx.CACHE_DIR .. md5 .. ".jsonl")
                return false
            end
        end

        if data.initial_nits then cached_initial_nits = data.initial_nits end
        local raw = data.series or data.curve
        if raw and #raw > 0 then
            local first = raw[1]
            if not (first.p or first.scene_peak or first.nits or first.a) then
                msg.error(string.format(
                    "Cached curve has unrecognized schema: %s -- deleting", curve_path))
                os.remove(curve_path)
                return false
            end
            engage_curve_mode(raw, curve_path, is_hot_swap)
            return true
        end
        return false
    end

    engage_live_mode = function()
        if not attach_shader() then return end
        mp.unobserve_property(live_metadata_observer)
        mp.unobserve_property(time_pos_observer)
        if frame_timer then frame_timer:kill(); frame_timer = nil end

        active_cabc = true
        cabc_mode = "live"
        live_debug_logged = false
        last_nits = -1
        last_gain = -1.0
        last_linear_target = -1.0
        hdr_gate_warned = false
        if hdr_gate_timer then hdr_gate_timer:kill(); hdr_gate_timer = nil end
        hdr_cache_t = 0.0

        -- Reset live-mode runtime state
        live_despike_buf     = {}
        live_peak_smoothed   = nil
        live_peak_last_t     = nil
        live_cut_pending     = 0
        live_cut_last_time   = 0
        live_cut_ref         = nil

        local seed_nits = cached_initial_nits
        if not seed_nits then
            local vo = mp.get_property_native("video-out-params")
            local vp = mp.get_property_native("video-params")
            local max_luma = (vo and vo["max-luma"]) or (vp and vp["max-luma"])
            if max_luma and max_luma > 50 then
                seed_nits = max_luma * 0.35
            else
                seed_nits = 203.0
            end
        end
        seed_nits = math.max(options.min_panel_nits,
            math.min(options.panel_peak_nits, seed_nits))

        live_envelope_current = seed_nits
        live_envelope_target  = seed_nits
        live_envelope_is_cut  = false
        live_envelope_last_t  = mp.get_time()

        -- Seed the runtime smoother at the seed value so the first frame
        -- doesn't ramp from 1.0x / full backlight.
        rt_gain_target  = 1.0
        rt_gain_current = 1.0
        rt_linear_target  = seed_nits / options.panel_peak_nits
        rt_linear_current = seed_nits / options.panel_peak_nits
        rt_last_step_t = mp.get_time()

        ctx.invalidate_caches()

        local vo = mp.get_property_native("video-out-params")
        local vp = mp.get_property_native("video-params")
        local is_dv = (vo and vo["colormatrix"] == "dolbyvision")
            or (vp and vp["colormatrix"] == "dolbyvision")
        local s_r = (vo and vo["scene-max-r"]) or (vp and vp["scene-max-r"])
        local label = "Dolby Vision Live"
        if s_r and s_r > 0 then
            label = "HDR10+ Live"
        elseif not is_dv then
            label = "HDR Dynamic Live"
        end
        live_hdr_label = label

        msg.info(string.format("CABC engaged: LIVE mode (%s, seed=%.0fn)", label, seed_nits))
        mp.osd_message(label, 2.0)

        on_live_metadata_update()
        apply_backlight_and_gain(live_envelope_current)
        step_runtime_smoothing()

        mp.observe_property("video-out-params", "native", live_metadata_observer)
        frame_timer = mp.add_periodic_timer(1.0 / 60.0, advance_live_envelope)
    end

    disengage_live_mode = function()
        mp.unobserve_property(live_metadata_observer)
        mp.unobserve_property(time_pos_observer)
        if frame_timer then frame_timer:kill(); frame_timer = nil end
        active_cabc = false
        cabc_mode = nil
        detach_shader()
        overlay:remove()
        -- Reset smoother and write-gate state. Without this, a pending
        -- smoother tick scheduled before the toggle would fire after
        -- re-engage against the new session's state. full_disengage does
        -- this too, but this function is the other exit path (from
        -- toggle_live_cabc) and must be self-contained -- full_disengage's
        -- early-return on `not active_cabc` means it won't reach the reset
        -- block once this function has cleared active_cabc.
        rt_gain_target      = 1.0
        rt_gain_current     = 1.0
        rt_linear_target    = 1.0
        rt_linear_current   = 1.0
        rt_last_step_t      = 0.0
        last_gain           = -1.0
        last_linear_target  = -1.0
        hdr_gate_warned     = false
        if hdr_gate_timer then hdr_gate_timer:kill(); hdr_gate_timer = nil end
        hdr_cache_t         = 0.0
        ctx.invalidate_caches()
        if ctx.sdr and ctx.sdr.reset_state then
            ctx.sdr.reset_state()
        end
    end

    -- ── Background export ─────────────────────────────────────────────────
    trigger_metadata_export = function(is_auto)
        local path = mp.get_property("path")
        if not path or path == "" then
            if not is_auto then mp.osd_message("No video playing", 2.0) end
            return
        end
        if not ctx.is_hdr_video() then
            if not is_auto then mp.osd_message("Not an HDR video", 2.0) end
            return
        end

        local md5 = get_path_md5(path)
        if not md5 then return end

        if in_flight_exports[md5] then
            if not is_auto then
                mp.osd_message("HDR curve export already in progress for this video...", 2.5)
            end
            return
        end

        local marker_path = ctx.CACHE_DIR .. md5 .. ".failed"

        if is_auto then
            local finfo = utils.file_info(marker_path)
            if finfo and (os.time() - finfo.mtime) < (options.failure_retry_sec or 604800) then
                msg.info(string.format(
                    "Skipping auto-export for %s: recent failure marker exists (%s.failed)",
                    path, md5))
                return
            end
        else
            os.remove(marker_path)
        end

        in_flight_exports[md5] = true
        if not is_auto then
            mp.osd_message("Exporting HDR metadata curve in background...", 3.5)
        end
        msg.info(string.format("%s background HDR curve export for: %s (md5: %s)",
            is_auto and "Auto-triggering" or "Starting", path, md5))

        local script_path = ctx.SCRIPT_DIR .. "/hdr_analyse.py"
        mp.command_native_async({
            name = "subprocess",
            playback_only = false,
            capture_stdout = true,
            capture_stderr = true,
            args = { "python3", "-B", script_path, path, "--force" }
        }, function(success, res, err)
            in_flight_exports[md5] = nil
            if success and res and res.status == 0 then
                msg.info("Background HDR curve export succeeded")
                os.remove(marker_path)
                local cur_path = mp.get_property("path")
                -- Gate on both file identity AND current HDR state. The
                -- export started when the file was HDR, but a mid-export
                -- state change (inv-tm toggle, track switch, metadata
                -- settling) can make is_hdr_video() false by the time
                -- this callback fires. Engaging without the check would
                -- bypass try_engage's HDR gate -- the one call site that
                -- would slip past the entry-point protection and
                -- re-trigger the exact warn/OSD/disengage pattern the
                -- gate was added to prevent.
                if cur_path == path and ctx.is_hdr_video() then
                    local loaded = try_load_curve(path, true)
                    if not loaded and not is_auto then
                        mp.osd_message("HDR curve exported!", 2.5)
                    end
                elseif cur_path == path then
                    msg.info("Video changed HDR state while exporting; cache saved but not applied.")
                else
                    msg.info("Video changed while exporting; cache saved.")
                end
            else
                local err_txt = (res and res.stderr) or err or "Export failed"
                msg.error("Background HDR curve export failed: " .. tostring(err_txt))
                local mf = io.open(marker_path, "w")
                if mf then
                    mf:write(string.format(
                        '{"time": %d, "path": %q, "error": %q}\n',
                        os.time(), path, tostring(err_txt)))
                    mf:close()
                end
                if not is_auto then
                    mp.osd_message("HDR export failed (check terminal/logs)", 3.0)
                end
            end
        end)
    end

    -- ── Shared reapply dispatch ──────────────────────────────────────────
    -- Resets the write gate so the next smoother tick definitely writes,
    -- then re-runs the current mode's update path. The smoother handles
    -- the actual ramp; force_reapply just makes sure nothing stale is
    -- blocking the write.
    local function force_reapply()
        if not active_cabc or not options.enable_hdr_cabc then return end
        last_nits = -1
        last_linear_target = -1
        last_gain = -1
        if cabc_mode == "curve" then
            local t = mp.get_property_number("time-pos", 0)
            if t then update_cabc_curve_playback(t) end
        elseif cabc_mode == "live" then
            on_live_metadata_update()
            live_envelope_current = live_envelope_target
            live_envelope_is_cut  = false
            apply_backlight_and_gain(live_envelope_current)
        end
        -- Snap the smoother to the targets just set by the mode-specific
        -- path above. force_reapply is triggered by explicit user actions
        -- (focus regain, option change, min-nits adjust) where a 40 ms
        -- exponential ramp reads as lag -- the user just asked for this
        -- value and expects it immediately. Compare with the per-tick
        -- smoother path, which stays smooth because it's following the
        -- curve, not responding to an event.
        rt_gain_current   = rt_gain_target
        rt_linear_current = rt_linear_target
        step_runtime_smoothing()
    end

    -- ── Toggles ───────────────────────────────────────────────────────────
    local function toggle_hud()
        show_hud = not show_hud
        if not show_hud then
            overlay:remove()
            mp.osd_message("HDR Diagnostic HUD: OFF", 1.5)
        else
            update_osd(last_nits, last_gain)
            mp.osd_message("HDR Diagnostic HUD: ON", 1.5)
        end
    end

    local function toggle_gain()
        gain_enabled = not gain_enabled
        local effective = 1.0
        if active_cabc and options.enable_hdr_cabc then
            force_reapply()
            -- Read the target, not last_gain (which is the last written
            -- value and lags the smoother by up to one tick).
            effective = rt_gain_target
        else
            effective = (gain_enabled and last_gain and last_gain >= 1.0) and last_gain or 1.0
            push_shader_opts(effective)
            last_gain = effective
        end
        if not active_cabc or not options.enable_hdr_cabc then
            mp.osd_message(string.format(
                "CABC Gain: %s (applies when CABC engages)",
                gain_enabled and "ACTIVE" or "BYPASSED"), 2.0)
        elseif gain_enabled then
            mp.osd_message(string.format("CABC Shader Gain: ACTIVE (%.2fx)", effective), 2.0)
        else
            mp.osd_message("CABC Shader Gain: BYPASSED (1.00x)", 2.0)
        end
        if active_cabc then update_osd(last_nits, effective) end
    end

    local function adjust_min_nits(delta)
        local lo = 20.0
        local hi = math.max(lo + 1.0, options.panel_peak_nits - 50.0)
        options.min_panel_nits = math.max(lo, math.min(hi, options.min_panel_nits + delta))
        mp.osd_message(string.format("CABC Backlight Floor: %.0f nits", options.min_panel_nits), 1.5)
        if cabc_mode == "curve" then
            schedule_curve_recompute()
        end
        force_reapply()
        if active_cabc then update_osd(last_nits, last_gain) end
    end

    local function adjust_decay_rate(delta)
        local cur = options.cabc_backlight_decay_rate or 10.0
        local new_rate = math.max(2.0, math.min(100.0, cur + delta))
        options.cabc_backlight_decay_rate = new_rate
        mp.osd_message(string.format("CABC Backlight Decay: %.1f dB/s", new_rate), 1.5)
        if cabc_mode == "curve" then
            schedule_curve_recompute()
        end
    end

    local function toggle_highlight_mode()
        options.preserve_highlights = not options.preserve_highlights
        if options.preserve_highlights then
            mp.osd_message("Highlights: PRESERVE (100% True Peak)", 2.0)
            msg.info("Highlight Mode: PRESERVE")
        else
            local pct = (options.avg_nits_weight or 0.3) * 100
            mp.osd_message(string.format("Highlights: CONSISTENT (%.0f%% Avg Blended)", pct), 2.0)
            msg.info(string.format("Highlight Mode: CONSISTENT (%.0f%% avg blend)", pct))
        end
        if cabc_mode == "curve" then
            schedule_curve_recompute()
        end
        if active_cabc and options.enable_hdr_cabc and cabc_mode == "live" then
            last_nits = -1
            on_live_metadata_update()
        end
    end

    local function toggle_live_cabc()
        if cabc_mode == "curve" then
            mp.osd_message("HDR Curve Active (Mode A)", 2.5)
            return
        end
        options.enable_live_hdr_cabc = not options.enable_live_hdr_cabc
        options.enable_hdr_cabc = options.enable_live_hdr_cabc
        if options.enable_live_hdr_cabc then
            if ctx.is_hdr_video() and not active_cabc then
                engage_live_mode()
            else
                mp.osd_message("Live Dolby CABC: Enabled", 2.0)
            end
        else
            if active_cabc and cabc_mode == "live" then
                disengage_live_mode()
                mp.osd_message("Live Dolby CABC: Off (Static HDR)", 2.0)
            else
                mp.osd_message("Live Dolby CABC: Disabled", 2.0)
            end
        end
        if ctx.sdr and ctx.sdr.reset_state then
            ctx.sdr.reset_state()
        end
        -- Re-apply the hdr-compute-peak policy now that enable_hdr_cabc has
        -- changed.
        if ctx.apply_hdr_compute_peak_policy then
            ctx.apply_hdr_compute_peak_policy()
        end
    end

    -- ── Observer callbacks ────────────────────────────────────────────────
    live_metadata_observer = function()
        if not ctx.is_window_active() then return end
        if active_cabc and cabc_mode == "live" then
            on_live_metadata_update()
        end
    end

    time_pos_observer = function(_, t)
        if not ctx.is_window_active() then return end
        if not active_cabc or not t then return end
        if cabc_mode == "curve" and mp.get_property_bool("pause", false) then
            update_cabc_curve_playback(t)
        end
    end

    -- ── Public module interface ───────────────────────────────────────────
    local M = {}

    full_disengage = function(clear_curve_data)
        if not active_cabc then return end
        mp.unobserve_property(live_metadata_observer)
        mp.unobserve_property(time_pos_observer)
        if frame_timer then frame_timer:kill(); frame_timer = nil end
        if recompute_timer then recompute_timer:kill(); recompute_timer = nil end
        if hdr_gate_timer then hdr_gate_timer:kill(); hdr_gate_timer = nil end
        active_cabc = false
        cabc_mode = nil
        detach_shader()
        overlay:remove()

        -- Reset runtime smoother and live-mode state
        rt_gain_target  = 1.0
        rt_gain_current = 1.0
        rt_linear_target  = 1.0
        rt_linear_current = 1.0
        rt_last_step_t = 0.0
        live_despike_buf     = {}
        live_peak_smoothed   = nil
        live_peak_last_t     = nil
        live_cut_pending     = 0
        live_cut_last_time   = 0
        live_cut_ref         = nil
        live_envelope_current = 0.0
        live_envelope_target  = 0.0
        live_envelope_is_cut  = false
        live_envelope_last_t  = 0.0
        last_gain = -1.0
        last_linear_target    = -1.0
        -- last_nits and live_hdr_label are not read outside an active
        -- session, but reset them anyway so a mid-session debug dump or
        -- accidental early read doesn't see stale values from a prior file.
        last_nits             = -1
        live_hdr_label        = nil
        hdr_gate_warned       = false
        hdr_cache_t           = 0.0
        if clear_curve_data then
            raw_series = nil
            curve = nil
            n_points = 0
            ctx.invalidate_caches()
            cached_initial_nits = nil
        end
    end

    local function try_engage(is_initial_load)
        if active_cabc or not options.enable_hdr_cabc then return false end
        local path = mp.get_property("path")
        if not path or path == "" then return false end

        -- Gate engagement on the file being reported as HDR *before*
        -- attempting to load and engage a curve. Without this, a stale
        -- cached curve for a file that is not currently HDR (or a file
        -- whose video-params hasn't settled yet) would engage, trip the
        -- apply-time HDR gate, arm the give-up timer, disengage, and
        -- then re-engage on the next property fan-out -- a warn/OSD/
        -- disengage loop for as long as whatever signal is flapping
        -- keeps flapping. The apply-time gate is still required as a
        -- runtime safety net (display state can change mid-file), but
        -- it should never be the *first* line of defense.
        --
        -- Cost of gating here: if video-params hasn't populated at the
        -- initial load instant (hwdec settling, mpv's HDR detection
        -- lagging), the first try_engage skips. A subsequent property
        -- change on video-params / vo-configured fires
        -- on_property_changed, which calls try_engage(false) and gets a
        -- second chance. Same retry path that already exists for the
        -- live-mode fallback.
        if not ctx.is_hdr_video() then
            if is_initial_load then
                msg.info(string.format(
                    "CABC: engage skipped for %s -- not reported as HDR yet",
                    path))
            end
            return false
        end

        local loaded_curve = try_load_curve(path, false)
        if is_initial_load then
            msg.info(string.format("CABC: on_file_loaded path=%s hdr=%s curve_loaded=%s",
                path, tostring(ctx.is_hdr_video()), tostring(loaded_curve)))
        end

        if not loaded_curve and options.enable_live_hdr_cabc then
            engage_live_mode()
        end

        if is_initial_load and not loaded_curve and options.auto_export_hdr_curve then
            trigger_metadata_export(true)
        end
        return loaded_curve
    end

    function M.on_file_loaded()
        full_disengage(true)
        live_debug_logged = false

        local path = mp.get_property("path")
        if not path or path == "" or not options.enable_hdr_cabc then
            msg.info("CABC: skipping (no path or disabled)")
            return
        end

        try_engage(true)
    end

    function M.on_property_changed()
        if not options.enable_hdr_cabc then return end
        if not ctx.is_window_active() then return end
        if not active_cabc then
            try_engage(false)
            return
        end
        if cabc_mode == "curve" then
            local t = mp.get_property_number("time-pos", 0)
            if t then update_cabc_curve_playback(t) end
        elseif cabc_mode == "live" then
            on_live_metadata_update()
        end
    end

    function M.on_session_end()
        full_disengage(true)
    end

    function M.on_options_updated(list)
        if not list then return end
        if list["panel_peak_nits"] or list["min_panel_nits"]
            or list["avg_nits_weight"] or list["preserve_highlights"] ~= nil
            or list["cabc_hdr_peak_percentile"] ~= nil
            or list["cabc_hdr_peak_decay_rate"] ~= nil
            or list["cabc_hdr_scene_threshold_low"] ~= nil
            or list["cabc_hdr_scene_threshold_high"] ~= nil
            or list["cabc_lead_time"] ~= nil
            or list["cabc_rise_tau"] ~= nil
            or list["cabc_backlight_decay_rate"] ~= nil
            or list["cabc_cut_confirm_samples"] ~= nil
            or list["cabc_cut_min_interval"] ~= nil
            or list["despike_window"] ~= nil
            or list["hdr_brightness"] ~= nil then
            if cabc_mode == "curve" then
                schedule_curve_recompute()
            end
            force_reapply()
            if active_cabc then update_osd(last_nits, last_gain) end
        end
    end

    function M.on_shutdown()
        full_disengage(false)
    end

    function M.reapply_current()
        if not active_cabc or not options.enable_hdr_cabc then return end
        ctx.invalidate_caches()
        force_reapply()
    end

    function M.suspend()
        if not active_cabc then return end
        if last_gain ~= 1.0 then
            push_shader_opts(1.0)
            last_gain = 1.0
        end
        -- sdr.lua takes over the backlight write from here. Reset the
        -- smoother's state so re-engage from a transient doesn't ramp
        -- from a stale value, and read the panel's current linear value
        -- so if reapply_current runs before sdr's fade finishes, the
        -- smoother starts from where the panel actually is.
        --
        -- Deliberately does NOT cancel hdr_gate_timer or clear
        -- hdr_gate_warned/hdr_cache_t. Timeline: sdr.lua's state machine
        -- detects is_hdr_video() went false and calls this function;
        -- apply_backlight_and_gain runs independently off the 60 Hz
        -- frame_timer reacting to the same signal, so it can arm the
        -- give-up timer on some tick *before* sdr's property-changed
        -- handler gets here. If that timer is armed and stays armed, it
        -- will fire ~HDR_GATE_GIVEUP_S later and call full_disengage,
        -- which is exactly what we want: without it, a suspend() that
        -- is never followed by reapply_current (video stays in inv_tm
        -- for the rest of the file) would leave the shader permanently
        -- attached at a no-op 1.0x gain and the 60 Hz frame_timer
        -- polling for nothing until the file ends. The give-up timer
        -- surviving suspend() is the only thing that eventually tears
        -- that down. Do not add a timer-cancel here for tidiness.
        rt_gain_target     = 1.0
        rt_gain_current    = 1.0
        rt_linear_target   = 1.0
        rt_linear_current  = ctx.get_linear_brightness()
        rt_last_step_t     = mp.get_time()
        last_linear_target = -1.0
        overlay:remove()
    end
    
    function M.get_state()
        local extra = ""
        if cabc_mode == "live" then
            extra = string.format(" env_cur=%.0f env_tgt=%.0f",
                live_envelope_current, live_envelope_target)
        end
        return string.format("active=%s mode=%s gain_enabled=%s nits=%.0f gain=%.3f%s",
            tostring(active_cabc), tostring(cabc_mode),
            tostring(gain_enabled), last_nits, last_gain, extra)
    end

    M.toggle_hud            = toggle_hud
    M.toggle_gain           = toggle_gain
    M.adjust_min_nits       = adjust_min_nits
    M.adjust_decay_rate     = adjust_decay_rate
    M.toggle_highlight_mode = toggle_highlight_mode
    M.trigger_export        = trigger_metadata_export
    M.toggle_live_cabc      = toggle_live_cabc

    return M
end