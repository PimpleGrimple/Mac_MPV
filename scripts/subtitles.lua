--[[
    subtitles.lua
    Auto-subtitles & auto-lyrics engine.
    Requires mpv >= 0.33.
]]

local mp = require("mp")
local utils = require("mp.utils")
local options = require("mp.options")

local SUBLIMINAL_BIN = "/Users/mahmoud/.local/bin/subliminal"

local opts = {
    auto_download          = false,
    -- Where both subtitles and lyrics are saved:
    -- media = beside a local media file (falls back to cache for streams/read-only media)
    -- cache = ~~/cache/scripts/subtitles
    -- temp  = a per-session /tmp directory, deleted when mpv exits
    download_location      = "media",
}
options.read_options(opts)

local valid_download_locations = { media = true, cache = true, temp = true }
if not valid_download_locations[opts.download_location] then
    mp.msg.warn("Invalid download_location '" .. tostring(opts.download_location)
        .. "'; using 'media'")
    opts.download_location = "media"
end

------------------------------------------------------------------
-- Logging
------------------------------------------------------------------
local function log_info(msg, dur)
    mp.msg.info("[subs] " .. msg)
    if dur then mp.osd_message(msg, dur) end
end
local function log_warn(msg, dur)
    mp.msg.warn("[subs] " .. msg)
    if dur then mp.osd_message(msg, dur) end
end

------------------------------------------------------------------
-- Utilities
------------------------------------------------------------------
local function nonempty(s)
    return (type(s) == "string" and s:match("%S+")) and s or nil
end

local function sanitize_filename(name)
    if not name then return "" end
    local s = name:gsub('[\\/:%*%?"<>|]', " "):gsub("%s+", " "):match("^%s*(.-)%s*$") or ""
    if #s > 200 then
        s = s:sub(1, 190) .. "_" .. tostring(os.time()):sub(-6)
    end
    return s
end

local function is_stream_path(path)
    if not path or path == "" or path == "fd://0" or path:find("^pipe:") then return true end
    return path:match("^[%a][%w+.-]*://") ~= nil and not path:match("^file://")
end

local function file_exists(path)
    return utils.file_info(path) ~= nil
end

local function ensure_dir(path)
    if not path or path == "" then return false end
    local info = utils.file_info(path)
    if info and info.is_dir then return true end
    local res = utils.subprocess({ args = { "mkdir", "-p", path }, playback_only = false })
    return res and res.status == 0
end

-- Fire-and-forget by default so cleanup never stalls mpv; `sync` is for
-- shutdown, where an async job might not get to finish.
local function clean_dir(path, sync)
    if not path or path == "" then return end
    if sync then
        if utils.file_info(path) then
            utils.subprocess({ args = { "rm", "-rf", path }, playback_only = false })
        end
        return
    end
    mp.command_native_async({
        name = "subprocess", args = { "rm", "-rf", path }, playback_only = false,
    }, function() end)
end

local function move_file(source, destination)
    if utils.rename then
        local ok = utils.rename(source, destination)
        if ok then return true end
    end
    local ok, err = os.rename(source, destination)
    if ok then return true end
    -- /bin/mv handles cross-device moves (EXDEV), which rename(2) cannot.
    local res = utils.subprocess({
        args = { "/bin/mv", "-f", source, destination },
        capture_stdout = true, capture_stderr = true,
    })
    if res.status == 0 then return true end
    return false, err or res.stderr
end

local function has_video_track()
    for _, t in ipairs(mp.get_property_native("track-list", {})) do
        if t.type == "video" and not t.image and not t.albumart then return true end
    end
    return false
end

local language_aliases = {
    en = { "en", "eng", "english" },
    ja = { "ja", "jpn", "japanese" },
    es = { "es", "spa", "spanish" },
    fr = { "fr", "fra", "french" },
}

local function language_value_matches(value, lang_code)
    if not value then return false end
    value = value:lower()
    for _, alias in ipairs(language_aliases[lang_code] or { lang_code }) do
        if value == alias
            or value:match("[^%a]" .. alias .. "[^%a]")
            or value:match("^" .. alias .. "[^%a]")
            or value:match("[^%a]" .. alias .. "$")
        then
            return true
        end
    end
    return false
end

local function has_loaded_subtitle(lang_code)
    for _, t in ipairs(mp.get_property_native("track-list", {})) do
        if t.type == "sub" then
            if not lang_code then return true end
            if language_value_matches(t.lang, lang_code)
                or language_value_matches(t.title, lang_code)
                or language_value_matches(t["external-filename"], lang_code)
            then
                return true
            end
        end
    end
    return false
end

