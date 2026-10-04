--[[
    subtitles.lua
    Hardened auto-subtitles & auto-lyrics engine.
    Requires mpv >= 0.33 (uses utils.file_info).
--]]

local mp = require("mp")
local utils = require("mp.utils")
local options = require("mp.options")

local function add_to_package_path(path)
    local expanded = mp.command_native({"expand-path", path})
    if expanded and expanded ~= "" then
        if not package.path:find(expanded, 1, true) then
            package.path = expanded .. ";" .. package.path
        end
    end
end
add_to_package_path("~~/script-modules/?.lua")
add_to_package_path("~~/scripts/?.lua")

local user_input_loaded, user_input = pcall(require, "user-input-module")

local opts = {
    musixmatch_token = "",
    subliminal_path  = "subliminal",                           -- PATH lookup (or Homebrew / ~/.local/bin); override if you have a custom install

    sub_download_binding            = "q",
    sub_download_manual_binding     = "Q",
    sub_download_alt_binding        = "ctrl+q",
    sub_download_alt_manual_binding = "ctrl+Q",

    auto_download          = false,
    auto_download_delay    = 2,
    download_to_tmp        = false,
    clean_tmp_on_exit      = false,
    min_sub_score          = 60,
    hearing_impaired       = false,
    max_workers            = 4,
    providers              = "",
    refiners               = "hash,metadata",
    subtitle_cache_enabled = true,     -- Reuse successful Subliminal results per media file
    debug                  = false,
}
options.read_options(opts)

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
local function log_debug(msg)
    if opts.debug then mp.msg.info("[subs] " .. msg) end
end

------------------------------------------------------------------
-- Utilities
------------------------------------------------------------------
local function nonempty(s)
    return (type(s) == "string" and s:match("%S+")) and s or nil
end

local function sanitize_filename(name)
    if not name then return "" end
    local s = name:gsub("[\\/:%*%?\"<>|]", " "):gsub("%s+", " "):match("^%s*(.-)%s*$") or ""
    if #s > 200 then
        local tail = tostring(os.time()):sub(-6)
        s = s:sub(1, 190) .. "_" .. tail
    end
    return s
end

local function is_stream_path(path)
    if not path or path == "" or path == "fd://0" or path:find("^pipe:") then return true end
    return path:match("^[%a][%w+.-]*://") ~= nil and not path:match("^file://")
end

local function file_exists(path)
    if utils.file_info then return utils.file_info(path) ~= nil end
    local f = io.open(path, "r"); if f then f:close(); return true end
    return false
end

local function get_subliminal_bin()
    local path = opts.subliminal_path
    if path and path ~= "" and path ~= "subliminal" then
        return mp.command_native({ "expand-path", path })
    end
    local home = os.getenv("HOME") or ""
    local candidates = {
        "/opt/homebrew/bin/subliminal",
        home .. "/.local/bin/subliminal",
        "/usr/local/bin/subliminal",
    }
    for _, c in ipairs(candidates) do
        if file_exists(c) then return c end
    end
    return "subliminal"
end

local function ensure_dir(path)
    if not path or path == "" then return false end
    if utils.file_info then
        local info = utils.file_info(path)
        if info and info.is_dir then return true end
    end
    local res = utils.subprocess({ args = { "mkdir", "-p", path }, playback_only = false })
    return res and res.status == 0
end

local function clean_dir(path)
    if not path or path == "" then return end
    if utils.file_info then
        local info = utils.file_info(path)
        if not info then return end
    end
    utils.subprocess({ args = { "rm", "-rf", path }, playback_only = false })
end

local function writable_dir(dir)
    if not dir or dir == "" then return false end
    local test = utils.join_path(dir, ".mpv-write-" .. tostring(os.time()) .. "-" .. tostring(math.random(1,1e6)))
    local f = io.open(test, "w")
    if not f then return false end
    f:close()
    os.remove(test)
    return true
end

local function get_file_hash(filepath)
    local res = utils.subprocess({ args = { "md5", "-q", filepath }, capture_stdout = true })
    if res.status ~= 0 or not res.stdout then return nil end
    local hex = res.stdout:match("(%x+)")
    return hex and hex:lower() or nil
end

