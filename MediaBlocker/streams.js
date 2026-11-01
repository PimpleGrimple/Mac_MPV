/**
 * Streams tab — the live list of what the current page requested, with every control the
 * old in-page panel had (rendition picker, copy, download, play in mpv, filters, bulk
 * actions, image hover-preview, expiry dots).
 *
 * The page's content script is headless: it collects and answers. This file renders its
 * answer (__mbPageInfo) and sends commands back (__mbSelectVariant, __mbDownloadFile,
 * __mbClear, __mbSetMode); play/download go through the shared launch pipeline
 * (sendLaunch in popup.js). Uses pageInfo / activeTab / loadPage / showToast / sendLaunch /
 * bgRequest / byId from popup.js.
 */

const TYPE_META = {
  video:    { color: '#5aa9e6', tint: 'rgba(90,169,230,.13)',  icon: '<rect x="2" y="5" width="14" height="14" rx="2"/><polygon points="22 8 16 12 22 16 22 8"/>' },
  image:    { color: '#5ecf8f', tint: 'rgba(94,207,143,.13)',  icon: '<rect x="3" y="3" width="18" height="18" rx="2"/><circle cx="8.5" cy="8.5" r="1.5"/><polyline points="21 15 16 10 5 21"/>' },
  audio:    { color: '#f0a85c', tint: 'rgba(240,168,92,.13)',  icon: '<path d="M9 18V5l12-2v13"/><circle cx="6" cy="18" r="3"/><circle cx="18" cy="16" r="3"/>' },
  subtitle: { color: '#4dd0c8', tint: 'rgba(77,208,200,.13)',  icon: '<rect x="2" y="5" width="20" height="14" rx="2"/><line x1="6" y1="11" x2="10" y2="11"/><line x1="13" y1="11" x2="18" y2="11"/><line x1="6" y1="15" x2="14" y2="15"/>' },
  font:     { color: '#c793f0', tint: 'rgba(199,147,240,.13)', icon: '<polyline points="4 7 4 4 20 4 20 7"/><line x1="9" y1="20" x2="15" y2="20"/><line x1="12" y1="4" x2="12" y2="20"/>' },
  svg:      { color: '#eb5e28', tint: 'rgba(235,94,40,.13)',   icon: '<rect x="3" y="3" width="18" height="18" rx="2"/><circle cx="8.5" cy="8.5" r="1.5"/><polyline points="21 15 16 10 5 21"/>' }
};
const ICON_DL = '<path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"/><polyline points="7 10 12 15 17 10"/><line x1="12" y1="15" x2="12" y2="3"/>';
const ICON_PLAY = '<polygon points="5 3 19 12 5 21 5 3" fill="currentColor"/>';
const ICON_OK = '<polyline points="20 6 9 17 4 12" stroke="#5ecf8f" stroke-width="3"/>';
const ICON_ERR = '<line x1="18" y1="6" x2="6" y2="18" stroke="#e6605a" stroke-width="3"/><line x1="6" y1="6" x2="18" y2="18" stroke="#e6605a" stroke-width="3"/>';

const svgIcon = (inner, size = 12) =>
  `<svg width="${size}" height="${size}" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">${inner}</svg>`;

let activeFilter = 'all';
const rowEls = new Map();      // entry id -> row element
let refreshTimer = null;
let previewToken = 0;

function el(tag, className) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  return node;
}

// Command to the page's top frame; resolves null when it can't be reached.
function toPage(msg) {
  return new Promise(resolve => {
    if (!activeTab || activeTab.id == null) return resolve(null);
    chrome.tabs.sendMessage(activeTab.id, msg, { frameId: 0 }, res => {
      resolve(chrome.runtime.lastError ? null : res);
    });
  });
}

async function copyToClipboard(text) {
  try {
    await navigator.clipboard.writeText(text);
    return true;
  } catch (e) {
    return false;
  }
}

const isAVType = t => t === 'video' || t === 'audio';
const entriesNow = () => (pageInfo && pageInfo.entries) || [];