-- Removes /tmp/mpv-subs-* dirs from crashed sessions untouched for 24+ hours.
local tmp_pruned = false
local function prune_stale_tmp()
    local dirs = utils.readdir("/tmp", "dirs")
    if type(dirs) ~= "table" then return end
    local now = os.time()
    for _, d in ipairs(dirs) do
        if d:match("^mpv%-subs%-%d+$") then
            local full = "/tmp/" .. d
            local info = utils.file_info(full)
            local mt = info and info.mtime
            if mt and (now - mt) > 86400 then
                clean_dir(full)
            end
        end
    end
end

------------------------------------------------------------------
-- Global state
------------------------------------------------------------------
local pid = utils.getpid()
local file_generation = 0
local cache_dir = mp.command_native({ "expand-path", "~~/cache/scripts/subtitles" })

local function session_tmp_dir()
    return utils.join_path("/tmp", "mpv-subs-" .. tostring(pid))
end

local function selected_storage_dir()
    if opts.download_location == "temp" then
        return utils.join_path(session_tmp_dir(), "kept")
    end
    return cache_dir
end

local job_counter = 0
local active_job_id = nil
local active_async_handle = nil

local lyrics_request_counter = 0
local active_lyrics_request_id = nil
local active_lyrics_async_handle = nil

local auto_dl_timer = nil

local sub_exts = { "srt", "ass", "ssa", "vtt" }

local primary_lang = { 'English', 'en' }

-- Manual search accepts a trailing ";xx" to pick the subtitle language for
-- that one search, e.g. "Frieren S01E05;fr" (or just ";es" to re-search the
-- current file in Spanish). Only 2-letter codes and the aliases above are
-- recognised, so a title like "foo;bar" is left alone.
local lang_names = { en = "English", ja = "Japanese", es = "Spanish", fr = "French" }

local function normalize_lang(code)
    code = code:lower()
    for key, aliases in pairs(language_aliases) do
        for _, alias in ipairs(aliases) do
            if code == alias then return key end
        end
    end
    if #code == 2 then return code end
    return nil
end

-- returns query_without_suffix, lang_table_or_nil
local function split_query_lang(query)
    if not query then return nil, nil end
    local q, code = query:match("^(.-)%s*;%s*(%a+)%s*$")
    local lang = code and normalize_lang(code)
    if not lang then return query, nil end
    return nonempty(q), { lang_names[lang] or lang:upper(), lang }
end

------------------------------------------------------------------
-- Cancellation
------------------------------------------------------------------
local function cancel_auto_download()
    if auto_dl_timer then
        auto_dl_timer:kill()
        auto_dl_timer = nil
    end
end

local function abort_active_job()
    cancel_auto_download()
    if active_async_handle then
        mp.abort_async_command(active_async_handle)
        active_async_handle = nil
    end
    if active_lyrics_async_handle then
        mp.abort_async_command(active_lyrics_async_handle)
        active_lyrics_async_handle = nil
    end
    active_job_id = nil
    active_lyrics_request_id = nil
end

local function finish_lyrics_request(req_id)
    if active_lyrics_request_id == req_id then
        active_lyrics_request_id = nil
        active_lyrics_async_handle = nil
    end
end

------------------------------------------------------------------
-- Async HTTP
------------------------------------------------------------------
local function fetch_json_async(url, extra_args, headers, req_gen, req_id, callback)
    local args = {
        "curl", "-fsS",
        "-A", "Mozilla/5.0 (mpv-subtitles/1.0)",
        "--connect-timeout", "5",
        "--max-time", "12",
        "--retry", "2", "--retry-delay", "1",
        "--get", url,
    }
    for _, h in ipairs(headers or {}) do
        table.insert(args, "-H"); table.insert(args, h)
    end
    for _, v in ipairs(extra_args or {}) do table.insert(args, v) end

    active_lyrics_async_handle = mp.command_native_async({
        name = "subprocess", args = args, capture_stdout = true
    }, function(success, res)
        local is_current = (active_lyrics_request_id == req_id)
        if is_current then active_lyrics_async_handle = nil end
        if req_gen ~= file_generation or not is_current then return end
        if not success or not res or res.status ~= 0 or not nonempty(res.stdout) then
            return callback(nil)
        end
        local data, parse_err = utils.parse_json(res.stdout)
        callback(not parse_err and data or nil)
    end)
end

------------------------------------------------------------------
-- Lifecycle
------------------------------------------------------------------
local function cleanup_tmp()
    abort_active_job()
    clean_dir(session_tmp_dir(), true)
end

local schedule_auto_download

mp.register_event("file-loaded", function()
    file_generation = file_generation + 1
    abort_active_job()
    if opts.auto_download then schedule_auto_download() end
end)

