--[[
sdr.lua -- desktop / SDR / inverse-tone-mapped / HDR static brightness
state machine.

Owns exactly one job: switching the baseline display brightness between
desktop / SDR / inverse-tone-mapped / HDR state, and correctly restoring
desktop brightness on focus loss, going idle, file/playlist transitions, and
mpv shutdown.

For HDR, the state machine defers to CABC when CABC is enabled (which owns
the actual per-scene value), and applies options.hdr_brightness when CABC is
disabled. It never writes the panel directly while CABC is engaged, leaving
CABC as the sole owner of the brightness value during dynamic HDR playback.

Hands off to CABC explicitly:
  entering HDR (CABC enabled)  ->  ctx.cabc.reapply_current()
  leaving HDR (any reason)     ->  ctx.cabc.suspend()

Write-path policy (this is what fixes the flicker):

DisplayServices exposes two control paths -- SetBrightness (the user-facing
slider) and SetLinearBrightness (a linear-luminance coordinate). On macOS
they are independent: writing one does not update the other's register, and
writing the same numeric value to both produces two different visual
brightnesses. Writing both per fade step (as an earlier version did)
alternates the panel between the two interpretations and reads as flicker:
dim, flash, dim, flash.

So: only ONE path is written per step, chosen by which one controls the
panel in the state we are leaving. From HDR with CABC active, CABC has been
driving via linear -- fade via linear, using the linear-coordinate desktop
value captured at module init. In every other state, slider is the driver --
fade via slider, using the slider-coordinate desktop value.

Fade policy on restore:
  - normal transitions (focus loss/regain, state changes, end-file that
    keeps the window open): non-blocking fade via mp.add_periodic_timer,
    so the event loop isn't held.
  - shutdown: blocking fade via ctx.sleep_us in a tight loop, because mpv
    does not wait for async timer callbacks once the shutdown handler
    returns.
]]