// ---------------------------------------------------------------------------
// Expiry
// ---------------------------------------------------------------------------
function applyExpiry(row, e) {
  const dot = row._dot;
  if (typeof e.expiry !== 'number') {
    dot.classList.add('hidden');
    row.classList.toggle('expired', !!e.expired);
    return;
  }
  const remaining = e.expiry - Date.now() / 1000;
  dot.classList.remove('hidden', 'soon', 'expired');
  if (remaining <= 0) {
    dot.classList.add('expired');
    dot.title = 'Link expired';
  } else if (remaining < 60) {
    dot.classList.add('soon');
    dot.title = 'Expires in ' + Math.ceil(remaining) + 's';
  } else {
    dot.title = 'Expires in ~' + Math.round(remaining / 60) + 'm';
  }
  row.classList.toggle('expired', remaining <= 0);
}

// ---------------------------------------------------------------------------
// Row actions
// ---------------------------------------------------------------------------

// Run an async action on a row button, flashing a check or cross when it settles.
async function flashButton(btn, idleIcon, action) {
  btn.disabled = true;
  let ok = false;
  try { ok = await action(); } catch (e) { ok = false; }
  btn.innerHTML = svgIcon(ok ? ICON_OK : ICON_ERR);
  setTimeout(() => { btn.innerHTML = svgIcon(idleIcon); btn.disabled = false; }, 1200);
  return ok;
}

// Images and fonts are saved by the page itself (its cookies/referer apply); anything
// else goes to yt-dlp through the native host.
function downloadEntry(e) {
  if (e.type === 'image' || e.type === 'font') {
    return toPage({ __mbDownloadFile: true, id: e.id }).then(r => !!(r && r.ok));
  }
  return sendLaunch(Object.assign({ action: 'download' }, e.req)).then(r => !!r.ok);
}

function playEntry(e) {
  return sendLaunch(Object.assign({ action: 'play' }, e.req)).then(r => !!r.ok);
}

async function copyEntry(row) {
  const ok = await copyToClipboard(row._entry.copyText);
  const name = row._name;
  const original = name.textContent;
  name.textContent = ok ? 'Copied!' : 'Copy failed';
  setTimeout(() => { name.textContent = row._entry.name || original; }, 900);
}

// ---------------------------------------------------------------------------
// Hover preview (images): loaded lazily, only for the row being hovered.
// ---------------------------------------------------------------------------
function previewEl() {
  let box = byId('preview');
  if (!box) {
    box = el('div', 'preview');
    box.id = 'preview';
    box.appendChild(document.createElement('img'));
    document.body.appendChild(box);
  }
  return box;
}

function showPreview(icon, url) {
  const token = ++previewToken;
  const box = previewEl();
  const img = box.querySelector('img');
  box.style.display = 'none';
  img.referrerPolicy = 'no-referrer';
  img.onload = () => {
    if (token !== previewToken) return;           // mouse already moved on
    box.style.display = 'block';
    const r = icon.getBoundingClientRect();
    const p = box.getBoundingClientRect();
    let top = r.top + r.height / 2 - p.height / 2;
    top = Math.max(8, Math.min(top, window.innerHeight - p.height - 8));
    const left = Math.max(8, Math.min(r.right + 8, window.innerWidth - p.width - 8));
    box.style.top = top + 'px';
    box.style.left = left + 'px';
  };
  img.onerror = () => { img.onload = null; };
  // the marker is exempt from the extension's own blocking rules
  img.src = url + (url.includes('?') ? '&' : '?') + '__mb_preview=1';
}

function hidePreview() {
  previewToken++;
  const box = byId('preview');
  if (box) box.style.display = 'none';
}

// ---------------------------------------------------------------------------
// Rows
// ---------------------------------------------------------------------------
function metaFor(e) {
  return TYPE_META[e.svg ? 'svg' : e.type] || TYPE_META.image;
}

