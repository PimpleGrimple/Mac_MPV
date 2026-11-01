(function () {
  'use strict';

  function GM_getValue(key, def) {
    try {
      let val = localStorage.getItem(key);
      if (val === null) return def;
      try { return JSON.parse(val); } catch(e) { return val; }
    } catch(err) { return def; }
  }
  function GM_setValue(key, value) {
    try { localStorage.setItem(key, JSON.stringify(value)); } catch(err) {}
  }
  function GM_download(opts) {
    const a = document.createElement('a');
    a.href = opts.url;
    a.download = opts.name || 'download';
    a.click();
  }


  const HOST = location.hostname;
  const MODE_KEY = 'mode:' + HOST;
  const TYPES_KEY = 'blockTypes:' + HOST;
  const AUDIO_MARK_KEY = 'audioMarkers:' + HOST;
  const ICON_KEY = 'iconThreshold:' + HOST;
  
  let GLOBAL_MODE = GM_getValue('GLOBAL_MODE', 'block');
  let DISABLED_SITES = GM_getValue('DISABLED_SITES', []);
  let MODE = GM_getValue(MODE_KEY, GLOBAL_MODE);
  
  function normalizeSiteHost(value) {
    let s = String(value || '').trim().toLowerCase();
    if (!s) return '';
    s = s.replace(/^https?:\/\//, '');
    s = s.split('/')[0].split('?')[0].split('#')[0];
    s = s.replace(/^www\./, '');
    return s;
  }

  function isHostDisabled(host, disabledSites) {
    const h = normalizeSiteHost(host);
    if (!h || !disabledSites || !disabledSites.length) return false;
    return disabledSites.some(site => {
      const d = normalizeSiteHost(site);
      return !!d && (h === d || h.endsWith('.' + d));
    });
  }

  if (isHostDisabled(HOST, DISABLED_SITES)) {
    MODE = 'off';
  }

  let BLOCK_TYPES = GM_getValue(TYPES_KEY, { image: true, video: true, audio: true, font: false, subtitle: false });
  const getActiveTypes = () => Object.keys(BLOCK_TYPES).filter(k => BLOCK_TYPES[k]);
  const EXCEPTIONS = [];
  const EXCEPTION_PATTERNS = [];
  const BLOCK_KEYWORDS = ['.m4s', '.ts', '_init.mp4', 'init-', '/init', '/segment', '/frag', 'seg-'];

  chrome.storage.local.get(['GLOBAL_MODE', 'DISABLED_SITES', 'TYPES', 'BLOCK_KEYWORDS', 'EXCEPTIONS'], function(result) {
    if (result.GLOBAL_MODE) {
      GLOBAL_MODE = result.GLOBAL_MODE;
      GM_setValue('GLOBAL_MODE', GLOBAL_MODE);
    }
    if (result.DISABLED_SITES) {
      DISABLED_SITES = result.DISABLED_SITES.map(normalizeSiteHost).filter(Boolean);
      GM_setValue('DISABLED_SITES', DISABLED_SITES);
    }
    
    if (isHostDisabled(HOST, DISABLED_SITES)) {
      MODE = 'off';
    } else {
      if (!localStorage.getItem(MODE_KEY)) {
        MODE = GLOBAL_MODE;
      }
    }

    if (result.TYPES) {
      BLOCK_TYPES = { image: false, video: false, audio: false, font: false, subtitle: false };
      result.TYPES.forEach(t => BLOCK_TYPES[t] = true);
    }
    if (result.BLOCK_KEYWORDS) {
      BLOCK_KEYWORDS.length = 0;
      BLOCK_KEYWORDS.push(...result.BLOCK_KEYWORDS);
    }
    if (result.EXCEPTIONS) {
      EXCEPTIONS.length = 0;
      EXCEPTIONS.push(...result.EXCEPTIONS);
      EXCEPTION_PATTERNS.length = 0;
      EXCEPTION_PATTERNS.push(...EXCEPTIONS.map(pat => {
        if (pat.includes('*')) {
          const esc = pat.replace(/[.+^${}()|[\]\\]/g, '\\$&').replace(/\*/g, '.*');
          return { type: 're', re: new RegExp(esc, 'i') };
        }
        return { type: 'str', str: pat.toLowerCase() };
      }));
    }
  });

  chrome.storage.onChanged.addListener((changes, area) => {
    if (area === 'local') {
      if (changes.GLOBAL_MODE) {
        GLOBAL_MODE = changes.GLOBAL_MODE.newValue || 'block';
        if (!localStorage.getItem(MODE_KEY) && !isHostDisabled(HOST, DISABLED_SITES)) {
          MODE = GLOBAL_MODE;
        }
      }
      if (changes.DISABLED_SITES) {
        DISABLED_SITES = (changes.DISABLED_SITES.newValue || []).map(normalizeSiteHost).filter(Boolean);
        GM_setValue('DISABLED_SITES', DISABLED_SITES);
        if (isHostDisabled(HOST, DISABLED_SITES)) {
          MODE = 'off';
            }
      }
      if (changes.MODE) MODE = changes.MODE.newValue;
      if (changes.TYPES) {
        BLOCK_TYPES = { image: false, video: false, audio: false, font: false, subtitle: false };
        changes.TYPES.newValue.forEach(t => BLOCK_TYPES[t] = true);
      }
      if (changes.BLOCK_KEYWORDS) {
        BLOCK_KEYWORDS.length = 0;
        BLOCK_KEYWORDS.push(...changes.BLOCK_KEYWORDS.newValue);
      }
      if (changes.EXCEPTIONS) {
        EXCEPTIONS.length = 0;
        EXCEPTIONS.push(...changes.EXCEPTIONS.newValue);
        EXCEPTION_PATTERNS.length = 0;
        EXCEPTION_PATTERNS.push(...EXCEPTIONS.map(pat => {
          if (pat.includes('*')) {
            const esc = pat.replace(/[.+^${}()|[\]\\]/g, '\\$&').replace(/\*/g, '.*');
            return { type: 're', re: new RegExp(esc, 'i') };
          }
          return { type: 'str', str: pat.toLowerCase() };
        }));
      }
    }
  });




  const AUDIO_MARKERS = GM_getValue(AUDIO_MARK_KEY, '')
    .replace(/\\n/g, '\n').split('\n').map(s => s.trim()).filter(Boolean);

  const ICON_THRESHOLD = parseInt(GM_getValue(ICON_KEY, '48'), 10) || 48;

  const MANIFEST_EXT = /\.(m3u8|mpd|f4m|ism\/manifest|json\?base64_init=1)(\?|#|$)/i;
  const PROGRESSIVE_VIDEO_EXT = /\.(mp4|m4v|m4s|webm|mkv|flv|mov|ts|m2t|aac|m4a|mp3|ogg|ogv|oga|opus|weba)(\?|#|$)/i;
  const FONT_EXT = /\.(woff2?|ttf|otf|eot)(\?|#|$)/i;
  const IMAGE_EXT = /\.(png|jpe?g|gif|webp|avif|svg|bmp|ico)(\?|#|$)/i;
  const SUBTITLE_EXT = /\.(vtt|srt|ass|ssa|ttml|ttml2|sbv|dfxp)(\?|#|$)/i;
  const CSS_URL_RE = /url\(\s*(['"]?)(.*?)\1\s*\)/gi;

  function isManifestUrl(url) {
    if (!url) return false;
    if (typeof url !== 'string') url = url.toString();
    return MANIFEST_EXT.test(url);
  }
  function isAudioManifestUrl(url) {
    return typeof url === 'string' && (matchesAudioOverride(url) || /\/audio\/|audio_/i.test(url));
  }
  function manifestType(url) {
    return isAudioManifestUrl(url) ? 'audio' : 'video';
  }
  function isHardBlockableVideoUrl(url) {
    if (!url) return false;
    if (typeof url !== 'string') url = url.toString();
    return PROGRESSIVE_VIDEO_EXT.test(url);
  }
  function isVideoUrl(url) {
    return typeof url === 'string' && (isManifestUrl(url) || isHardBlockableVideoUrl(url));
  }
  function isManifestContentType(ct) {
    if (!ct) return false;
    const lower = ct.toLowerCase();
    return lower.includes('mpegurl') || 
           lower.includes('dash+xml') || 
           lower.includes('mpegts') ||
           lower.includes('application/f4m');
  }

  function isVideoContentType(ct) {
    if (!ct) return false;
    const lower = ct.toLowerCase();
    return lower.includes('video/') || lower.includes('audio/');
  }

  const SEGMENT_EXT = /\.(ts|m4s)(\?|#|$)/i;
  const INIT_SEGMENT_RE = /_init\.mp4(\?|#|$)/i;
  function isSegmentUrl(url) {
    return typeof url === 'string' && (SEGMENT_EXT.test(url) || INIT_SEGMENT_RE.test(url));
  }

  const progressiveUrlSeen = new Set();
  function canonicalizeUrl(url) {
    try { return new URL(url, location.href).href; } catch (e) { return url; }
  }
  function shouldAllowFirstProgressiveRequest(url) {
    const key = canonicalizeUrl(url);
    if (progressiveUrlSeen.has(key)) return false;
    progressiveUrlSeen.add(key);
    return true;
  }

  const manifestRows = new Map();
  const knownVariantUrls = new Set();
  function manifestCanonicalKey(url) {
    try {
      const u = new URL(url, location.href);
      return u.origin + u.pathname;
    } catch (e) { return url; }
  }

  function parseM3U8Variants(text, baseUrl) {
    const lines = text.split(/\r?\n/);
    const seen = new Set();
    const known = [];
    const unknown = [];

    for (let i = 0; i < lines.length; i++) {
      const line = lines[i].trim();
      if (!line.startsWith('#EXT-X-STREAM-INF')) continue;

      const resMatch = /RESOLUTION=\d+x(\d+)/i.exec(line);
      const height = resMatch ? parseInt(resMatch[1], 10) : null;
      const quality = Number.isFinite(height) ? height + 'p' : null;
      const bandwidthMatch = /(?:^|[,:])BANDWIDTH=(\d+)/i.exec(line);
      const bandwidth = bandwidthMatch ? parseInt(bandwidthMatch[1], 10) : 0;
      const avgMatch = /AVERAGE-BANDWIDTH=(\d+)/i.exec(line);
      const avgBandwidth = avgMatch ? parseInt(avgMatch[1], 10) : 0;
      const fpsMatch = /FRAME-RATE=([\d.]+)/i.exec(line);
      const fps = fpsMatch ? parseFloat(fpsMatch[1]) : null;
      const codecMatch = /CODECS="([^"]+)"/i.exec(line);
      const codecs = codecMatch ? codecMatch[1] : '';

      let uri = null;
      for (let j = i + 1; j < lines.length; j++) {
        const next = lines[j].trim();
        if (!next || next.startsWith('#')) continue;
        uri = next;
        break;
      }
      if (!uri) continue;

      try {
        const absoluteUrl = new URL(uri, baseUrl).href;
        // Only a *true* duplicate (same URL, resolution, bitrate and codecs)
        // is dropped. Same resolution with a different bitrate is a different
        // rendition and must stay selectable.
        const key = [absoluteUrl, height, bandwidth, avgBandwidth, codecs].join('|');
        if (seen.has(key)) continue;
        seen.add(key);
        const candidate = { url: absoluteUrl, quality, height, bandwidth, avgBandwidth, fps, codecs };
        (quality ? known : unknown).push(candidate);
      } catch (e) {}
    }

    const rate = v => v.avgBandwidth || v.bandwidth || 0;
    known.sort((a, b) => (b.height - a.height) || (rate(b) - rate(a)));
    unknown.sort((a, b) => rate(b) - rate(a));
    const variants = known.concat(unknown);
    labelVariants(variants);
    return variants;
  }

  function formatBitrate(bps) {
    if (!bps) return '';
    if (bps >= 1e6) return (Math.round(bps / 1e4) / 100) + ' Mbps';
    return Math.round(bps / 1000) + ' kbps';
  }

  function codecFamily(codecs) {
    const c = String(codecs || '').toLowerCase();
    if (/av01/.test(c)) return 'AV1';
    if (/hvc1|hev1|dvh1|dvhe/.test(c)) return 'HEVC';
    if (/vp09|vp9/.test(c)) return 'VP9';
    if (/avc1|avc3/.test(c)) return 'H.264';
    return '';
  }

  // Gives each variant a label like "1080p · 4.5 Mbps" (+ fps / codec when
  // those are what tell renditions apart). Guaranteed unique per variant.
  function labelVariants(variants) {
    const families = new Set(variants.map(v => codecFamily(v.codecs)).filter(Boolean));
    const showCodec = families.size > 1;
    const used = new Map();
    for (const v of variants) {
      const parts = [v.quality || 'Unknown'];
      const br = formatBitrate(v.avgBandwidth || v.bandwidth);
      if (br) parts.push(br);
      if (v.fps && v.fps > 30) parts.push(Math.round(v.fps) + 'fps');
      if (showCodec && codecFamily(v.codecs)) parts.push(codecFamily(v.codecs));
      let label = parts.join(' · ');
      const n = (used.get(label) || 0) + 1;
      used.set(label, n);
      if (n > 1) label += ' #' + n;
      v.label = label;
    }
  }

  // yt-dlp format selector for one exact rendition: height + bitrate window,
  // falling back to height-only if the bitrate window matches nothing.
  function variantToFormatSelector(v) {
    if (!v || !Number.isFinite(v.height)) return null;
    const h = v.height;
    const bw = v.avgBandwidth || v.bandwidth;
    const heightOnly = `bv*[height=${h}]+ba/b[height=${h}]`;
    if (!bw) return heightOnly;
    const tbr = bw / 1000;
    const lo = Math.floor(tbr - 1);
    const hi = Math.ceil(tbr + 1);
    const exact = `[height=${h}][tbr>=${lo}][tbr<=${hi}]`;
    return `bv*${exact}+ba/b${exact}/${heightOnly}`;
  }

  function qualityToFormatSelector(quality) {
    const match = /^(\d{3,4})p$/i.exec(String(quality || ''));
    if (!match) return null;
    const height = parseInt(match[1], 10);
    if (!Number.isFinite(height)) return null;
    return `bv*[height=${height}]+ba/b[height=${height}]`;
  }

  // Stashed on window (not a module-local var) so a second injection into the same
  // page context — e.g. an extension reload without a page reload — recovers the
  // true native fetch instead of accidentally capturing our own wrapped version.
  window.__mbNativeFetch = window.__mbNativeFetch || window.fetch;
  const origFetch = window.__mbNativeFetch;
  const masterPlaylistsParsed = new Set();

  function parseMasterText(masterUrl, text) {
    if (!/#EXT-X-STREAM-INF/i.test(text)) return;
    const variants = parseM3U8Variants(text, masterUrl);
    if (!variants.length) return;

    const key = manifestCanonicalKey(masterUrl);
    for (const variant of variants) {
      try {
        knownVariantUrls.add(canonicalizeUrl(variant.url));
      } catch (e) {}
    }

    const entryRef = manifestRows.get(key);
    if (entryRef) {
      entryRef.state.variants = variants;
      updateEntryDisplay(entryRef, entryRef.state.url);

      // This site can expose each resolution as a separate request in addition
      // to the master playlist. Once the master has been parsed, those child
      // playlists belong inside the selector and should not appear as separate
      // rows.
      for (let i = allEntryRefs.length - 1; i >= 0; i--) {
        const ref = allEntryRefs[i];
        if (ref === entryRef || !ref.state || ref.state.type === 'audio') continue;
        if (knownVariantUrls.has(canonicalizeUrl(ref.state.url))) {
          const variantUrlKey = canonicalizeUrl(ref.state.url);
          allEntryRefs.splice(i, 1);
          for (let j = collected.length - 1; j >= 0; j--) {
            if (canonicalizeUrl(collected[j].url) === variantUrlKey) {
              collected.splice(j, 1);
              break;
            }
          }
        }
      }
      notifyChange();
    }
  }

  function maybeParseMasterPlaylist(url, referrer) {
    const key = manifestCanonicalKey(url);
    if (masterPlaylistsParsed.has(key)) return;
    masterPlaylistsParsed.add(key);

    const fromPage = origFetch(url).then(response => {
      if (!response.ok) throw new Error(`HTTP ${response.status}`);
      return response.text();
    });

    const fromExtension = () => new Promise((resolve, reject) => {
      chrome.runtime.sendMessage(
        {
          __mbFetchManifest: true,
          url,
          ref: referrer || location.href,
          ua: navigator.userAgent
        },
        response => {
          if (chrome.runtime.lastError) {
            reject(new Error(chrome.runtime.lastError.message));
            return;
          }
          if (!response || !response.ok) {
            reject(new Error(response && response.error || 'Manifest fetch failed'));
            return;
          }
          resolve(response.text || '');
        }
      );
    });

    fromPage
      .catch(() => fromExtension())
      .then(text => {
        if (!text || !/#EXT-X-STREAM-INF/i.test(text)) {
          throw new Error('Not a parseable HLS master playlist');
        }
        parseMasterText(url, text);
      })
      .catch(error => {
        // Allow a later duplicate capture of the same master to retry after a
        // transient CDN/worker/native-host failure rather than permanently
        // suppressing the selector for the rest of the page session.
        masterPlaylistsParsed.delete(key);
        try { console.debug('[Media Blocker] HLS master parse failed:', error); } catch (e) {}
      });
  }

  const QUALITY_RE = /(\d{3,4})p(?![a-z0-9])/i;
  function extractQuality(url) {
    if (isAudioManifestUrl(url)) return null;
    const m = QUALITY_RE.exec(url);
    return m ? m[1] + 'p' : null;
  }

  function isPlausibleEpochSeconds(n) {
    const nowSec = Date.now() / 1000;
    return n > nowSec - 5 * 365 * 86400 && n < nowSec + 5 * 365 * 86400;
  }

  function extractExpiryEpoch(url) {
    let u;
    try { u = new URL(url); } catch (e) { return null; }
    const params = u.searchParams;

    const policy = params.get('Policy');
    if (policy) {
      try {
        const std = policy.replace(/-/g, '+').replace(/_/g, '=').replace(/~/g, '/');
        const json = JSON.parse(atob(std));
        const stmt = json.Statement && json.Statement[0];
        const epoch = stmt && stmt.Condition && stmt.Condition.DateLessThan
          && stmt.Condition.DateLessThan['AWS:EpochTime'];
        if (typeof epoch === 'number') return epoch;
      } catch (e) {}
    }

    for (const key of ['expires', 'exp', 'Expires']) {
      const v = params.get(key);
      if (v && /^\d+$/.test(v)) {
        const n = parseInt(v, 10);
        if (isPlausibleEpochSeconds(n)) return n;
      }
    }

    const t = params.get('t');
    if (t && /^\d+$/.test(t)) {
      const n = parseInt(t, 10);
      if (isPlausibleEpochSeconds(n)) return n;
    }

    return null;
  }

  function guessCssUrlType(url) {
    if (url.includes('manifest.webmanifest') || url.includes('manifest.json')) return 'unknown';
    if (FONT_EXT.test(url)) return 'font';
    if (IMAGE_EXT.test(url)) return 'image';
    if (SUBTITLE_EXT.test(url)) return 'subtitle';
    if (isVideoUrl(url)) return 'video';
    return 'image';
  }

  function isSvgUrl(url) { return typeof url === 'string' && /\.svg(\?|#|$)/i.test(url); }

  const collected = [];
  const collectedUrls = new Set();



  const AUDIO_MARKER_PATTERNS = AUDIO_MARKERS.map(pat => {
    if (pat.includes('*')) {
      const esc = pat.replace(/[.+^${}()|[\]\\]/g, '\\$&').replace(/\*/g, '.*');
      return { type: 're', re: new RegExp(esc, 'i') };
    }
    return { type: 'str', str: pat.toLowerCase() };
  });
  function matchesPatternList(url, patterns) {
    if (!url || patterns.length === 0) return false;
    let resolved = url;
    try { resolved = new URL(url, location.href).href; } catch (e) {}
    const lower = resolved.toLowerCase();
    for (const p of patterns) {
      if (p.type === 're' ? p.re.test(resolved) : lower.includes(p.str)) return true;
    }
    return false;
  }
  function matchesAudioOverride(url) {
    return matchesPatternList(url, AUDIO_MARKER_PATTERNS);
  }

  function matchesException(url) {
    return matchesPatternList(url, EXCEPTION_PATTERNS);
  }

  try {
    // Note: this attaches to the content script's isolated-world `window`, not the
    // page's main-world window — visible via DevTools' context dropdown, not the
    // regular page console. (unsafeWindow, used here previously, is Tampermonkey-only
    // and doesn't exist in a raw MV3 content script; that version always threw and
    // was silently swallowed by this try/catch.)
    window.__mbDebug = {
      exceptionsRaw: EXCEPTIONS,
      exceptionPatterns: EXCEPTION_PATTERNS,
      host: HOST,
      checkException: url => matchesException(url),
      checkAudioOverride: url => matchesAudioOverride(url),
      audioMarkersRaw: AUDIO_MARKERS,
      checkShouldBlock: (type, url) => shouldIntercept(type, url, null),
      canonicalize: url => canonicalizeUrl(url),
      manifestRowCount: () => manifestRows.size,
      collectedCount: () => collected.length,
      forceReinstall: () => { installImageSrcHook(); installSetAttributeHook(); },
    };
  } catch (e) {}

  function isTinyIcon(el) {
    if (!el) return false;
    const w = parseInt(el.getAttribute('width'), 10);
    const h = parseInt(el.getAttribute('height'), 10);
    if (!isNaN(w) && !isNaN(h) && w > 0 && h > 0) {
      return w <= ICON_THRESHOLD && h <= ICON_THRESHOLD;
    }
    return false;
  }

  function shouldIntercept(type, url, el) {
    if (url && url.includes('__mb_preview=1')) return false;
    if (!BLOCK_TYPES[type]) return false;
    if (matchesException(url)) return false;
    if (type === 'image' && isTinyIcon(el)) return false;
    return true;
  }

  // True only in the top frame — with all_frames:true, content.js also runs inside
  // embedded iframes, and only the top frame should ever draw the panel.
  const IS_TOP = window.self === window.top;

  // Captured entries. Declared up here because the popup-facing code below runs on
  // disabled sites too, where this script returns early.
  const allEntryRefs = [];

  function record(type, url, el) {
    // new URL('', base) is the base itself, so a blank/whitespace value would otherwise
    // turn into "the page URL" below.
    if (typeof url !== 'string') return;
    url = url.trim();
    if (!url || url.startsWith('data:') || url.startsWith('blob:') || url === 'about:blank') return;

    try {
      url = new URL(url, location.href).href;
    } catch (e) {}

    if (!IS_TOP) {
      // Not the top frame — don't build our own panel, just hand the capture up
      // to the top frame's instance of this script.
      try { window.top.postMessage({ __mbCapture: true, type, url, ref: location.href }, '*'); } catch (e) {}
      return;
    }
    recordResolved(type, url, location.href, null, el);
  }

  function recordResolved(type, url, ref, qualityOverride, el) {
    const isManifest = (type === 'video' || type === 'audio') && isManifestUrl(url);
    if (type === 'video' && knownVariantUrls.has(canonicalizeUrl(url))) {
      return;
    }
    if (isManifest) {
      maybeParseMasterPlaylist(url, ref);
      const key = manifestCanonicalKey(url);
      const existing = manifestRows.get(key);
      if (existing) {
        existing.state.url = url;
        existing.state.ref = ref;
        existing.state.expiry = extractExpiryEpoch(url);
        updateEntryDisplay(existing, url);
        return;
      }
    }

    if (collectedUrls.has(url)) return;
    collectedUrls.add(url);

    collected.push({ type, url, ref });
    const state = {
      url, ref, el, type,
      quality: type === 'video' || type === 'audio' ? (qualityOverride || extractQuality(url)) : null,
      expiry: type === 'video' || type === 'audio' ? extractExpiryEpoch(url) : null,
    };
    const entryRef = addEntry(type, state);
    if (isManifest && entryRef) {
      manifestRows.set(manifestCanonicalKey(url), entryRef);
    }
  }

  function parseSrcset(value) {
    if (!value) return [];
    return String(value)
      .split(/,(?=\s)/)
      .map(part => part.trim())
      .filter(Boolean)
      .map(part => {
        const sp = part.indexOf(' ');
        if (sp === -1) return { url: part, descriptor: '' };
        return { url: part.slice(0, sp), descriptor: part.slice(sp).trim() };
      });
  }

  function buildSrcset(candidates) {
    return candidates
      .map(c => c.descriptor ? `${c.url} ${c.descriptor}` : c.url)
      .join(', ');
  }

  function filterSrcset(value, type, el) {
    const candidates = parseSrcset(value);
    if (candidates.length === 0) return { filtered: '', blockedAny: false, allBlocked: false };
    const kept = [];
    let blockedAny = false;
    for (const c of candidates) {
      if (shouldIntercept(type, c.url, el)) {
        record(type, c.url, el);
        if (MODE === 'block') blockedAny = true;
        else kept.push(c);
      } else {
        kept.push(c);
      }
    }
    return {
      filtered: buildSrcset(kept),
      blockedAny,
      allBlocked: blockedAny && kept.length === 0,
    };
  }

  
  
  
  
  // ===========================================================================
  // Stream list (headless)
  //
  // This script draws nothing on the page. It collects what the page requests into
  // allEntryRefs ({ state } per capture) and answers the toolbar popup, which renders
  // the list and drives every action through the messages in the "mpv integration"
  // block below (__mbPageInfo, __mbSelectVariant, __mbDownloadFile, __mbClear).
  // ===========================================================================
  let entrySeq = 0;

  function isExpired(state) {
    return typeof state.expiry === 'number' && state.expiry - Date.now() / 1000 <= 0;
  }

  // What a click on a row's name copies: the URL bundled with its referer / UA / chosen
  // rendition as a "#MBSTREAM" JSON blob, so copypaste.lua can restore them in mpv. With
  // a chosen rendition it's the *master* URL plus a yt-dlp format selector, because a
  // child playlist is often video-only.
  function copyTextFor(state) {
    const fmt = state.downloadFormat || null;
    const playUrl = fmt ? state.url : (state.selectedUrl || state.url);
    const payload = { url: playUrl };
    if (state.ref) payload.ref = state.ref;
    if (navigator.userAgent) payload.ua = navigator.userAgent;
    if (fmt) {
      payload.format = fmt;
      if (state.selectedVariant && state.selectedVariant.label) payload.label = state.selectedVariant.label;
    }
    return (payload.ref || payload.ua || payload.format)
      ? '#MBSTREAM\n' + JSON.stringify(payload)
      : playUrl;
  }

  // Plain, serialisable snapshot of one entry for the popup.
  function entryView(ref) {
    const s = ref.state;
    const variants = s.variants || [];
    return {
      id: s.id,
      type: s.type,
      url: s.url,
      selectedUrl: s.selectedUrl || s.url,
      name: formatFilename(s.url),
      svg: s.type === 'image' && isSvgUrl(s.url),
      quality: s.quality || null,
      variants: variants.map(v => ({
        label: v.label || v.quality || 'Unknown',
        detail: [v.quality, formatBitrate(v.bandwidth), v.fps ? v.fps + 'fps' : '', v.codecs].filter(Boolean).join(' · ')
      })),
      selectedIndex: s.selectedVariant ? variants.indexOf(s.selectedVariant) : -1,
      expiry: typeof s.expiry === 'number' ? s.expiry : null,
      expired: isExpired(s),
      copyText: copyTextFor(s),
      req: streamRequest(s, s.type)
    };
  }

  function selectVariant(ref, index) {
    const s = ref.state;
    const v = index >= 0 && s.variants ? (s.variants[index] || null) : null;
    s.selectedVariant = v;
    s.selectedUrl = v ? v.url : s.url;
    s.selectedQuality = v ? v.quality : null;
    s.downloadFormat = variantToFormatSelector(v);
  }

  // Images and fonts are saved straight from the page (its cookies/referer apply, and
  // MODE is flipped off for the duration so our own network hooks let the request
  // through); everything else goes to yt-dlp through the native host.
  async function downloadFile(state, type) {
    const targetUrl = state.selectedUrl || state.url;
    let filename = targetUrl.split('/').pop().split('?')[0];
    if (!filename) filename = type === 'image' ? 'image.jpg' : 'font.woff';

    try {
      const oldMode = MODE;
      let resp;
      try {
        MODE = 'off';
        resp = await fetch(targetUrl, { mode: 'cors' });
      } finally {
        MODE = oldMode;
      }
      if (resp.ok) {
        const blob = await resp.blob();
        const blobUrl = URL.createObjectURL(blob);
        const a = document.createElement('a');
        a.href = blobUrl;
        a.download = filename;
        document.body.appendChild(a);
        a.click();
        document.body.removeChild(a);
        setTimeout(() => URL.revokeObjectURL(blobUrl), 10000);
        return { ok: true };
      }
    } catch (e) {}

    GM_download({
      url: targetUrl,
      name: filename,
      headers: { 'Referer': window.location.href, 'Origin': window.location.origin },
      saveAs: false,
      onerror: () => { window.open(targetUrl, '_blank'); }
    });
    return { ok: true };
  }

  function clearEntries() {
    allEntryRefs.length = 0;
    collected.length = 0;
    collectedUrls.clear();
    manifestRows.clear();
    masterPlaylistsParsed.clear();   // so a re-captured master gets its rendition list again
    notifyChange();
  }

  function addEntry(type, state) {
    if (MODE === 'off') return null;
    state.id = ++entrySeq;
    state.ref = state.ref || document.location.href;
    const entryRef = { state };
    allEntryRefs.push(entryRef);
    notifyChange();
    return entryRef;
  }

  // Tells the extension something changed: the service worker keeps the toolbar badge
  // current, and an open popup re-reads the list. Debounced; top frame only.
  let notifyTimer = null;
  function notifyChange() {
    if (!IS_TOP || notifyTimer) return;
    notifyTimer = setTimeout(() => {
      notifyTimer = null;
      const streams = allEntryRefs.filter(r => r.state.type === 'video' || r.state.type === 'audio').length;
      try {
        chrome.runtime.sendMessage(
          { __mbChanged: true, streams, total: allEntryRefs.length, mode: MODE },
          () => { void chrome.runtime.lastError; }
        );
      } catch (e) {}
    }, 120);
  }

  // Captures broadcast by the service worker (chrome.tabs.sendMessage reaches every
  // injected frame in the tab, so only the top frame acts on it).
  chrome.runtime.onMessage.addListener((msg, sender, sendResponse) => {
    if (msg.__mbCapture) {
      if (!IS_TOP) return;
      recordResolved(msg.type, msg.url, msg.ref || location.href, null, null);
    }
  });

  function updateEntryDisplay(entryRef, newUrl) {
    notifyChange();
  }

  // Captures relayed up from embedded iframes (see record()) join this frame's list.
  if (IS_TOP) {
    window.addEventListener('message', e => {
      if (!e.data || !e.data.__mbCapture) return;
      let { type, url, ref } = e.data;
      if (!url) return;
      try { url = new URL(url, ref || e.origin).href; } catch (err) {}
      recordResolved(type, url, ref || e.origin || location.href, null, null);
    });
  }


  notifyChange();   // announce this page (resets the toolbar badge on a fresh load)

  // NOTE: everything from here to the `MODE === 'off'` return below must not depend on
  // the capture/panel machinery being active — the browser command, the YouTube button and the
  // popup must keep working on sites listed under Disabled Sites.

  // ===========================================================================
  // mpv integration (merged from "Play in MPV")
  //
  // One set of helpers behind every way of starting mpv from a page: the panel's
  // row buttons, the YouTube player button, the browser command, the context
  // menu (via __mbBestStream) and the toolbar popup (via __mbPageInfo). They all
  // end in background.js -> MPV.handle(), so the popup settings apply to all.
  // ===========================================================================

  // Block <-> Capture for this site. Used by the FAB and by the popup.
  function setSiteMode(next) {
    GM_setValue(MODE_KEY, next);
    chrome.runtime.sendMessage({ type: 'SET_SITE_MODE', host: HOST, mode: next }, () => {
      location.reload();
    });
  }

  // What to send to the host for a captured row. A resolution-specific HLS child
  // playlist is often video-only, so with a chosen rendition we send the master
  // playlist plus a yt-dlp format selector and let it pick that height + best audio.
  function streamRequest(state, type) {
    const fmt = state.downloadFormat || null;
    const req = {
      type,
      url: fmt ? state.url : (state.selectedUrl || state.url),
      format: fmt,
      ref: state.ref,
      ua: navigator.userAgent,
      title: document.title || 'video'
    };
    // Sites that serve one file per quality (site-adapters.js): the bridge picks per action.
    if (!fmt && (type === 'video' || type === 'audio') && self.MBSites) {
      const alts = self.MBSites.collect(req.url);
      if (alts) req.alts = alts;
    }
    return req;
  }

  if (self.MPV) {
    let prefs = Object.assign({}, self.MPV.DEFAULTS);
    chrome.storage.local.get(self.MPV.DEFAULTS, s => { prefs = Object.assign(prefs, s); });
    chrome.storage.onChanged.addListener((changes, area) => {
      if (area !== 'local') return;
      for (const k of Object.keys(changes)) {
        if (k in self.MPV.DEFAULTS) prefs[k] = changes[k].newValue;
      }
    });

    const isAV = r => r.state.type === 'video' || r.state.type === 'audio';

    // Newest captured stream whose link hasn't expired.
    function bestStreamRef() {
      for (let i = allEntryRefs.length - 1; i >= 0; i--) {
        const r = allEntryRefs[i];
        if (isAV(r) && !isExpired(r.state)) return r;
      }
      return null;
    }

    function mainVideo() {
      const vids = Array.from(document.querySelectorAll('video'));
      return document.querySelector('.html5-main-video')
        || vids.find(v => !v.paused && v.readyState > 0)
        || vids[0] || null;
    }

    function onYouTubeVideoPage() {
      return /(^|\.)youtube\.com$/i.test(location.hostname) && /^\/(watch|shorts)\b/.test(location.pathname);
    }

    // "Play whatever is on this page in mpv": YouTube -> the page (yt-dlp);
    // elsewhere -> the newest captured stream, falling back to the page URL.
    function playHere(cb) {
      const done = r => { if (cb) cb(r); };
      let req = null;
      const best = onYouTubeVideoPage() ? null : bestStreamRef();
      if (best) req = streamRequest(best.state, best.state.type);

      const video = mainVideo();
      if (!req) {
        if (!/^https?:/i.test(location.href)) return done({ ok: false, error: 'Not a playable page' });
        req = { url: location.href, title: document.title || 'video' };
        if (prefs.startFromCurrentTime && video && video.currentTime > 0) req.startTime = video.currentTime;
      }
      if (prefs.autoPause && video && !video.paused) video.pause();

      launchMpv(Object.assign({ action: 'play' }, req), done);
    }
    // Shared with the YouTube button script (same isolated world).
    self.__mbPlayHere = playHere;

    // Top frame answers the popup and the service worker's context-menu lookups.
    chrome.runtime.onMessage.addListener((msg, sender, sendResponse) => {
      if (!IS_TOP || !msg) return;

      if (msg.__mbPlayHere) {
        // The "Play this page in mpv" browser command (chrome://extensions/shortcuts)
        // lands here via the service worker; answer with the launch result.
        playHere(result => sendResponse(result || { ok: true }));
        return true;   // async response
      } else if (msg.__mbBestStream) {
        const r = bestStreamRef();
        sendResponse(r ? { ok: true, stream: streamRequest(r.state, r.state.type) } : { ok: false });
      } else if (msg.__mbPageInfo) {
        const video = mainVideo();
        sendResponse({
          ok: true,
          host: HOST,
          mode: MODE,
          currentTime: video ? video.currentTime : null,
          // Per-site blocker settings (stored in this origin's localStorage), shown in
          // the popup's Blocking tab.
          iconThreshold: ICON_THRESHOLD,
          audioMarkers: AUDIO_MARKERS.join('\n'),
          entries: allEntryRefs.map(entryView)
        });
      } else if (msg.__mbSetSiteSettings) {
        // From the popup's Blocking tab. The two per-site values live in this page's
        // localStorage; the global ones are saved by the service worker, but this page
        // also keeps a synchronous cached copy (read at document_start, before
        // chrome.storage answers), so refresh it here to make the reload apply at once.
        if (msg.iconThreshold !== undefined) GM_setValue(ICON_KEY, String(parseInt(msg.iconThreshold, 10) || 48));
        if (typeof msg.audioMarkers === 'string') GM_setValue(AUDIO_MARK_KEY, msg.audioMarkers);
        if (typeof msg.globalMode === 'string') GM_setValue('GLOBAL_MODE', msg.globalMode);
        if (Array.isArray(msg.disabledSites)) GM_setValue('DISABLED_SITES', msg.disabledSites);
        sendResponse({ ok: true });
      } else if (msg.__mbSetMode) {
        if (msg.mode === 'block' || msg.mode === 'capture') setSiteMode(msg.mode);
        sendResponse({ ok: true });
      } else if (msg.__mbSelectVariant) {
        const r = allEntryRefs.find(x => x.state.id === msg.id);
        if (!r) { sendResponse({ ok: false }); return; }
        selectVariant(r, Number.isInteger(msg.index) ? msg.index : -1);
        sendResponse({ ok: true, entry: entryView(r) });
      } else if (msg.__mbDownloadFile) {
        const r = allEntryRefs.find(x => x.state.id === msg.id);
        if (!r) { sendResponse({ ok: false }); return; }
        downloadFile(r.state, r.state.type).then(sendResponse, err => sendResponse({ ok: false, error: String(err) }));
        return true;   // async response
      } else if (msg.__mbClear) {
        clearEntries();
        sendResponse({ ok: true });
      }
    });
  }

  if (MODE === 'off') return;


  function sourceType(el, urlForGuess) {
    if (el && el.tagName === 'SOURCE') {
      const parentTag = el.parentElement && el.parentElement.tagName;
      if (parentTag === 'PICTURE') return 'image';
      if (parentTag === 'VIDEO') return 'video';
      if (parentTag === 'AUDIO') return 'audio';
    }
    return isVideoUrl(urlForGuess) ? 'video' : 'audio';
  }

  
  // --- Network Hooks ---
  // Shared by the fetch and XHR hooks below: is this a media/manifest URL worth
  // recording, and if so what type?
  function classifyNetworkUrl(url) {
    if (guessCssUrlType(url) === 'image' && !isVideoUrl(url) && !isManifestUrl(url)) return 'image';
    if (isVideoUrl(url) || isManifestUrl(url)) return manifestType(url);
    return 'unknown';
  }

  const _fetch = window.__mbNativeFetch;
  if (_fetch) {
    window.fetch = async function() {
      let url = arguments[0] instanceof Request ? arguments[0].url : arguments[0];
      url = String(url);
      const type = classifyNetworkUrl(url);
      
      if (type !== 'unknown' && shouldIntercept(type, url, null)) {
        record(type, url, null);
        if (MODE === 'block' && BLOCK_TYPES[type]) {
          return new Promise(() => {}); // Hanging promise to block fetch
        }
      }
      return _fetch.apply(this, arguments);
    };
  }

  const _xhrOpen = XMLHttpRequest.prototype.open;
  const _xhrSend = XMLHttpRequest.prototype.send;
  XMLHttpRequest.prototype.open = function(method, url) {
    this._mbUrl = String(url);
    return _xhrOpen.apply(this, arguments);
  };
  XMLHttpRequest.prototype.send = function() {
    if (this._mbUrl) {
      const url = this._mbUrl;
      const type = classifyNetworkUrl(url);
      if (type !== 'unknown' && shouldIntercept(type, url, null)) {
        record(type, url, null);
        if (MODE === 'block' && BLOCK_TYPES[type]) {
          return; // Block by silently ignoring send
        }
      }
    }
    return _xhrSend.apply(this, arguments);
  };

  const srcObjDesc = Object.getOwnPropertyDescriptor(HTMLMediaElement.prototype, 'srcObject');
  if (srcObjDesc && srcObjDesc.set) {
    Object.defineProperty(HTMLMediaElement.prototype, 'srcObject', {
      configurable: true,
      get() { return srcObjDesc.get.call(this); },
      set(value) {
        if (this.__mbIgnore) { srcObjDesc.set.call(this, value); return; }
        const type = this.tagName === 'VIDEO' ? 'video' : 'audio';
        if (shouldIntercept(type, 'srcObject', this)) {
          record(type, 'srcObject', this);
          if (MODE === 'block') return; // Block
        }
        srcObjDesc.set.call(this, value);
      }
    });
  }

  function installImageSrcHook() {
    const currentDesc = Object.getOwnPropertyDescriptor(HTMLImageElement.prototype, 'src');
    if (currentDesc && currentDesc.set && currentDesc.set.__mbOwned) return;
    // Bail if another script has redefined `src` as a plain data property —
    // re-wrapping would break the getter/setter contract this code relies on.
    if (!currentDesc || typeof currentDesc.get !== 'function' || typeof currentDesc.set !== 'function') return;
    const base = currentDesc;
    const setter = function (value) {
      if (this.__mbIgnore) { base.set.call(this, value); return; }
      if (shouldIntercept('image', value, this)) {
        record('image', value, this);
        if (MODE === 'block') return;
      }
      base.set.call(this, value);
    };
    setter.__mbOwned = true;
    Object.defineProperty(HTMLImageElement.prototype, 'src', {
      configurable: true,
      get() { return base.get.call(this); },
      set: setter,
    });
  }
  installImageSrcHook();

  const imgSrcsetDesc = Object.getOwnPropertyDescriptor(HTMLImageElement.prototype, 'srcset');
  if (imgSrcsetDesc && imgSrcsetDesc.set) {
    Object.defineProperty(HTMLImageElement.prototype, 'srcset', {
      configurable: true,
      get() { return imgSrcsetDesc.get.call(this); },
      set(value) {
        const { filtered, allBlocked } = filterSrcset(value, 'image', this);
        imgSrcsetDesc.set.call(this, allBlocked ? '' : filtered);
      }
    });
  }

  const sourceSrcsetDesc = window.HTMLSourceElement &&
    Object.getOwnPropertyDescriptor(HTMLSourceElement.prototype, 'srcset');
  if (sourceSrcsetDesc && sourceSrcsetDesc.set) {
    Object.defineProperty(HTMLSourceElement.prototype, 'srcset', {
      configurable: true,
      get() { return sourceSrcsetDesc.get.call(this); },
      set(value) {
        const first = parseSrcset(value)[0];
        const type = sourceType(this, first && first.url);
        const { filtered, allBlocked } = filterSrcset(value, type, this);
        sourceSrcsetDesc.set.call(this, allBlocked ? '' : filtered);
      }
    });
  }

  ['HTMLMediaElement', 'HTMLSourceElement'].forEach(ctorName => {
    const proto = window[ctorName] && window[ctorName].prototype;
    const desc = proto && Object.getOwnPropertyDescriptor(proto, 'src');
    if (!desc) return;
    Object.defineProperty(proto, 'src', {
      configurable: true,
      get() { return desc.get.call(this); },
      set(value) {
        if (this.__mbIgnore) { desc.set.call(this, value); return; }
        const type = ctorName === 'HTMLSourceElement'
          ? sourceType(this, value)
          : (isVideoUrl(value) || this.tagName === 'VIDEO' ? 'video' : 'audio');
        if (type === 'video' && isHardBlockableVideoUrl(value) && shouldIntercept(type, value, this)) {
          if (shouldAllowFirstProgressiveRequest(value)) {
            record(type, value, this);
            desc.set.call(this, value);
          } else {
            record(type, value, this);
            if (MODE !== 'block') desc.set.call(this, value);
          }
          return;
        }
        if (shouldIntercept(type, value, this)) {
          record(type, value, this);
          if (MODE !== 'block') desc.set.call(this, value);
        } else {
          desc.set.call(this, value);
        }
      }
    });
  });

  function installSetAttributeHook() {
    if (Element.prototype.setAttribute.__mbOwned) return;
    const origSetAttribute = Element.prototype.setAttribute;
    const wrapped = function (name, value) {
      if (this.__mbIgnore) return origSetAttribute.call(this, name, value);
      if (name === 'src' && ['IMG', 'VIDEO', 'AUDIO', 'SOURCE'].includes(this.tagName)) {
        const type = this.tagName === 'IMG' ? 'image' : sourceType(this, value);
        if (type === 'video' && isHardBlockableVideoUrl(value) && shouldIntercept(type, value, this)) {
          if (shouldAllowFirstProgressiveRequest(value)) {
            record(type, value, this);
            return origSetAttribute.call(this, name, value);
          }
          record(type, value, this);
          if (MODE === 'block') return;
        }
        if (shouldIntercept(type, value, this)) {
          record(type, value, this);
          if (MODE === 'block') return;
        }
      }
      if (name === 'srcset' && ['IMG', 'SOURCE'].includes(this.tagName)) {
        const first = parseSrcset(value)[0];
        const type = this.tagName === 'IMG' ? 'image' : sourceType(this, first && first.url);
        const { filtered, allBlocked } = filterSrcset(value, type, this);
        if (allBlocked) return;
        return origSetAttribute.call(this, name, filtered);
      }
      if (name === 'style' && typeof value === 'string' && /url\(/i.test(value)) {
        return origSetAttribute.call(this, name, filterCssText(value, this));
      }
      return origSetAttribute.call(this, name, value);
    };
    wrapped.__mbOwned = true;
    Element.prototype.setAttribute = wrapped;
  }
  installSetAttributeHook();

  setInterval(() => {
    installImageSrcHook();
    installSetAttributeHook();
  }, 4000);

  function filterCssText(cssText, el, forcedType) {
    return cssText.replace(CSS_URL_RE, (match, quote, url) => {
      url = url.trim();
      if (!url || url.startsWith('data:')) return match;
      const type = forcedType || guessCssUrlType(url);
      if (shouldIntercept(type, url, el)) {
        record(type, url, el);
        if (MODE === 'block') return 'none';
      }
      return match;
    });
  }

  const FONT_FACE_RE = /@font-face\s*\{[^}]*\}/gi;
  function filterCssTextWithFontFace(cssText, el) {
    return cssText.replace(FONT_FACE_RE, block => filterCssText(block, el, 'font'));
  }

  const bgProps = ['backgroundImage', 'background'];
  const cssProto = window.CSSStyleDeclaration && CSSStyleDeclaration.prototype;
  if (cssProto) {
    bgProps.forEach(prop => {
      const desc = Object.getOwnPropertyDescriptor(cssProto, prop);
      if (!desc || !desc.set) return;
      Object.defineProperty(cssProto, prop, {
        configurable: true,
        get() { return desc.get.call(this); },
        set(value) {
          if (typeof value === 'string' && /url\(/i.test(value)) {
            value = filterCssText(value, null);
          }
          desc.set.call(this, value);
        }
      });
    });
  }

  const origInsertRule = CSSStyleSheet.prototype.insertRule;
  CSSStyleSheet.prototype.insertRule = function (rule, index) {
    if (typeof rule === 'string' && /url\(/i.test(rule)) {
      rule = filterCssTextWithFontFace(rule, null);
    }
    return origInsertRule.call(this, rule, index);
  };

  function scanStyleTag(styleEl) {
    if (!styleEl.textContent || !/url\(/i.test(styleEl.textContent)) return;
    const filtered = filterCssTextWithFontFace(styleEl.textContent, null);
    if (filtered !== styleEl.textContent) styleEl.textContent = filtered;
  }

  
  function formatFilename(urlStr) {
    let filename = urlStr;
    try {
      const parsedUrl = new URL(urlStr);
      filename = parsedUrl.pathname.split('/').pop() || parsedUrl.hostname;
      if (!filename) filename = urlStr;
      
      // Clean up common long hls.js generated names if requested
      if (filename.includes('index-') && filename.endsWith('.m3u8')) {
        filename = 'index.m3u8';
      }
    } catch(e) {}
    return filename.length > 40 ? filename.slice(0, 37) + '…' : filename;
  }


  // Sends a play/download request to background.js, which relays it to the
  // com.playinmpv.host native messaging host and hands back a real ok/error
  // result — no more mpv-play:// custom protocol handler or hidden iframe.
  function launchMpv(payload, onResult) {
    chrome.runtime.sendMessage({ __mbLaunchMpv: true, ...payload }, (response) => {
      if (chrome.runtime.lastError) {
        onResult && onResult({ ok: false, error: chrome.runtime.lastError.message });
        return;
      }
      onResult && onResult(response || { ok: false, error: 'No response from native host' });
    });
  }

  const domObserver = new MutationObserver(muts => {
    for (const m of muts) {
      if (m.type === 'childList') {
        for (const node of m.addedNodes) {
          if (node.nodeType === 1) {
            scanElementFast(node);
            if (node.querySelectorAll) {
              node.querySelectorAll('img,[style*="url("]').forEach(scanElementFast);
            }
          }
        }
      } else if (m.type === 'attributes') {
        scanElementFast(m.target);
      }
    }
  });

  function scanElementFast(el) {
    if (!el || !el.tagName) return;
    const tag = el.tagName.toUpperCase();
    if (tag === 'IMG') {
      // Look at the attribute as written: for a blank <img src=""> the resolved el.src
      // property is the *page's own URL*, which would be captured as a bogus image.
      const raw = (el.getAttribute('src') || '').trim();
      if (raw && !raw.startsWith('data:')) {
        const src = el.src || raw;
        if (shouldIntercept('image', src, el)) record('image', src);
      }
      const srcset = el.getAttribute('srcset');
      if (srcset) {
        const urls = srcset.split(',').map(s => s.trim().split(/\s+/)[0]).filter(u => u && !u.startsWith('data:'));
        urls.forEach(u => {
          if (shouldIntercept('image', u, el)) record('image', u);
        });
      }
    }
    const styleAttr = el.getAttribute('style');
    if (styleAttr && /url\(/i.test(styleAttr)) {
      const urls = Array.from(styleAttr.matchAll(/url\(['"]?(.*?)['"]?\)/ig)).map(m => m[1].trim()).filter(u => u && !u.startsWith('data:'));
      urls.forEach(u => {
        if (shouldIntercept('image', u, el)) record('image', u);
      });
    }
  }

  function initScanner() {
    domObserver.observe(document.documentElement, {
      childList: true, subtree: true, attributes: true,
      attributeFilter: ['src', 'srcset', 'style']
    });
    document.querySelectorAll('img,[style*="url("]').forEach(scanElementFast);
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', initScanner);
  } else {
    initScanner();
  }

})();
