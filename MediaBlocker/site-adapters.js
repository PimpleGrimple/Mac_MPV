/**
 * Site adapters — per-site knowledge of "this captured file also exists in other qualities".
 *
 * Content script only (loaded before content.js). For a captured stream URL, an adapter
 * returns quality variants of the SAME file as [{ height, url, guess? }]. content.js attaches
 * them to the launch request as `req.alts`; the mpv bridge picks one per action using the
 * saved stream / download quality (MPV.pickAlt). Nothing here talks to mpv.
 *
 * Add a site:
 *   - KVS-style CDN (/get_file/<n>/<hash>/<dir>/<id>/<id>[_720].mp4):
 *       register(kvsAdapter({ name, host: /(^|\.)site\.com$/i, ladder: [360, 480, 720, 1080] }));
 *     `ladder` = the heights the site offers. Heights the page doesn't expose as a link are
 *     built by swapping the _<height> suffix of a link the page DID expose (marked guess:true).
 *     Omit `ladder` to offer only the links the page really contains.
 *   - anything else: register({ name, host: /regex on hostname/, collect(url) { ... } })
 *     where collect returns [{ height, url }, ...] or null if the URL isn't its.
 */
(function (root) {
  'use strict';

  const adapters = [];
  const register = a => { adapters.push(a); return a; };

  // ---- KVS-style adapter factory -------------------------------------------------------
  // .../get_file/47/<md5>/4172000/4172211/4172211_360.mp4/?token...
  //                                      id        id[_height]
  // A file with no _<height> suffix is the site's "main" link (height: null).
  const KVS_FILE_RE = /\/get_file\/\d+\/[0-9a-f]+\/\d+\/(\d+)\/\1(?:_(\d{3,4})p?)?\.(?:mp4|m4v|webm)\/?$/i;
  const KVS_NAME_RE = /\/(\d+)(?:_\d{3,4}p?)?(\.(?:mp4|m4v|webm))(\/?)$/i;
  const KVS_ANY_RE  = /https?:\/\/[^\s"'<>\\]+\/get_file\/[^\s"'<>\\]+/g;
  const SCAN_TTL_MS = 3000;

  function kvsParse(url) {
    let path;
    try { path = new URL(url).pathname; } catch (e) { return null; }   // query/token excluded
    const m = KVS_FILE_RE.exec(path);
    return m ? { id: m[1], height: m[2] ? parseInt(m[2], 10) : null } : null;
  }

  // Same URL with the file name's quality suffix replaced (query string untouched).
  function kvsRewrite(url, height) {
    try {
      const u = new URL(url);
      if (!KVS_NAME_RE.test(u.pathname)) return null;
      u.pathname = u.pathname.replace(KVS_NAME_RE, (all, id, ext, slash) => '/' + id + '_' + height + ext + slash);
      return u.href;
    } catch (e) { return null; }
  }

  // Every /get_file/ URL the live page holds: links, media elements, inline scripts.
  function scanPageForKvs() {
    const found = [];
    const add = raw => {
      if (!raw) return;
      try { found.push(new URL(raw, location.href).href); } catch (e) { /* ignore */ }
    };
    document.querySelectorAll('[href*="/get_file/"],[src*="/get_file/"],[data-src*="/get_file/"]').forEach(el => {
      add(el.getAttribute('href')); add(el.getAttribute('src')); add(el.getAttribute('data-src'));
    });
    document.querySelectorAll('script:not([src])').forEach(sc => {
      const text = (sc.textContent || '').replace(/\\\//g, '/').replace(/\\u0026/g, '&');
      if (text.indexOf('/get_file/') === -1) return;
      (text.match(KVS_ANY_RE) || []).forEach(add);
    });
    return found;
  }

  // Pure core (also what the tests exercise). Real links of this file id (the captured one
  // plus whatever the page holds) -> [{height, url, guess?}], tallest first.
  //   - A real link with an explicit height is used as is.
  //   - With a ladder, every missing height is built from a real suffixed link (the captured
  //     one first, since the browser demonstrably used it), else from the main link.
  //   - The unsuffixed main link is not offered as a quality of its own when a ladder exists.
  function kvsVariants(capturedUrl, pageUrls, ladder) {
    const me = kvsParse(capturedUrl);
    if (!me) return null;
    const real = new Map();                                // height -> url (suffixed links only)
    let main = null;
    for (const u of [capturedUrl].concat(pageUrls)) {
      const p = kvsParse(u);
      if (!p || p.id !== me.id) continue;
      if (p.height == null) { if (!main) main = u; }
      else if (!real.has(p.height)) real.set(p.height, u);
    }

    const out = new Map(real);
    if (!ladder || !ladder.length) {
      if (main && !out.size) return null;                  // nothing to choose between
    } else {
      const base = real.values().next().value || main;     // captured suffixed link comes first
      if (base) {
        for (const h of ladder) {
          if (out.has(h)) continue;
          const u = kvsRewrite(base, h);
          if (u) out.set(h, u);
        }
      }
    }
    return Array.from(out, ([height, url]) => {
      const guess = !real.has(height);
      return guess ? { height, url, guess } : { height, url };
    }).sort((a, b) => b.height - a.height);
  }

  function kvsAdapter(opts) {
    const cache = new Map();                               // file id -> { t, urls }
    return {
      name: opts.name,
      host: opts.host,
      collect(url) {
        const me = kvsParse(url);
        if (!me) return null;
        let hit = cache.get(me.id);
        if (!hit || Date.now() - hit.t > SCAN_TTL_MS) {
          hit = { t: Date.now(), urls: scanPageForKvs() };
          cache.set(me.id, hit);
        }
        return kvsVariants(url, hit.urls, opts.ladder);
      }
    };
  }

  // ---- Registered sites ----------------------------------------------------------------
  // The player's quality menu runs 360 -> 1080; the page only ever shows the main link plus the
  // one for the quality currently selected, so the rest are built from that.
  register(kvsAdapter({ name: 'rule34video', host: /(^|\.)rule34video\.com$/i, ladder: [360, 480, 720, 1080] }));

  // ---- Public API ----------------------------------------------------------------------
  // Variants for a captured URL on the current site, or null (no adapter / nothing to choose).
  function collect(url) {
    if (typeof url !== 'string') return null;
    const host = location.hostname;
    for (const a of adapters) {
      if (!a.host.test(host)) continue;
      try {
        const alts = a.collect(url);
        if (alts && alts.length > 1) return alts;
      } catch (e) { /* a broken adapter must never break capture */ }
    }
    return null;
  }

  root.MBSites = { register, kvsAdapter, collect, _kvsVariants: kvsVariants, _kvsParse: kvsParse, _kvsRewrite: kvsRewrite };
})(self);
