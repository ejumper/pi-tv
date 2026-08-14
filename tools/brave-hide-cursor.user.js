// ==UserScript==
// @name        Brave cursor autohide
// @description Hide cursor after 5s of mouse idle inside web pages
// @match       *://*/*
// @run-at      document-end
// @noframes
// @grant       none
// ==/UserScript==

(() => {
  const HIDE_DELAY_MS = 5000;
  let timerId = null;

  const style = document.createElement('style');
  style.textContent = 'html.tm-cursor-hidden, html.tm-cursor-hidden * { cursor: none !important; }';
  document.head.appendChild(style);

  const reset = () => {
    if (timerId) {
      clearTimeout(timerId);
    }
    document.documentElement.classList.remove('tm-cursor-hidden');
    timerId = window.setTimeout(() => {
      document.documentElement.classList.add('tm-cursor-hidden');
    }, HIDE_DELAY_MS);
  };

  window.addEventListener('mousemove', reset, { passive: true });
  window.addEventListener('pointermove', reset, { passive: true });

  reset();
})();