function buildRow(e) {
  const meta = metaFor(e);
  const row = el('div', 'srow');
  row.dataset.id = String(e.id);
  row.style.setProperty('--c', meta.color);
  row.style.setProperty('--tint', meta.tint);

  const icon = el('a', 'srow-icon');
  icon.target = '_blank';
  icon.rel = 'noopener noreferrer';
  icon.title = 'Open in new tab';
  icon.innerHTML = svgIcon(meta.icon);
  row.appendChild(icon);
  row._icon = icon;

  const name = el('span', 'srow-name');
  name.title = 'Click to copy';
  name.addEventListener('click', () => copyEntry(row));
  row.appendChild(name);
  row._name = name;

  const dot = el('span', 'srow-dot hidden');
  row.appendChild(dot);
  row._dot = dot;

  const btns = el('div', 'srow-btns');
  const dl = el('button', 'srow-btn');
  dl.type = 'button';
  dl.innerHTML = svgIcon(ICON_DL);
  dl.title = (e.type === 'image' || e.type === 'font') ? 'Download file directly' : 'Download with yt-dlp';
  dl.addEventListener('click', () => flashButton(dl, ICON_DL, () => downloadEntry(row._entry)));
  btns.appendChild(dl);

  if (e.type !== 'font' && e.type !== 'subtitle' && !e.svg) {
    const play = el('button', 'srow-btn play');
    play.type = 'button';
    play.innerHTML = svgIcon(ICON_PLAY);
    play.title = 'Open directly in mpv';
    play.addEventListener('click', () => flashButton(play, ICON_PLAY, () => playEntry(row._entry)));
    btns.appendChild(play);
  }
  row.appendChild(btns);

  if (e.type === 'image') {
    icon.addEventListener('mouseenter', () => showPreview(icon, row._entry.url));
    icon.addEventListener('mouseleave', hidePreview);
  }

  return row;
}

// Quality label (fixed, from the URL) or a rendition picker (HLS master playlists).
function syncQuality(row, e) {
  let q = row._q;
  if (e.quality) {
    if (!q || q.tagName !== 'SPAN') {
      if (q) q.remove();
      q = el('span', 'srow-q');
      row.insertBefore(q, row._name);
      row._q = q;
    }
    q.textContent = e.quality;
    return;
  }
  if (e.variants && e.variants.length) {
    if (!q || q.tagName !== 'SELECT') {
      if (q) q.remove();
      q = el('select', 'srow-q');
      q.title = 'Quality';
      q.addEventListener('change', async () => {
        const index = q.value === 'auto' ? -1 : parseInt(q.value, 10);
        const res = await toPage({ __mbSelectVariant: true, id: row._entry.id, index });
        if (res && res.ok) {
          const list = entriesNow();
          const at = list.findIndex(x => x.id === res.entry.id);
          if (at >= 0) list[at] = res.entry;
          updateRow(row, res.entry);
        }
      });
      row.insertBefore(q, row._name);
      row._q = q;
    }
    if (q.options.length !== e.variants.length + 1) {
      q.textContent = '';
      const auto = el('option');
      auto.value = 'auto';
      auto.textContent = 'Auto (Best)';
      q.appendChild(auto);
      e.variants.forEach((v, i) => {
        const o = el('option');
        o.value = String(i);
        o.textContent = v.label;
        o.title = v.detail;
        q.appendChild(o);
      });
    }
    q.value = e.selectedIndex < 0 ? 'auto' : String(e.selectedIndex);
    return;
  }
  if (q) { q.remove(); row._q = null; }
}

function updateRow(row, e) {
  row._entry = e;
  row.dataset.type = e.type;
  row._icon.href = e.selectedUrl;
  row._name.textContent = e.name;
  syncQuality(row, e);
  applyExpiry(row, e);
}

// ---------------------------------------------------------------------------
// Filters, counts, empty/notice states
// ---------------------------------------------------------------------------
function applyFilter() {
  let shown = 0;
  rowEls.forEach(row => {
    const show = activeFilter === 'all' || row.dataset.type === activeFilter;
    row.style.display = show ? '' : 'none';
    if (show) shown++;
  });
  return shown;
}

// "8 captured" / "3 of 8 shown", and how many "download all" will fetch.
function updateBulk(entries, shown) {
  const total = entries.length;
  byId('bulkSummary').textContent = total === 0 ? '' : (shown === total ? total + ' captured' : shown + ' of ' + total + ' shown');
  byId('bulkDownloadN').textContent = shown > 0 ? String(shown) : '';
  byId('bulkDownload').title = shown > 0 ? 'Download all ' + shown + ' shown' : 'Download all shown';
}