local function move_file(source, destination)
    -- Prefer mpv's rename (single syscall, cross-fs safe)
    if utils.rename then
        local ok, err = utils.rename(source, destination)
        if ok then return true end
        log_debug("utils.rename failed: " .. tostring(err))
    end
    -- Fallback: libc rename
    local ok, err = os.rename(source, destination)
    if ok then return true end
    -- Last resort: /bin/mv (handles cross-device moves)
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
    fr = { "fr", "fra", "fre", "french" },
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

local function prune_stale_tmp()
    local dirs = utils.readdir("/tmp", "dirs")
    if type(dirs) ~= "table" then return end
    local now = os.time()
    for _, d in ipairs(dirs) do
        if d:match("^mpv%-subs%-%d+$") then
            local full = "/tmp/" .. d
            local info = utils.file_info and utils.file_info(full)
            local mt = info and info.mtime
            if mt and (now - mt) > 86400 then
                log_debug("Pruning stale temp: " .. full)
                clean_dir(full)
            end
        end
    end
end

------------------------------------------------------------------
-- Global state
------------------------------------------------------------------
local pid = mp.get_property_number("pid") or os.time()
local file_generation = 0

local job_counter = 0
local active_job_id = nil
local active_async_handle = nil

local lyrics_request_counter = 0
local active_lyrics_request_id = nil
local active_lyrics_async_handle = nil

local download_count = 0
local alt_lang_index = 1
local auto_dl_timer = nil
local seen_sub_hashes = {}

local sub_exts = { "srt", "ass", "ssa", "vtt", "idx", "sub", "smi", "mpl2" }

local primary_lang = { 'English', 'en' }
local alt_languages = {
    { 'Japanese', 'ja' },
    { 'Spanish', 'es' },
    { 'French', 'fr' },
}

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
    }, function(success, res, err)
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
    if opts.clean_tmp_on_exit then
        clean_dir(utils.join_path("/tmp", "mpv-subs-" .. tostring(pid)))
    end
end

local schedule_auto_download

mp.register_event("file-loaded", function()
    file_generation = file_generation + 1
    abort_active_job()

    download_count = 0
    alt_lang_index = 1
    seen_sub_hashes = {}

    if opts.auto_download then schedule_auto_download() end
end)

mp.register_event("shutdown", cleanup_tmp)

prune_stale_tmp()

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

local function strip_lyric_meta(lyrics)
    lyrics = lyrics:gsub("’", "'")
    for _, p in ipairs({ '作词','作詞','作曲','制作人','编曲','編曲','詞','曲' }) do
        lyrics = lyrics:gsub('%[[%d:%.]*] ?' .. p .. ' ?[:：] ?.-\n', '')
    end
    return lyrics
end

