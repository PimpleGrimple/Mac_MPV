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
  function GM_setClipboard(text) {
    navigator.clipboard.writeText(text);
  }
  function GM_download(opts) {
    const a = document.createElement('a');
    a.href = opts.url;
    a.download = opts.name || 'download';
    a.click();
  }


  // Icon fragments reused across the copy/download/mpv buttons' idle -> success flash states.
  const ICON_DOWNLOAD = '<svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"></path><polyline points="7 10 12 15 17 10"></polyline><line x1="12" y1="15" x2="12" y2="3"></line></svg>';
  const ICON_CHECK_12 = '<svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="#5ecf8f" stroke-width="3" stroke-linecap="round" stroke-linejoin="round"><polyline points="20 6 9 17 4 12"></polyline></svg>';
  const ICON_ERROR_12 = '<svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="#e6605a" stroke-width="3" stroke-linecap="round" stroke-linejoin="round"><line x1="18" y1="6" x2="6" y2="18"></line><line x1="6" y1="6" x2="18" y2="18"></line></svg>';
  const ICON_MPV_PLAY = '<svg width="12" height="12" viewBox="0 0 24 24" fill="currentColor" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><polygon points="5 3 19 12 5 21 5 3"></polygon></svg>';

  // Bumped on every preview hover/unhover so an in-flight image load from a row
  // the mouse has already left can detect it's stale and skip showing itself
  // (the popup+<img> are a single shared singleton reused across every row).
  let previewToken = 0;
  function positionPreviewPopup(popup, badge) {
    popup.style.display = 'block';
    const rect = badge.getBoundingClientRect();
    const pRect = popup.getBoundingClientRect();
    let top = rect.top + rect.height / 2 - pRect.height / 2;
    top = Math.max(8, Math.min(top, window.innerHeight - pRect.height - 8));
    popup.style.top = top + 'px';

    let left = rect.left - pRect.width - 15;
    if (left < 8) left = Math.min(rect.right + 15, window.innerWidth - pRect.width - 8);
    popup.style.left = Math.max(8, left) + 'px';
  }

  const HOST = location.hostname;
  const MODE_KEY = 'mode:' + HOST;
  const TYPES_KEY = 'blockTypes:' + HOST;
  const AUDIO_MARK_KEY = 'audioMarkers:' + HOST;
  const ICON_KEY = 'iconThreshold:' + HOST;
  const MIN_KEY = 'minimized:' + HOST;
  
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
      document.querySelectorAll('#mb-widget-wrap').forEach(w => w.remove());
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
          document.querySelectorAll('#mb-widget-wrap').forEach(w => w.remove());
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
          ref.row.remove();
          allEntryRefs.splice(i, 1);
          for (let j = collected.length - 1; j >= 0; j--) {
            if (canonicalizeUrl(collected[j].url) === variantUrlKey) {
              collected.splice(j, 1);
              break;
            }
          }
        }
      }
      updateCounts();
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
  let panel, list, toggleBadge, toggleWrap;

  // Guard against duplicate widget creation (can happen from renderEntry,
  // message listeners, or pages that re-trigger DOMContentLoaded)
  let widgetBuilt = false;



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
      forceReattach: () => {
        if (toggleWrap && !toggleWrap.isConnected) document.documentElement.appendChild(toggleWrap);
        if (panel && !panel.isConnected) document.documentElement.appendChild(panel);
      },
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

  function record(type, url, el) {
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
    const entryRef = renderEntry(type, state);
    if (isManifest) {
      manifestRows.set(manifestCanonicalKey(url), entryRef);
    }
    if (typeof toggleBadge !== 'undefined' && toggleBadge) {
      toggleBadge.classList.remove('mb-pulse-anim');
      void toggleBadge.offsetWidth;
      toggleBadge.classList.add('mb-pulse-anim');
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

  
  
  
  
  // --- UI Widget Setup ---
  let widgetWrap, widgetPanel, mainView, settingsView, speedDial;
  // Per-site persistent minimize state. GM_getValue JSON-parses the stored
  // value, so `true`/`false` round-trip cleanly. `=== true` guards against
  // a legacy string value.
  let isMinimized = GM_getValue(MIN_KEY, false) === true;
  
  let isSettingsOpen = false;

  function updateCounts() {
    const counts = { all: collected.length, video: 0, image: 0, audio: 0, subtitle: 0, font: 0 };
    collected.forEach(c => {
      if (counts[c.type] !== undefined) counts[c.type]++;
    });
    document.querySelectorAll('.mb-tab').forEach(tab => {
      const type = tab.dataset.type;
      const count = counts[type] || 0;
      const name = type === 'all' ? 'All' : type[0].toUpperCase() + type.slice(1);
      if (tab.classList.contains('active')) {
        tab.textContent = `${name} (${count})`;
      } else {
        tab.textContent = name;
      }
    });
  }

  function buildWidget() {
    // Prevent duplicate widgets — check both the flag and the DOM
    if (widgetBuilt || document.getElementById('mb-widget-wrap')) return;
    widgetBuilt = true;
    if (isHostDisabled(HOST, DISABLED_SITES)) return;
    injectStyles();
    
    widgetWrap = document.createElement('div');
    widgetWrap.id = 'mb-widget-wrap';
    widgetWrap.className = 'mb-widget-wrap';
    
    const fabContainer = document.createElement('div');
    fabContainer.className = 'mb-fab-container';
    
    const fab = document.createElement('div');
    fab.className = 'mb-fab';
    const svgBlock = '<svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="#e6605a" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><rect x="3" y="3" width="18" height="18" rx="2" ry="2"></rect><line x1="9" y1="9" x2="15" y2="15"></line><line x1="15" y1="9" x2="9" y2="15"></line></svg>';
    const svgCapture = '<svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="#f0a85c" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><path d="M1 12s4-8 11-8 11 8 11 8-4 8-11 8-11-8-11-8z"></path><circle cx="12" cy="12" r="3"></circle></svg>';
    const svgOff = '<span style="display:block;width:10px;height:10px;border-radius:50%;background:#6b6b70;"></span>';
    
    fab.innerHTML = MODE === 'block' ? svgBlock : MODE === 'capture' ? svgCapture : svgOff;
    fab.title = (MODE === 'block' ? 'Blocking & Capturing' : MODE === 'capture' ? 'Capture Only' : 'Off') + ' — click to toggle (Drag to move)';
    
    let isDragging = false;
    let dragStartX, dragStartY, initX, initY;
    
    fab.onmousedown = (e) => {
      isDragging = false;
      dragStartX = e.clientX;
      dragStartY = e.clientY;
      const rect = widgetWrap.getBoundingClientRect();
      initX = rect.left;
      initY = rect.top;
      
      const onMouseMove = (ev) => {
        if (Math.abs(ev.clientX - dragStartX) > 3 || Math.abs(ev.clientY - dragStartY) > 3) {
          isDragging = true;
          widgetWrap.style.bottom = 'auto';
          widgetWrap.style.right = 'auto';
          widgetWrap.style.left = (initX + ev.clientX - dragStartX) + 'px';
          widgetWrap.style.top = (initY + ev.clientY - dragStartY) + 'px';
        }
      };
      
      const onMouseUp = () => {
        window.removeEventListener('mousemove', onMouseMove);
        window.removeEventListener('mouseup', onMouseUp);
      };
      
      window.addEventListener('mousemove', onMouseMove);
      window.addEventListener('mouseup', onMouseUp);
    };

    fab.onclick = (e) => {
      if (isDragging) return; 
      if (MODE !== 'off' && isMinimized) {
        isMinimized = false;
        GM_setValue(MIN_KEY, false);
        if (widgetPanel) widgetPanel.style.display = 'flex';
        if (speedDial) speedDial.style.display = 'flex';
        return;
      }
      // Block <-> Capture only. The "off" state is now reserved for sites
      // listed in the settings' "Disabled Sites" field; the FAB no longer
      // cycles to it.
      const next = MODE === 'block' ? 'capture' : 'block';
      GM_setValue(MODE_KEY, next);
      chrome.runtime.sendMessage({ 
        type: 'SET_SITE_MODE', 
        host: HOST,
        mode: next
      }, () => {
        location.reload();
      });
    };
    
    toggleBadge = fab;
    
    if (MODE !== 'off') {
      speedDial = document.createElement('div');
      speedDial.className = 'mb-speed-dial';
      speedDial.innerHTML = `
        <button id="mb-dial-min" class="mb-iconbtn" title="Minimize panel"><svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><line x1="5" y1="12" x2="19" y2="12"></line></svg></button>
        <button id="mb-dial-dl" class="mb-iconbtn" title="Download All"><svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"></path><polyline points="7 10 12 15 17 10"></polyline><line x1="12" y1="15" x2="12" y2="3"></line></svg></button>
        <button id="mb-dial-copy" class="mb-iconbtn" title="Copy URLs"><svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M16 4h2a2 2 0 0 1 2 2v14a2 2 0 0 1-2 2H6a2 2 0 0 1-2-2V6a2 2 0 0 1 2-2h2"></path><rect x="8" y="2" width="8" height="4" rx="1" ry="1"></rect></svg></button>
        <button id="mb-dial-clear" class="mb-iconbtn" title="Clear all"><svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><polyline points="3 6 5 6 21 6"></polyline><path d="M19 6v14a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V6m3 0V4a2 2 0 0 1 2-2h4a2 2 0 0 1 2 2v2"></path></svg></button>
        <button id="mb-dial-save" class="mb-iconbtn" title="Save & Reload" style="display:none; color:#5ecf8f; border-color:#5ecf8f;"><svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><polyline points="20 6 9 17 4 12"></polyline></svg></button>
        <button id="mb-dial-gear" class="mb-iconbtn" title="Settings"><svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="3"></circle><path d="M19.4 15a1.65 1.65 0 0 0 .33 1.82l.06.06a2 2 0 0 1 0 2.83 2 2 0 0 1-2.83 0l-.06-.06a1.65 1.65 0 0 0-1.82-.33 1.65 1.65 0 0 0-1 1.51V21a2 2 0 0 1-2 2 2 2 0 0 1-2-2v-.09A1.65 1.65 0 0 0 9 19.4a1.65 1.65 0 0 0-1.82.33l-.06.06a2 2 0 0 1-2.83 0 2 2 0 0 1 0-2.83l.06-.06a1.65 1.65 0 0 0 .33-1.82 1.65 1.65 0 0 0-1.51-1H3a2 2 0 0 1-2-2 2 2 0 0 1 2-2h.09A1.65 1.65 0 0 0 4.6 9a1.65 1.65 0 0 0-.33-1.82l-.06-.06a2 2 0 0 1 0-2.83 2 2 0 0 1 2.83 0l.06.06a1.65 1.65 0 0 0 1.82.33H9a1.65 1.65 0 0 0 1-1.51V3a2 2 0 0 1 2-2 2 2 0 0 1 2 2v.09a1.65 1.65 0 0 0 1 1.51 1.65 1.65 0 0 0 1.82-.33l.06-.06a2 2 0 0 1 2.83 0 2 2 0 0 1 0 2.83l-.06.06a1.65 1.65 0 0 0-.33 1.82V9a1.65 1.65 0 0 0 1.51 1H21a2 2 0 0 1 2 2 2 2 0 0 1-2 2h-.09a1.65 1.65 0 0 0-1.51 1z"></path></svg></button>
      `;
      fabContainer.appendChild(speedDial);

      widgetPanel = document.createElement('div');
      widgetPanel.className = 'mb-widget-panel';
      panel = widgetPanel;
      
      speedDial.querySelector('#mb-dial-dl').onclick = async (e) => {
        const dlBtn = speedDial.querySelector('#mb-dial-dl');
        const rows = Array.from(list.querySelectorAll('.mb-row')).filter(r => r.style.display !== 'none');
        if (rows.length === 0) return;
        dlBtn.style.color = '#5ecf8f';
        for (const r of rows) {
          const btn = r.querySelector('button[title*="Download"]');
          if (btn) { btn.click(); await new Promise(res => setTimeout(res, 400)); }
        }
        setTimeout(() => { dlBtn.style.color = ''; }, 1000);
      };
      
      speedDial.querySelector('#mb-dial-copy').onclick = (e) => {
        const copyBtn = speedDial.querySelector('#mb-dial-copy');
        const text = collected.map(c => `[${c.type}] ${c.url}`).join('\n');
        if (typeof GM_setClipboard === 'function') GM_setClipboard(text); else navigator.clipboard.writeText(text);
        copyBtn.innerHTML = '<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="#5ecf8f" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><polyline points="20 6 9 17 4 12"></polyline></svg>';
        setTimeout(() => { copyBtn.innerHTML = '<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M16 4h2a2 2 0 0 1 2 2v14a2 2 0 0 1-2 2H6a2 2 0 0 1-2-2V6a2 2 0 0 1 2-2h2"></path><rect x="8" y="2" width="8" height="4" rx="1" ry="1"></rect></svg>'; }, 900);
      };
      
      speedDial.querySelector('#mb-dial-gear').onclick = () => toggleSettings();
      speedDial.querySelector('#mb-dial-clear').onclick = (e) => { e.stopPropagation(); collected.length = 0; collectedUrls.clear(); list.innerHTML = ''; updateCounts(); renderEmptyState(); };
      speedDial.querySelector('#mb-dial-save').onclick = () => {
        const types = {
          image: document.querySelector('#mb-block-image').checked,
          video: document.querySelector('#mb-block-video').checked,
          audio: document.querySelector('#mb-block-audio').checked,
          font: document.querySelector('#mb-block-font').checked,
          subtitle: document.querySelector('#mb-block-subtitle').checked,
        };
        GM_setValue(TYPES_KEY, types);
        GM_setValue(AUDIO_MARK_KEY, document.querySelector('#mb-audio-markers').value);
        GM_setValue(ICON_KEY, String(parseInt(document.querySelector('#mb-icon-threshold').value, 10) || 48));
        
        const gm = document.querySelector('#mb-global-mode').value;
        const rawDs = document.querySelector('#mb-disabled-sites').value.split('\n').map(s=>s.trim()).filter(Boolean);
        const ds = rawDs.map(site => {
           let s = site.toLowerCase();
           s = s.replace(/^https?:\/\//, '');
           s = s.split('/')[0];
           s = s.replace(/^www\./, '');
           if (!s.includes('.')) s += '.com';
           return s;
        }).filter(Boolean);
        
        GM_setValue('GLOBAL_MODE', gm);
        GM_setValue('DISABLED_SITES', ds);
        
        chrome.runtime.sendMessage({
          type: 'SET_GLOBAL_SETTINGS',
          globalMode: gm,
          disabledSites: ds,
          types: Object.keys(types).filter(k => types[k]),
          exceptions: document.querySelector('#mb-exceptions').value.split('\n').map(s=>s.trim()).filter(Boolean),
          blockKeywords: document.querySelector('#mb-block-keywords').value.split('\n').map(s=>s.trim()).filter(Boolean)
        }, () => {
          location.reload();
        });
      };

      
      
      speedDial.querySelector('#mb-dial-min').onclick = () => {
        isMinimized = true;
        GM_setValue(MIN_KEY, true);
        widgetPanel.style.display = 'none';
        speedDial.style.display = 'none';
      };

      const resizer = document.createElement('div');
      resizer.className = 'mb-resizer';
      resizer.title = "Drag up/down to resize";
      widgetPanel.appendChild(resizer);
      
      let isResizing = false;
      let startHeight = 0;
      let startY = 0;
      let startWrapTop = null;
      
      resizer.onmousedown = (e) => {
        isResizing = true;
        startY = e.clientY;
        startHeight = widgetPanel.offsetHeight;
        startWrapTop = widgetWrap.style.top && widgetWrap.style.top !== 'auto' ? parseFloat(widgetWrap.style.top) : null;
        
        const onMouseMove = (ev) => {
          if (!isResizing) return;
          const deltaY = ev.clientY - startY;
          widgetPanel.style.height = (startHeight - deltaY) + 'px';
          if (startWrapTop !== null) {
            widgetWrap.style.top = (startWrapTop + deltaY) + 'px';
          }
        };
        
        const onMouseUp = () => {
          isResizing = false;
          window.removeEventListener('mousemove', onMouseMove);
          window.removeEventListener('mouseup', onMouseUp);
        };
        
        window.addEventListener('mousemove', onMouseMove);
        window.addEventListener('mouseup', onMouseUp);
      };

      mainView = document.createElement('div');
      mainView.className = 'mb-view-main';
      
      const tabs = document.createElement('div');
      tabs.className = 'mb-tabs';
      tabs.title = "Drag to move";
      ['all', 'video', 'image', 'audio', 'subtitle', 'font'].forEach(t => {
        const tab = document.createElement('div');
        tab.className = 'mb-tab' + (t === 'all' ? ' active' : '');
        tab.textContent = t === 'all' ? 'All' : t[0].toUpperCase() + t.slice(1);
        tab.dataset.type = t;
        tab.onclick = () => {
          activeFilter = t;
          tabs.querySelectorAll('.mb-tab').forEach(el => el.classList.toggle('active', el === tab));
          updateCounts();
          applyFilter();
        };
        tabs.appendChild(tab);
      });
      
      list = document.createElement('div');
      list.className = 'mb-list';
      
      mainView.append(tabs, list);
      
      settingsView = document.createElement('div');
      settingsView.className = 'mb-view-settings';
      settingsView.style.display = 'none';
      buildSettingsView(settingsView);
      
      widgetPanel.append(mainView, settingsView);
      widgetWrap.appendChild(widgetPanel);
      
      tabs.onmousedown = (e) => {
        if (e.target.tagName === 'BUTTON' || e.target.closest('button')) return;
        isDragging = false;
        dragStartX = e.clientX;
        dragStartY = e.clientY;
        const rect = widgetWrap.getBoundingClientRect();
        initX = rect.left;
        initY = rect.top;
        
        const onMouseMove = (ev) => {
          isDragging = true;
          widgetWrap.style.bottom = 'auto';
          widgetWrap.style.right = 'auto';
          widgetWrap.style.left = (initX + ev.clientX - dragStartX) + 'px';
          widgetWrap.style.top = (initY + ev.clientY - dragStartY) + 'px';
        };
        
        const onMouseUp = () => {
          window.removeEventListener('mousemove', onMouseMove);
          window.removeEventListener('mouseup', onMouseUp);
        };
        
        window.addEventListener('mousemove', onMouseMove);
        window.addEventListener('mouseup', onMouseUp);
      };
    }
    
    fabContainer.appendChild(fab);
    widgetWrap.appendChild(fabContainer);
    document.documentElement.appendChild(widgetWrap);
    
    if (MODE !== 'off') {
        // Restore per-site minimized state. When minimized, only the FAB is
        // visible; clicking it brings the panel and speed dial back.
        if (isMinimized) {
          if (widgetPanel) widgetPanel.style.display = 'none';
          if (speedDial) speedDial.style.display = 'none';
        }
        updateCounts();
        renderEmptyState();
    }
  }

  function buildSettingsView(container) {
    container.innerHTML = `
      <div class="mb-set-tabs">
        <div class="mb-set-tab active" data-target="mb-tab-general">General</div>
        <div class="mb-set-tab" data-target="mb-tab-types">Types</div>
        <div class="mb-set-tab" data-target="mb-tab-blacklist">Blacklist</div>
        <div class="mb-set-tab" data-target="mb-tab-whitelist">Whitelist</div>
      </div>
      
      <div class="mb-set-content active" id="mb-tab-general">
        <div class="mb-set-label">Global Default Mode:</div>
        <select id="mb-global-mode" style="background:rgba(255,255,255,0.03); border:1px solid rgba(255,255,255,0.1); color:var(--mb-text-main); border-radius:8px; height: 32px; margin-bottom: 12px; padding: 4px; outline:none;">
          <option value="block" style="background:#1a1a1c;">Block (Default)</option>
          <option value="capture" style="background:#1a1a1c;">Capture</option>
          <option value="off" style="background:#1a1a1c;">Off</option>
        </select>
        <div class="mb-set-label">Disabled Sites (e.g. youtube.com, google.com):</div>
        <textarea id="mb-disabled-sites" class="mb-set-textarea" style="flex: 1; resize: none;">${DISABLED_SITES.join('\n')}</textarea>
      </div>

      <div class="mb-set-content" id="mb-tab-types">
        <div class="mb-set-row">
          <div class="mb-set-info">
            <div class="mb-set-name">Block Images</div>
            <div class="mb-set-desc">Prevent all image loading</div>
          </div>
          <div class="mb-set-actions-inline">
            <input type="number" id="mb-icon-threshold" class="mb-settings-input-small" value="${ICON_THRESHOLD}" min="0" title="Max width/height px to auto-allow">
            <label class="mb-switch">
              <input type="checkbox" id="mb-block-image" ${BLOCK_TYPES.image ? 'checked' : ''}>
              <span class="mb-slider mb-slider-image"></span>
            </label>
          </div>
        </div>
        
        <div class="mb-set-row">
          <div class="mb-set-info">
            <div class="mb-set-name">Block Video</div>
            <div class="mb-set-desc">Block autoplay and streaming video</div>
          </div>
          <label class="mb-switch">
            <input type="checkbox" id="mb-block-video" ${BLOCK_TYPES.video ? 'checked' : ''}>
            <span class="mb-slider mb-slider-video"></span>
          </label>
        </div>
        
        <div class="mb-set-row">
          <div class="mb-set-info">
            <div class="mb-set-name">Block Audio</div>
            <div class="mb-set-desc">Mute background audio</div>
          </div>
          <div class="mb-set-actions-inline">
            <button id="mb-audio-gear" class="mb-iconbtn" title="Advanced Audio Settings"><svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><circle cx="12" cy="12" r="3"></circle><path d="M19.4 15a1.65 1.65 0 0 0 .33 1.82l.06.06a2 2 0 0 1 0 2.83 2 2 0 0 1-2.83 0l-.06-.06a1.65 1.65 0 0 0-1.82-.33 1.65 1.65 0 0 0-1 1.51V21a2 2 0 0 1-2 2 2 2 0 0 1-2-2v-.09A1.65 1.65 0 0 0 9 19.4a1.65 1.65 0 0 0-1.82.33l-.06.06a2 2 0 0 1-2.83 0 2 2 0 0 1 0-2.83l.06-.06a1.65 1.65 0 0 0 .33-1.82 1.65 1.65 0 0 0-1.51-1H3a2 2 0 0 1-2-2 2 2 0 0 1 2-2h.09A1.65 1.65 0 0 0 4.6 9a1.65 1.65 0 0 0-.33-1.82l-.06-.06a2 2 0 0 1 0-2.83 2 2 0 0 1 2.83 0l.06.06a1.65 1.65 0 0 0 1.82.33H9a1.65 1.65 0 0 0 1-1.51V3a2 2 0 0 1 2-2 2 2 0 0 1 2 2v.09a1.65 1.65 0 0 0 1 1.51 1.65 1.65 0 0 0 1.82-.33l.06-.06a2 2 0 0 1 2.83 0 2 2 0 0 1 0 2.83l-.06.06a1.65 1.65 0 0 0-.33 1.82V9a1.65 1.65 0 0 0 1.51 1H21a2 2 0 0 1 2 2 2 2 0 0 1-2 2h-.09a1.65 1.65 0 0 0-1.51 1z"></path></svg></button>
            <label class="mb-switch">
              <input type="checkbox" id="mb-block-audio" ${BLOCK_TYPES.audio ? 'checked' : ''}>
              <span class="mb-slider mb-slider-audio"></span>
            </label>
          </div>
        </div>
        
        <div id="mb-audio-adv" style="display:none; padding:12px; background:rgba(0,0,0,.3); border-radius:10px; margin-bottom:12px; border:1px solid rgba(255,255,255,.05);">
          <div class="mb-set-label">Force URLs matching to Audio:</div>
          <textarea id="mb-audio-markers" class="mb-set-textarea" style="flex: 1; resize: none;">${AUDIO_MARKERS.join('\n')}</textarea>
        </div>

        <div class="mb-set-row">
          <div class="mb-set-info">
            <div class="mb-set-name">Block Web Fonts</div>
            <div class="mb-set-desc">Prevent @font-face loading</div>
          </div>
          <label class="mb-switch">
            <input type="checkbox" id="mb-block-font" ${BLOCK_TYPES.font ? 'checked' : ''}>
            <span class="mb-slider mb-slider-font"></span>
          </label>
        </div>
        
        <div class="mb-set-row">
          <div class="mb-set-info">
            <div class="mb-set-name">Block Subtitles</div>
            <div class="mb-set-desc">vtt, srt, ass, etc.</div>
          </div>
          <label class="mb-switch">
            <input type="checkbox" id="mb-block-subtitle" ${BLOCK_TYPES.subtitle ? 'checked' : ''}>
            <span class="mb-slider mb-slider-font"></span>
          </label>
        </div>
      </div>
      
      <div class="mb-set-content" id="mb-tab-blacklist">
        <div class="mb-set-label">Always block URLs containing (Video Segments, one per line):</div>
        <textarea id="mb-block-keywords" class="mb-set-textarea" style="flex: 1; resize: none;">${BLOCK_KEYWORDS.join('\n')}</textarea>
      </div>
      
      <div class="mb-set-content" id="mb-tab-whitelist">
        <div class="mb-set-label">Never block URLs containing (one per line, * wildcard OK):</div>
        <textarea id="mb-exceptions" class="mb-set-textarea" style="flex: 1; resize: none;">${EXCEPTIONS.join('\n')}</textarea>
      </div>
    `;
    
    // Tab switching
    container.querySelectorAll('.mb-set-tab').forEach(tab => {
      tab.onclick = () => {
        container.querySelectorAll('.mb-set-tab').forEach(t => t.classList.remove('active'));
        container.querySelectorAll('.mb-set-content').forEach(c => c.classList.remove('active'));
        tab.classList.add('active');
        container.querySelector('#' + tab.dataset.target).classList.add('active');
      };
    });
    
    // Audio advanced toggle
    container.querySelector('#mb-audio-gear').onclick = () => {
      const adv = container.querySelector('#mb-audio-adv');
      adv.style.display = adv.style.display === 'none' ? 'block' : 'none';
      if (adv.style.display === 'block') adv.scrollIntoView({ behavior: 'smooth' });
    };
    
    const modeSelect = container.querySelector('#mb-global-mode');
    if (modeSelect) modeSelect.value = GLOBAL_MODE;
  }
  
  function toggleSettings() {
    isSettingsOpen = !isSettingsOpen;
    const gearBtn = document.querySelector('.mb-speed-dial #mb-dial-gear');
    const saveBtn = document.querySelector('.mb-speed-dial #mb-dial-save');
    const otherBtns = document.querySelectorAll('.mb-speed-dial button:not(#mb-dial-gear):not(#mb-dial-save)');
    
    if (isSettingsOpen) {
      mainView.style.display = 'none';
      settingsView.style.display = 'flex';
      if (gearBtn) gearBtn.classList.add('active');
      if (saveBtn) saveBtn.style.display = '';
      otherBtns.forEach(b => b.style.display = 'none');
    } else {
      settingsView.style.display = 'none';
      mainView.style.display = 'flex';
      if (gearBtn) gearBtn.classList.remove('active');
      if (saveBtn) saveBtn.style.display = 'none';
      otherBtns.forEach(b => b.style.display = '');
    }
  }

  document.addEventListener('DOMContentLoaded', () => {
    if (!IS_TOP) return;
    buildWidget();

    setInterval(() => {
      if (widgetWrap && !widgetWrap.isConnected && !isHostDisabled(HOST, DISABLED_SITES)) {
        document.documentElement.appendChild(widgetWrap);
      }
    }, 4000);

    // Receives captures relayed up from non-top frames (embedded iframes) via
    // record()'s postMessage above, and feeds them into the same panel pipeline
    // as this frame's own captures.
    window.addEventListener('message', e => {
      if (!e.data || !e.data.__mbCapture) return;
      let { type, url, ref } = e.data;
      if (!url) return;
      try { url = new URL(url, ref || e.origin).href; } catch (err) {}
      recordResolved(type, url, ref || e.origin || location.href, null, null);
    });
  });

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

  
  function injectStyles() {
    if (document.getElementById('mb-styles')) return;
    const style = document.createElement('style');
    style.id = 'mb-styles';
    style.textContent = `
      :root {
        --mb-font: 'Inter', 'SF Pro Display', -apple-system, sans-serif;
        --mb-bg: rgba(18, 18, 20, 0.85);
        --mb-glass-border: rgba(255, 255, 255, 0.08);
        --mb-glass-border-hover: rgba(255, 255, 255, 0.15);
        --mb-accent: #5aa9e6;
        --mb-accent-hover: #75bdf0;
        --mb-accent-bg: rgba(90, 169, 230, 0.15);
        --mb-green: #5ecf8f;
        --mb-orange: #f0a85c;
        --mb-red: #e6605a;
        --mb-purple: #c793f0;
        --mb-text-main: #f4f4f5;
        --mb-text-muted: #a1a1aa;
        --mb-ease: cubic-bezier(0.2, 0.8, 0.2, 1);
      }
      
      /* Widget Container */
      .mb-widget-wrap { position:fixed; bottom:20px; right:20px; z-index:2147483644; 
        display:flex; flex-direction:column; align-items:flex-end; gap:14px; 
        font-family:var(--mb-font); pointer-events:none; }
      .mb-widget-wrap > * { pointer-events:auto; }
      
      .mb-fab-container { display:flex; align-items:center; justify-content:flex-end; gap:12px; }
      
      .mb-speed-dial { display:flex; align-items:center; gap:8px; 
        background:rgba(20,20,22,0.9); border:1px solid var(--mb-glass-border);
        backdrop-filter:blur(16px) saturate(1.5); -webkit-backdrop-filter:blur(16px) saturate(1.5);
        border-radius:24px; padding:6px 10px; 
        box-shadow:0 8px 32px -4px rgba(0,0,0,0.6), inset 0 1px 0 rgba(255,255,255,0.05);
        animation:mb-fade-in 0.4s var(--mb-ease); }
      
      /* Floating Action Button (FAB) */
      .mb-fab {
        width:42px; height:42px; border-radius:21px; cursor:move; user-select:none;
        display:flex; align-items:center; justify-content:center;
        background:rgba(20,20,22,0.95); border:1px solid var(--mb-glass-border);
        backdrop-filter:blur(16px) saturate(1.5); -webkit-backdrop-filter:blur(16px) saturate(1.5);
        box-shadow:0 8px 32px -4px rgba(0,0,0,0.6), inset 0 1px 0 rgba(255,255,255,0.05);
        transition:all 0.3s var(--mb-ease);
      }
      .mb-fab:hover { background:rgba(30,30,34,0.98); border-color:var(--mb-glass-border-hover); transform:scale(1.04) translateY(-2px); box-shadow:0 12px 40px -4px rgba(0,0,0,0.7), inset 0 1px 0 rgba(255,255,255,0.1); }
      .mb-fab:active { transform:scale(0.94); }
      
      /* Main Morphing Panel */
      .mb-widget-panel {
        width:340px; height:450px; min-height:200px; min-width:300px; max-height:80vh;
        background:var(--mb-bg); backdrop-filter:blur(28px) saturate(1.6);
        -webkit-backdrop-filter:blur(28px) saturate(1.6);
        border:1px solid var(--mb-glass-border); border-radius:16px;
        box-shadow:0 30px 80px -12px rgba(0,0,0,0.8), 0 4px 16px rgba(0,0,0,0.4), inset 0 1px 0 rgba(255,255,255,0.05);
        display:flex; flex-direction:column; overflow:hidden;
        transform-origin:bottom right; animation:mb-morph-in 0.4s var(--mb-ease);
      }
      
      .mb-resizer {
        height:6px; width:100%; cursor:ns-resize; background:transparent; flex-shrink:0;
      }
      
      .mb-iconbtn { background:transparent; border:1px solid transparent;
        color:var(--mb-text-muted); cursor:pointer; padding:0;
        width:30px; height:30px; display:flex; align-items:center; justify-content:center;
        border-radius:10px; transition:all 0.25s var(--mb-ease); }
      .mb-iconbtn:hover { background:rgba(255,255,255,0.08); color:var(--mb-text-main); transform:translateY(-1px); }
      .mb-iconbtn:active { transform:scale(0.92); }
      .mb-iconbtn.active { background:var(--mb-accent-bg); color:var(--mb-accent); border-color:rgba(90,169,230,0.3); box-shadow:0 0 12px rgba(90,169,230,0.2); }
      
      /* Main View */
      .mb-view-main { display:flex; flex-direction:column; overflow:hidden; flex:1; }
      
      .mb-tabs { display:flex; gap:6px; padding:12px 14px 4px; overflow-x:auto; scrollbar-width:none; cursor:move; }
      .mb-tabs::-webkit-scrollbar { display:none; }
      .mb-tab { font-size:12px; font-weight:600; padding:6px 14px; border-radius:20px; cursor:pointer;
        color:var(--mb-text-muted); background:transparent; transition:all 0.3s var(--mb-ease); white-space:nowrap; }
      .mb-tab:hover { color:var(--mb-text-main); background:rgba(255,255,255,0.06); transform:translateY(-1px); }
      .mb-tab.active { color:#fff; background:rgba(255,255,255,0.15); box-shadow:0 4px 12px rgba(0,0,0,0.2); }
      
      .mb-list { flex:1; overflow-y:auto; padding:8px 12px 16px; scrollbar-gutter:stable; min-height:100px; }
      .mb-list::-webkit-scrollbar { width:5px; }
      .mb-list::-webkit-scrollbar-track { background:transparent; margin-bottom: 8px; }
      .mb-list::-webkit-scrollbar-thumb { background:rgba(255,255,255,0.15); border-radius:10px; }
      .mb-list::-webkit-scrollbar-thumb:hover { background:rgba(255,255,255,0.25); }
      
      /* Rows */
      .mb-row { display:flex; align-items:center; gap:12px; padding:12px 14px; border-radius:12px;
        margin-bottom:8px; border:1px solid rgba(255,255,255,0.02); background:rgba(255,255,255,0.015);
        animation:mb-slide-up 0.4s var(--mb-ease) backwards;
        transition:all 0.25s var(--mb-ease); }
      .mb-row:hover { border-color:var(--mb-glass-border-hover); background:rgba(255,255,255,0.04); transform:scale(0.99) translateY(-1px); box-shadow:0 4px 12px rgba(0,0,0,0.2); }
      .mb-row select.mb-quality { flex:0 1 auto; min-width:0; max-width:112px; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
      .mb-row .mb-url { min-width:0; }
      .mb-row .mb-badge, .mb-row .mb-expiry-dot { flex-shrink:0; }
      .mb-row > div { flex-shrink:0; }
      .mb-row .mb-badge { font-size:11px; font-weight:700; padding:4px 8px; border-radius:8px; display:flex; align-items:center; gap:4px; letter-spacing:0.3px; }
      .mb-row .mb-url { flex:1; overflow:hidden; text-overflow:ellipsis; white-space:nowrap;
        font-family:'SF Mono', ui-monospace, Menlo, monospace; font-size:12px; color:#d4d4d8; }
      .mb-row button { background:rgba(255,255,255,0.08); border:none;
        color:var(--mb-text-main); border-radius:8px; padding:6px 12px; font-size:12px; font-weight:600;
        cursor:pointer; transition:all 0.25s var(--mb-ease); flex-shrink:0; }
      .mb-row button:hover { background:rgba(255,255,255,0.18); transform:scale(1.05); box-shadow:0 4px 12px rgba(0,0,0,0.2); }
      .mb-row button:active { transform:scale(0.95); }
      .mb-row .mb-mpv { background:var(--mb-accent-bg); color:var(--mb-accent); box-shadow:0 0 12px rgba(90,169,230,0.1); }
      .mb-row .mb-mpv:hover { background:rgba(90,169,230,0.25); color:var(--mb-accent-hover); box-shadow:0 0 16px rgba(90,169,230,0.2); }
      
      .mb-quality { font-size:11px; font-weight:700; color:var(--mb-text-muted); background:rgba(255,255,255,0.06);
        padding:3px 7px; border-radius:8px; flex-shrink:0; }
        
      /* Settings View */
      .mb-view-settings { display:flex; flex-direction:column; flex:1; min-height:400px; animation:mb-fade-in 0.4s var(--mb-ease); }
      .mb-set-tabs { display:flex; background:rgba(255,255,255,0.02); border-bottom:1px solid rgba(255,255,255,0.04); }
      .mb-set-tab { flex:1; text-align:center; padding:14px 0; font-size:12px; font-weight:700; color:var(--mb-text-muted);
        cursor:pointer; transition:all 0.3s var(--mb-ease); border-bottom:2px solid transparent; letter-spacing:0.5px; }
      .mb-set-tab:hover { color:var(--mb-text-main); background:rgba(255,255,255,0.03); }
      .mb-set-tab.active { color:var(--mb-accent); border-bottom-color:var(--mb-accent); background:var(--mb-accent-bg); text-shadow:0 0 8px rgba(90,169,230,0.4); }
      
      .mb-set-content { display:none; flex-direction:column; padding:16px 16px 0 16px; flex:1; overflow-y:auto; box-sizing:border-box; scrollbar-gutter:stable; }
      .mb-set-content.active { display:flex; animation:mb-slide-up 0.3s var(--mb-ease); }
      .mb-set-content::-webkit-scrollbar { width:5px; }
      .mb-set-content::-webkit-scrollbar-track { background:transparent; margin-bottom: 8px; }
      .mb-set-content::-webkit-scrollbar-thumb { background:rgba(255,255,255,0.15); border-radius:10px; }
      .mb-set-content::-webkit-scrollbar-thumb:hover { background:rgba(255,255,255,0.25); }
      .mb-set-content::after { content:""; display:block; height:16px; flex-shrink:0; }
      
      .mb-set-row { display:flex; justify-content:space-between; align-items:center; padding:14px 0;
        border-bottom:1px solid rgba(255,255,255,0.04); gap:16px; transition:all 0.3s var(--mb-ease); border-radius:10px; }
      .mb-set-row:hover { background:rgba(255,255,255,0.015); transform:translateX(2px); padding-left:8px; padding-right:8px; margin-left:-8px; margin-right:-8px; border-bottom-color:transparent; box-shadow:0 2px 8px rgba(0,0,0,0.1); }
      .mb-set-row:last-child { border-bottom:none; }
      .mb-set-info { flex:1; }
      .mb-set-name { font-size:14px; font-weight:600; color:var(--mb-text-main); margin-bottom:4px; letter-spacing:0.2px; }
      .mb-set-desc { font-size:12px; color:var(--mb-text-muted); line-height:1.5; }
      .mb-set-actions-inline { display:flex; align-items:center; gap:12px; }
      
      .mb-set-label { font-size:12px; font-weight:700; color:var(--mb-text-muted); margin-bottom:10px; text-transform:uppercase; letter-spacing:0.8px; flex-shrink:0; }
      
      .mb-set-textarea { 
        width:100%; background:rgba(0,0,0,0.25); border:1px solid rgba(255,255,255,0.08);
        border-radius:12px; color:#eee; font:13px/1.6 'SF Mono', ui-monospace, monospace; 
        padding:16px; resize:none; box-sizing:border-box; transition:all 0.3s var(--mb-ease);
        flex:1; min-height:100px; margin-bottom:0; box-shadow:inset 0 2px 8px rgba(0,0,0,0.2);
      }
      .mb-set-textarea:focus { outline:none; border-color:var(--mb-accent); background:rgba(0,0,0,0.4); box-shadow:0 0 0 4px rgba(90,169,230,0.15), inset 0 2px 8px rgba(0,0,0,0.3); }
      
      .mb-settings-input-small { width:54px; background:rgba(0,0,0,0.25); border:1px solid rgba(255,255,255,0.08);
        border-radius:8px; color:#eee; padding:6px 8px; font-size:13px; text-align:center; transition:all 0.3s var(--mb-ease); box-shadow:inset 0 2px 4px rgba(0,0,0,0.1); }
      .mb-settings-input-small:focus { outline:none; border-color:var(--mb-accent); box-shadow:0 0 0 3px rgba(90,169,230,0.15); }
      
      /* iOS Toggle Switches */
      .mb-switch { position:relative; display:inline-block; width:44px; height:24px; flex-shrink:0; }
      .mb-switch input { opacity:0; width:0; height:0; }
      .mb-slider { position:absolute; cursor:pointer; top:0; left:0; right:0; bottom:0; background-color:rgba(255,255,255,0.12); transition:0.4s var(--mb-ease); border-radius:24px; box-shadow:inset 0 2px 4px rgba(0,0,0,0.2); }
      .mb-slider:before { position:absolute; content:""; height:18px; width:18px; left:3px; bottom:3px; background-color:#fff; transition:0.4s var(--mb-ease); border-radius:50%; box-shadow:0 2px 6px rgba(0,0,0,0.3); }
      input:checked + .mb-slider { background-color:var(--mb-accent); box-shadow:inset 0 2px 4px rgba(0,0,0,0.2), 0 0 12px rgba(90,169,230,0.3); }
      input:checked + .mb-slider-image { background-color:var(--mb-green); box-shadow:inset 0 2px 4px rgba(0,0,0,0.2), 0 0 12px rgba(94,207,143,0.3); }
      input:checked + .mb-slider-video { background-color:var(--mb-purple); box-shadow:inset 0 2px 4px rgba(0,0,0,0.2), 0 0 12px rgba(199,147,240,0.3); }
      input:checked + .mb-slider-audio { background-color:var(--mb-orange); box-shadow:inset 0 2px 4px rgba(0,0,0,0.2), 0 0 12px rgba(240,168,92,0.3); }
      input:checked + .mb-slider-font { background-color:var(--mb-red); box-shadow:inset 0 2px 4px rgba(0,0,0,0.2), 0 0 12px rgba(230,96,90,0.3); }
      input:checked + .mb-slider:before { transform:translateX(20px); }
      
      .mb-empty { color:#78787d; font-size:13px; text-align:center; padding:30px 16px; font-weight:500; letter-spacing:0.2px; }
      .mb-expiry-dot { width:8px; height:8px; border-radius:50%; flex-shrink:0; transition:background 0.3s ease; }
      .mb-expiry-fresh { background:var(--mb-green); box-shadow:0 0 8px rgba(94,207,143,0.6); }
      .mb-expiry-soon { background:var(--mb-orange); box-shadow:0 0 8px rgba(240,168,92,0.6); }
      .mb-expiry-expired { background:var(--mb-red); box-shadow:0 0 8px rgba(230,96,90,0.6); }
      .mb-expiry-unknown { background:#4a4a4f; }
      .mb-row.mb-expired > button { opacity:0.3; filter:grayscale(1); pointer-events:none; }
      
      @keyframes mb-morph-in { from { opacity:0; transform:scale(0.9) translateY(20px); } to { opacity:1; transform:none; } }
      @keyframes mb-fade-in { from { opacity:0; transform:translateY(10px); } to { opacity:1; transform:none; } }
      @keyframes mb-slide-up { from { opacity:0; transform:translateY(15px) scale(0.98); } to { opacity:1; transform:none; } }
      @keyframes mb-pulse { 0% { box-shadow: 0 0 0 0 rgba(230,96,90,0.6); } 70% { box-shadow: 0 0 0 12px rgba(230,96,90,0); } 100% { box-shadow: 0 0 0 0 rgba(230,96,90,0); } }
      .mb-pulse-anim { animation: mb-pulse 1.2s var(--mb-ease); }

    `;
    document.documentElement.appendChild(style);
  }



  chrome.runtime.onMessage.addListener((msg, sender, sendResponse) => {
    if (msg.__mbCapture) {
      // background.js's chrome.tabs.sendMessage broadcasts to every injected frame
      // in the tab (not just the top one) — without this guard, every embedded
      // iframe would independently build its own panel from the same broadcast.
      // The top frame is the only one that should ever act on it.
      if (!IS_TOP) return;
      if (typeof recordResolved === 'function') {
        recordResolved(msg.type, msg.url, msg.ref || location.href, null, null);
      }
    }
  });

  const TYPE_STYLE = {
    video: { color: '#5aa9e6', bg: 'rgba(90,169,230,.13)', icon: '<svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><polygon points="23 7 16 12 23 17 23 7"></polygon><rect x="1" y="5" width="15" height="14" rx="2" ry="2"></rect></svg>' },
    image: { color: '#5ecf8f', bg: 'rgba(94,207,143,.13)', icon: '<svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="3" y="3" width="18" height="18" rx="2" ry="2"></rect><circle cx="8.5" cy="8.5" r="1.5"></circle><polyline points="21 15 16 10 5 21"></polyline></svg>' },
    audio: { color: '#f0a85c', bg: 'rgba(240,168,92,.13)', icon: '<svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><polygon points="11 5 6 9 2 9 2 15 6 15 11 19 11 5"></polygon><path d="M19.07 4.93a10 10 0 0 1 0 14.14M15.54 8.46a5 5 0 0 1 0 7.07"></path></svg>' },
    font: { color: '#c793f0', bg: 'rgba(199,147,240,.13)', icon: '<svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><polyline points="4 7 4 4 20 4 20 7"></polyline><line x1="9" y1="20" x2="15" y2="20"></line><line x1="12" y1="4" x2="12" y2="20"></line></svg>' },
  };

  let activeFilter = 'all';

  function renderEmptyState() {
    if (collected.length === 0 && !list.querySelector('.mb-empty')) {
      const empty = document.createElement('div');
      empty.className = 'mb-empty';
      empty.textContent = 'Nothing blocked yet on this page.';
      list.appendChild(empty);
    }
  }

  function applyFilter() {
    list.querySelectorAll('.mb-row').forEach(row => {
      row.style.display = (activeFilter === 'all' || row.dataset.type === activeFilter) ? 'flex' : 'none';
    });
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

  const allEntryRefs = [];

  function updateExpiryVisual(entryRef) {
    const expiry = entryRef.state.expiry;
    const dot = entryRef.expiryDot;
    if (!dot) return;
    if (typeof expiry !== 'number') {
      dot.className = 'mb-expiry-dot mb-expiry-unknown';
      dot.style.display = 'none'; // Hide if unknown
      dot.title = 'No expiry detected';
      entryRef.row.classList.remove('mb-expired');
      return;
    }
    dot.style.display = ''; // Show if known
    const remaining = expiry - Date.now() / 1000;
    if (remaining <= 0) {
      dot.className = 'mb-expiry-dot mb-expiry-expired';
      dot.title = 'Link expired';
      entryRef.row.classList.add('mb-expired');
    } else if (remaining < 60) {
      dot.className = 'mb-expiry-dot mb-expiry-soon';
      dot.title = 'Expires in ' + Math.ceil(remaining) + 's';
      entryRef.row.classList.remove('mb-expired');
    } else {
      dot.className = 'mb-expiry-dot mb-expiry-fresh';
      dot.title = 'Expires in ~' + Math.round(remaining / 60) + 'm';
      entryRef.row.classList.remove('mb-expired');
    }
  }
  setInterval(() => {
    if (widgetPanel && widgetPanel.style.display === 'none') return;
    allEntryRefs.forEach(updateExpiryVisual);
  }, 5000);

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

  // Builds the "quality variant" <select> shown when a master playlist's variants
  // are known — used both when the row is first drawn (variants known immediately)
  // and when they arrive later via updateEntryDisplay (async HLS parse).
  function buildVariantSelect(state, onSelect) {
    const variantSelect = document.createElement('select');
    variantSelect.className = 'mb-quality';
    variantSelect.style.cssText = 'appearance:none; border:none; outline:none; cursor:pointer; padding-right:14px; background:rgba(255,255,255,.06) url("data:image/svg+xml,%3Csvg xmlns=\'http://www.w3.org/2000/svg\' width=\'10\' height=\'10\' viewBox=\'0 0 24 24\' fill=\'none\' stroke=\'%239d9da2\' stroke-width=\'2\' stroke-linecap=\'round\' stroke-linejoin=\'round\'%3E%3Cpolyline points=\'6 9 12 15 18 9\'%3E%3C/polyline%3E%3C/svg%3E") no-repeat right 3px center;';

    const autoOpt = document.createElement('option');
    autoOpt.value = 'auto';
    autoOpt.textContent = 'Auto (Best)';
    autoOpt.style.background = '#1a1a1c';
    variantSelect.appendChild(autoOpt);

    state.variants.forEach((v, idx) => {
      const opt = document.createElement('option');
      opt.value = String(idx);
      opt.textContent = v.label || v.quality || 'Unknown';
      opt.title = [v.quality, formatBitrate(v.bandwidth), v.fps ? v.fps + 'fps' : '', v.codecs].filter(Boolean).join(' · ');
      opt.style.background = '#1a1a1c';
      variantSelect.appendChild(opt);
    });

    variantSelect.onchange = () => {
      const selected = variantSelect.value === 'auto' ? null : (state.variants[parseInt(variantSelect.value, 10)] || null);
      state.selectedVariant = selected;
      state.selectedUrl = selected ? selected.url : state.url;
      state.selectedQuality = selected ? selected.quality : null;
      state.downloadFormat = variantToFormatSelector(selected);
      onSelect(state.selectedUrl);
    };
    return variantSelect;
  }

  function renderEntry(type, state) {
    if (MODE === 'off') return;
    state.ref = state.ref || document.location.href;
    if (!panel) buildWidget();
    const emptyEl = list.querySelector('.mb-empty');
    if (emptyEl) emptyEl.remove();
    updateCounts();

    let style = TYPE_STYLE[type] || TYPE_STYLE.image;
    if (type === 'image' && isSvgUrl(state.url)) {
      style = { color: '#eb5e28', bg: 'rgba(235,94,40,.13)', icon: '<svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><polygon points="12 2 2 7 12 12 22 7 12 2"></polygon><polyline points="2 17 12 22 22 17"></polyline><polyline points="2 12 12 17 22 12"></polyline></svg>' };
    }
    const row = document.createElement('div');
    row.className = 'mb-row';
    row.dataset.type = type;
    row.style.background = style.bg;
    if (activeFilter !== 'all' && activeFilter !== type) row.style.display = 'none';

    const badge = document.createElement('a');
    badge.href = state.selectedUrl || state.url;
    badge.target = '_blank';
    badge.rel = 'noopener noreferrer';
    badge.className = 'mb-badge';
    badge.style.color = style.color;
    badge.style.background = 'rgba(255,255,255,.06)';
    badge.style.display = 'flex';
    badge.style.alignItems = 'center';
    badge.style.justifyContent = 'center';
    badge.style.padding = '5px 7px';
    badge.style.cursor = 'pointer';
    badge.style.textDecoration = 'none';
    badge.innerHTML = style.icon;
    badge.title = 'Click to open in new tab';
    badge.onclick = (e) => {
      e.stopPropagation();
    };
    row.appendChild(badge);

    let qualityBadge = null;
    let variantSelect = null;
    if (state.quality) {
      qualityBadge = document.createElement('span');
      qualityBadge.className = 'mb-quality';
      qualityBadge.textContent = state.quality;
      row.appendChild(qualityBadge);
    } else if (state.variants && state.variants.length > 0) {
      variantSelect = buildVariantSelect(state, (selectedUrl) => { badge.href = selectedUrl; });
      row.appendChild(variantSelect);
    }

    const link = document.createElement('span');
    link.className = 'mb-url';
    link.textContent = formatFilename(state.url);
    link.title = state.selectedUrl || state.url;
    link.style.cursor = 'pointer';
    link.onclick = () => {
      // Bundle the URL with its referer/UA so copypaste.lua's paste() can set
      // --referrer/--user-agent before loading in mpv (needed for CDNs that
      // check these). Falls back to a bare URL when we have neither header,
      // so the clipboard still works as a normal link anywhere else.
      // With a chosen rendition we copy the *master* URL plus a yt-dlp format
      // selector (same as the play/download buttons), because a child
      // playlist is often video-only.
      const fmt = state.downloadFormat || null;
      const playUrl = fmt ? state.url : (state.selectedUrl || state.url);
      const payload = { url: playUrl };
      if (state.ref) payload.ref = state.ref;
      if (navigator.userAgent) payload.ua = navigator.userAgent;
      if (fmt) {
        payload.format = fmt;
        if (state.selectedVariant && state.selectedVariant.label) payload.label = state.selectedVariant.label;
      }
      const text = (payload.ref || payload.ua || payload.format)
        ? '#MBSTREAM\n' + JSON.stringify(payload)
        : playUrl;
      if (typeof GM_setClipboard === 'function') GM_setClipboard(text);
      else navigator.clipboard.writeText(text);
      const originalText = link.textContent;
      link.textContent = 'Copied!';
      setTimeout(() => { link.textContent = originalText; }, 900);
    };
    row.appendChild(link);

    const expiryDot = document.createElement('span');
    row.appendChild(expiryDot);

    const btnWrap = document.createElement('div');
    btnWrap.style.display = 'flex';
    btnWrap.style.gap = '4px';

    const dlBtn = document.createElement('button');
    dlBtn.innerHTML = ICON_DOWNLOAD;
    dlBtn.title = (type === 'image' || type === 'font') ? 'Download file directly' : 'Download with yt-dlp';
    dlBtn.onclick = async () => {
      if (type === 'image' || type === 'font') {
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
            return;
          }
        } catch (e) {}

        if (typeof GM_download === 'function') {
          GM_download({
            url: targetUrl,
            name: filename,
            headers: { 'Referer': window.location.href, 'Origin': window.location.origin },
            saveAs: false,
            onerror: () => {
              window.open(targetUrl, '_blank');
            }
          });
        } else {
          window.open(targetUrl, '_blank');
        }
        return;
      }

      const selectedQualityFormat = state.downloadFormat || null;
      const payload = {
        action: 'download',
        // Resolution-specific HLS playlists from some sites are video-only.
        // For a selected resolution, download from the master playlist and let
        // yt-dlp select that video height plus best audio, then merge them.
        url: selectedQualityFormat ? state.url : (state.selectedUrl || state.url),
        format: selectedQualityFormat || null,
        ref: state.ref,
        ua: navigator.userAgent,
        title: document.title || 'video'
      };
      launchMpv(payload, (result) => {
        dlBtn.innerHTML = result.ok ? ICON_CHECK_12 : ICON_ERROR_12;
        if (!result.ok) console.warn('[Media Blocker] mpv download failed:', result.error);
        setTimeout(() => { dlBtn.innerHTML = ICON_DOWNLOAD; }, 1200);
      });
    };
    btnWrap.appendChild(dlBtn);

    if (type !== 'font' && type !== 'subtitle' && !isSvgUrl(state.url)) {
      const mpvBtn = document.createElement('button');
      mpvBtn.className = 'mb-mpv';
      mpvBtn.innerHTML = ICON_MPV_PLAY;
      mpvBtn.title = 'Open directly in mpv';
      mpvBtn.onclick = () => {
        const selectedQualityFormat = state.downloadFormat || null;
        const payload = {
          action: 'play',
          type: type,
          // A resolution-specific HLS child playlist is often video-only.
          // Use the master playlist plus an yt-dlp format selector so playback
          // gets both the selected video rendition and the best audio.
          url: selectedQualityFormat ? state.url : (state.selectedUrl || state.url),
          format: selectedQualityFormat,
          ref: state.ref,
          ua: navigator.userAgent,
          title: document.title || 'video'
        };
        mpvBtn.innerHTML = '<svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><path d="M21 12a9 9 0 1 1-6.219-8.56"><animateTransform attributeName="transform" type="rotate" from="0 12 12" to="360 12 12" dur="0.8s" repeatCount="indefinite"/></path></svg>';
        launchMpv(payload, (result) => {
          mpvBtn.innerHTML = result.ok ? ICON_CHECK_12 : ICON_ERROR_12;
          if (!result.ok) console.warn('[Media Blocker] mpv play failed:', result.error);
          setTimeout(() => { mpvBtn.innerHTML = ICON_MPV_PLAY; }, 1200);
        });
      };
      btnWrap.appendChild(mpvBtn);
    }
    row.appendChild(btnWrap);
    
    if (type === 'image') {
      badge.addEventListener('mouseenter', () => {
        const myToken = ++previewToken;
        let popup = document.getElementById('mb-preview-popup');
        if (!popup) {
          popup = document.createElement('div');
          popup.id = 'mb-preview-popup';
          popup.style.cssText = `
            position: fixed;
            z-index: 2147483647;
            background: #111;
            border: 1px solid #333;
            border-radius: 6px;
            padding: 4px;
            box-shadow: 0 4px 12px rgba(0,0,0,0.8);
            pointer-events: none;
            display: none;
          `;
          const img = document.createElement('img');
          img.style.cssText = 'max-width: 300px; max-height: 300px; border-radius: 4px; display: block; object-fit: contain;';
          popup.appendChild(img);
          document.documentElement.appendChild(popup);
        }
        // Keep the popup hidden until the new image has actually decoded — the
        // <img> is a shared singleton, so showing it immediately just displays
        // whatever the last-hovered row's image was until this one loads in.
        popup.style.display = 'none';
        const img = popup.querySelector('img');
        const sep = state.url.includes('?') ? '&' : '?';
        img.onload = () => {
          if (myToken !== previewToken) return; // mouse already moved elsewhere
          positionPreviewPopup(popup, badge);
        };
        img.onerror = () => { img.onload = null; };
        img.src = state.url + sep + '__mb_preview=1';
      });

      badge.addEventListener('mouseleave', () => {
        previewToken++; // invalidate any load from this row still in flight
        const popup = document.getElementById('mb-preview-popup');
        if (popup) popup.style.display = 'none';
      });
    }

    list.appendChild(row);

    const entryRef = { state, link, row, expiryDot, qualityBadge, badge, variantSelect };
    allEntryRefs.push(entryRef);
    updateExpiryVisual(entryRef);
    return entryRef;
  }

function updateEntryDisplay(entryRef, newUrl) {
    if (entryRef.state.variants && !entryRef.variantSelect && !entryRef.qualityBadge) {
      const variantSelect = buildVariantSelect(entryRef.state, (selectedUrl) => {
        if (entryRef.badge) entryRef.badge.href = selectedUrl;
      });

      entryRef.row.insertBefore(variantSelect, entryRef.link);
      entryRef.variantSelect = variantSelect;
    }

    entryRef.link.textContent = formatFilename(newUrl);
    entryRef.link.title = newUrl;
    updateExpiryVisual(entryRef);
    const prevTransition = entryRef.row.style.transition;
    const prevBackground = entryRef.row.style.background;
    entryRef.row.style.transition = 'background .3s ease';
    entryRef.row.style.background = 'rgba(90,169,230,.25)';
    setTimeout(() => {
      entryRef.row.style.background = prevBackground;
      entryRef.row.style.transition = prevTransition;
    }, 400);
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
      const src = el.src || el.getAttribute('src');
      if (src && !src.startsWith('data:')) {
        if (shouldIntercept('image', src, el)) record('image', src);
      }
      const srcset = el.getAttribute('srcset');
      if (srcset) {
        const urls = srcset.split(',').map(s => s.trim().split(' ')[0]).filter(u => u && !u.startsWith('data:'));
        urls.forEach(u => {
          if (shouldIntercept('image', u, el)) record('image', u);
        });
      }
    }
    const styleAttr = el.getAttribute('style');
    if (styleAttr && /url\(/i.test(styleAttr)) {
      const urls = Array.from(styleAttr.matchAll(/url\(['"]?(.*?)['"]?\)/ig)).map(m => m[1]).filter(u => u && !u.startsWith('data:'));
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