mp.register_event("shutdown", cleanup_tmp)

------------------------------------------------------------------
-- Lyrics engine
------------------------------------------------------------------
local function get_metadata(manual_query)
    local m = mp.get_property_native("metadata") or {}
    local raw_media_title = mp.get_property("media-title") or ""

    local title  = nonempty(m.title) or nonempty(m.TITLE) or nonempty(m.Title)
                   or nonempty(raw_media_title:gsub("%b[]", ""))
                   or "Unknown Title"
    local artist = nonempty(mp.get_property("filtered-metadata/by-key/Artist"))
                   or nonempty(mp.get_property("filtered-metadata/by-key/Uploader"))
                   or nonempty(m.artist) or " "
    local album  = nonempty(m.album) or nonempty(m.ALBUM) or nonempty(m.Album) or ""
    local dur    = mp.get_property_number("duration") or 0

    if manual_query then title = manual_query end
    return title, artist, album, dur
end

-- Strips CJK lyric credit prefixes (作词: lyricist, 作曲: composer) that some
-- synced lyric files carry. No-op for non-CJK lyrics.
local function strip_lyric_meta(lyrics)
    lyrics = lyrics:gsub("’", "'")
    for _, p in ipairs({ '作词','作詞','作曲','制作人','编曲','編曲','詞','曲' }) do
        lyrics = lyrics:gsub('%[[%d:%.]*] ?' .. p .. ' ?[:：] ?.-\\n', '')
    end
    return lyrics
end

local function save_lyrics(lyrics, is_stream, path, req_gen, type_label, cache_filename)
    if req_gen ~= file_generation then return false end
    if not lyrics or #lyrics:gsub("%s", "") < 8 then return false end
    type_label = type_label or "Lyrics"
    lyrics = strip_lyric_meta(lyrics)

    -- In media mode, use a sidecar for local files. Streams and read-only media
    -- fall back to the persistent cache so downloads remain usable.
    local lrc_path, f, err
    if opts.download_location == "media" and not is_stream then
        lrc_path = path:gsub("%?", "") .. ".lrc"
        f = io.open(lrc_path, "w")
    end
    if not f then
        lrc_path = utils.join_path(selected_storage_dir(), cache_filename)
        local dir = lrc_path:match("(.+[\\/])")
        if dir then ensure_dir(dir) end
        f, err = io.open(lrc_path, "w")
    end
    if not f then
        log_warn("Failed to write lyrics: " .. tostring(err), 2)
        return false
    end
    f:write(lyrics); f:close()

    mp.commandv("sub-add", lrc_path, "select", type_label)
    mp.osd_message("", 0)
    log_info(type_label .. " downloaded", 2)
    return true
end

local function download_lyrics(manual_query)
    abort_active_job()

    lyrics_request_counter = lyrics_request_counter + 1
    local req_id = lyrics_request_counter
    active_lyrics_request_id = req_id

    local req_gen = file_generation
    local title, artist, album, dur = get_metadata(manual_query)
    if not title then return log_warn("Metadata missing", 2) end

    local path = mp.get_property("path") or ""
    local is_stream = is_stream_path(path)

    local dur_sec = math.floor(dur + 0.5)
    local album_tag = nonempty(album) and (" - " .. album) or ""
    local cache_file_name = sanitize_filename(artist .. " - " .. title .. album_tag .. " - " .. dur_sec .. "s") .. ".lrc"
    local sidecar_lrc = path:gsub("%?", "") .. ".lrc"
    local stored_lrc = utils.join_path(selected_storage_dir(), cache_file_name)
    local cached_lrc = nil
    if opts.download_location == "media" and not is_stream and file_exists(sidecar_lrc) then
        cached_lrc = sidecar_lrc
    elseif file_exists(stored_lrc) then
        cached_lrc = stored_lrc
    end

    if not manual_query and cached_lrc then
        mp.commandv("sub-add", cached_lrc, "cached", "Cached Lyrics")
        finish_lyrics_request(req_id)
        return log_info("Loaded lyrics from local cache", 2)
    end

    log_info("Searching lyrics...", 30)

    fetch_json_async("https://lrclib.net/api/get", {
        "--data-urlencode", "track_name=" .. title,
        "--data-urlencode", "artist_name=" .. artist,
        "--data-urlencode", "album_name=" .. album,
        "--data-urlencode", "duration=" .. dur,
    }, { "Lrclib-Client: mpv-subtitles/1.0" }, req_gen, req_id, function(lrc)
        if req_gen ~= file_generation then return end
        if lrc then
            if lrc.instrumental then
                finish_lyrics_request(req_id)
                return log_info("LRCLIB: track is instrumental", 2)
            end
            local lyrics = lrc.syncedLyrics or lrc.plainLyrics
            local label = lrc.syncedLyrics and "LRCLIB (Synced)" or "LRCLIB (Plain)"
            if lyrics and save_lyrics(lyrics, is_stream, path, req_gen, label, cache_file_name) then
                finish_lyrics_request(req_id); return
            end
        end
        finish_lyrics_request(req_id)
        log_warn("Lyrics not found", 2)
    end)