local function save_lyrics(lyrics, name, is_stream, path, req_gen, type_label, cache_filename)
    if req_gen ~= file_generation then return false end
    if not lyrics or #lyrics:gsub("%s", "") < 8 then return false end
    type_label = type_label or "Lyrics"
    lyrics = strip_lyric_meta(lyrics)

    local base_dir = mp.command_native({ "expand-path", opts.lyrics_store })
    local lrc_path
    if is_stream then
        lrc_path = utils.join_path(base_dir, cache_filename)
    else
        local sidecar = path:gsub("%?", "") .. ".lrc"
        local dir = sidecar:match("(.+[\\/])")
        if dir and writable_dir(dir) then
            lrc_path = sidecar
        else
            lrc_path = utils.join_path(base_dir, cache_filename)
        end
    end

    local dir = lrc_path:match("(.+[\\/])")
    if dir then ensure_dir(dir) end

    local f, err = io.open(lrc_path, "w")
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
    local base_dir = mp.command_native({ "expand-path", opts.lyrics_store })
    local local_lrc_path = is_stream
        and utils.join_path(base_dir, cache_file_name)
        or (path:gsub("%?", "") .. ".lrc")

    if not manual_query and file_exists(local_lrc_path) then
        mp.commandv("sub-add", local_lrc_path, "cached", "Cached Lyrics")
        finish_lyrics_request(req_id)
        return log_info("Loaded lyrics from local cache", 2)
    end

    log_info("Searching lyrics...", 30)

    local function search_lrclib()
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
                if lrc.syncedLyrics then
                    if save_lyrics(lrc.syncedLyrics,
                        (lrc.artistName or artist) .. " - " .. (lrc.trackName or title),
                        is_stream, path, req_gen, "LRCLIB (Synced)", cache_file_name) then
                        finish_lyrics_request(req_id); return
                    end
                elseif lrc.plainLyrics then
                    if save_lyrics(lrc.plainLyrics,
                        (lrc.artistName or artist) .. " - " .. (lrc.trackName or title),
                        is_stream, path, req_gen, "LRCLIB (Plain)", cache_file_name) then
                        finish_lyrics_request(req_id); return
                    end
                end
            end
            finish_lyrics_request(req_id)
            log_warn("Lyrics not found", 2)
        end)
    end

    if not nonempty(opts.musixmatch_token) then return search_lrclib() end

    -- Musixmatch is best-effort with a shorter timeout so LRCLIB still gets a turn
    local mxm_args = {
        "curl", "-fsS", "-A", "Mozilla/5.0",
        "--connect-timeout", "4", "--max-time", "6",
        "--get", "https://apic-desktop.musixmatch.com/ws/1.1/macro.subtitles.get",
        "--cookie", "x-mxm-token-guid=" .. opts.musixmatch_token,
        "--data", "app_id=web-desktop-app-v1.0",
        "--data", "usertoken=" .. opts.musixmatch_token,
        "--data-urlencode", "q_track=" .. title,
        "--data-urlencode", "q_artist=" .. artist,
    }

    active_lyrics_async_handle = mp.command_native_async({
        name = "subprocess", args = mxm_args, capture_stdout = true
    }, function(success, res, err)
        local is_current = (active_lyrics_request_id == req_id)
        if is_current then active_lyrics_async_handle = nil end
        if req_gen ~= file_generation or not is_current then return end
        if not success or not res or res.status ~= 0 or not nonempty(res.stdout) then
            return search_lrclib()
        end
        local mxm = utils.parse_json(res.stdout)
        if not mxm then return search_lrclib() end

        local msg  = mxm.message
        local hdr  = msg and msg.header
        local body = msg and msg.body
        local calls = body and body.macro_calls
        local matcher = calls and calls["matcher.track.get"]
        local m_body  = matcher and matcher.message and matcher.message.body
        local tr      = m_body and m_body.track

        local duration_match = true
        if tr and tr.track_length and dur > 0 and math.abs(tr.track_length - dur) > 15 then
            duration_match = false
        end

        if hdr and hdr.status_code == 200 and tr and duration_match then
            local txt, is_synced = "", false
            if tr.has_subtitles == 1 and calls["track.subtitles.get"] then
                local sub_list = calls["track.subtitles.get"].message.body.subtitle_list
                if sub_list and sub_list[1] then
                    txt = sub_list[1].subtitle.subtitle_body
                    is_synced = true
                end
            elseif tr.has_lyrics == 1 and calls["track.lyrics.get"] then
                local l_body = calls["track.lyrics.get"].message.body.lyrics
                if l_body then txt = l_body.lyrics_body end
            end

            local label = is_synced and "Musixmatch (Synced)" or "Musixmatch (Plain)"
            if txt ~= "" and save_lyrics(txt,
                (tr.artist_name or artist) .. " - " .. (tr.track_name or title),
                is_stream, path, req_gen, label, cache_file_name) then
                finish_lyrics_request(req_id); return
            end
        end
        search_lrclib()
    end)
end

------------------------------------------------------------------
-- Subtitles engine
------------------------------------------------------------------
local function pick_free_target(target_dir, stem, lang, ext)
    local n = 0
    while true do
        local suffix = n > 0 and ("_" .. n) or ""
        local candidate = utils.join_path(target_dir, stem .. suffix .. "." .. lang .. "." .. ext)
        if not file_exists(candidate) then return candidate, suffix end
        n = n + 1
        if n > 99 then return candidate, suffix end -- give up, just overwrite
    end
end

