# pi-tv

Raspberry Pi 5 smart-TV stack (user `tv`), rooted at `/home/tv/pi-tv/`.

## Layout

- `scripts/` - remote-control and alarm scripts. `alarm-clock.sh` schedules a
  daily alarm via a transient systemd timer (`--set HHMM`, `--trigger`).
- `tools/` - vendored ydotool source, screen dimming, Jellyfin helpers, TTS sounds.
- `remote/` - phone web remote (Node `server.js`, port 8081, plus service worker).
- `systemd/` - copies of the unit files: `user/` mirrors
  `~/.config/systemd/user/`, `system/` mirrors `/etc/systemd/system/ydotoold.service`.

## Paths

Everything assumes `/home/tv/pi-tv/`. If the tree moves, update:

- `scripts/alarm-clock.sh` (`SCRIPTS_DIR`)
- `remote/server.js` (command paths, `YDOTOOL`, alarm script)
- `tools/*.sh` (`YDOTOOL_BIN`, screen-dim paths)
- unit files in `systemd/`

## Services

- `remote-site.service` (user) - web remote on :8081
- `alarm-clock.timer` (transient, user) - created by `alarm-clock.sh --set HHMM`
- `ydotoold.service` (system) - input injection daemon
- `screen-dim-on/off.service` (user, timer-driven)

## Backup workflow

Manual snapshot:

```
cd /home/tv/pi-tv
git add -A
git commit -m "message"
git push
```

The Pi authenticates to GitHub with SSH key `~/.ssh/id_ed25519_github`.

## ydotool

Vendored clone of https://github.com/ReimuNotMoe/ydotool (commit `708e96f`).
`build/` is gitignored; rebuild with cmake/make.
