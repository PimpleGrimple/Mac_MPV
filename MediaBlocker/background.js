// Everything that talks to the native host (settings, URL checks, message format)
// lives in mpv-bridge.js so the YouTube button, browser commands, menus and popup
// all go through the same code.
importScripts('mpv-bridge.js');

let GLOBAL_MODE = 'block';
let blockingDomains = [];
let nonBlockingDomains = [];
let DISABLED_SITES = [];
let TYPES = ['image', 'video', 'audio', 'font'];
// Extended so the manifest itself is caught even before tab-scoped host
// rules have been installed. Keywords are tab-scoped and only applied to
// xmlhttprequest/media/other, so this does not affect normal page resources.
let BLOCK_KEYWORDS = [
  '.m4s', '.ts', '_init.mp4', 'init-', '/init', '/segment', '/frag', 'seg-',
];
// Manifest keywords are kept in their own list on purpose. They are blocked at
// the network level (so the manifest is caught before tab-scoped host rules
// exist) but they must NOT feed isSegmentUrl(): that function decides what is
// *ignored* by the capture pipeline, and manifests are exactly what we capture.
// Previously these lived in BLOCK_KEYWORDS, so on a fresh install (no saved
// keyword list) every .m3u8/.mpd URL was classed as a "segment" and skipped.
const MANIFEST_BLOCK_KEYWORDS = ['.mpd', '.m3u8', '.f4m', '/manifest'];
let EXCEPTIONS = [];

const MB_DEBUG = true;
function dbg(...args) { if (MB_DEBUG) try { console.log('[MB]', ...args); } catch (e) {} }

const tabUrlCache = new Map();

// MV3 service workers are killed after ~30s idle. Anything held only in memory
// is lost, and recomputeSessionRules() wipes ALL session rules before rebuilding
// them, so learned media prefixes/hosts silently vanished on every wake-up.
// stateReady gates the first rule build until settings + learned state are
// loaded (it also stops a first build running with default settings).
let resolveStateReady;
const stateReady = new Promise(resolve => { resolveStateReady = resolve; });

