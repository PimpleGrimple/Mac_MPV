local msg = require("mp.msg")

local cfg = {
	default_state = false,   -- true: auto-skip is on when mpv starts, false: off (toggle with \)
	skip_mode = "speed",     -- "speed": fast-forward through gaps, "seek": jump to the next subtitle
	min_skip_interval = 1.5, -- seconds; gaps shorter than this are not skipped
	speed_skip_speed = 2.5,  -- playback speed used during gaps in "speed" mode
	lead_in = 0,             -- seconds to wait after a subtitle ends before speeding up
	lead_out = 1.4           -- seconds before the next subtitle to return to normal speed
}
require("mp.options").read_options(cfg, nil)

if cfg.skip_mode ~= "speed" and cfg.skip_mode ~= "seek" then
	msg.warn("skip_mode must be \"speed\" or \"seek\", got \"" .. tostring(cfg.skip_mode) .. "\"; using \"speed\"")
	cfg.skip_mode = "speed"
end
cfg.speed_skip_speed = math.max(0.1, math.min(100, cfg.speed_skip_speed))
cfg.min_skip_interval = math.max(cfg.min_skip_interval, 0)

local active = cfg.default_state
local seek_skip = cfg.skip_mode == "seek"

local skipping = false
local sped_up = false
local last_sub_end, next_sub_start
local is_processing = false
local last_poll = 0
local POLL_INTERVAL = 0.5 -- seconds (wall clock) between next-sub lookups when none is known yet

function calc_next_delay()
	local was_visible = mp.get_property_bool("sub-visibility")
	if was_visible then
		mp.set_property_bool("sub-visibility", false)
	end

	local initial_delay = mp.get_property_number("sub-delay")

	mp.commandv("sub-step", "1")
	local new_delay = mp.get_property_number("sub-delay")
	mp.set_property_number("sub-delay", initial_delay)

	if was_visible then
		mp.set_property_bool("sub-visibility", true)
	end

	if new_delay == initial_delay then return nil
	else return -(new_delay - initial_delay) end
end

-- ==========================================
-- SPEED SKIP (mostly) - ORIGINAL BEN KERMAN
-- ==========================================
local initial_speed
local initial_video_sync

function handle_tick(_, time_pos)
	if time_pos == nil or not last_sub_end then return end

	if not sped_up then
		if time_pos > last_sub_end + cfg.lead_in then
			initial_speed = mp.get_property_number("speed")
			initial_video_sync = mp.get_property("video-sync")
			mp.set_property("video-sync", "desync")
			mp.set_property_number("speed", cfg.speed_skip_speed)
			sped_up = true
		end
	elseif next_sub_start == nil then
		-- next sub not known yet: look again, but not on every tick
		local now = mp.get_time()
		if now - last_poll < POLL_INTERVAL then return end
		last_poll = now
		local next_delay = calc_next_delay()
		if next_delay ~= nil then
			next_sub_start = time_pos + next_delay
		end
	elseif time_pos > next_sub_start - cfg.lead_out then
		end_skip()
	end
end

function start_skip()
	skipping = true
	last_poll = 0
	mp.observe_property("time-pos", "number", handle_tick)
end

function end_skip()
	mp.unobserve_property(handle_tick)
	-- only touch speed/video-sync if this script actually changed them
	if sped_up then
		mp.set_property_number("speed", initial_speed)
		mp.set_property("video-sync", "audio")
		mp.set_property("video-sync", initial_video_sync)
	end
	skipping = false
	sped_up = false
	last_sub_end, next_sub_start = nil, nil
end

-- ==========================================
-- MAIN SUBTITLE TRACKER
-- ==========================================
function handle_sub_change(_, sub_end)
	if mp.get_property_number('sid', -1) == -1 then return end

	-- PURE INSTANT SEEK
	if not sub_end and seek_skip then
		if not is_processing then
			is_processing = true
			-- don't bother seeking across gaps shorter than the minimum interval
			local delay = calc_next_delay()
			if delay and delay >= cfg.min_skip_interval then
				mp.command("no-osd sub-seek 1")
			end
			mp.add_timeout(0.3, function() is_processing = false end)
		end
		return
	end

	-- ORIGINAL BEN KERMAN SPEED SKIP LOGIC
	if not sub_end and not skipping then
		local time_pos = mp.get_property_number("time-pos")
		if not time_pos then return end

		local next_delay = calc_next_delay()
		if next_delay ~= nil and next_delay < cfg.min_skip_interval then return end

		last_sub_end = time_pos
		next_sub_start = next_delay and (time_pos + next_delay) or nil
		start_skip()
	elseif skipping and sub_end then
		end_skip()
	end
end

-- track switched or subs turned off mid-skip: restore speed
function handle_sid_change()
	if skipping then end_skip() end
end

function activate()
	mp.observe_property("sub-end", "number", handle_sub_change)
	mp.observe_property("sid", "native", handle_sid_change)
	active = true
end

function deactivate()
	end_skip()
	mp.unobserve_property(handle_sub_change)
	mp.unobserve_property(handle_sid_change)
	active = false
end

if active then activate() end

-- file ended/changed or manual seek during a speed skip: end it cleanly
mp.register_event("end-file", function()
	if skipping then end_skip() end
end)
mp.register_event("seek", function()
	if skipping then end_skip() end
end)

-- ==========================================
-- HOTKEY CONFIGURATIONS
-- ==========================================
function toggle_script()
	if active then
		deactivate()
		mp.osd_message("Auto Sub-Skip: OFF")
	else
		activate()
		mp.osd_message("Auto Sub-Skip: ON")
	end
end
mp.add_key_binding("\\", "toggle", toggle_script)

function switch_mode()
	seek_skip = not seek_skip
	mp.osd_message("Seek skip " .. (seek_skip and "enabled" or "disabled"))
end
mp.add_key_binding("|", "switch-mode", switch_mode)