local function download_subs(manual_query, target_lang)
    abort_active_job()

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
        local media_title = mp.get_property("media-title") or "stream_video"
        real_fname = sanitize_filename(media_title) .. ".mkv"
    end

    -- Per-pid session dir, per-job scratch dir, and a session-scoped "kept"
    -- dir for subs that must survive the per-job cleanup.
    local session_tmp  = utils.join_path("/tmp", "mpv-subs-" .. tostring(pid))
    local job_tmp_dir  = utils.join_path(session_tmp, "job-" .. tostring(job_id))
    local keep_tmp_dir = utils.join_path(session_tmp, "kept")
    ensure_dir(job_tmp_dir)
    ensure_dir(keep_tmp_dir)

    -- ------------------------------------------------------------------
    -- Decide what to feed Subliminal.
    --
    -- Subliminal guesses title/season/episode from the *filename*, so the
    -- input path must be named correctly. Three cases:
    --
    --   * Manual query  → user typed exactly what to search. Create a stub
    --                     file with that name. Metadata-only refiners.
    --   * Stream        → no local file. Create a stub from media-title.
    --                     Metadata-only refiners.
    --   * Local file    → point Subliminal at the real file so hash
    --                     refiners can work.
    -- ------------------------------------------------------------------
    local input_target
    local stub_created
    local metadata_only = false

    if manual_query then
        -- Manual always wins: the user typed this because the auto name
        -- was wrong or a specific release is wanted.
        local clean = sanitize_filename(manual_query)
        if clean == "" then clean = "video" end
        if not clean:match("%.%w+$") then clean = clean .. ".mkv" end
        input_target = utils.join_path(job_tmp_dir, clean)
        local f = io.open(input_target, "w"); if f then f:close() end
        stub_created = input_target
        metadata_only = true
    elseif is_stream then
        local clean = real_fname
        if not clean:match("%.%w+$") then clean = clean .. ".mkv" end
        input_target = utils.join_path(job_tmp_dir, clean)
        local f = io.open(input_target, "w"); if f then f:close() end
        stub_created = input_target
        metadata_only = true
    else
        input_target = path
    end

    -- Stem Subliminal uses for its output: <stem>.<lang>.<ext>
    local search_stem = input_target:match("([^/\\]+)%.%w+$")
                     or input_target:match("([^/\\]+)$")
                     or "video"

    -- Final on-disk name: for local files, always use the media's own name
    -- so subs sit alongside the media consistently. For streams, name after
    -- whatever we searched for so the tmp filename is meaningful.
    local output_stem
    if is_stream then
        output_stem = search_stem
    else
        output_stem = real_fname:match("(.+)%.%w+$") or real_fname
    end

    log_info("Searching " .. target_lang[1] .. " subtitles...", 30)

    local args = {
        get_subliminal_bin(), "download",
        "-e", "utf-8",
        "-l", target_lang[2],
        "-m", tostring(opts.min_sub_score),
        "-w", tostring(opts.max_workers),
        "-d", job_tmp_dir,
    }

    local active_refiners = metadata_only and "metadata" or opts.refiners
    if nonempty(active_refiners) then
        for ref in active_refiners:gmatch("[^,]+") do
            table.insert(args, '-r'); table.insert(args, ref:match("^%s*(.-)%s*$"))
        end
    end
    if nonempty(opts.providers) then
        for prov in opts.providers:gmatch("[^,]+") do
            table.insert(args, '-p'); table.insert(args, prov:match("^%s*(.-)%s*$"))
        end
    end
    if opts.hearing_impaired then table.insert(args, '-hi') end
    table.insert(args, input_target)

    log_debug("subliminal cmd: " .. table.concat(args, " "))

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
            local why = err and tostring(err) or "unknown"
            return log_warn("Subliminal failed to run (" .. why
                .. "). Check subliminal_path in script-opts/subtitles.conf.", 4)
        end

        if res.status ~= 0 then
            log_debug("subliminal exit=" .. tostring(res.status)
                .. (res.stderr and res.stderr ~= "" and
                    (" stderr=" .. res.stderr:gsub("%s+$", "")) or ""))
        end

        for _, ext in ipairs(sub_exts) do
            local staged_sub = utils.join_path(job_tmp_dir,
                search_stem .. "." .. target_lang[2] .. "." .. ext)
            if file_exists(staged_sub) then
                local file_hash = get_file_hash(staged_sub)
                if file_hash and seen_sub_hashes[file_hash] then
                    clean_dir(job_tmp_dir)
                    return log_warn("No new subtitle found (duplicate file)", 2)
                end
                if file_hash then seen_sub_hashes[file_hash] = true end

                download_count = download_count + 1

                -- Where does the sub end up?
                local target_dir
                if opts.download_to_tmp or is_stream then
                    target_dir = keep_tmp_dir
                elseif writable_dir(media_dir) then
                    target_dir = media_dir
                else
                    target_dir = mp.command_native({ "expand-path", opts.lyrics_store })
                    ensure_dir(target_dir)
                end

                local final_sub = pick_free_target(target_dir, output_stem, target_lang[2], ext)
                local ok, move_err = move_file(staged_sub, final_sub)
                if not ok then
                    clean_dir(job_tmp_dir)
                    return log_warn("Failed to move subtitle: " .. tostring(move_err), 3)
                end

                -- VobSub companion (.idx + .sub)
                local load_target = final_sub
                if ext == "idx" or ext == "sub" then
                    local companion_ext = (ext == "idx") and "sub" or "idx"
                    local staged_companion = utils.join_path(job_tmp_dir,
                        search_stem .. "." .. target_lang[2] .. "." .. companion_ext)
                    if file_exists(staged_companion) then
                        local final_companion = final_sub:gsub("%." .. ext .. "$", "." .. companion_ext)
                        local ok_comp, comp_err = move_file(staged_companion, final_companion)
                        if not ok_comp then
                            os.remove(final_sub)
                            clean_dir(job_tmp_dir)
                            return log_warn("Failed to move VobSub companion: " .. tostring(comp_err), 3)
                        end
                        if ext == "sub" then load_target = final_companion end
                    elseif ext == "sub" then
                        load_target = final_sub
                    end
                end

                local add_ok, add_err = pcall(function()
                    mp.commandv("sub-add", load_target, "select",
                        "Downloaded • " .. target_lang[1], target_lang[2])
                end)
                if not add_ok then
                    log_warn("sub-add failed: " .. tostring(add_err), 3)
                end

                clean_dir(job_tmp_dir)
                mp.osd_message("", 0)
                return log_info(target_lang[1] .. " subtitle #" .. download_count .. " ready!", 2)
            end
        end

        clean_dir(job_tmp_dir)
        log_warn("No " .. target_lang[1] .. " subtitles found", 2)
    end)
