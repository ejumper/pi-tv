# pi-tv

Raspberry Pi 5 smart-TV stack (user `tv`), rooted at `/home/tv/pi-tv/`.

## Layout

- `scripts/` - remote-control and alarm scripts. `alarm-clock.sh` schedules a
  daily alarm via a transient systemd timer (`--set HHMM`, `--trigger`).
  `alarm-logs.sh` prints what the alarm actually did (`alarm-logs.sh`,
  `alarm-logs.sh -f`, `alarm-logs.sh --since "today"`).
- `tools/` - vendored ydotool source, screen dimming, Jellyfin helpers, TTS sounds.
- `remote/` - phone web remote (Node `server.js`, port 8081, plus service worker).
- `systemd/` - copies of the unit files: `user/` mirrors
  `~/.config/systemd/user/`, `system/` mirrors `/etc/systemd/system/ydotoold.service`.

## The alarm, in one paragraph

The trigger fires `ALARM_LEAD_SECONDS` (78s) before the set time so the jingle starts
exactly on time after TV wake + volume setup. Mon-Fri it plays the Democracy Now video
RSS stream; weekends it embeds an Invidious playlist (YouTube removed the extractable
stream formats, so the embed is the only stable weekend path). Media resolution runs in a
separate, time-bounded child process *while* the TV is waking, and the player page opens
whether or not media resolved - clock and TTS announcements never depend on the network.
Audio-only fallbacks cover a dead video feed and a video that resolves but will not start
playing. Config knobs are documented at the top of `scripts/alarm-clock.sh`.

## Paths

Everything assumes `/home/tv/pi-tv/`. If the tree moves, update:

- `scripts/alarm-clock.sh` (`SCRIPTS_DIR`)
- `remote/server.js` (command paths, `YDOTOOL`, alarm script)
- `tools/*.sh` (`YDOTOOL_BIN`, screen-dim paths)
- unit files in `systemd/`

The transient alarm timer embeds the script path in its ExecStart: after moving the tree,
re-run `alarm-clock.sh --set <current time>`.

## Services

- `remote-site.service` (user) - web remote on :8081
- `alarm-clock.timer` (transient, user) - created by `alarm-clock.sh --set HHMM`; re-created at boot by `alarm-restore.service` from the saved time file
- `ydotoold.service` (system) - input injection daemon
- `screen-dim-on/off.service` (user, timer-driven)

Logs: this Pi has no per-user journald namespace, so user-unit output lands in the
*system* journal and `journalctl --user` shows nothing while still exiting 0. Use
`scripts/alarm-logs.sh` (or `sudo journalctl _SYSTEMD_USER_UNIT=alarm-clock.service`).
Raspberry Pi OS also ships `Storage=volatile`, so logs live in RAM and a reboot clears
them; capture anything you care about before rebooting.

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
