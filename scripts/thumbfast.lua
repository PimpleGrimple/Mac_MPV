-- thumbfast.lua (macOS Optimized)

local options = {
    socket = "",
    thumbnail = "",
    max_height = 200,
    max_width = 200,
    scale_factor = 1,
    tone_mapping = "auto",
    overlay_id = 46,
    spawn_first = false,
    quit_after_inactivity = 0,
    network = false,
    audio = false,
    hwdec = true,
    mpv_path = "mpv"
}

mp.utils = require("mp.utils")
mp.options = require("mp.options")
mp.options.read_options(options)

local properties = {}
local support_media_control = mp.get_property_native("media-controls") ~= nil

local function subprocess(args, async, callback)
    callback = callback or function() end
    if async then
        return mp.command_native_async({name = "subprocess", playback_only = true, args = args, env = "PATH="..os.getenv("PATH")}, callback)
    else
        return mp.command_native({name = "subprocess", playback_only = false, capture_stdout = true, args = args, env = "PATH="..os.getenv("PATH")})
    end
end

local file, file_bytes = nil, 0
local spawned, disabled, force_disabled = false, false, false
local spawn_waiting, spawn_working, script_written = false, false, false
local dirty = false
local x, y, last_x, last_y, last_seek_time
local effective_w, effective_h = options.max_width, options.max_height
local real_w, real_h, last_real_w, last_real_h
local script_name, show_thumbnail = nil, false

local filters_reset = {["lavfi-crop"]=true, ["crop"]=true}
local filters_runtime = {["hflip"]=true, ["vflip"]=true}
local filters_all = {["hflip"]=true, ["vflip"]=true, ["lavfi-crop"]=true, ["crop"]=true}
local tone_mappings = {["none"]=true, ["clip"]=true, ["linear"]=true, ["gamma"]=true, ["reinhard"]=true, ["hable"]=true, ["mobius"]=true}
local last_tone_mapping

local last_vf_reset, last_vf_runtime = "", ""
local last_rotate, par, last_par = 0, "", ""
local last_crop, last_has_vid, has_vid = nil, 0, 0

local file_timer
local file_check_period = 1/60
local allow_fast_seek = true