function normalizeDomain(value) {
  let s = String(value || '').trim().toLowerCase();
  if (!s) return '';
  s = s.replace(/^https?:\/\//, '');
  s = s.split('/')[0].split('?')[0].split('#')[0];
  s = s.replace(/^\*\.?/, '');
  s = s.replace(/^www\./, '');
  return s;
}

function normalizeDomainList(list) {
  return Array.from(new Set((Array.isArray(list) ? list : [])
    .map(normalizeDomain)
    .filter(Boolean)));
}

// Registrable domain (eTLD+1). CDNs like av1encodes.com serve manifests from
// cdn11.av1encodes.com but segments from cdn04.av1encodes.com — recording the
// exact host would miss the sibling nodes, so we record the eTLD+1.
//
// TWO_PART_TLDS is a pragmatic subset of the Public Suffix List covering the
// common two-label suffixes seen on media sites. If registrableDomain() ever
// mis-splits a host, the fallback (last two labels) is correct for the vast
// majority of domains.
const TWO_PART_TLDS = new Set([
  'co.uk', 'org.uk', 'ac.uk', 'gov.uk',
  'com.au', 'net.au', 'org.au',
  'co.nz', 'com.br', 'com.cn', 'com.mx',
]);

function registrableDomain(host) {
  if (!host) return '';
  const parts = String(host).toLowerCase().split('.');
  if (parts.length <= 2) return parts.join('.');
  const lastTwo = parts.slice(-2).join('.');
  if (TWO_PART_TLDS.has(lastTwo)) return parts.slice(-3).join('.');
  return lastTwo;
}

function cacheTabUrl(tabId, url) {
  if (!Number.isInteger(tabId)) return false;
  if (typeof url === 'string' && /^https?:\/\//i.test(url)) {
    const old = tabUrlCache.get(tabId);
    tabUrlCache.set(tabId, url);
    return old !== url;
  }
  const had = tabUrlCache.delete(tabId);
  return had;
}

function refreshTabFromId(tabId, callback) {
  chrome.tabs.get(tabId, tab => {
    if (chrome.runtime.lastError || !tab) return callback(false);
    callback(cacheTabUrl(tabId, tab.url));
  });
}

chrome.tabs.onUpdated.addListener((tabId, changeInfo, tab) => {
  const url = changeInfo.url || (tab && tab.url);
  if (changeInfo.url) {
    clearMediaPrefixes(tabId);
  }
  if (url !== undefined) {
    if (cacheTabUrl(tabId, url)) scheduleDnrUpdate();
  }
});

chrome.tabs.onActivated.addListener(({ tabId }) => {
  refreshTabFromId(tabId, changed => {
    if (changed) scheduleDnrUpdate();
  });
});

chrome.tabs.onRemoved.addListener(tabId => {
  clearMediaPrefixes(tabId);
  if (tabUrlCache.delete(tabId)) scheduleDnrUpdate();
});

chrome.tabs.query({}, tabs => {
  let changed = false;
  for (const tab of tabs) {
    if (cacheTabUrl(tab.id, tab.url)) changed = true;
  }
  if (changed || tabs.length > 0) scheduleDnrUpdate();
});

const requestRefererCache = new Map();

const tabMediaPathPrefixes = new Map();
const tabMediaHosts = new Map();

function mediaDirectoryPrefix(url) {
  try {
    const u = new URL(url);
    const slash = u.pathname.lastIndexOf('/');
    let prefix;
    if (slash < 0) {
      prefix = `${u.origin}/`;
    } else {
      prefix = `${u.origin}${u.pathname.slice(0, slash + 1)}`;
    }
    // DNR urlFilter has a length cap. Some manifests embed a multi-hundred-
    // char base64 token in the path, so truncate very long prefixes. Since
    // `|prefix` is start-anchored, truncation is safe.
    if (prefix.length > 2000) prefix = prefix.slice(0, 2000);
    return prefix;
  } catch (e) {
    return '';
  }
}

function mediaHost(url) {
  try { return new URL(url).hostname; } catch (e) { return ''; }
}

function rememberMediaPrefix(tabId, url) {
  if (!Number.isInteger(tabId) || tabId < 0 || !url) return false;

  let changed = false;

  const prefix = mediaDirectoryPrefix(url);
  if (prefix) {
    let set = tabMediaPathPrefixes.get(tabId);
    if (!set) { set = new Set(); tabMediaPathPrefixes.set(tabId, set); }
    if (!set.has(prefix)) {
      if (set.size >= 8) set.delete(set.values().next().value);
      set.add(prefix);
      changed = true;
    }
  }

  const host = mediaHost(url);
  const regDomain = registrableDomain(host);
  if (regDomain) {
    let hosts = tabMediaHosts.get(tabId);
    if (!hosts) { hosts = new Set(); tabMediaHosts.set(tabId, hosts); }
    if (!hosts.has(regDomain)) {
      if (hosts.size >= 8) hosts.delete(hosts.values().next().value);
      hosts.add(regDomain);
      changed = true;
    }
  }

  return changed;
}

function rememberMediaHost(tabId, url) {
  if (!Number.isInteger(tabId) || tabId < 0 || !url) return false;
  const regDomain = registrableDomain(mediaHost(url));
  if (!regDomain) return false;
  let hosts = tabMediaHosts.get(tabId);
  if (!hosts) { hosts = new Set(); tabMediaHosts.set(tabId, hosts); }
  if (hosts.has(regDomain)) return false;
  if (hosts.size >= 8) hosts.delete(hosts.values().next().value);
  hosts.add(regDomain);
  return true;
}

function clearMediaPrefixes(tabId) {
  const a = tabMediaPathPrefixes.delete(tabId);
  const b = tabMediaHosts.delete(tabId);
  return a || b;
}

function persistMediaState() {
  if (!chrome.storage.session) return;
  const dump = map => Array.from(map, ([id, set]) => [id, Array.from(set)]);
  chrome.storage.session.set({
    mbPrefixes: dump(tabMediaPathPrefixes),
    mbHosts: dump(tabMediaHosts),
  }).catch(() => {});
}

function restoreMediaState(done) {
  if (!chrome.storage.session) return done();
  chrome.storage.session.get(['mbPrefixes', 'mbHosts'], res => {
    const merge = (saved, target) => {
      for (const [id, values] of (Array.isArray(saved) ? saved : [])) {
        const set = target.get(id) || new Set();
        for (const v of values) set.add(v);
        target.set(id, set);
      }
    };
    if (!chrome.runtime.lastError && res) {
      merge(res.mbPrefixes, tabMediaPathPrefixes);
      merge(res.mbHosts, tabMediaHosts);
    }
    done();
  });
}

// requestId -> first URL of a redirect chain. Redirect targets (one-time CDN tokens)
// die quickly; the URL the page originally asked for re-resolves every time.
const chainOrigin = new Map();
chrome.webRequest.onBeforeRedirect.addListener(
  d => { if (!chainOrigin.has(d.requestId)) chainOrigin.set(d.requestId, d.url); },
  { urls: ["<all_urls>"] }
);
const originalUrl = d => chainOrigin.get(d.requestId) || d.url;

chrome.webRequest.onCompleted.addListener(
  d => { requestRefererCache.delete(d.requestId); chainOrigin.delete(d.requestId); },
  { urls: ["<all_urls>"] }
);
chrome.webRequest.onErrorOccurred.addListener(
  d => { requestRefererCache.delete(d.requestId); chainOrigin.delete(d.requestId); },
  { urls: ["<all_urls>"] }
);

const INVALID_REFERER_PREFIXES = [
  'about:', 'chrome:', 'chrome-extension:', 'moz-extension:',
  'file:', 'blob:', 'data:'
];

function bestReferer(details) {
  let ref = requestRefererCache.get(details.requestId)
    || details.originUrl
    || details.documentUrl
    || (details.initiator && details.initiator !== 'null' ? details.initiator : null)
    || tabUrlCache.get(details.tabId);

  if (ref && INVALID_REFERER_PREFIXES.some(p => ref.startsWith(p))) ref = null;
  return ref || details.url;
}

let dnrQueue = Promise.resolve();
let dnrScheduled = false;

function scheduleDnrUpdate() {
  if (dnrScheduled) return;
  dnrScheduled = true;
  queueMicrotask(() => {
    dnrScheduled = false;
    dnrQueue = dnrQueue
      .then(async () => {
        await stateReady;
        await updateStaticRules();
        await recomputeSessionRules();
        persistMediaState();
      })
      .catch(err => {
        dbg('DNR queue error', err);
      });
  });
}

function getDynamicRulesAsync() {
  return new Promise(resolve => {
    chrome.declarativeNetRequest.getDynamicRules(rules => resolve(rules || []));
  });
}

function getSessionRulesAsync() {
  return new Promise(resolve => {
    chrome.declarativeNetRequest.getSessionRules(rules => resolve(rules || []));
  });
}

function updateDynamicRulesAsync(options) {
  return new Promise(resolve => {
    chrome.declarativeNetRequest.updateDynamicRules(options, () => {
      if (chrome.runtime.lastError) {
        dbg('updateDynamicRules error:', chrome.runtime.lastError.message);
      }
      resolve();
    });
  });
}

function updateSessionRulesAsync(options) {
  return new Promise(resolve => {
    chrome.declarativeNetRequest.updateSessionRules(options, () => {
      if (chrome.runtime.lastError) {
        dbg('updateSessionRules error:', chrome.runtime.lastError.message);
      }
      resolve();
    });
  });
}

function hostMatches(host, domain) {
  const h = normalizeDomain(host);
  const d = normalizeDomain(domain);
  return !!d && (h === d || h.endsWith('.' + d));
}

function isTabDisabled(host) {
  return DISABLED_SITES.some(domain => hostMatches(host, domain));
}

function isTabBlocking(host) {
  if (!host || isTabDisabled(host)) return false;
  if (GLOBAL_MODE === 'block') {
    return !nonBlockingDomains.some(domain => hostMatches(host, domain));
  }
  return blockingDomains.some(domain => hostMatches(host, domain));
}

function isTabBlockingById(tabId, details) {
  let url = tabUrlCache.get(tabId);
  if (!url && details) {
    url = details.originUrl
      || details.documentUrl
      || (details.initiator && details.initiator !== 'null' ? details.initiator : null);
  }
  if (!url) {
    dbg('isTabBlockingById: no url for tab', tabId);
    return false;
  }
  try {
    return isTabBlocking(new URL(url).hostname);
  } catch (e) {
    return false;
  }
}

function noteManifestDirectory(details, isManifest) {
  if (!isManifest) return;
  if (!isTabBlockingById(details.tabId, details)) return;
  if (rememberMediaPrefix(details.tabId, details.url)) {
    dbg('remembered media for tab', details.tabId, 'url', details.url);
    scheduleDnrUpdate();
  }
}

function getBaseResourceTypes() {
  const rt = new Set();
  if (TYPES.includes('image')) rt.add('image');
  if (TYPES.includes('video') || TYPES.includes('audio')) rt.add('media');
  if (TYPES.includes('font')) rt.add('font');
  return Array.from(rt);
}

async function updateStaticRules() {
  const existingRules = await getDynamicRulesAsync();
  const removeRuleIds = existingRules.map(r => r.id);
  const rules = [];
  let nextId = 1;

  rules.push({
    id: nextId++,
    priority: 1000,
    action: { type: 'allow' },
    condition: { urlFilter: '__mb_preview=1' }
  });

  for (const ex of EXCEPTIONS) {
    if (!ex) continue;
    rules.push({
      id: nextId++,
      priority: 900,
      action: { type: 'allow' },
      condition: { urlFilter: ex }
    });
  }

  await updateDynamicRulesAsync({ addRules: rules, removeRuleIds });
}

async function recomputeSessionRules() {
  const baseResourceTypes = getBaseResourceTypes();
  const blockingTabIds = [];
  const allowedTabIds = [];

  for (const [tabId, url] of tabUrlCache.entries()) {
    let host;
    try {
      host = new URL(url).hostname;
    } catch (e) {
      continue;
    }
    if (isTabBlocking(host)) blockingTabIds.push(tabId);
    else allowedTabIds.push(tabId);
  }

  const existingRules = await getSessionRulesAsync();
  const removeRuleIds = existingRules.map(r => r.id);
  const rules = [];
  let nextId = 1;

  const allowResourceTypes = Array.from(new Set([
    ...baseResourceTypes,
    ...(TYPES.includes('video') || TYPES.includes('audio') ? ['media', 'xmlhttprequest', 'other'] : [])
  ]));

  if (allowedTabIds.length > 0 && allowResourceTypes.length > 0) {
    rules.push({
      id: nextId++,
      priority: 100,
      action: { type: 'allow' },
      condition: {
        tabIds: allowedTabIds,
        resourceTypes: allowResourceTypes
      }
    });
  }

  if (blockingTabIds.length > 0) {
    if (baseResourceTypes.length > 0) {
      rules.push({
        id: nextId++,
        priority: 1,
        action: { type: 'block' },
        condition: {
          tabIds: blockingTabIds,
          resourceTypes: baseResourceTypes
        }
      });
    }

    if (TYPES.includes('video') || TYPES.includes('audio')) {
      const segmentResourceTypes = ['media', 'xmlhttprequest', 'other'];
      for (const kw of new Set([...BLOCK_KEYWORDS, ...MANIFEST_BLOCK_KEYWORDS])) {
        if (!kw) continue;
        rules.push({
          id: nextId++,
          priority: 1,
          action: { type: 'block' },
          condition: {
            tabIds: blockingTabIds,
            urlFilter: kw,
            resourceTypes: segmentResourceTypes
          }
        });
      }
    }

    for (const tabId of blockingTabIds) {
      const prefixes = tabMediaPathPrefixes.get(tabId);
      if (prefixes) {
        for (const prefix of prefixes) {
          rules.push({
            id: nextId++,
            priority: 2,
            action: { type: 'block' },
            condition: {
              tabIds: [tabId],
              urlFilter: `|${prefix}`,
              resourceTypes: ['media', 'xmlhttprequest', 'other']
            }
          });
        }
      }

      // Registrable-domain rules: ||av1encodes.com matches cdn04, cdn11, apex
      // — every subdomain at once. Only applied to block-scoped tabs.
      const hosts = tabMediaHosts.get(tabId);
      if (hosts) {
        for (const host of hosts) {
          rules.push({
            id: nextId++,
            priority: 2,
            action: { type: 'block' },
            condition: {
              tabIds: [tabId],
              urlFilter: `||${host}`,
              resourceTypes: ['media', 'xmlhttprequest', 'other']
            }
          });
        }
      }
    }
  }

  if (MB_DEBUG && blockingTabIds.length > 0) {
    dbg('session rules:', {
      blocking: blockingTabIds.length,
      allowed: allowedTabIds.length,
      total: rules.length,
      blockingTabs: blockingTabIds,
    });
  }

  await updateSessionRulesAsync({ addRules: rules, removeRuleIds });
}

chrome.storage.local.get([
  'GLOBAL_MODE',
  'blockingDomains',
  'nonBlockingDomains',
  'DISABLED_SITES',
  'TYPES',
  'BLOCK_KEYWORDS',
  'EXCEPTIONS'
], result => {
  if (result.GLOBAL_MODE) GLOBAL_MODE = result.GLOBAL_MODE;
  if (result.blockingDomains) blockingDomains = normalizeDomainList(result.blockingDomains);
  if (result.nonBlockingDomains) nonBlockingDomains = normalizeDomainList(result.nonBlockingDomains);
  if (result.DISABLED_SITES) DISABLED_SITES = normalizeDomainList(result.DISABLED_SITES);
  if (result.TYPES) TYPES = Array.isArray(result.TYPES) ? result.TYPES : TYPES;
  if (result.BLOCK_KEYWORDS) BLOCK_KEYWORDS = Array.isArray(result.BLOCK_KEYWORDS) ? result.BLOCK_KEYWORDS : BLOCK_KEYWORDS;
  if (result.EXCEPTIONS) EXCEPTIONS = Array.isArray(result.EXCEPTIONS) ? result.EXCEPTIONS : EXCEPTIONS;
  dbg('init', { GLOBAL_MODE, blockingDomains, nonBlockingDomains, DISABLED_SITES });
  restoreMediaState(() => {
    resolveStateReady();
    scheduleDnrUpdate();
  });
});

// "Download all" from the popup. The popup is destroyed the moment it loses focus, so it
// can't run the loop itself: it hands the whole list over in one message and this worker
// works through it, one item at a time with a short gap (so the browser and the native
// host aren't hammered). Items are either { file: true, id } (images/fonts, saved by the
// page itself) or { req } (a yt-dlp download through the shared pipeline). Batches are
// queued, so two clicks never interleave.
let bulkChain = Promise.resolve();
function queueBulkDownload(tabId, items) {
  bulkChain = bulkChain.then(async () => {
    for (const item of items) {
      try {
        if (item.file) {
          await new Promise(resolve => {
            chrome.tabs.sendMessage(tabId, { __mbDownloadFile: true, id: item.id }, { frameId: 0 }, () => {
              void chrome.runtime.lastError;   // page navigated away or closed: skip
              resolve();
            });
          });
        } else {
          const r = await MPV.handle(Object.assign({}, item.req, { action: 'download' }));
          if (!r.ok) console.error('[Media Blocker] bulk download failed:', r.error);
        }
      } catch (err) {
        console.error('[Media Blocker] bulk download failed:', err.message);
      }
      await new Promise(resolve => setTimeout(resolve, 400));
    }
  });
  return bulkChain;
}

// Toolbar icon: badge = number of video/audio streams captured on that tab; tooltip = mode.
// Badge colour matches the popup's mode control: red = blocking, amber = capture.
// Badge state is per tab, and a fresh page load announces itself with 0, which clears it.
function updateActionBadge(tabId, info) {
  const n = info.streams | 0;
  const mode = info.mode === 'capture' ? 'Capture only' : info.mode === 'off' ? 'Off on this site' : 'Blocking';
  const ignore = () => {};
  try {
    chrome.action.setBadgeText({ tabId, text: n > 0 ? (n > 99 ? '99+' : String(n)) : '' }).catch(ignore);
    chrome.action.setBadgeBackgroundColor({ tabId, color: info.mode === 'capture' ? '#f0a85c' : '#e6605a' }).catch(ignore);
    chrome.action.setTitle({ tabId, title: 'Media Blocker \u2014 ' + mode + (n ? ' \u00b7 ' + n + ' stream' + (n > 1 ? 's' : '') : '') }).catch(ignore);
  } catch (e) { /* tab closed, or action API unavailable */ }
}

chrome.runtime.onMessage.addListener((msg, sender, sendResponse) => {
  // Current blocking settings (with the worker's defaults applied) for the popup's
  // Blocking tab. Waits for the saved state to load so a cold-started worker doesn't
  // answer with defaults.
  if (msg.type === 'GET_GLOBAL_SETTINGS') {
    stateReady.then(() => sendResponse({
      globalMode: GLOBAL_MODE,
      disabledSites: DISABLED_SITES,
      types: TYPES,
      blockKeywords: BLOCK_KEYWORDS,
      exceptions: EXCEPTIONS
    }));
    return true;
  }

  if (msg.type === 'SET_GLOBAL_SETTINGS') {
    if (msg.globalMode) GLOBAL_MODE = msg.globalMode;
    if (msg.disabledSites) DISABLED_SITES = normalizeDomainList(msg.disabledSites);
    if (msg.types) TYPES = Array.isArray(msg.types) ? msg.types : TYPES;
    if (msg.blockKeywords) BLOCK_KEYWORDS = Array.isArray(msg.blockKeywords) ? msg.blockKeywords : BLOCK_KEYWORDS;
    if (msg.exceptions) EXCEPTIONS = Array.isArray(msg.exceptions) ? msg.exceptions : EXCEPTIONS;

    chrome.storage.local.set({
      GLOBAL_MODE,
      DISABLED_SITES,
      TYPES,
      BLOCK_KEYWORDS,
      EXCEPTIONS
    }, () => {
      scheduleDnrUpdate();
      sendResponse({ success: true });
    });
    return true;
  }

  if (msg.type === 'SET_SITE_MODE') {
    const host = normalizeDomain(msg.host);
    dbg('SET_SITE_MODE', host, msg.mode);
    if (host) {
      if (msg.mode === 'block') {
        nonBlockingDomains = nonBlockingDomains.filter(d => !hostMatches(d, host));
        if (!blockingDomains.some(d => hostMatches(d, host))) blockingDomains.push(host);
      } else {
        blockingDomains = blockingDomains.filter(d => !hostMatches(d, host));
        if (!nonBlockingDomains.some(d => hostMatches(d, host))) nonBlockingDomains.push(host);
      }
    }

    chrome.storage.local.set({ blockingDomains, nonBlockingDomains }, () => {
      dbg('site mode saved', { blockingDomains, nonBlockingDomains });
      scheduleDnrUpdate();
      dnrQueue.then(() => sendResponse({ success: true }))
              .catch(() => sendResponse({ success: true }));
    });
    return true;
  }

  // Diagnostic: dumps everything relevant to the SW console.
  // Trigger by running: chrome.runtime.sendMessage({__mbDump: true}, console.log)
  // (from the SW console itself, so the tab hint may be missing).
  if (msg.__mbDump) {
    chrome.declarativeNetRequest.getSessionRules(rules => {
      sendResponse({
        ok: true,
        storage: { GLOBAL_MODE, blockingDomains, nonBlockingDomains, DISABLED_SITES, TYPES, BLOCK_KEYWORDS },
        tabCacheSize: tabUrlCache.size,
        tabMediaHosts: Array.from(tabMediaHosts.entries()),
        tabMediaPathPrefixes: Array.from(tabMediaPathPrefixes.entries()),
        sessionRuleCount: rules.length,
        sessionRules: rules,
      });
    });
    return true;
  }

  if (msg.__mbFetchManifest) {
    const target = typeof msg.url === 'string' ? msg.url.trim() : '';
    if (!target) {
      sendResponse({ ok: false, error: 'No manifest URL provided' });
      return false;
    }

    const nativeFetch = {
      type: 'FETCH_MANIFEST',
      url: target,
      ref: typeof msg.ref === 'string' ? msg.ref : '',
      ua: typeof msg.ua === 'string' ? msg.ua : ''
    };

    chrome.runtime.sendNativeMessage(MPV.HOST, nativeFetch, nativeResponse => {
      const nativeError = chrome.runtime.lastError
        ? chrome.runtime.lastError.message
        : (nativeResponse && nativeResponse.error);

      if (!chrome.runtime.lastError && nativeResponse && nativeResponse.ok && typeof nativeResponse.text === 'string') {
        sendResponse(nativeResponse);
        return;
      }

      (async () => {
        try {
          const options = { cache: 'no-store', redirect: 'follow', credentials: 'omit' };
          if (typeof msg.ref === 'string' && /^https?:\/\//i.test(msg.ref)) {
            options.referrer = msg.ref;
            options.referrerPolicy = 'strict-origin-when-cross-origin';
          }
          const response = await fetch(target, options);
          if (!response.ok) throw new Error(`HTTP ${response.status}`);
          const text = await response.text();
          sendResponse({ ok: true, text });
        } catch (error) {
          sendResponse({
            ok: false,
            error: String(error && error.message || error),
            native_error: nativeError || ''
          });
        }
      })();
    });
    return true;
  }

  // The page announces what it has captured; the toolbar icon is the only always-visible
  // indicator now (there's no in-page widget), so reflect it per tab.
  if (msg.__mbChanged) {
    if (sender && sender.tab && Number.isInteger(sender.tab.id) && sender.tab.id >= 0) updateActionBadge(sender.tab.id, msg);
    return false;
  }

  if (msg.__mbBulkDownload) {
    const items = (Array.isArray(msg.items) ? msg.items : []).filter(it =>
      it && ((it.file === true && Number.isInteger(it.id)) || (it.req && typeof it.req.url === 'string')));
    if (!Number.isInteger(msg.tabId) || !items.length) {
      sendResponse({ ok: false, error: 'Nothing to download' });
    } else {
      queueBulkDownload(msg.tabId, items);
      sendResponse({ ok: true, queued: items.length });
    }
    return false;   // answered right away; the work carries on in the background
  }

  // The single entry point for play / download / host check, used by the panel
  // buttons, YouTube button, Alt+P, and the popup. msg: { __mbLaunchMpv, action,
  // url, ref, ua, title, format, type, startTime } — see MPV.buildMessage().
  if (msg.__mbLaunchMpv) {
    MPV.handle(msg).then(sendResponse, err => {
      sendResponse({ ok: false, error: String((err && err.message) || err) });
    });
    return true;
  }
});

function isManifestUrl(url) {
  if (!url) return false;
  const u = url.toLowerCase();
  return u.includes('.m3u8') || u.includes('.mpd') || u.includes('.f4m') || u.includes('ism/manifest');
}

// Path only, and the extension must END a path segment ("/" allowed: ".../123.mp4/?token=").
const VIDEO_PATH_RE = /\.(mp4|m4v|webm|ogg|ogv)(\/|$)/i;
function isHardBlockableVideoUrl(url) {
  if (!url) return false;
  try { return VIDEO_PATH_RE.test(new URL(url).pathname); } catch (e) { return false; }
}

function isSegmentUrl(url) {
  if (!url) return false;
  const u = url.toLowerCase();
  return BLOCK_KEYWORDS.some(kw => {
    if (!kw) return false;
    const cleanKw = kw.toLowerCase().replace(/\*/g, '');
    return u.includes(cleanKw);
  });
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

function manifestType(_url) {
  return 'video';
}

function shouldIntercept(type) {
  return type === 'video' || type === 'audio';
}

function sendCapture(tabId, payload) {
  if (!Number.isInteger(tabId) || tabId < 0) return;
  chrome.tabs.sendMessage(tabId, payload).catch(() => {});
}

function isCandidateUrl(url) {
  return !!url && !url.startsWith('chrome-extension://') && !isSegmentUrl(url);
}

chrome.webRequest.onBeforeRequest.addListener(
  details => {
    const url = details.url;
    if (!isCandidateUrl(url)) return;

    if (isManifestUrl(url) || isHardBlockableVideoUrl(url)) {
      noteManifestDirectory(details, isManifestUrl(url));
      const type = manifestType(url);
      if (shouldIntercept(type)) {
        sendCapture(details.tabId, {
          __mbCapture: true,
          type,
          url: originalUrl(details),
          ref: bestReferer(details)
        });
      }
    }
  },
  { urls: ['<all_urls>'] }
);

chrome.webRequest.onBeforeSendHeaders.addListener(
  details => {
    if (details.requestHeaders) {
      const refHeader = details.requestHeaders.find(h => h.name.toLowerCase() === 'referer');
      if (refHeader && refHeader.value) requestRefererCache.set(details.requestId, refHeader.value);
    }

    const url = details.url;
    if (!isCandidateUrl(url)) return;
    if (!isManifestUrl(url) && !isHardBlockableVideoUrl(url)) return;

    noteManifestDirectory(details, isManifestUrl(url));

    const type = manifestType(url);
    if (!shouldIntercept(type)) return;

    sendCapture(details.tabId, {
      __mbCapture: true,
      type,
      url: originalUrl(details),
      ref: bestReferer(details)
    });
  },
  { urls: ['<all_urls>'] },
  ['requestHeaders', 'extraHeaders']
);

// onHeadersReceived deliberately does NOT filter by isCandidateUrl() before
// the host-learning step: segment URLs are excluded from capture (they'd be
// noise) but they still need to be observed to learn their registrable domain.
chrome.webRequest.onHeadersReceived.addListener(
  details => {
    const url = details.url;
    if (!url || url.startsWith('chrome-extension://')) return;

    let contentType = '';
    if (details.responseHeaders) {
      for (const header of details.responseHeaders) {
        if (header.name.toLowerCase() === 'content-type') {
          contentType = header.value || '';
          break;
        }
      }
    }

    const isManifestCt = isManifestContentType(contentType);
    const isVideoCt = isVideoContentType(contentType);

    // Host learning — runs for segments AND manifests.
    if ((isManifestCt || isVideoCt) && isTabBlockingById(details.tabId, details)) {
      if (rememberMediaHost(details.tabId, url)) {
        dbg('remembered media host', registrableDomain(mediaHost(url)), 'for tab', details.tabId);
        scheduleDnrUpdate();
      }
    }

    // Capture pipeline — skips segments. Reports the originally requested URL.
    const reported = originalUrl(details);
    if (!isCandidateUrl(reported)) return;
    if (!isManifestCt && !isVideoCt) return;

    const type = manifestType(reported);
    if (!shouldIntercept(type)) return;

    sendCapture(details.tabId, {
      __mbCapture: true,
      type,
      url: reported,
      ref: bestReferer(details)
    });
  },
  { urls: ['<all_urls>'] },
  ['responseHeaders']
);

// ---------------------------------------------------------------------------
// Keyboard shortcuts. Bound by the user at chrome://extensions/shortcuts (manifest
// "commands"), so they work wherever focus is — including inside a player iframe.
//   _execute_action  opens the popup (the browser handles that one itself)
//   play-in-mpv      plays what's on this page, the same way the YouTube button does:
//                    YouTube -> the page; elsewhere -> the newest captured stream
//                    (with its referer/UA/rendition), else the page URL
// ---------------------------------------------------------------------------
chrome.commands.onCommand.addListener(async (command, tab) => {
  if (command !== 'play-in-mpv') return;
  try {
    if (!tab || tab.id == null) {
      [tab] = await chrome.tabs.query({ active: true, lastFocusedWindow: true });
    }
    if (!tab || tab.id == null) return;

    const res = await new Promise(resolve => {
      chrome.tabs.sendMessage(tab.id, { __mbPlayHere: true }, { frameId: 0 }, r => {
        resolve(chrome.runtime.lastError ? null : r);
      });
    });
    if (res) {
      if (!res.ok) console.error('[Media Blocker] play-in-mpv failed:', res.error);
      return;
    }

    // The page's script isn't there (a tab opened before the extension was reloaded,
    // or a page extensions can't script): fall back to playing the tab's URL.
    if (/^https?:\/\//i.test(tab.url || '')) {
      const r = await MPV.handle({ action: 'play', url: tab.url, title: tab.title });
      if (!r.ok) console.error('[Media Blocker] play-in-mpv failed:', r.error);
    }
  } catch (err) {
    console.error('[Media Blocker] play-in-mpv failed:', err.message);
  }
});

// ---------------------------------------------------------------------------
// Right-click menu. One pair of items for everything:
//   link / selected URL / <video> src  -> that URL
//   anywhere else on the page          -> the stream the panel captured on this
//                                         tab (with its referer, UA and chosen
//                                         rendition), else the page itself
// YouTube links and plain page URLs are resolved by mpv's yt-dlp hook. All of it
// goes through MPV.handle(), so the saved popup settings apply.
// ---------------------------------------------------------------------------
const MENU_PLAY = 'mb-open-in-mpv';
const MENU_DOWNLOAD = 'mb-download-ytdlp';

function createMpvMenus() {
  chrome.contextMenus.removeAll(() => {
    const contexts = ['selection', 'link', 'page', 'video', 'audio'];
    chrome.contextMenus.create({ id: MENU_PLAY, title: 'Open in mpv', contexts });
    chrome.contextMenus.create({ id: MENU_DOWNLOAD, title: 'Download with yt-dlp', contexts });
  });
}

chrome.runtime.onInstalled.addListener(createMpvMenus);
chrome.runtime.onStartup.addListener(createMpvMenus);

// Ask the tab's top frame for the stream the panel would play right now.
function bestStreamForTab(tabId) {
  return new Promise(resolve => {
    if (!Number.isInteger(tabId) || tabId < 0) return resolve(null);
    chrome.tabs.sendMessage(tabId, { __mbBestStream: true }, { frameId: 0 }, res => {
      if (chrome.runtime.lastError || !res || !res.ok) return resolve(null);
      resolve(res.stream || null);
    });
  });
}

async function resolveMenuTarget(info, tab) {
  const isHttp = u => /^https?:\/\//i.test(u || '');
  const pageUrl = info.pageUrl || (tab && tab.url) || '';
  const title = (tab && tab.title) || 'video';

  let url = info.linkUrl || '';
  if (!url && info.selectionText) {
    const m = info.selectionText.match(/https?:\/\/[^\s"'<>]+/i);
    if (m) url = m[0];
  }
  if (!url && isHttp(info.srcUrl)) url = info.srcUrl;
  if (url) return { url, ref: pageUrl, title };

  const stream = tab && (await bestStreamForTab(tab.id));
  if (stream) return stream;
  return isHttp(pageUrl) ? { url: pageUrl, title } : null;
}

chrome.contextMenus.onClicked.addListener(async (info, tab) => {
  if (info.menuItemId !== MENU_PLAY && info.menuItemId !== MENU_DOWNLOAD) return;
  const action = info.menuItemId === MENU_DOWNLOAD ? 'download' : 'play';
  try {
    const target = await resolveMenuTarget(info, tab);
    if (!target) return;
    const res = await MPV.handle(Object.assign({ action }, target));
    if (!res.ok) console.error('[Media Blocker] menu', action, 'failed:', res.error);
  } catch (err) {
    console.error('[Media Blocker] menu', action, 'failed:', err.message);
  }
});