end

------------------------------------------------------------------
-- Subtitles engine
------------------------------------------------------------------
local function download_subs(manual_query, target_lang)
    abort_active_job()

    if not file_exists(SUBLIMINAL_BIN) then
        return log_warn("Subliminal not found at: " .. SUBLIMINAL_BIN, 4)
    end
    if not tmp_pruned then
        tmp_pruned = true
        prune_stale_tmp()
    end

    job_counter = job_counter + 1
    local job_id = job_counter
    active_job_id = job_id

    local req_gen = file_generation
    target_lang = target_lang or primary_lang

    local path = mp.get_property("path") or ""
    local is_stream = is_stream_path(path)
    local media_dir = "/tmp"
    local real_fname = "video.mkv"

    if not is_stream then
        media_dir, real_fname = utils.split_path(path)
    else
        real_fname = sanitize_filename(mp.get_property("media-title") or "stream_video") .. ".mkv"
    end

    -- Reuse a previously downloaded file from the selected destination. This
    -- matters most for cache mode, whose files mpv does not auto-discover like
    -- sidecars, and prevents redundant provider requests across sessions.
    if not manual_query then
        local saved_stem = real_fname:match("(.+)%.%w+$") or real_fname
        local saved_dir = (opts.download_location == "media" and not is_stream)
            and media_dir or selected_storage_dir()
        for _, ext in ipairs(sub_exts) do
            local saved_sub = utils.join_path(saved_dir,
                saved_stem .. "." .. target_lang[2] .. "." .. ext)
            if file_exists(saved_sub) then
                mp.commandv("sub-add", saved_sub, "select",
                    "Cached • " .. target_lang[1], target_lang[2])
                return log_info(target_lang[1] .. " subtitle loaded from storage", 2)
            end
        end
    end

    -- Skip the whole search when an auto press finds a previously-downloaded
    -- sub for this file+language already loaded. Prevents duplicate entries
    -- and redundant Subliminal invocations.
    if not manual_query then
        local output_stem = real_fname:match("(.+)%.%w+$") or real_fname
        local prefix = output_stem .. "." .. target_lang[2] .. "."
        for _, t in ipairs(mp.get_property_native("track-list", {})) do
            local ext_file = t["external-filename"]
            if t.type == "sub" and ext_file then
                local fname = ext_file:match("([^/\\]+)$") or ""
                if fname:sub(1, #prefix) == prefix then
                    mp.set_property("sid", t.id)
                    return log_info(target_lang[1] .. " subtitle already loaded", 2)
                end
            end
        end
    end

    local session_tmp  = session_tmp_dir()
    local job_tmp_dir  = utils.join_path(session_tmp, "job-" .. tostring(job_id))
    ensure_dir(job_tmp_dir)

    local input_target, stub_created, metadata_only = path, nil, false

    if manual_query or is_stream then
        local clean = manual_query and sanitize_filename(manual_query) or real_fname
        if clean == "" then clean = "video" end
        if not clean:match("%.%w+$") then clean = clean .. ".mkv" end
        input_target = utils.join_path(job_tmp_dir, clean)
        local f = io.open(input_target, "w"); if f then f:close() end
        stub_created = input_target
        metadata_only = true
    end

    local search_stem = input_target:match("([^/\\]+)%.%w+$")
                     or input_target:match("([^/\\]+)$")
                     or "video"

    local output_stem
    if is_stream then
        output_stem = search_stem
    else
        output_stem = real_fname:match("(.+)%.%w+$") or real_fname
    end

    log_info("Searching " .. target_lang[1] .. " subtitles...", 30)

    local args = {
        SUBLIMINAL_BIN, "download",
        "-e", "utf-8",
        "-l", target_lang[2],
        "-m", "60",
        "-d", job_tmp_dir,
    }

    -- Metadata-only refinement for stub-based searches (manual query / stream):
    -- hash refinement on a stub file would be meaningless.
    if metadata_only then
        table.insert(args, '-r'); table.insert(args, 'metadata')
    end

    table.insert(args, input_target)

    active_async_handle = mp.command_native_async({
        name = "subprocess", args = args,
        capture_stdout = true, capture_stderr = true,
    }, function(success, res, err)
        local is_current_job = (active_job_id == job_id)
        if stub_created then os.remove(stub_created) end
        if is_current_job then
            active_job_id = nil
            active_async_handle = nil
        end

        if req_gen ~= file_generation or not is_current_job then
            clean_dir(job_tmp_dir); return
        end
        if not success or not res then
            clean_dir(job_tmp_dir)
            return log_warn("Subliminal failed to run (" .. tostring(err or "unknown")
                .. "). Check SUBLIMINAL_BIN at top of script.", 4)
        end

        for _, ext in ipairs(sub_exts) do
            local staged_sub = utils.join_path(job_tmp_dir,
                search_stem .. "." .. target_lang[2] .. "." .. ext)
            if file_exists(staged_sub) then
                local sub_name = output_stem .. "." .. target_lang[2] .. "." .. ext
                local final_sub, ok, move_err
                if opts.download_location == "media" and not is_stream then
                    -- A failed move doubles as the writability test.
                    final_sub = utils.join_path(media_dir, sub_name)
                    ok, move_err = move_file(staged_sub, final_sub)
                end
                if not ok then
                    -- Cache is the safe fallback for streams and read-only media.
                    local target_dir = selected_storage_dir()
                    ensure_dir(target_dir)
                    final_sub = utils.join_path(target_dir, sub_name)
                    ok, move_err = move_file(staged_sub, final_sub)
                end
                if not ok then
                    clean_dir(job_tmp_dir)
                    return log_warn("Failed to move subtitle: " .. tostring(move_err), 3)
                end

                -- Safety net: if this exact file is already loaded, select it
                -- instead of adding a duplicate track entry.
                local already_id
                for _, t in ipairs(mp.get_property_native("track-list", {})) do
                    if t.type == "sub" and t["external-filename"] == final_sub then
                        already_id = t.id
                        break
                    end
                end
                if already_id then
                    mp.set_property("sid", already_id)
                    clean_dir(job_tmp_dir)
                    mp.osd_message("", 0)
                    return log_info(target_lang[1] .. " subtitle already loaded", 2)
                end

                local add_ok, add_err = pcall(function()
                    mp.commandv("sub-add", final_sub, "select",
                        "Downloaded • " .. target_lang[1], target_lang[2])
                end)
                if not add_ok then
                    log_warn("sub-add failed: " .. tostring(add_err), 3)
                end

                clean_dir(job_tmp_dir)
                mp.osd_message("", 0)
                return log_info(target_lang[1] .. " subtitle ready!", 2)
            end
        end

        clean_dir(job_tmp_dir)
        log_warn("No " .. target_lang[1] .. " subtitles found", 2)
    end)
end

------------------------------------------------------------------
-- Smart dispatcher
------------------------------------------------------------------
local function smart_dispatch(is_manual)
    cancel_auto_download()

    local function execute_search(query)
        if has_video_track() then
            local q, lang = split_query_lang(query)
            download_subs(q, lang or primary_lang)
        else
            download_lyrics(query)
        end
    end

    if is_manual then
        -- native mp.input (mpv >= 0.38), loaded on first use
        local input_ok, input = pcall(require, "mp.input")
        if not (input_ok and input and input.get) then
            mp.osd_message("This mpv build has no mp.input. Can't prompt.", 3)
            return
        end
        local current_path = mp.get_property("path") or ""
        local current_filename = current_path:match("([^/\\]+)$") or current_path
        input.get({
            prompt        = "Search: ",
            id            = "subtitles",
            default_text  = current_filename,
            cursor_position = #current_filename + 1,
            submit = function(text)
                input.terminate() -- get() stays open after submit unless closed explicitly
                local query = nonempty(text)
                if query then execute_search(query) end
            end,
        })
    else
        execute_search(nil)
    end
end

------------------------------------------------------------------
-- Auto-download on load
------------------------------------------------------------------
schedule_auto_download = function()
    -- Defer one event-loop turn so track-list has settled, without imposing a
    -- user-visible delay on local files or streams.
    auto_dl_timer = mp.add_timeout(0, function()
        auto_dl_timer = nil
        if not has_video_track() then return end
        if not has_loaded_subtitle(primary_lang[2]) then
            download_subs(nil, primary_lang)
        end
    end)
end

------------------------------------------------------------------
-- Keybindings
------------------------------------------------------------------
mp.add_key_binding("q", "smart-dl-primary",
    function() smart_dispatch(false) end)
mp.add_key_binding("Q", "smart-dl-primary-manual",
    function() smart_dispatch(true) end)