local client_script = [=[
#!/usr/bin/env bash
MPV_IPC_FD=0; MPV_IPC_PATH="%s"
trap "kill 0" EXIT
while [[ $# -ne 0 ]]; do case $1 in --mpv-ipc-fd=*) MPV_IPC_FD=${1/--mpv-ipc-fd=/} ;; esac; shift; done
if echo "print-text thumbfast" >&"$MPV_IPC_FD"; then echo -n > "$MPV_IPC_PATH"; tail -f "$MPV_IPC_PATH" >&"$MPV_IPC_FD" & while read -r -u "$MPV_IPC_FD" 2>/dev/null; do :; done; fi
]=]

local unique = mp.utils.getpid()
options.socket = options.socket == "" and ("/tmp/thumbfast" .. unique) or (options.socket .. unique)
options.thumbnail = options.thumbnail == "" and ("/tmp/thumbfast.out" .. unique) or (options.thumbnail .. unique)
options.scale_factor = math.floor(options.scale_factor)

local mpv_path = options.mpv_path

if mpv_path == "mpv" and unique then
    mpv_path = string.gsub(subprocess({"ps", "-o", "comm=", "-p", tostring(unique)}).stdout, "[\n\r]", "")
    if mpv_path ~= "mpv" then
        mpv_path = string.gsub(mpv_path, "/mpv%-bundle$", "/mpv")
        local mpv_bin = mp.utils.file_info("/usr/local/mpv")
        if mpv_bin and mpv_bin.is_file then
            mpv_path = "/usr/local/mpv"
        else
            local mpv_app = mp.utils.file_info("/Applications/mpv.app/Contents/MacOS/mpv")
            if mpv_app and mpv_app.is_file then
                mp.msg.warn("symlink mpv to fix Dock icons: `sudo ln -s /Applications/mpv.app/Contents/MacOS/mpv /usr/local/mpv`")
            else
                mp.msg.warn("drag to your Applications folder and symlink mpv to fix Dock icons: `sudo ln -s /Applications/mpv.app/Contents/MacOS/mpv /usr/local/mpv`")
            end
        end
    end
end

local function vo_tone_mapping()
    local passes = mp.get_property_native("vo-passes")
    if passes and passes["fresh"] then
        for _, v in pairs(passes["fresh"]) do
            for k2, v2 in pairs(v) do
                if k2 == "desc" and v2 then
                    local tone_mapping = string.match(v2, "([0-9a-z.-]+) tone map")
                    if tone_mapping then return tone_mapping end
                end
            end
        end
    end
end

local function vf_string(filters, full)
    local vf = ""
    local vf_table = properties["vf"]

    if (properties["video-crop"] or "") ~= "" then
        vf = "lavfi-crop="..string.gsub(properties["video-crop"], "(%d*)x?(%d*)%+(%d+)%+(%d+)", "w=%1:h=%2:x=%3:y=%4")..","
        local width = properties["video-out-params"] and properties["video-out-params"]["dw"]
        local height = properties["video-out-params"] and properties["video-out-params"]["dh"]
        if width and height then
            vf = string.gsub(vf, "w=:h=:", "w="..width..":h="..height..":")
        end
    end

    if vf_table and #vf_table > 0 then
        for i = #vf_table, 1, -1 do
            if filters[vf_table[i].name] then
                local args = ""
                for key, value in pairs(vf_table[i].params) do
                    if args ~= "" then args = args .. ":" end
                    args = args .. key .. "=" .. value
                end
                vf = vf .. vf_table[i].name .. "=" .. args .. ","
            end
        end
    end

    if (full and options.tone_mapping ~= "no") or options.tone_mapping == "auto" then
        if properties["video-params"] and properties["video-params"]["primaries"] == "bt.2020" then
            local tone_mapping = options.tone_mapping
            if tone_mapping == "auto" then
                tone_mapping = last_tone_mapping or properties["tone-mapping"]
                if tone_mapping == "auto" and properties["current-vo"] == "gpu-next" then
                    tone_mapping = vo_tone_mapping()
                end
            end
            if not tone_mappings[tone_mapping] then tone_mapping = "hable" end
            last_tone_mapping = tone_mapping
            vf = vf .. "zscale=transfer=linear,format=gbrpf32le,tonemap="..tone_mapping..",zscale=transfer=bt709,"
        end
    end

    if full then
        vf = vf.."scale=w="..effective_w..":h="..effective_h..par..",pad=w="..effective_w..":h="..effective_h..":x=-1:y=-1,format=bgra"
    end
    return vf
end

local function calc_dimensions()
    local width = properties["video-out-params"] and properties["video-out-params"]["dw"]
    local height = properties["video-out-params"] and properties["video-out-params"]["dh"]
    if not width or not height then return end

    local scale = properties["display-hidpi-scale"] or 1

    if width / height > options.max_width / options.max_height then
        effective_w = math.floor(options.max_width * scale + 0.5)
        effective_h = math.floor(height / width * effective_w + 0.5)
    else
        effective_h = math.floor(options.max_height * scale + 0.5)
        effective_w = math.floor(width / height * effective_h + 0.5)
    end

    local v_par = properties["video-out-params"] and properties["video-out-params"]["par"] or 1
    par = v_par == 1 and ":force_original_aspect_ratio=decrease" or ""
end

local info_timer = nil
local function info(w, h)
    local rotate = properties["video-params"] and properties["video-params"]["rotate"]
    local image = properties["current-tracks/video"] and properties["current-tracks/video"]["image"]
    local albumart = image and properties["current-tracks/video"]["albumart"]

    disabled = (w or 0) == 0 or (h or 0) == 0 or
        has_vid == 0 or
        (properties["demuxer-via-network"] and not options.network) or
        (albumart and not options.audio) or
        (image and not albumart) or force_disabled

    if info_timer then
        info_timer:kill()
        info_timer = nil
    elseif has_vid == 0 or (rotate == nil and not disabled) then
        info_timer = mp.add_timeout(0.05, function() info(w, h) end)
    end

    local json, _ = mp.utils.format_json({width=w * options.scale_factor, height=h * options.scale_factor, scale_factor=options.scale_factor, disabled=disabled, available=true, socket=options.socket, thumbnail=options.thumbnail, overlay_id=options.overlay_id})
    mp.command_native_async({"script-message", "thumbfast-info", json}, function() end)
end

local function remove_thumbnail_files()
    if file then
        file:close()
        file = nil
        file_bytes = 0
    end
    os.remove(options.thumbnail)
    os.remove(options.thumbnail..".bgra")
end

local activity_timer
local function spawn(time)
    if disabled then return end
    local path = properties["path"]
    if path == nil then return end

    if options.quit_after_inactivity > 0 then
        if show_thumbnail or activity_timer:is_enabled() then activity_timer:kill() end
        activity_timer:resume()
    end

    local open_filename = properties["stream-open-filename"]
    local ytdl = open_filename and properties["demuxer-via-network"] and path ~= open_filename
    if ytdl then path = open_filename end

    remove_thumbnail_files()
    local vid = properties["vid"]
    has_vid = vid or 0

    local args = {
        mpv_path, "--no-config", "--msg-level=all=no", "--idle", "--pause", "--keep-open=always", "--really-quiet", "--no-terminal",
        "--load-scripts=no", "--osc=no", "--ytdl=no", "--load-stats-overlay=no", "--load-osd-console=no", "--load-auto-profiles=no",
        "--edition="..(properties["edition"] or "auto"), "--vid="..(vid or "auto"), "--no-sub", "--no-audio",
        "--start="..time, allow_fast_seek and "--hr-seek=no" or "--hr-seek=yes",
        "--ytdl-format=worst", "--demuxer-readahead-secs=0", "--demuxer-max-bytes=128KiB",
        "--vd-lavc-skiploopfilter=all", "--vd-lavc-software-fallback=1", "--vd-lavc-fast", "--vd-lavc-threads=2", "--hwdec="..(options.hwdec and "auto" or "no"),
        "--vf="..vf_string(filters_all, true),
        "--sws-scaler=fast-bilinear",
        "--video-rotate="..last_rotate,
        "--ovc=rawvideo", "--of=image2", "--ofopts=update=1", "--o="..options.thumbnail,
        "--sws-allow-zimg=no"
    }

    if support_media_control then table.insert(args, "--media-controls=no") end
    if properties["macos-app-activation-policy"] then table.insert(args, "--macos-app-activation-policy=accessory") end

    if not script_written then
        local client_script_path = options.socket..".run"
        local script = io.open(client_script_path, "w+")
        if script == nil then
            mp.msg.error("client script write failed")
            return
        else
            script_written = true
            script:write(string.format(client_script, options.socket))
            script:close()
            subprocess({"chmod", "+x", client_script_path}, true)
            table.insert(args, "--scripts="..client_script_path)
        end
    else
        table.insert(args, "--scripts="..options.socket..".run")
    end

    table.insert(args, "--")
    table.insert(args, path)

    spawned = true
    spawn_waiting = true

    subprocess(args, true, function(success, result)
        if spawn_waiting and (success == false or (result.status ~= 0 and result.status ~= -2)) then
            spawned = false
            spawn_waiting = false
            options.tone_mapping = "no"
            mp.msg.error("mpv subprocess create failed")
        elseif success == true and (result.status == 0 or result.status == -2) then
            spawn_working = true
            spawn_waiting = false
        end
    end)
end

local function run(command)
    if not spawned then return end
    local command_n = command.."\n"
    if not file then file = io.open(options.socket, "r+") end
    if file then
        file_bytes = file:seek("end")
        file:write(command_n)
        file:flush()
    end
end

local function draw(w, h, script)
    if not w or not show_thumbnail then return end
    if x ~= nil then
        local scale_w = options.scale_factor ~= 1 and (w * options.scale_factor) or nil
        local scale_h = options.scale_factor ~= 1 and (h * options.scale_factor) or nil
        mp.command_native_async({"overlay-add", options.overlay_id, x, y, options.thumbnail..".bgra", 0, "bgra", w, h, (4*w), scale_w, scale_h}, function() end)
    elseif script then
        local json, _ = mp.utils.format_json({width=w, height=h, scale_factor=options.scale_factor, x=x, y=y, socket=options.socket, thumbnail=options.thumbnail, overlay_id=options.overlay_id})
        mp.commandv("script-message-to", script, "thumbfast-render", json)
    end
end

local function real_res(req_w, req_h, filesize)
    local count = filesize / 4
    local diff = (req_w * req_h) - count

    if (properties["video-params"] and properties["video-params"]["rotate"] or 0) % 180 == 90 then
        req_w, req_h = req_h, req_w
    end

    if diff == 0 then return req_w, req_h else
        local threshold = 5
        local long_side, short_side = req_h > req_w and req_h or req_w, req_h > req_w and req_w or req_h
        for a = short_side, short_side - threshold, -1 do
            if count % a == 0 then
                local b = count / a
                if long_side - b < threshold then
                    return req_h < req_w and b or a, req_h < req_w and a or b
                end
            end
        end
        return nil
    end
end

local function move_file(from, to)
    os.rename(from, to)
end

local function seek(fast)
    if last_seek_time then run("async seek " .. last_seek_time .. (fast and " absolute+keyframes" or " absolute+exact")) end
end

local seek_period = 3/60
local seek_period_counter = 0
local seek_timer

seek_timer = mp.add_periodic_timer(seek_period, function()
    if seek_period_counter == 0 then
        seek(allow_fast_seek)
        seek_period_counter = 1
    elseif seek_period_counter == 2 then
        if allow_fast_seek then
            if seek_timer then seek_timer:kill() end
            seek()
        end
    else
        seek_period_counter = seek_period_counter + 1
    end
end)

if seek_timer then seek_timer:kill() end

local function request_seek()
    if seek_timer:is_enabled() then
        seek_period_counter = 0
    else
        seek_timer:resume()
        seek(allow_fast_seek)
        seek_period_counter = 1
    end
end

local function check_new_thumb()
    local tmp = options.thumbnail..".tmp"
    move_file(options.thumbnail, tmp)
    local finfo = mp.utils.file_info(tmp)
    if not finfo then return false end
    spawn_waiting = false
    local w, h = real_res(effective_w, effective_h, finfo.size)
    if w then
        move_file(tmp, options.thumbnail..".bgra")
        real_w, real_h = w, h
        if real_w and (real_w ~= last_real_w or real_h ~= last_real_h) then
            last_real_w, last_real_h = real_w, real_h
            info(real_w, real_h)
        end
        if not show_thumbnail then file_timer:kill() end
        return true
    end
    return false
end

file_timer = mp.add_periodic_timer(file_check_period, function()
    if check_new_thumb() then draw(real_w, real_h, script_name) end
end)
file_timer:kill()

local function clear()
    file_timer:kill()
    seek_timer:kill()
    if options.quit_after_inactivity > 0 then
        if show_thumbnail or activity_timer:is_enabled() then activity_timer:kill() end
        activity_timer:resume()
    end
    last_seek_time, show_thumbnail, last_x, last_y = nil, false, nil, nil
    if script_name then return end
    mp.command_native_async({"overlay-remove", options.overlay_id}, function() end)
end

local function quit()
    activity_timer:kill()
    if show_thumbnail then activity_timer:resume() return end
    run("quit")
    spawned = false
    real_w, real_h = nil, nil
    clear()
end

activity_timer = mp.add_timeout(options.quit_after_inactivity, quit)
activity_timer:kill()

local function thumb(time, r_x, r_y, script)
    if disabled then return end
    time = tonumber(time)
    if time == nil then return end

    x, y = r_x == "" and nil or math.floor(r_x + 0.5), r_y == "" and nil or math.floor(r_y + 0.5)
    script_name = script

    if last_x ~= x or last_y ~= y or not show_thumbnail then
        show_thumbnail = true
        last_x, last_y = x, y
        draw(real_w, real_h, script)
    end

    if options.quit_after_inactivity > 0 then
        if show_thumbnail or activity_timer:is_enabled() then activity_timer:kill() end
        activity_timer:resume()
    end

    if time == last_seek_time then return end
    last_seek_time = time
    if not spawned then spawn(time) end
    request_seek()
    if not file_timer:is_enabled() then file_timer:resume() end
end

local function watch_changes()
    if not dirty or not properties["video-out-params"] then return end
    dirty = false

    local old_w, old_h = effective_w, effective_h
    calc_dimensions()

    local vf_reset = vf_string(filters_reset)
    local rotate = properties["video-rotate"] or 0

    local resized = old_w ~= effective_w or old_h ~= effective_h or last_vf_reset ~= vf_reset or (last_rotate % 180) ~= (rotate % 180) or par ~= last_par or last_crop ~= properties["video-crop"]

    if resized or (last_has_vid ~= has_vid and has_vid ~= 0) then
        last_rotate = rotate
        info(effective_w, effective_h)
    end

    if spawned then
        if resized then
            local seek_time = last_seek_time
            run("quit")
            clear()
            spawned = false
            spawn(seek_time or mp.get_property_number("time-pos", 0))
            file_timer:resume()
        else
            if rotate ~= last_rotate then run("set video-rotate "..rotate) end
            local vf_runtime = vf_string(filters_runtime)
            if vf_runtime ~= last_vf_runtime then
                run("vf set "..vf_string(filters_all, true))
                last_vf_runtime = vf_runtime
            end
        end
    else
        last_vf_runtime = vf_string(filters_runtime)
    end

    last_vf_reset = vf_reset
    last_rotate = rotate
    last_par = par
    last_crop = properties["video-crop"]
    last_has_vid = has_vid

    if not spawned and not disabled and options.spawn_first and resized then
        spawn(mp.get_property_number("time-pos", 0))
        file_timer:resume()
    end
end

local function update_property(name, value) properties[name] = value end
local function update_property_dirty(name, value)
    properties[name] = value
    dirty = true
    if name == "tone-mapping" then last_tone_mapping = nil end
end

local function update_tracklist(_, value)
    for _, track in ipairs(value) do
        if track.type == "video" and track.selected then
            properties["current-tracks/video"] = track
            return
        end
    end
end

local function sync_changes(prop, val)
    update_property(prop, val)
    if val == nil then return end

    if type(val) == "boolean" then
        if prop == "vid" then
            has_vid, last_has_vid = 0, 0
            info(effective_w, effective_h)
            clear()
            return
        end
        val = val and "yes" or "no"
    end

    if prop == "vid" then has_vid = 1 end
    if not spawned then return end

    run("set "..prop.." "..val)
    dirty = true
end

local function file_load()
    clear()
    spawned = false
    real_w, real_h, last_real_w, last_real_h, last_tone_mapping, last_seek_time = nil, nil, nil, nil, nil, nil
    if info_timer then
        info_timer:kill()
        info_timer = nil
    end
    calc_dimensions()
    info(effective_w, effective_h)
end

local function shutdown()
    run("quit")
    remove_thumbnail_files()
    os.remove(options.socket)
    os.remove(options.socket..".run")
end

mp.observe_property("current-tracks/video", "native", update_property)
mp.observe_property("track-list", "native", update_tracklist)
mp.observe_property("display-hidpi-scale", "native", update_property_dirty)
mp.observe_property("video-out-params", "native", update_property_dirty)
mp.observe_property("video-params", "native", update_property_dirty)
mp.observe_property("vf", "native", update_property_dirty)
mp.observe_property("tone-mapping", "native", update_property_dirty)
mp.observe_property("demuxer-via-network", "native", update_property)
mp.observe_property("stream-open-filename", "native", update_property)
mp.observe_property("macos-app-activation-policy", "native", update_property)
mp.observe_property("current-vo", "native", update_property)
mp.observe_property("video-rotate", "native", update_property)
mp.observe_property("video-crop", "native", update_property)
mp.observe_property("path", "native", update_property)
mp.observe_property("vid", "native", sync_changes)
mp.observe_property("edition", "native", sync_changes)
mp.observe_property("duration", "native", function(_, val) allow_fast_seek = (val or 30) >= 30 end)

mp.register_script_message("thumb", thumb)
mp.register_script_message("clear", clear)
mp.register_event("file-loaded", file_load)
mp.register_event("shutdown", shutdown)
mp.register_idle(watch_changes)