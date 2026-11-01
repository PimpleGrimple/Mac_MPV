/**
 * Play in MPV — Popup Script
 * 
 * Handles loading configuration settings from local storage, updating form values,
 * registering listeners to auto-save values, and showing saving toast feedback.
 */

const MIN_HOST_VERSION = '0.3.0';

function isVersionOutdated(hostVersion, minVersion) {
  // A custom host that doesn't report a version is assumed fine; only warn when
  // a version is reported and it's older than the minimum.
  if (!hostVersion) return false;
  const parts1 = hostVersion.split('.').map(Number);
  const parts2 = minVersion.split('.').map(Number);
  for (let i = 0; i < Math.max(parts1.length, parts2.length); i++) {
    const val1 = parts1[i] || 0;
    const val2 = parts2[i] || 0;
    if (val1 < val2) return true;
    if (val1 > val2) return false;
  }
  return false;
}

// Defaults, URL checks and the host message format are shared with the
// service worker and content scripts via mpv-bridge.js.
const DEFAULT_SETTINGS = MPV.DEFAULTS;

// UI Element selectors
const elements = {
  qualityCap: document.getElementById('qualityCap'),
  downloadQuality: document.getElementById('downloadQuality'),
  savePosition: document.getElementById('savePosition'),
  startFromCurrentTime: document.getElementById('startFromCurrentTime'),
  autoPause: document.getElementById('autoPause'),
  forceWindow: document.getElementById('forceWindow'),
  customFlags: document.getElementById('customFlags'),
  toast: document.getElementById('toast'),
  toastText: document.getElementById('toastText'),
  toastSuccessIcon: document.getElementById('toastSuccessIcon'),
  toastErrorIcon: document.getElementById('toastErrorIcon'),
  videoUrl: document.getElementById('videoUrl'),
  playCurrentTabBtn: document.getElementById('playCurrentTabBtn'),
  playBtnText: document.getElementById('playBtnText'),
  playWarning: document.getElementById('playWarning'),
  warningText: document.getElementById('warningText'),
  spinnerContainer: document.querySelector('.spinner-container'),
  ytdlWarningBanner: document.getElementById('ytdlWarningBanner'),
  warningBannerText: document.getElementById('warningBannerText')
};

let toastTimeout = null;
let saveDebounceTimer = null;
let currentTabUrl = '';

/**
 * Show confirmation or error toast feedback.
 * Debounces calls to prevent blinking on rapid updates.
 */
function showToast(message, isError = false, autoDismiss = true) {
  if (toastTimeout) {
    clearTimeout(toastTimeout);
    toastTimeout = null;
  }
  
  elements.toastText.textContent = message;
  
  if (isError) {
    elements.toastSuccessIcon.classList.add('hidden');
    elements.toastErrorIcon.classList.remove('hidden');
  } else {
    elements.toastSuccessIcon.classList.remove('hidden');
    elements.toastErrorIcon.classList.add('hidden');
  }
  
  elements.toast.classList.add('show');
  
  if (autoDismiss) {
    toastTimeout = setTimeout(() => {
      elements.toast.classList.remove('show');
    }, isError ? 3000 : 1500);
  }
}

/**
 * Verify URL playability and DRM status (shared rules from mpv-bridge.js).
 */
function checkUrl(urlStr) {
  const r = MPV.checkUrl(urlStr);
  if (r.ok) return { status: 'valid', hostname: r.hostname };
  return { status: r.reason === 'drm' ? 'drm' : 'invalid', message: r.message };
}

/**
 * Clean/format YouTube URLs to short link if applicable.
 */
function getYouTubeShortLink(urlStr) {
  try {
    const url = new URL(urlStr);
    if (url.hostname.includes('youtube.com')) {
      if (url.pathname === '/watch') {
        const videoId = url.searchParams.get('v');
        if (videoId) {
          return `https://youtu.be/${videoId}`;
        }
      } else if (url.pathname.startsWith('/shorts/')) {
        const videoId = url.pathname.split('/')[2];
        if (videoId) {
          return `https://youtu.be/${videoId}`;
        }
      }
    }
  } catch (e) {
    // ignore
  }
  return urlStr;
}