function updateCounts(entries) {
  const counts = { all: entries.length, video: 0, image: 0, audio: 0, subtitle: 0, font: 0 };
  entries.forEach(e => { if (counts[e.type] !== undefined) counts[e.type]++; });
  document.querySelectorAll('#filterChips .chip').forEach(chip => {
    const n = counts[chip.dataset.filter] || 0;
    chip.querySelector('.chip-n').textContent = String(n);
    chip.classList.toggle('active', chip.dataset.filter === activeFilter);
    chip.classList.toggle('zero', n === 0);
  });
  const av = entries.filter(e => isAVType(e.type)).length;
  byId('streamsTabCount').textContent = av ? String(av) : '';
}

// Header control: both choices are always visible, the active one is lit in its own colour
// (red = blocking, amber = capture, as on the original floating button), so what a click
// will do is obvious. On a site where Media Blocker is off it shows a single "Off" button
// that turns it back on.
function renderModeSwitch() {
  const sw = byId('modeSwitch');
  if (!pageInfo) { sw.classList.add('hidden'); return; }
  sw.classList.remove('hidden');
  const off = pageInfo.mode === 'off';
  sw.querySelectorAll('.mode-opt').forEach(btn => {
    const isOffBtn = btn.dataset.mode === 'off';
    btn.hidden = off ? !isOffBtn : isOffBtn;
    const active = off ? isOffBtn : btn.dataset.mode === pageInfo.mode;
    btn.classList.toggle('active', active);
    btn.setAttribute('aria-pressed', String(active));
  });
}

function emptyText(entries) {
  if (entries.length) return 'Nothing of this type.';
  return pageInfo && pageInfo.mode === 'capture' ? 'Nothing captured yet on this page.' : 'Nothing blocked yet on this page.';
}

// Returns the message to show instead of the list (or null when the list should show).
function noticeFor(info) {
  if (!info) {
    return { text: 'Streams are listed for regular web pages. Open one, or refresh this tab if it was open before the extension was reloaded. You can still paste a link above and play it.' };
  }
  if (info.mode === 'off') {
    return { text: 'Media Blocker is off for ' + info.host + '. The mpv button and shortcut still work here.', button: 'Turn on for this site' };
  }
  return null;
}

function renderStreams() {
  renderModeSwitch();
  const info = pageInfo;
  const entries = entriesNow();
  const notice = noticeFor(info);

  const noticeBox = byId('streamNotice');
  noticeBox.classList.toggle('hidden', !notice);
  byId('streamsSection').classList.toggle('hidden', !!notice);
  if (notice) {
    byId('streamNoticeText').textContent = notice.text;
    const nb = byId('streamNoticeBtn');
    nb.classList.toggle('hidden', !notice.button);
    nb.textContent = notice.button || '';
    rowEls.forEach(r => r.remove());
    rowEls.clear();
    updateCounts([]);
    updateBulk([], 0);
    return;
  }

  const list = byId('streamList');
  const seen = new Set();
  for (const e of entries) {
    seen.add(e.id);
    let row = rowEls.get(e.id);
    if (!row) {
      row = buildRow(e);
      rowEls.set(e.id, row);
      list.appendChild(row);
    }
    updateRow(row, e);
  }
  for (const [id, row] of rowEls) {
    if (!seen.has(id)) { row.remove(); rowEls.delete(id); }
  }

  updateCounts(entries);
  const shown = applyFilter();
  updateBulk(entries, shown);

  const empty = byId('streamEmpty');
  empty.classList.toggle('hidden', shown > 0);
  if (shown === 0) byId('streamEmptyText').textContent = emptyText(entries);
  byId('bulkDownload').disabled = shown === 0;
  byId('bulkCopy').disabled = entries.length === 0;
  byId('bulkClear').disabled = entries.length === 0;
}

// ---------------------------------------------------------------------------
// Bulk actions, site switches, live refresh
// ---------------------------------------------------------------------------
// Hands everything currently shown to the service worker, which carries on even after the
// popup closes (a popup's own timers die with it).
async function downloadAllShown() {
  const rows = Array.from(rowEls.values()).filter(r => r.style.display !== 'none');
  if (!rows.length || !activeTab) return;
  const items = rows.map(row => {
    const e = row._entry;
    return (e.type === 'image' || e.type === 'font') ? { file: true, id: e.id } : { req: e.req };
  });
  try {
    const res = await bgRequest({ __mbBulkDownload: true, tabId: activeTab.id, items });
    if (!res || !res.ok) throw new Error((res && res.error) || 'Could not start');
    showToast('Downloading ' + res.queued + (res.queued === 1 ? ' item' : ' items') + ' in the background');
  } catch (err) {
    showToast(err.message || 'Could not start downloads', true);
  }
}

