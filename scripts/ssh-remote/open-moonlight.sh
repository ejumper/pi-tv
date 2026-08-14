#!/usr/bin/env bash
DISPLAY=:0 QT_QPA_PLATFORM=xcb \
  moonlight-qt stream kubuntu "Steam Big Picture" &