/**
 * Validate the current value of the videoUrl input and update play button & warning states.
 */
function validateInputUrl() {
  const urlStr = elements.videoUrl.value.trim();
  if (!urlStr) {
    elements.playBtnText.textContent = 'Play in MPV';
    elements.playCurrentTabBtn.disabled = true;
    elements.playWarning.classList.add('hidden');
    return;
  }

  const check = checkUrl(urlStr);
  
  if (check.status === 'invalid') {
    elements.playBtnText.textContent = 'Play in MPV';
    elements.playCurrentTabBtn.disabled = true;
    elements.playWarning.classList.remove('hidden');
    elements.warningText.textContent = check.message;
  } else if (check.status === 'drm') {
    elements.playBtnText.textContent = 'Play in MPV';
    elements.playCurrentTabBtn.disabled = true;
    elements.playWarning.classList.remove('hidden');
    elements.warningText.textContent = check.message;
  } else {
    elements.playBtnText.textContent = 'Play in MPV';
    elements.playCurrentTabBtn.disabled = false;
    elements.playWarning.classList.add('hidden');
  }
}

/**
 * Detect active tab and set up Play button state.
 */
async function initPlayCurrentTab() {
  try {
    const tabs = await chrome.tabs.query({ active: true, currentWindow: true });
    if (!tabs || tabs.length === 0) {
      elements.videoUrl.value = '';
      validateInputUrl();
      return;
    }
    
    const tab = tabs[0];
    currentTabUrl = tab.url || '';
    
    elements.videoUrl.value = getYouTubeShortLink(currentTabUrl);
    validateInputUrl();
  } catch (err) {
    console.error('[Play in MPV] Error loading current tab:', err);
    elements.videoUrl.value = '';
    validateInputUrl();
  }
}

/**
 * Helper to update the system warning banner content and visibility based on requirements check.
 */
function updateWarningBanner(ytdlMissing, mpvMissing, hostMissing = false, hostOutdated = false, hostVersion = '') {
  if (hostMissing) {
    elements.ytdlWarningBanner.classList.remove('hidden');
    elements.warningBannerText.innerHTML = '<strong>Native Host Not Connected:</strong> The local bridge is missing or failed to connect. <a href="https://franciscobecheli.github.io/play-in-mpv/" target="_blank" style="color: #60a5fa; text-decoration: underline; font-weight: 500;">Download & Install Setup Guide</a>';
  } else if (hostOutdated) {
    elements.ytdlWarningBanner.classList.remove('hidden');
    elements.warningBannerText.innerHTML = `<strong>Outdated Host Bridge:</strong> Your local bridge (v${hostVersion || 'unknown'}) is outdated. Please update and run the installer for version ${MIN_HOST_VERSION}. <a href="https://franciscobecheli.github.io/play-in-mpv/" target="_blank" style="color: #60a5fa; text-decoration: underline; font-weight: 500;">Setup Guide & Installer</a>`;
  } else if (ytdlMissing || mpvMissing) {
    elements.ytdlWarningBanner.classList.remove('hidden');
    let msg = '';
    if (ytdlMissing && mpvMissing) {
      msg = 'Both <code>mpv</code> and <code>yt-dlp</code> were not found on your system <strong>PATH</strong>.';
    } else if (ytdlMissing) {
      msg = '<code>yt-dlp</code> was not found on your system <strong>PATH</strong>.';
    } else {
      msg = '<code>mpv</code> was not found on your system <strong>PATH</strong> (or custom settings path).';
    }
    elements.warningBannerText.innerHTML = `<strong>System Warning:</strong> ${msg} This is required for the extension to work. <a href="https://franciscobecheli.github.io/play-in-mpv/" target="_blank" style="color: #60a5fa; text-decoration: underline; font-weight: 500;">Setup Guide & PATH Instructions</a>`;
  } else {
    elements.ytdlWarningBanner.classList.add('hidden');
  }
}

/**
 * Send a play / download / check request through the single launch pipeline.
 * Resolves with { ok, error, response }.
 */
function sendLaunch(req) {
  return new Promise((resolve, reject) => {
    chrome.runtime.sendMessage(Object.assign({ __mbLaunchMpv: true }, req), (res) => {
      if (chrome.runtime.lastError) reject(new Error(chrome.runtime.lastError.message));
      else resolve(res || { ok: false, error: 'No response' });
    });
  });
}