return function(ctx)
    local mp      = ctx.mp
    local options = ctx.options

    local bl_state         = nil      -- nil ("desktop") | "hdr" | "inv_tm" | "sdr"
    local bl_current_sdr   = options.sdr_brightness
    local bl_current_invtm = options.inv_tm_brightness
    local bl_fade_timer    = nil

    -- Capture both the slider and linear register values at module init,
    -- before any file has loaded and before CABC exists to touch the panel.
    -- These are the only reliable reads of the user's desktop brightness --
    -- during HDR playback, the slider and linear control paths report
    -- independently and neither reflects what the user set at the desktop.
    --
    -- Both coordinates are captured because CABC drives the panel via the
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
    local bl_desktop = ctx.get_slider_brightness()
    if bl_desktop and bl_desktop > 0.999 then
        bl_desktop = options.sdr_brightness
    end

    local bl_desktop_lin = ctx.get_linear_brightness()
    if not bl_desktop_lin or bl_desktop_lin <= 0.0 then
        -- Linear read failed (DisplayServicesGetLinearBrightness absent or
        -- returning 0). Falling back to the slider value is not physically
        -- correct, but it's strictly better than nil and this path only
        -- triggers on systems where the linear API is broken anyway.
        bl_desktop_lin = bl_desktop or options.sdr_brightness
    end

    -- ── Write-path selection ──────────────────────────────────────────────
    -- The write path is passed EXPLICITLY by every call site, as a boolean.
    -- The previous version inferred it from the outgoing state name, which
    -- caused the reported bug: when leaving HDR, `from_state == "hdr"`
    -- selected the linear write path, but the caller was still passing
    -- `bl_desktop` (a slider-space value). An explicit boolean makes that
    -- mismatch impossible to reintroduce.
    local function bl_write(v, use_linear)
        if use_linear then
            ctx.set_linear_brightness(v, true)
        else
            ctx.set_slider_brightness(v, true)
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
        local steps = 8
        local step_us = math.max(1, math.floor(duration * 1000000 / steps))
        for i = 1, steps do
            bl_write(start + (target - start) * (i / steps), use_linear)
            if i < steps then
                ctx.sleep_us(step_us)
            end
        end
    end

    -- ── State machine ─────────────────────────────────────────────────────
    -- Returns (target, state). `target` is `true` (sentinel) for the "hdr"
    -- state when CABC is enabled and will own the actual value; it's a real
    -- slider value (options.hdr_brightness) when CABC is disabled and this
    -- module has to set the panel itself.
    local function bl_get_target()
        if ctx.is_hdr_video() then
            if options.enable_hdr_cabc then
                return true, "hdr"                    -- CABC owns the value
            end
            return options.hdr_brightness, "hdr"     -- static HDR fallback
        elseif mp.get_property_bool("inverse-tone-mapping", false) then
            return bl_current_invtm, "inv_tm"
        elseif options.jump_to_sdr_on_start then
            return bl_current_sdr, "sdr"
        end
        return nil, "desktop"
    end

    -- Notify CABC that the panel is about to stop being under its control.
    -- Without this, CABC's last shader gain stays on the pipeline while the
    -- backlight reverts to desktop, producing a visibly wrong image if the
    -- mpv window is still visible (e.g. unfocused behind another app on a
    -- single display). CABC.suspend() resets gain to 1.0 but keeps the
    -- shader attached and the module engaged, so re-entering HDR is cheap.
    local function notify_cabc_leave_hdr()
        if ctx.cabc and ctx.cabc.suspend then ctx.cabc.suspend() end
    end

    -- Apply the "hdr" target. If `target` is the sentinel `true`, CABC owns
    -- it and we just prompt it to reapply. If it's a real value, CABC is
    -- disabled and we set the panel ourselves via the slider path.
    local function apply_hdr_target(target, fade)
        if target == true then
            if bl_fade_timer then bl_fade_timer:kill(); bl_fade_timer = nil end
            ctx.invalidate_caches()
            if ctx.cabc and ctx.cabc.reapply_current then
                ctx.cabc.reapply_current()
            end
        else
            -- Static HDR fallback (CABC disabled): slider path.
            bl_set(target, fade, false)
        end
    end

    -- mode: "instant" | "async_fade" | "blocking_fade"
    local function bl_restore(mode)
        local from = bl_state
        if from == "sdr" and options.remember_sdr_adjustments then
            bl_current_sdr = ctx.get_slider_brightness()
        end
        if from == "hdr" then
            notify_cabc_leave_hdr()
        end

        -- Write path and target coordinate must agree. Leaving HDR with
        -- CABC engaged is the only case that needs linear; every other
        -- state drives via the slider register.
        local use_linear = (from == "hdr" and options.enable_hdr_cabc)
        local target
        if use_linear then
            target = bl_desktop_lin
        else
            target = bl_desktop
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
        bl_state = nil
    end

    local function bl_update_now()
        local target, target_state = bl_get_target()

        if not ctx.is_window_active() then
            target, target_state = nil, "desktop"
        end

        if target then
            if not bl_state then
                -- Entering a managed state from desktop.
                --
                -- For non-HDR states (sdr/inv_tm), refresh bl_desktop from
                -- the panel: the panel is at desktop at this moment, so the
                -- read is reliable, and this respects any manual brightness
                -- change the user made while we were at desktop.
                --
                -- For HDR, do NOT re-read. By the time this reconcile runs,
                -- CABC may already have dimmed the panel (via the engage
                -- path triggered on file-loaded), so a read would capture
                -- CABC's dim value rather than the user's real desktop
                -- brightness. The module-init captures above are the
                -- authoritative values for HDR.
                if target_state ~= "hdr" then
                    local captured = ctx.get_slider_brightness()
                    if captured and captured <= 0.999 then
                        bl_desktop = captured
                    end
                end

                if target_state == "hdr" then
                    apply_hdr_target(target, false)
                else
                    bl_set(target, false, false)
                end
                bl_state = target_state
            elseif bl_state ~= target_state then
                -- Managed-state-to-managed-state transition without passing
                -- through desktop (e.g. HDR file ends, SDR file starts next).
                -- Instant, no fade. `bl_state` is still the outgoing state
                -- here -- bl_set / apply_hdr_target use it for
                -- notify_cabc_leave_hdr and write-path selection before we
                -- overwrite it at the end of the block.
                local leaving_hdr = (bl_state == "hdr")
                if bl_state == "sdr" and options.remember_sdr_adjustments then
                    bl_current_sdr = ctx.get_slider_brightness()
                end
                if target_state == "sdr"    then target = bl_current_sdr    end
                if target_state == "inv_tm" then target = bl_current_invtm end

                if leaving_hdr then
                    notify_cabc_leave_hdr()
                end

                if target_state == "hdr" then
                    apply_hdr_target(target, false)
                else
                    -- sdr/inv_tm targets are slider-coordinate values, and
                    -- the destination state drives via the slider register,
                    -- so write path and value agree.
                    bl_set(target, false, false)
                end
                bl_state = target_state
            else
                -- Same state name -- but the target may have changed from the
                -- sentinel to a real value or vice versa (e.g. user toggled
                -- live CABC mid-playback without changing file). Re-run the
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
    -- state" branch. Used when CABC toggles on/off mid-playback: the state
    -- name ("hdr") doesn't change, but the target source does (sentinel vs
    -- options.hdr_brightness), and the normal `bl_state == target_state`
    -- short-circuit would skip the reapply.
    function M.reset_state()
        bl_state = nil
        M.update_now()
    end

    function M.on_file_loaded()
        -- Synchronous: main.lua calls this before cabc.on_file_loaded()
        -- so the HDR-state decision (ours vs CABC's) is made before anything
        -- dims the panel.
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
        if list["sdr_brightness"] then
            bl_current_sdr = options.sdr_brightness
            if bl_state == "sdr" and not options.remember_sdr_adjustments then
                bl_set(bl_current_sdr, false, false)
            end
        end
        if list["inv_tm_brightness"] then
            bl_current_invtm = options.inv_tm_brightness
            if bl_state == "inv_tm" then
                bl_set(bl_current_invtm, false, false)
            end
        end
        if list["hdr_brightness"] and not options.enable_hdr_cabc then
            if bl_state == "hdr" then
                bl_set(options.hdr_brightness, false, false)
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
            "state=%s desktop_saved=%s desktop=%.3f desktop_lin=%.3f sdr=%.3f invtm=%.3f hdr=%.3f cabc=%s",
            tostring(bl_state),
            tostring(bl_desktop ~= nil),
            bl_desktop or 0.0, bl_desktop_lin or 0.0,
            bl_current_sdr, bl_current_invtm, options.hdr_brightness,
            tostring(options.enable_hdr_cabc))
    end

    return M
end