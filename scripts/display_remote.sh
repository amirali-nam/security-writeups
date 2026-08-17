#!/bin/bash
# ─────────────────────────────────────────────────────────────
#  display_remote.sh  (auto-detecting)
#  Run from the CONTROL node. Transfers an image to the TARGET
#  and renders it full-screen on the target's physical monitor.
#
#  Auto-detects the target's display layer:
#    - graphical session (X / Xwayland) -> feh, with the correct
#      DISPLAY and XAUTHORITY discovered at runtime
#    - text console                     -> fbi on the ACTIVE tty
#
#  Companion to: remote-file-delivery-and-display.md
#  Lab use only, on machines you own. See the writeup's scope note.
#
#  usage: ./display_remote.sh <image>
# ─────────────────────────────────────────────────────────────

# ──── config: fill these in ────
TARGET_USER="<user>"          # login account on the target
TARGET_IP="<target-ip>"       # host with the physical monitor
CONTROL_IP="<control-ip>"     # this machine (serves the file)
HTTP_PORT=9000
REMOTE_TMP="/tmp"
FB_DEVICE="/dev/fb0"
# ───────────────────────────────

set -u
GRN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
info() { echo -e "${GRN}[*]${NC} $1"; }
err()  { echo -e "${RED}[!]${NC} $1"; exit 1; }

[[ $# -ge 1 ]] || { echo "usage: $0 <image>"; exit 1; }
FILE="$(realpath "$1")"
[[ -f "$FILE" ]] || err "file not found: $FILE"
NAME="$(basename "$FILE")"
DIR="$(dirname "$FILE")"

# ── serve the file from the control node ──
info "serving on ${CONTROL_IP}:${HTTP_PORT}"
pkill -f "http.server ${HTTP_PORT}" 2>/dev/null || true
sleep 0.3
( cd "$DIR" && python3 -m http.server "$HTTP_PORT" >/dev/null 2>&1 ) &
HTTP_PID=$!
sleep 0.8

# ── on the target: pull the file, detect the display layer, render ──
info "connecting to ${TARGET_IP}"
ssh -o ConnectTimeout=5 "${TARGET_USER}@${TARGET_IP}" \
    TARGET_USER="${TARGET_USER}" \
    CONTROL_IP="${CONTROL_IP}" \
    HTTP_PORT="${HTTP_PORT}" \
    NAME="${NAME}" \
    REMOTE_TMP="${REMOTE_TMP}" \
    FB_DEVICE="${FB_DEVICE}" \
    bash <<'ENDSSH'
  set -e
  DEST="${REMOTE_TMP}/${NAME}"

  echo "[*] downloading ${NAME}"
  wget -q -O "${DEST}" "http://${CONTROL_IP}:${HTTP_PORT}/${NAME}"
  # verify we actually got an image, not an error page
  if ! file "${DEST}" | grep -qiE 'image|bitmap'; then
    echo "[!] downloaded file is not an image — aborting"; exit 1
  fi

  # clear any previous viewers
  pkill feh 2>/dev/null || true
  sudo pkill fbi 2>/dev/null || true
  sleep 0.3

  # ── detect display layer ──
  if [ -e /tmp/.X11-unix/X0 ]; then
    # a graphical session is running -> use feh
    echo "[*] target has a graphical session -> feh"
    command -v feh >/dev/null 2>&1 || { echo "[!] feh not installed on target — run: sudo apt install feh"; exit 1; }

    # find the X authority cookie: modern desktops keep it under
    # /run/user/<uid>/ (e.g. mutter-Xwaylandauth.*), not in ~/.Xauthority
    XAUTH="$(ls -t /run/user/$(id -u)/.mutter-Xwaylandauth.* 2>/dev/null | head -1)"
    [ -z "$XAUTH" ] && XAUTH="/home/${TARGET_USER}/.Xauthority"

    DISPLAY=:0 XAUTHORITY="$XAUTH" feh --fullscreen "${DEST}" >/dev/null 2>&1 &
    sleep 1
    pgrep -x feh >/dev/null || { echo "[!] feh failed to start (check DISPLAY/XAUTHORITY)"; exit 1; }
  else
    # text console -> use fbi on whichever tty is currently active
    command -v fbi >/dev/null 2>&1 || { echo "[!] fbi not installed on target — run: sudo apt install fbi"; exit 1; }
    ACTIVE_TTY="$(cat /sys/class/tty/tty0/active 2>/dev/null || echo tty1)"
    TTY_NUM="${ACTIVE_TTY#tty}"
    echo "[*] target is on text console ${ACTIVE_TTY} -> fbi"
    sudo fbi -T "${TTY_NUM}" -d "${FB_DEVICE}" -a --noverbose "${DEST}" >/dev/null 2>&1 &
    sleep 1
    pgrep -x fbi >/dev/null || { echo "[!] fbi failed to start"; exit 1; }
  fi

  echo "[+] rendered on the target"
ENDSSH
SSH_STATUS=$?

# ── stop the file server ──
sleep 2
kill "$HTTP_PID" 2>/dev/null || true

if [[ $SSH_STATUS -eq 0 ]]; then
  info "'${NAME}' displayed on the target monitor."
  echo "    clear (graphical): ssh ${TARGET_USER}@${TARGET_IP} 'pkill feh'"
  echo "    clear (console):   ssh ${TARGET_USER}@${TARGET_IP} 'sudo pkill fbi'"
else
  err "SSH, download, or render step failed (see message above)."
fi
