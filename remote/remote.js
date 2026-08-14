// ── Button press animation ────────────────────────────────────────────────────
document.querySelectorAll('button').forEach(btn => {
    btn.addEventListener('pointerdown', () => {
        btn.classList.remove('pressing');
        void btn.offsetWidth;
        btn.classList.add('pressing');
    });
    btn.addEventListener('animationend', () => btn.classList.remove('pressing'));
});

// ── API helper ────────────────────────────────────────────────────────────────
function sendCmd(payload) {
    fetch('/api/cmd', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(payload),
    }).catch(() => {});
}

// ── Remote buttons ────────────────────────────────────────────────────────────
['power','vol-up','vol-down','up','down','left','right','enter','tab','home','escape','menu','skip-back','skip-fwd']
    .forEach(cmd => {
        const btn = document.getElementById('btn-' + cmd);
        if (btn) btn.addEventListener('click', () => sendCmd({ cmd }));
    });

// ── Overlay helpers ───────────────────────────────────────────────────────────
function openOverlay(id) {
    document.getElementById(id).removeAttribute('hidden');
}
function closeOverlay(id) {
    document.getElementById(id).setAttribute('hidden', '');
}

// ── Trackpad overlay ──────────────────────────────────────────────────────────
document.getElementById('btn-trackpad-mode').addEventListener('click', () => openOverlay('overlay-trackpad'));
document.getElementById('close-trackpad').addEventListener('click', () => closeOverlay('overlay-trackpad'));

document.getElementById('btn-mouse-left').addEventListener('click', () => sendCmd({ cmd: 'mouse-left' }));
document.getElementById('btn-mouse-right').addEventListener('click', () => sendCmd({ cmd: 'mouse-right' }));

const trackpadArea = document.getElementById('trackpad-area');
const SENSITIVITY = 2.5;
let lastPX = null, lastPY = null;
let pendingDx = 0, pendingDy = 0;
let flushPending = false;

function flushMove() {
    flushPending = false;
    const dx = Math.round(pendingDx);
    const dy = Math.round(pendingDy);
    pendingDx = 0;
    pendingDy = 0;
    if (dx !== 0 || dy !== 0) sendCmd({ cmd: 'mouse-move', dx, dy });
}

trackpadArea.addEventListener('pointerdown', e => {
    trackpadArea.setPointerCapture(e.pointerId);
    lastPX = e.clientX;
    lastPY = e.clientY;
    e.preventDefault();
}, { passive: false });

trackpadArea.addEventListener('pointermove', e => {
    if (lastPX === null) return;
    pendingDx += (e.clientX - lastPX) * SENSITIVITY;
    pendingDy += (e.clientY - lastPY) * SENSITIVITY;
    lastPX = e.clientX;
    lastPY = e.clientY;
    if (!flushPending) {
        flushPending = true;
        requestAnimationFrame(flushMove);
    }
    e.preventDefault();
}, { passive: false });

trackpadArea.addEventListener('pointerup', () => { lastPX = null; lastPY = null; });
trackpadArea.addEventListener('pointercancel', () => { lastPX = null; lastPY = null; });

// ── Keyboard overlay ──────────────────────────────────────────────────────────
document.getElementById('btn-keyboard-mode').addEventListener('click', () => {
    openOverlay('overlay-keyboard');
    setTimeout(() => document.getElementById('type-input').focus(), 80);
});
document.getElementById('close-keyboard').addEventListener('click', () => closeOverlay('overlay-keyboard'));

function sendTyped() {
    const input = document.getElementById('type-input');
    const text = input.value;
    if (!text) return;
    sendCmd({ cmd: 'type', text });
    input.value = '';
    input.focus();
}

document.getElementById('type-send').addEventListener('click', sendTyped);
document.getElementById('type-input').addEventListener('keydown', e => {
    if (e.key === 'Enter') { e.preventDefault(); sendTyped(); }
});

// ── Alarm overlay ────────────────────────────────────────────────────────────
document.getElementById('btn-alarm-mode').addEventListener('click', () => {
    openOverlay('overlay-alarm');
    setTimeout(() => document.getElementById('alarm-input').focus(), 80);
});
document.getElementById('close-alarm').addEventListener('click', () => closeOverlay('overlay-alarm'));

const alarmInput = document.getElementById('alarm-input');

alarmInput.addEventListener('input', () => {
    alarmInput.value = alarmInput.value.replace(/[^0-9]/g, '');
    alarmInput.classList.remove('input-error');
});

function sendAlarm() {
    const time = alarmInput.value;
    if (!/^([01][0-9]|2[0-3])[0-5][0-9]$/.test(time)) {
        alarmInput.classList.remove('input-error');
        void alarmInput.offsetWidth;
        alarmInput.classList.add('input-error');
        alarmInput.focus();
        return;
    }
    sendCmd({ cmd: 'alarm-set', time });
    alarmInput.value = '';
    closeOverlay('overlay-alarm');
}

document.getElementById('alarm-send').addEventListener('click', sendAlarm);
alarmInput.addEventListener('keydown', e => {
    if (e.key === 'Enter') { e.preventDefault(); sendAlarm(); }
});