async function copyAllUrls() {
  const entries = entriesNow();
  const ok = await copyToClipboard(entries.map(e => `[${e.type}] ${e.url}`).join('\n'));
  showToast(ok ? 'Copied ' + entries.length + (entries.length === 1 ? ' URL' : ' URLs') : 'Copy failed', !ok);
}

async function clearAll() {
  await toPage({ __mbClear: true });
  await loadPage();
  renderStreams();
}

async function setMode(mode) {
  if (!pageInfo) return;
  if (pageInfo.mode === 'off') { turnOnForSite(); return; }
  if (mode === pageInfo.mode) return;
  await toPage({ __mbSetMode: true, mode });   // the page reloads itself
  window.close();
}

// "Turn on for this site": remove the host from Disabled Sites; if the site is only off
// because the default mode is Off, give it its own Block override instead.
async function turnOnForSite() {
  const btn = byId('streamNoticeBtn');
  btn.disabled = true;
  try {
    const host = pageInfo.host;
    const g = await bgRequest({ type: 'GET_GLOBAL_SETTINGS' });
    const disabled = g.disabledSites || [];
    const matches = d => host === d || host.endsWith('.' + d);
    if (disabled.some(matches)) {
      const remaining = disabled.filter(d => !matches(d));
      const res = await bgRequest({
        type: 'SET_GLOBAL_SETTINGS', globalMode: g.globalMode, disabledSites: remaining,
        types: g.types, exceptions: g.exceptions, blockKeywords: g.blockKeywords
      });
      if (!res || !res.success) throw new Error('Save was not confirmed');
      await toPage({ __mbSetSiteSettings: true, disabledSites: remaining, globalMode: g.globalMode });
      chrome.tabs.reload(activeTab.id);
    } else {
      await toPage({ __mbSetMode: true, mode: 'block' });   // reloads the page itself
    }
    window.close();
  } catch (err) {
    showToast(err.message || 'Could not turn on', true);
    btn.disabled = false;
  }
}

function scheduleRefresh() {
  clearTimeout(refreshTimer);
  refreshTimer = setTimeout(async () => {
    await loadPage();
    renderStreams();
  }, 150);
}

function initStreams() {
  // Each chip carries its type's icon and colour, the same as that type's rows.
  document.querySelectorAll('#filterChips .chip').forEach(chip => {
    const meta = TYPE_META[chip.dataset.filter];
    if (meta) {
      chip.style.setProperty('--c', meta.color);
      chip.insertAdjacentHTML('afterbegin', svgIcon(meta.icon, 13));
    }
    chip.addEventListener('click', () => {
      activeFilter = chip.dataset.filter;
      updateCounts(entriesNow());
      const shown = applyFilter();
      updateBulk(entriesNow(), shown);
      const empty = byId('streamEmpty');
      empty.classList.toggle('hidden', shown > 0);
      if (shown === 0) byId('streamEmptyText').textContent = emptyText(entriesNow());
      byId('bulkDownload').disabled = shown === 0;
    });
  });
  byId('bulkDownload').addEventListener('click', downloadAllShown);
  byId('bulkCopy').addEventListener('click', copyAllUrls);
  byId('bulkClear').addEventListener('click', clearAll);
  byId('modeSwitch').querySelectorAll('.mode-opt').forEach(btn => {
    btn.addEventListener('click', () => setMode(btn.dataset.mode));
  });
  byId('streamNoticeBtn').addEventListener('click', turnOnForSite);

  // The page announces new captures; re-read the list while the popup is open.
  chrome.runtime.onMessage.addListener((msg, sender) => {
    if (msg && msg.__mbChanged && sender && sender.tab && activeTab && sender.tab.id === activeTab.id) {
      scheduleRefresh();
    }
  });

  // Expiry dots tick without a round trip.
  setInterval(() => rowEls.forEach(row => applyExpiry(row, row._entry)), 5000);
}
