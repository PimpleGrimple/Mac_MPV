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
  '.mpd', '.m3u8', '.f4m', '/manifest',
];
let EXCEPTIONS = [];

const MB_DEBUG = true;
function dbg(...args) { if (MB_DEBUG) try { console.log('[MB]', ...args); } catch (e) {} }

const tabUrlCache = new Map();

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

chrome.webRequest.onCompleted.addListener(
  d => requestRefererCache.delete(d.requestId),
  { urls: ["<all_urls>"] }
);
chrome.webRequest.onErrorOccurred.addListener(
  d => requestRefererCache.delete(d.requestId),
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
        await updateStaticRules();
        await recomputeSessionRules();
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
      for (const kw of BLOCK_KEYWORDS) {
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
  scheduleDnrUpdate();
});

chrome.runtime.onMessage.addListener((msg, sender, sendResponse) => {
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

    chrome.runtime.sendNativeMessage(MPV_NATIVE_HOST, nativeFetch, nativeResponse => {
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

  if (msg.__mbLaunchMpv) {
    const nativeMsg = buildNativeMpvMessage(msg);
    chrome.runtime.sendNativeMessage(MPV_NATIVE_HOST, nativeMsg, response => {
      if (chrome.runtime.lastError) {
        sendResponse({ ok: false, error: chrome.runtime.lastError.message });
        return;
      }
      sendResponse(response);
    });
    return true;
  }
});

const MPV_NATIVE_HOST = 'com.playinmpv.host';

function buildNativeMpvMessage(msg) {
  if (msg.action === 'download') {
    return {
      type: 'DOWNLOAD',
      url: msg.url,
      ref: msg.ref || '',
      ua: msg.ua || '',
      title: msg.title || 'video',
      format: msg.format || ''
    };
  }

  return {
    type: 'PLAY',
    url: msg.url,
    ref: msg.ref || '',
    ua: msg.ua || '',
    title: msg.title || 'video',
    media_type: msg.type || '',
    format: msg.format || ''
  };
}

function isManifestUrl(url) {
  if (!url) return false;
  const u = url.toLowerCase();
  return u.includes('.m3u8') || u.includes('.mpd') || u.includes('.f4m') || u.includes('ism/manifest');
}

function isHardBlockableVideoUrl(url) {
  if (!url) return false;
  const u = url.toLowerCase();
  return u.includes('.mp4') || u.includes('.m4v') || u.includes('.webm') || u.includes('.ogg') || u.includes('.ogv');
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
          url,
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
      url,
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

    // Capture pipeline — skips segments.
    if (!isCandidateUrl(url)) return;
    if (!isManifestCt && !isVideoCt) return;

    const type = manifestType(url);
    if (!shouldIntercept(type)) return;

    sendCapture(details.tabId, {
      __mbCapture: true,
      type,
      url,
      ref: bestReferer(details)
    });
  },
  { urls: ['<all_urls>'] },
  ['responseHeaders']
);

// ---------------------------------------------------------------------------
// Right-click menu: "Open in mpv" (selected URL, link, or the page itself).
// Plain URL goes to the native host; mpv's yt-dlp hook resolves the site.
// ---------------------------------------------------------------------------
const MPV_MENU_ID = 'mb-open-in-mpv';

function createMpvMenu() {
  chrome.contextMenus.removeAll(() => {
    chrome.contextMenus.create({
      id: MPV_MENU_ID,
      title: 'Open in mpv',
      contexts: ['selection', 'link', 'page', 'video', 'audio']
    });
  });
}

chrome.runtime.onInstalled.addListener(createMpvMenu);
chrome.runtime.onStartup.addListener(createMpvMenu);

chrome.contextMenus.onClicked.addListener((info, tab) => {
  if (info.menuItemId !== MPV_MENU_ID) return;

  let url = info.linkUrl || '';
  if (!url && info.selectionText) {
    const m = info.selectionText.match(/https?:\/\/[^\s"'<>]+/i);
    if (m) url = m[0];
  }
  if (!url && /^https?:\/\//i.test(info.srcUrl || '')) url = info.srcUrl;
  if (!url) url = info.pageUrl || (tab && tab.url) || '';
  if (!/^https?:\/\//i.test(url)) return;

  const msg = buildNativeMpvMessage({
    url,
    ref: url === info.pageUrl ? '' : (info.pageUrl || ''),
    title: (tab && tab.title) || 'video'
  });
  chrome.runtime.sendNativeMessage(MPV_NATIVE_HOST, msg, response => {
    if (chrome.runtime.lastError) {
      console.error('[Media Blocker] Open in mpv failed:', chrome.runtime.lastError.message);
    }
  });
});
