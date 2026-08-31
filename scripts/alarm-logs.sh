#!/usr/bin/env bash
# Read what the alarm clock has actually logged.
#
# On this Pi there is no per-user journald namespace: user-unit output lands in
# the SYSTEM journal, so `journalctl --user` finds nothing (and still exits 0,
# which is how that gets mistaken for "no log entries"). sudo is required.
#
#   alarm-logs.sh                     last 40 alarm lines
#   alarm-logs.sh -f                  follow
#   alarm-logs.sh --since "today"     filter however journalctl does
set -euo pipefail
[ "$#" -gt 0 ] || set -- -n 40
exec sudo journalctl \
  _SYSTEMD_USER_UNIT=alarm-clock.service \
  _SYSTEMD_USER_UNIT=alarm-clock.timer \
  _SYSTEMD_USER_UNIT=alarm-restore.service \
  -o short "$@"