/**
 * Query the background script to check if yt-dlp or mpv are missing.
 */
async function checkSystemStatus() {
  try {
    const res = await sendLaunch({ action: 'check' });
    if (res && res.ok && res.response) {
      const hostVersion = res.response.version;
      const outdated = isVersionOutdated(hostVersion, MIN_HOST_VERSION);
      updateWarningBanner(
        !!res.response.ytdl_missing,
        !!res.response.mpv_missing,
        false,
        outdated,
        hostVersion
      );
    } else if (res && !res.ok) {
      updateWarningBanner(false, false, true);
    } else {
      updateWarningBanner(false, false, false);
    }
  } catch (err) {
    console.error('[Play in MPV] Failed to check system status:', err);
    updateWarningBanner(false, false, true);
  }
}

let pageInfo = null;
let activeTab = null;

/**
 * Ask the active tab's top frame what it has captured (plus mode, per-site settings and
 * the page video's current time). Resolves with null on pages the content script can't
 * reach (chrome://, the Web Store, tabs opened before the extension was reloaded).
 */
async function loadPage() {
  try {
    const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
    if (!tab || tab.id == null) return null;
    activeTab = tab;
    pageInfo = await new Promise(resolve => {
      chrome.tabs.sendMessage(tab.id, { __mbPageInfo: true }, { frameId: 0 }, res => {
        resolve(chrome.runtime.lastError ? null : res);
      });
    });
  } catch (e) {
    pageInfo = null;
  }
  if (pageInfo && !pageInfo.ok) pageInfo = null;
  return pageInfo;
}

// ---------------------------------------------------------------------------
// Tabs
// ---------------------------------------------------------------------------
function initTabs() {
  const tabs = document.querySelectorAll('.tab');
  const panels = document.querySelectorAll('.tab-panel');
  tabs.forEach(btn => btn.addEventListener('click', () => {
    tabs.forEach(t => {
      const on = t === btn;
      t.classList.toggle('active', on);
      t.setAttribute('aria-selected', String(on));
    });
    panels.forEach(p => { p.hidden = p.dataset.panel !== btn.dataset.tab; });
  }));
}

// ---------------------------------------------------------------------------
// Blocking tab (was the in-page panel's settings view)
//
// Global settings live in the service worker (GET/SET_GLOBAL_SETTINGS). The two
// per-site values (icon threshold, audio markers) live in the site's own
// localStorage, so they go through that page's content script.
// ---------------------------------------------------------------------------
const BLOCK_TYPE_IDS = ['image', 'video', 'audio', 'font', 'subtitle'];
const byId = id => document.getElementById(id);

function bgRequest(msg) {
  return new Promise((resolve, reject) => {
    chrome.runtime.sendMessage(msg, (res) => {
      if (chrome.runtime.lastError) reject(new Error(chrome.runtime.lastError.message));
      else resolve(res);
    });
  });
}

