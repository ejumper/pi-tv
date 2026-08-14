const http = require('http');
const fs = require('fs');
const path = require('path');
const { exec, execFile } = require('child_process');

const PORT = 8081;
const YDOTOOL = '/home/tv/pi-tv/tools/ydotool/build/ydotool';
const YDOTOOL_ENV = { ...process.env, YDOTOOL_SOCKET: '/tmp/ydotoold.socket' };
const WAYLAND_ENV = { ...process.env, WAYLAND_DISPLAY: process.env.WAYLAND_DISPLAY || 'wayland-0' };

const COMMANDS = {
    'power':    '/home/tv/pi-tv/scripts/tv-toggle.sh',
    'vol-up':   '/home/tv/pi-tv/scripts/volume-up.sh',
    'vol-down': '/home/tv/pi-tv/scripts/volume-down.sh',
    'up':       'wtype -k Up',
    'down':     'wtype -k Down',
    'left':     'wtype -k Left',
    'right':    'wtype -k Right',
    'enter':    'wtype -k KP_Enter',
    'home':      'wtype -M ctrl -k w',
    'tab':       'wtype -k Tab',
    'escape':    'wtype -k Escape',
    'menu':      '/home/tv/pi-tv/scripts/script-menu.sh',
    'skip-back': 'wtype -k j',
    'skip-fwd':  'wtype -k l',
};

function runCmd(cmd) {
    exec(cmd, { env: WAYLAND_ENV, timeout: 10000 }, (err) => {
        if (err) console.error(`cmd failed [${cmd}]:`, err.message);
    });
}

const MIME_TYPES = {
    '.html': 'text/html',
    '.css': 'text/css',
    '.js': 'application/javascript',
    '.json': 'application/json',
    '.svg': 'image/svg+xml',
    '.png': 'image/png',
    '.ico': 'image/x-icon',
};

const server = http.createServer((req, res) => {
    if (req.method === 'POST' && req.url === '/api/cmd') {
        let body = '';
        req.on('data', chunk => { body += chunk; });
        req.on('end', () => {
            try {
                const payload = JSON.parse(body);
                const { cmd } = payload;

                if (cmd === 'mouse-move') {
                    const dx = Math.round(Number(payload.dx)) || 0;
                    const dy = Math.round(Number(payload.dy)) || 0;
                    if (dx !== 0 || dy !== 0) {
                        execFile(YDOTOOL, ['mousemove', '-x', String(dx), '-y', String(dy)],
                            { env: YDOTOOL_ENV },
                            err => { if (err) console.error('mousemove:', err.message); });
                    }
                    res.writeHead(204); res.end(); return;
                }

                if (cmd === 'mouse-left' || cmd === 'mouse-right') {
                    execFile(YDOTOOL, ['click', cmd === 'mouse-left' ? '0xC0' : '0xC1'],
                        { env: YDOTOOL_ENV },
                        err => { if (err) console.error('click:', err.message); });
                    res.writeHead(204); res.end(); return;
                }

                if (cmd === 'type') {
                    const text = String(payload.text || '');
                    if (text) {
                        execFile('/usr/bin/wtype', [text], { env: WAYLAND_ENV },
                            err => { if (err) console.error('type:', err.message); });
                    }
                    res.writeHead(204); res.end(); return;
                }

                if (cmd === 'alarm-set') {
                    const time = String(payload.time || '');
                    if (!/^([01][0-9]|2[0-3])[0-5][0-9]$/.test(time)) {
                        res.writeHead(400); res.end('Failed to set alarm: invalid time');
                        return;
                    }
                    execFile('/home/tv/pi-tv/scripts/alarm-clock.sh', ['--set', time],
                        { env: WAYLAND_ENV, encoding: 'utf8' },
                        (err, stdout) => {
                            if (err) {
                                console.error('alarm-set:', err.message);
                                res.writeHead(500); res.end('Failed to set alarm');
                                return;
                            }
                            res.writeHead(200, { 'Content-Type': 'text/plain' });
                            res.end(String(stdout).trim());
                        });
                    return;
                }

                const command = COMMANDS[cmd];
                if (!command) { res.writeHead(400); res.end('Unknown command'); return; }
                runCmd(command);
                res.writeHead(204); res.end();
            } catch {
                res.writeHead(400); res.end('Bad request');
            }
        });
        return;
    }

    let filePath = (req.url || '/').split('?')[0];
    filePath = filePath === '/' ? '/index.html' : filePath;
    const fullPath = path.join(__dirname, decodeURIComponent(filePath));
    const ext = path.extname(fullPath).toLowerCase();
    const contentType = MIME_TYPES[ext] || 'application/octet-stream';

    fs.readFile(fullPath, (err, data) => {
        if (err) {
            res.writeHead(err.code === 'ENOENT' ? 404 : 500);
            res.end(err.code === 'ENOENT' ? 'Not found' : 'Server error');
            return;
        }
        const headers = {
            'Content-Type': contentType,
            'Cache-Control': 'no-cache',
        };
        res.writeHead(200, headers);
        res.end(data);
    });
});

server.listen(PORT, '0.0.0.0', () => {
    console.log(`Remote running at http://0.0.0.0:${PORT}`);
});
