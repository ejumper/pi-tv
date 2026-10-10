// ==UserScript==
// @name        Jellyfin favorites auto-shuffle (Pi-TV)
// @version     0.1
// @description When the TV opens the marked favorite-songs URL, click the list's
//              Shuffle button, then hop to the now-playing queue view.
// @match       https://media.halfab.net/*
// @grant       none
// @run-at      document-idle
// @noframes
// ==/UserScript==
//
// Trigger URL (marker param is ignored by jellyfin-web — params are read by
// specific keys only, verified against v10.11.11 src/controllers/list.js):
//   https://media.halfab.net/web/#/list?serverId=ca51be806e1245acaeb85fb6cc174783
//          &type=Audio&IsFavorite=true&autoshuffle=1
//
// What it does, per page load, when that hash is entered:
//   1. polls for the list view's shuffle button (.btnShuffle, unhidden after
//      the items query resolves; filtered lists fetch SortBy=Random and call
//      playbackManager.play({items, autoplay:true}))
//   2. clicks it
//   3. once playback is detectable (now-playing bar) — or after a timeout —
//      navigates to #/queue (SPA hash route; playback is uninterrupted)
//
// A tiny status overlay appears bottom-left ONLY for the marked URL and
// removes itself a few seconds after navigation; normal browsing untouched.

(() => {
  'use strict';

  const MARKER = 'autoshuffle=1';
  const POLL_MS = 300;
  const MAX_WAIT_MS = 20000;   // list query + render on a Pi over tailnet
  const PLAY_DETECT_MS = 4000; // how long to wait for a media element
  const QUEUE_HOP_DELAY_MS = 400;
  const OVERLAY_TTL_MS = 6000; // overlay lifetime after hop

  // one-shot per exact hash string per page load
  const fired = new Set();
  let overlay = null;

  const show = (msg) => {
    if (!overlay) {
      overlay = document.createElement('div');
      Object.assign(overlay.style, {
        position: 'fixed', left: '12px', bottom: '12px', zIndex: 99999,
        font: '14px monospace', color: '#0ff', background: 'rgba(0,0,0,.65)',
        padding: '4px 8px', borderRadius: '4px', pointerEvents: 'none'
      });
      document.body.appendChild(overlay);
    }
    overlay.textContent = `[fav-shuffle] ${msg}`;
  };

  const hideSoon = () => {
    setTimeout(() => { overlay?.remove(); overlay = null; }, OVERLAY_TTL_MS);
  };

  const markedHash = () => {
    const h = window.location.hash || '';
    return h.startsWith('#/list') && h.includes(MARKER) && h.includes('type=Audio');
  };

  const findShuffleButton = () =>
    [...document.querySelectorAll('button.btnShuffle:not(.hide)')][0] || null;

  const findNowPlayingBar = () =>
    document.querySelector('audio, video'); // version-proof: jellyfin-web's player element

  const tryRun = () => {
    if (!markedHash()) return;

    const hash = window.location.hash;
    if (fired.has(hash)) return;
    fired.add(hash);

    show('waiting for list…');
    const t0 = Date.now();

    const poll = setInterval(() => {
      if (window.location.hash !== hash) {           // navigated away
        clearInterval(poll);
        return;
      }
      const btn = findShuffleButton();
      if (btn) {
        clearInterval(poll);
        show('clicking shuffle…');
        btn.click();
        const p0 = Date.now();
        const pollPlay = setInterval(() => {
          if (findNowPlayingBar()) {
            clearInterval(pollPlay);
            show('playing → queue');
            setTimeout(() => { window.location.hash = '#/queue'; hideSoon(); }, QUEUE_HOP_DELAY_MS);
          } else if (Date.now() - p0 > PLAY_DETECT_MS) {
            clearInterval(pollPlay);
            show('no playback detected → queue anyway');
            setTimeout(() => { window.location.hash = '#/queue'; hideSoon(); }, QUEUE_HOP_DELAY_MS);
          }
        }, POLL_MS);
      } else if (Date.now() - t0 > MAX_WAIT_MS) {
        clearInterval(poll);
        show('gave up (no shuffle button)');
        hideSoon();
      }
    }, POLL_MS);
  };

  setInterval(tryRun, 400);
  window.addEventListener('hashchange', tryRun);
})();
