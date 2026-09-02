-- Save inside ~/mpv-scripts/subskip.lua
-- FINAL: Flawless Original Speed + Pure Instant Seek

local cfg = {
	default_state = false,
	seek_mode_default = false,
	min_skip_interval = 3,
	speed_skip_speed = 2.5,
	lead_in = 0,
	lead_out = 1,
	speed_skip_speed_delta = 0.1,
	min_skip_interval_delta = 0.25
}
require("mp.options").read_options(cfg, nil, function(changes)
	if changes.default_state then toggle_script() end
	if changes.seek_mode_default then switch_mode() end
	if changes.min_skip_interval then set_min_interval(cfg.min_skip_interval) end
	if changes.speed_skip_speed then set_speed_skip_speed(cfg.speed_skip_speed) end
end)

local active = cfg.default_state
local seek_skip = cfg.seek_mode_default
local cache_path = mp.command_native({"expand-path", "~~/cache/scripts/mpv_subskip_mode.txt"})

-- Ensure cache directory exists
local dir = cache_path:match("(.*[/\\])")
if dir then
	local platform = mp.get_property_native("platform")
	if platform == "windows" then
		os.execute('mkdir "' .. dir:gsub("/", "\\") .. '" 2>nul')
	else
		os.execute('mkdir -p "' .. dir .. '"')
	end
end

-- Load persisted seek_skip state on startup
local f_init = io.open(cache_path, "r")
if f_init then
	local content = f_init:read("*a")
	f_init:close()
	if content then
		content = content:gsub("%s+", "")
		if content == "seek" or content == "instant" or content == "true" then
			seek_skip = true
		elseif content == "speed" or content == "false" then
			seek_skip = false
		end
	end
end

local skipping = false
local sped_up = false
local last_sub_end, next_sub_start
local is_processing = false

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
local initial_speed = mp.get_property_number("speed")
local initial_video_sync = mp.get_property("video-sync")

function handle_tick(_, time_pos)
	if time_pos == nil then return end

	if not sped_up and time_pos > last_sub_end + cfg.lead_in then
		initial_speed = mp.get_property_number("speed")
		initial_video_sync = mp.get_property("video-sync")
		mp.set_property("video-sync", "desync")
		mp.set_property_number("speed", cfg.speed_skip_speed)
		sped_up = true
	elseif sped_up and next_sub_start == nil then
		local next_delay = calc_next_delay()
		if next_delay ~= nil then
			next_sub_start = time_pos + next_delay
		end
	elseif sped_up and time_pos > next_sub_start - cfg.lead_out then
		end_skip()
	end
end

function start_skip()
	skipping = true
	mp.observe_property("time-pos", "number", handle_tick)
end

function end_skip()
	mp.unobserve_property(handle_tick)
	skipping = false
	sped_up = false
	mp.set_property_number("speed", initial_speed)
	mp.set_property("video-sync", "audio")
	mp.set_property("video-sync", initial_video_sync)
	last_sub_end, next_sub_start = nil
end

-- ==========================================
-- MAIN SUBTITLE TRACKER
-- ==========================================
function handle_sub_change(_, sub_end)
	if mp.get_property_number('sid', -1) == -1 then return end

	-- YOUR PURE INSTANT SEEK BYPASS
	if not sub_end and seek_skip then
		if not is_processing then
			is_processing = true
			mp.command("no-osd sub-seek 1")
			mp.add_timeout(0.3, function() is_processing = false end)
		end
		return
	end

	-- ORIGINAL BEN KERMAN SPEED SKIP LOGIC
	if not sub_end and not skipping then
		local time_pos = mp.get_property_number("time-pos")
		local next_delay = calc_next_delay()

		if not time_pos then
			last_sub_end = -cfg.lead_in
		else
			last_sub_end = time_pos
		end
		
		if next_delay ~= nil then
			if next_delay < cfg.min_skip_interval then return
			else next_sub_start = time_pos + next_delay end
		end
		start_skip()
	elseif skipping and sub_end then 
		end_skip() 
	end
end

function activate()
	mp.observe_property("sub-end", "number", handle_sub_change)
	active = true
end

function deactivate()
	end_skip()
	mp.unobserve_property(handle_sub_change)
	active = false
end

if active then activate() end

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
	
	local f = io.open(cache_path, "w")
	if f then
		f:write(seek_skip and "seek" or "speed")
		f:close()
	end
end
mp.add_key_binding("|", "switch-mode", switch_mode)

function set_speed_skip_speed(new_value)
	cfg.speed_skip_speed = new_value
	if skipping then mp.set_property_number("speed", new_value) end
	mp.osd_message("Skip speed: " .. new_value)
end
mp.add_key_binding("Ctrl+Alt+[", "decrease-speed", function()
	set_speed_skip_speed(cfg.speed_skip_speed - cfg.speed_skip_speed_delta)
end, {repeatable = true})

mp.add_key_binding("Ctrl+Alt+]", "increase-speed", function()
	set_speed_skip_speed(cfg.speed_skip_speed + cfg.speed_skip_speed_delta)
end, {repeatable = true})

function set_min_interval(new_value)
	cfg.min_skip_interval = new_value
	mp.osd_message("Minimum interval: " .. new_value)
end
mp.add_key_binding("Ctrl+Alt+-", "decrease-interval", function()
	set_min_interval(cfg.min_skip_interval - cfg.min_skip_interval_delta)
end, {repeatable = true})

mp.add_key_binding("Ctrl+Alt++", "increase-interval", function()
	set_min_interval(cfg.min_skip_interval + cfg.min_skip_interval_delta)
end, {repeatable = true})