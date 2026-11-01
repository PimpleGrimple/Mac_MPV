/**
 * mpv bridge — the one place that knows how to talk to the native host.
 *
 * Loaded as a content script (all pages), importScripts()'d by the service
 * worker, and a <script> in the popup, so every entry point (panel buttons,
 * YouTube button, browser commands, context menu, popup) shares the same
 * settings, URL checks and message format. Pure helpers are safe everywhere;
 * MPV.handle() / MPV.native() need chrome.* and are only called from the
 * service worker.
 */
(function (root) {
  'use strict';

  const HOST = 'com.playinmpv.host';

  // Saved from the popup; read fresh on every launch.
  const DEFAULTS = {
    qualityCap: 'best',          // stream quality:   best | 2160p | 1440p | 1080p | 720p | 480p | audio
    downloadQuality: 'best',     // download quality: same choices
    savePosition: true,
    startFromCurrentTime: true,
    autoPause: true,
    forceWindow: true,
    customFlags: ''              // everything else (hwdec, ontop, fullscreen, paths...) lives in mpv.conf
  };

  // Matched against the hostname (not the whole URL), so "wolfmax.com" or a
  // "?q=netflix.com" query string don't trip them.
  const DRM_HOSTS = [
    ['Netflix', /(^|\.)netflix\.com$/],
    ['Prime Video', /(^|\.)primevideo\.com$/],
    ['Disney+', /(^|\.)disneyplus\.com$/],
    ['Max', /(^|\.)max\.com$/],
    ['Hulu', /(^|\.)hulu\.com$/],
    ['Apple TV', /^tv\.apple\.com$/],
    ['Paramount+', /(^|\.)paramountplus\.com$/],
    ['Peacock', /(^|\.)peacocktv\.com$/]
  ];

  function checkUrl(urlStr) {
    let url;
    try { url = new URL(urlStr); } catch (e) {
      return { ok: false, reason: 'invalid', message: 'Invalid video URL.' };
    }
    if (url.protocol !== 'http:' && url.protocol !== 'https:') {
      return { ok: false, reason: 'invalid', message: 'Cannot play on internal browser pages.' };
    }
    const host = url.hostname.toLowerCase();
    for (const [name, re] of DRM_HOSTS) {
      if (re.test(host)) {
        return { ok: false, reason: 'drm', message: `DRM protected stream — ${name} is not supported.` };
      }
    }
    if (/(^|\.)amazon\.[a-z.]+$/.test(host) && /^\/(gp\/video|show|video)/.test(url.pathname)) {
      return { ok: false, reason: 'drm', message: 'DRM protected stream — Prime Video is not supported.' };
    }
    return { ok: true, hostname: host };
  }

  // Page titles are untrusted and noisy: collapse whitespace, drop control
  // characters, cap the length. (Quoting/escaping is the native host's job.)
  function cleanTitle(t) {
    const s = String(t || '')
      .replace(/[\u0000-\u001f\u007f]+/g, ' ')
      .replace(/\s+/g, ' ')
      .trim()
      .slice(0, 150);
    return s || 'video';
  }

  function cleanYoutubeUrl(urlStr) {
    try {
      const url = new URL(urlStr);
      if (url.pathname === '/watch') {
        const id = url.searchParams.get('v');
        if (id) return `${url.origin}/watch?v=${encodeURIComponent(id)}`;
      }
    } catch (e) { /* leave as is */ }
    return urlStr;
  }

  // Quality cap -> yt-dlp format selector.
  //
  // A plain `height<=N` filter is wrong for portrait video: yt-dlp's "height" is the long
  // side, so a 480p YouTube Short (480x854) has height 854 and is rejected by a 480 cap. The
  // best format that passed was 240p (426 tall), and with a 240 cap *nothing* passed, so
  // there was no video format at all and mpv ended up audio-only. yt-dlp computes an
  // aspect_ratio for every format, so portrait video is capped on its short side (width)
  // and everything else on height. Order matters, because `/` takes the first alternative
  // that matches anything:
  //   1-2  separate video + audio streams: portrait first, then everything else
  //   3-4  the same for pre-merged single files
  //   5    nothing fits under the cap: take the SMALLEST video rather than fail
  // "<=?" also accepts formats that don't report that field (some HLS), so a cap can never
  // make a plain stream unplayable. (No ">" anywhere, in case a host ever uses a shell.)
  function capFormat(cap) {
    if (cap === 'audio') return { format: 'bestaudio/best', audioOnly: true };
    const m = /^(\d{3,4})p$/.exec(cap || '');
    if (!m) return null;
    const n = m[1];
    return {
      format: [
        `bestvideo[aspect_ratio<1][width<=?${n}]+bestaudio`,
        `bestvideo[height<=?${n}]+bestaudio`,
        `best[aspect_ratio<1][width<=?${n}]`,
        `best[height<=?${n}]`,
        'worstvideo+bestaudio',
        'worst'
      ].join('/'),
      audioOnly: false,
      height: parseInt(n, 10)
    };
  }

  // Site adapters (site-adapters.js) can attach `alts` = [{height, url}, ...]: the same file in
  // several qualities, each with its own signed URL. Pick the tallest one within the cap, or
  // the smallest if every one is taller. capHeight Infinity (cap "best") -> the tallest.
  function pickAlt(alts, capHeight) {
    if (!Array.isArray(alts) || alts.length < 2) return null;
    const ok = alts.filter(a => a && typeof a.height === 'number' && typeof a.url === 'string' && checkUrl(a.url).ok);
    if (ok.length < 2) return null;
    const within = ok.filter(a => a.height <= capHeight);
    return within.length
      ? within.reduce((best, a) => (a.height > best.height ? a : best))
      : ok.reduce((best, a) => (a.height < best.height ? a : best));
  }

  function playFlags(s, req, cap) {
    const f = [];
    if (cap && cap.audioOnly) f.push('--force-window=immediate');
    if (s.savePosition) f.push('--save-position-on-quit');
    if (s.forceWindow && !f.includes('--force-window=immediate')) f.push('--force-window=immediate');
    if (s.startFromCurrentTime && typeof req.startTime === 'number' && req.startTime > 0) {
      f.push(`--start=${Math.floor(req.startTime)}`);
    }
    return f;
  }

  // mpv_path / ytdlp_path are always null: the host falls back to its own lookup. The
  // fields stay in the message because the native host reads them.

  /**
   * req: { action: 'play'|'download'|'check', url, ref, ua, title, format,
   *        type (media type), startTime }
   * s:   saved settings (missing keys fall back to DEFAULTS)
   * Throws on an unplayable URL. Pure — no chrome.* calls.
   */
  function buildMessage(req, s) {
    s = Object.assign({}, DEFAULTS, s || {});
    const action = req.action || 'play';

    if (action === 'check') {
      return { type: 'CHECK_STATUS', mpv_path: null, ytdlp_path: null };
    }

    const chk = checkUrl(req.url);
    if (!chk.ok) throw new Error(chk.message);

    let url = cleanYoutubeUrl(req.url);
    // Stream and download have their own quality setting.
    const cap = capFormat(action === 'download' ? s.downloadQuality : s.qualityCap);
    // A site that exposes separate files per quality: choose by the same setting. An explicit
    // rendition (req.format) and audio-only both skip this.
    if (!req.format && !(cap && cap.audioOnly)) {
      const alt = pickAlt(req.alts, cap ? cap.height : Infinity);
      if (alt) {
        url = alt.url;
        console.debug('[MB] site quality', cap ? cap.height + 'p cap' : 'best', '->', alt.height + 'p', alt.guess ? '(suffix swapped)' : '(link from page)');
      }
    }
    // An explicit format (a rendition picked in the panel) always beats the cap.
    const format = req.format || (cap ? cap.format : '');

    if (action === 'download') {
      return {
        type: 'DOWNLOAD',
        url,
        ref: req.ref || '',
        ua: req.ua || '',
        title: cleanTitle(req.title),
        format,
        ytdlp_path: null
      };
    }

    return {
      type: 'PLAY',
      url,
      ref: req.ref || '',
      ua: req.ua || '',
      title: cleanTitle(req.title),
      media_type: req.type || '',
      format,
      flags: playFlags(s, req, req.format ? null : cap),
      custom_flags: s.customFlags || '',
      mpv_path: null,
      ytdlp_path: null
    };
  }

  function native(msg) {
    return new Promise((resolve, reject) => {
      chrome.runtime.sendNativeMessage(HOST, msg, res => {
        if (chrome.runtime.lastError) reject(new Error(chrome.runtime.lastError.message));
        else resolve(res);
      });
    });
  }

  // Service-worker entry point: settings -> message -> host -> normalised result.
  async function handle(req) {
    const settings = await chrome.storage.local.get(DEFAULTS);
    const msg = buildMessage(req, settings);
    const res = await native(msg);
    if (!res) return { ok: false, error: 'No response from native host' };
    return { ok: res.ok !== false, error: res.error, response: res };
  }

  root.MPV = { HOST, DEFAULTS, checkUrl, cleanTitle, cleanYoutubeUrl, pickAlt, buildMessage, native, handle };
})(self);