// Same cleanup the in-page Save applied: strip scheme/path/www, bare names get ".com".
function normalizeSite(site) {
  let s = String(site).toLowerCase().replace(/^https?:\/\//, '').split('/')[0].replace(/^www\./, '');
  if (s && !s.includes('.')) s += '.com';
  return s;
}

const linesOf = id => byId(id).value.split('\n').map(x => x.trim()).filter(Boolean);

async function loadBlocking() {
  try {
    const g = await bgRequest({ type: 'GET_GLOBAL_SETTINGS' });
    if (g && g.globalMode) {
      byId('globalMode').value = g.globalMode || 'block';
      BLOCK_TYPE_IDS.forEach(t => {
        byId('block' + t[0].toUpperCase() + t.slice(1)).checked = (g.types || []).includes(t);
      });
      byId('disabledSites').value = (g.disabledSites || []).join('\n');
      byId('blockKeywords').value = (g.blockKeywords || []).join('\n');
      byId('exceptions').value = (g.exceptions || []).join('\n');
      blockingLoaded = true;     // from here on, edits autosave
    } else {
      throw new Error('no settings returned');
    }
  } catch (err) {
    // Autosave stays off: saving now would overwrite the real settings with blanks.
    showToast('Could not load blocking settings', true);
  }

  const note = byId('siteOnlyNote');
  const siteInputs = [byId('iconThreshold'), byId('audioMarkers')];
  if (pageInfo && pageInfo.ok) {
    byId('iconThreshold').value = pageInfo.iconThreshold;
    byId('audioMarkers').value = pageInfo.audioMarkers || '';
    note.textContent = 'These apply to ' + pageInfo.host + ' only.';
    siteInputs.forEach(i => { i.disabled = false; });
  } else {
    note.textContent = 'Open a regular website tab to edit these site-specific values.';
    siteInputs.forEach(i => { i.disabled = true; });
  }
}

// Autosave, like the mpv settings: toggles and dropdowns save at once, text fields 350ms after
// the last keystroke. Saves are chained so they always land in the order they were made.
let blockingLoaded = false;
let blockingTimer = null;
let blockingChain = Promise.resolve();

function scheduleBlockingSave(immediate) {
  if (!blockingLoaded) return;
  clearTimeout(blockingTimer);
  blockingTimer = setTimeout(() => {
    blockingTimer = null;
    blockingChain = blockingChain.then(saveBlocking);
  }, immediate ? 0 : 350);
}

// The popup is destroyed the moment it loses focus: don't lose a pending edit.
function flushBlockingSave() {
  if (blockingTimer === null) return;
  clearTimeout(blockingTimer);
  blockingTimer = null;
  blockingChain = blockingChain.then(saveBlocking);
}

async function saveBlocking() {
  try {
    const globalMode = byId('globalMode').value;
    const disabledSites = linesOf('disabledSites').map(normalizeSite).filter(Boolean);
    const types = BLOCK_TYPE_IDS.filter(t => byId('block' + t[0].toUpperCase() + t.slice(1)).checked);

    const saveGlobal = bgRequest({
      type: 'SET_GLOBAL_SETTINGS',
      globalMode,
      disabledSites,
      types,
      exceptions: linesOf('exceptions'),
      blockKeywords: linesOf('blockKeywords')
    });
    // Sent alongside (not after) so a popup that closes mid-save still delivers both.
    const reachable = !!(pageInfo && pageInfo.ok && activeTab);
    const saveSite = !reachable ? Promise.resolve() : new Promise(resolve => {
      chrome.tabs.sendMessage(activeTab.id, {
        __mbSetSiteSettings: true,
        iconThreshold: byId('iconThreshold').value,
        audioMarkers: byId('audioMarkers').value,
        // keeps the page's synchronous cache in step with what was just saved
        globalMode,
        disabledSites
      }, { frameId: 0 }, () => { void chrome.runtime.lastError; resolve(); });
    });

    const [res] = await Promise.all([saveGlobal, saveSite]);
    if (!res || !res.success) throw new Error('Save was not confirmed');
    // New requests are blocked/allowed straight away; what the page already loaded isn't.
    showToast(reachable ? 'Saved. Reload the page to apply.' : 'Settings saved');
  } catch (err) {
    showToast(err.message || 'Save failed', true);
  }
}

function initBlockingAutosave() {
  ['globalMode', 'blockImage', 'blockVideo', 'blockAudio', 'blockFont', 'blockSubtitle'].forEach(id => {
    byId(id).addEventListener('change', () => scheduleBlockingSave(true));
  });
  ['iconThreshold', 'audioMarkers', 'disabledSites', 'blockKeywords', 'exceptions'].forEach(id => {
    byId(id).addEventListener('input', () => scheduleBlockingSave(false));
    byId(id).addEventListener('change', () => scheduleBlockingSave(true));   // on blur
  });
  window.addEventListener('pagehide', flushBlockingSave);
}

/**
 * Read settings from storage and populate the inputs.
 */
async function loadSettings() {
  try {
    const settings = await chrome.storage.local.get(DEFAULT_SETTINGS);
    
    elements.qualityCap.value = settings.qualityCap;
    elements.downloadQuality.value = settings.downloadQuality;
    elements.savePosition.checked = settings.savePosition;
    elements.startFromCurrentTime.checked = settings.startFromCurrentTime;
    elements.autoPause.checked = settings.autoPause;
    elements.forceWindow.checked = settings.forceWindow;
    elements.customFlags.value = settings.customFlags;
  } catch (err) {
    console.error('[Play in MPV] Failed to load settings:', err);
  }
}

/**
 * Gather form values and save them to storage.
 */
async function saveSettings() {
  const updatedSettings = {
    qualityCap: elements.qualityCap.value,
    downloadQuality: elements.downloadQuality.value,
    savePosition: elements.savePosition.checked,
    startFromCurrentTime: elements.startFromCurrentTime.checked,
    autoPause: elements.autoPause.checked,
    forceWindow: elements.forceWindow.checked,
    customFlags: elements.customFlags.value
  };

  try {
    await chrome.storage.local.set(updatedSettings);
    showToast('Settings saved');
  } catch (err) {
    console.error('[Play in MPV] Failed to save settings:', err);
  }
}

/**
 * Setup event listeners for inputs
 */
function setupListeners() {
  // Dismiss toast on click
  elements.toast.addEventListener('click', () => {
    elements.toast.classList.remove('show');
    if (toastTimeout) {
      clearTimeout(toastTimeout);
      toastTimeout = null;
    }
  });

  // No close option for ytdlWarningBanner as per requirements

  // Save immediately on changes to options/dropdowns/switches
  const immediateSaveList = [
    elements.qualityCap,
    elements.downloadQuality,
    elements.savePosition,
    elements.startFromCurrentTime,
    elements.autoPause,
    elements.forceWindow
  ];

  immediateSaveList.forEach(input => {
    input.addEventListener('change', () => {
      saveSettings();
    });
  });

  // Debounce saves for keyboard input fields to prevent excessive storage writes
  const debouncedSaveList = [
    elements.customFlags
  ];

  debouncedSaveList.forEach(input => {
    input.addEventListener('input', () => {
      if (saveDebounceTimer) {
        clearTimeout(saveDebounceTimer);
      }
      saveDebounceTimer = setTimeout(() => {
        saveSettings();
      }, 350);
    });
  });

  // Listener for video URL changes to run validation
  elements.videoUrl.addEventListener('input', () => {
    validateInputUrl();
  });

  // Listener for the "Play Current Tab" button
  elements.playCurrentTabBtn.addEventListener('click', async () => {
    const targetUrl = elements.videoUrl.value.trim();
    if (!targetUrl) return;

    elements.playCurrentTabBtn.disabled = true;
    elements.playCurrentTabBtn.classList.add('loading');
    elements.spinnerContainer.classList.remove('hidden');

    try {
      // Playing the current tab's own URL: start where the page's video is now.
      let startTime = null;
      const isCurrentTab = currentTabUrl && (
        getYouTubeShortLink(currentTabUrl) === getYouTubeShortLink(targetUrl) ||
        currentTabUrl === targetUrl
      );
      if (isCurrentTab && pageInfo && typeof pageInfo.currentTime === 'number') {
        startTime = pageInfo.currentTime;
      }

      const res = await sendLaunch({ action: 'play', url: targetUrl, startTime });
      if (!res.ok) throw new Error(res.error || 'Failed to open video in MPV');
      showToast('Launching MPV...');
    } catch (err) {
      console.error('[Play in MPV] Play URL error:', err);
      showToast(err.message || 'Failed to launch MPV', true);
    } finally {
      elements.playCurrentTabBtn.classList.remove('loading');
      elements.spinnerContainer.classList.add('hidden');
      validateInputUrl();
    }
  });
}

// Initialize
document.addEventListener('DOMContentLoaded', () => {
  const badge = document.getElementById('versionBadge');
  if (badge) badge.textContent = 'v' + chrome.runtime.getManifest().version;
  loadSettings();
  setupListeners();
  // pageInfo is needed for the "start at current time" lookup, so wait for it
  // before the play button can be used, but don't block the rest of the popup.
  initTabs();
  initStreams();                       // streams.js: the Streams tab
  initBlockingAutosave();
  loadPage().then(() => {
    renderStreams();
    loadBlocking();
  });
  initPlayCurrentTab();
  checkSystemStatus();
});