end

local function download_alt_subs(manual_query)
    local lang = alt_languages[alt_lang_index]
    download_subs(manual_query, lang)
    alt_lang_index = (alt_lang_index % #alt_languages) + 1
end

------------------------------------------------------------------
-- Smart dispatcher
------------------------------------------------------------------
local function smart_dispatch(is_manual, is_alt)
    cancel_auto_download()

    local function execute_search(query)
        if has_video_track() then
            if is_alt then download_alt_subs(query)
            else download_subs(query, primary_lang) end
        else
            download_lyrics(query)
        end
    end

    if is_manual then
        if not user_input_loaded or not user_input then
            mp.osd_message("user-input-module not found. Can't prompt.", 2)
            return
        end
        local current_path = mp.get_property("path") or ""
        local current_filename = current_path:match("([^/\\]+)$") or current_path
        user_input.get_user_input(function(line, err)
            local query = nonempty(line)
            if err or not query then return end
            execute_search(query)
        end, {
            request_text  = "Enter title/query to search:",
            default_input = current_filename,
            cursor_pos    = #current_filename + 1,
        })
    else
        execute_search(nil)
    end
end

------------------------------------------------------------------
-- Auto-download on load
------------------------------------------------------------------
schedule_auto_download = function()
    auto_dl_timer = mp.add_timeout(opts.auto_download_delay, function()
        auto_dl_timer = nil
        if not has_video_track() then return end
        if not has_loaded_subtitle(primary_lang[2]) then
            download_subs(nil, primary_lang)
        end
    end)
end

------------------------------------------------------------------
-- Preflight
------------------------------------------------------------------
local function preflight()
    local path = get_subliminal_bin()
    if path:match("^[/~]") then
        local expanded = mp.command_native({ "expand-path", path })
        if not file_exists(expanded) then
            log_warn("Subliminal not found at: " .. tostring(expanded), 4)
        end
    else
        local res = utils.subprocess({ args = { "which", path }, capture_stdout = true })
        if res.status ~= 0 then
            log_debug("Subliminal not found on PATH (will fail at runtime): " .. path)
        end
    end
end
preflight()

------------------------------------------------------------------
-- Keybindings
------------------------------------------------------------------
mp.add_key_binding(opts.sub_download_binding, "smart-dl-primary",
    function() smart_dispatch(false, false) end)
mp.add_key_binding(opts.sub_download_manual_binding, "smart-dl-primary-manual",
    function() smart_dispatch(true, false) end)
mp.add_key_binding(opts.sub_download_alt_binding, "smart-dl-alt",
    function() smart_dispatch(false, true) end)
mp.add_key_binding(opts.sub_download_alt_manual_binding, "smart-dl-alt-manual",
    function() smart_dispatch(true, true) end)