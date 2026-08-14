// ==UserScript==
// @name        Jellyfin auto-play via local trigger
// @description Trigger /home/tv/pi-tv/tools/jellyfin-play.sh when a Jellyfin detail panel opens
// @match       http://home-site/*
// @match       https://home-site/*
// @match       http://192.168.48.173:8096/*
// @match       https://192.168.48.173:8096/*
// @run-at      document-end
// @noframes
// @grant       GM.xmlHttpRequest
// @grant       GM_xmlhttpRequest
// @connect     127.0.0.1
// @connect     localhost
// ==/UserScript==

(() => {
  const DEBUG = true;
  const API_URL = 'http://127.0.0.1:8765/jellyfin-play';
  const COOLDOWN_MS = 2500;
  const PLAY_DELAY_MS = 1200;
  const SECOND_TRIGGER_DELAY_MS = 1600;
  const LOG_THROTTLE_MS = 1200;

  let lastDetailId = '';
  let lastTriggerAt = 0;
  let lastLogAt = 0;

  const log = (...args) => {
    if (!DEBUG) {
      return;
    }
    const now = Date.now();
    if (now - lastLogAt < LOG_THROTTLE_MS) {
      return;
    }
    lastLogAt = now;
    console.log('[jellyfin-auto-play]', ...args);
  };

  const getDetailId = () => {
    const href = window.location.href;
    if (!href.includes('details')) {
      return '';
    }
    const match = href.match(/(?:[?&]|#.*?[?&])(id|itemId)=([^&]+)/i);
    return match ? decodeURIComponent(match[2]) : '';
  };

  const sendBeacon = () => {
    const img = new Image();
    img.src = `${API_URL}?t=${Date.now()}`;
  };

  const triggerPlay = () => {
    const now = Date.now();
    if (now - lastTriggerAt < COOLDOWN_MS) {
      log('cooldown active');
      return;
    }
    lastTriggerAt = now;

    log('sending play trigger');
    try {
      if (typeof GM !== 'undefined' && typeof GM.xmlHttpRequest === 'function') {
        GM.xmlHttpRequest({
          method: 'POST',
          url: API_URL,
          data: 'play',
          headers: { 'Content-Type': 'text/plain' },
          onload: () => log('GM.xmlHttpRequest ok'),
          onerror: (error) => log('GM.xmlHttpRequest error', error)
        });
        return;
      }
      if (typeof GM_xmlhttpRequest === 'function') {
        GM_xmlhttpRequest({
          method: 'POST',
          url: API_URL,
          data: 'play',
          headers: { 'Content-Type': 'text/plain' },
          onload: () => log('GM_xmlhttpRequest ok'),
          onerror: (error) => log('GM_xmlhttpRequest error', error)
        });
        return;
      }
      fetch(API_URL, { method: 'POST', mode: 'no-cors' }).catch(() => {});
      sendBeacon();
      log('fetch fallback sent');
    } catch (error) {
      log('GM_xmlhttpRequest failed, falling back', error);
      fetch(API_URL, { method: 'POST', mode: 'no-cors' }).catch(() => {});
      sendBeacon();
    }
  };

  const triggerIfStillOnItem = (detailId) => {
    if (getDetailId() !== detailId) {
      log('details changed while waiting');
      return;
    }
    triggerPlay();
  };

  const maybeAutoPlay = () => {
    const detailId = getDetailId();
    if (!detailId) {
      if (lastDetailId) {
        log('left details view');
      }
      lastDetailId = '';
      return;
    }

    if (detailId === lastDetailId) {
      return;
    }

    lastDetailId = detailId;
    log('details detected', detailId);
    window.setTimeout(() => triggerIfStillOnItem(detailId), PLAY_DELAY_MS);
    if (SECOND_TRIGGER_DELAY_MS > 0) {
      window.setTimeout(
        () => triggerIfStillOnItem(detailId),
        PLAY_DELAY_MS + SECOND_TRIGGER_DELAY_MS
      );
    }
  };

  const observer = new MutationObserver(() => {
    maybeAutoPlay();
  });
  observer.observe(document.body, { childList: true, subtree: true });

  window.addEventListener('hashchange', () => {
    window.setTimeout(maybeAutoPlay, PLAY_DELAY_MS);
  });

  window.addEventListener('popstate', () => {
    window.setTimeout(maybeAutoPlay, PLAY_DELAY_MS);
  });

  document.addEventListener(
    'click',
    (event) => {
      const target = event.target;
      if (!(target instanceof Element)) {
        return;
      }
      const hit = target.closest(
        'a[href*="details"], a[href*="itemId"], .card, .itemCard, .searchResult'
      );
      if (!hit) {
        return;
      }
      log('click detected, checking details');
      window.setTimeout(maybeAutoPlay, PLAY_DELAY_MS);
    },
    true
  );

  window.setInterval(maybeAutoPlay, 1000);

  log('script loaded', window.location.href);
  maybeAutoPlay();
})();
