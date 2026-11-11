#!/bin/sh
# Linux desktop entry point. Never installs system packages or changes shell profiles.
set -u
umask 077
launcher_here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd) || exit 1
launcher_error() {
    launcher_message=$1
    printf '%s\n' "$launcher_message" >&2
    if command -v zenity >/dev/null 2>&1; then
        zenity --error --title=Delegatus --text="$launcher_message" 2>/dev/null && return
    fi
    if command -v kdialog >/dev/null 2>&1; then
        kdialog --error "$launcher_message" --title Delegatus 2>/dev/null && return
    fi
    if command -v xmessage >/dev/null 2>&1; then
        xmessage -center -title Delegatus "$launcher_message" 2>/dev/null && return
    fi
    if command -v x-terminal-emulator >/dev/null 2>&1; then
        x-terminal-emulator -e sh -c 'printf "%s\n\nPress Enter to close.\n" "$1"; read -r answer' sh "$launcher_message" && return
    elif command -v xterm >/dev/null 2>&1; then
        xterm -hold -e printf '%s\n' "$launcher_message" && return
    fi
    if command -v konsole >/dev/null 2>&1; then
        konsole --hold -e sh -c 'printf "%s\n" "$1"' sh "$launcher_message" && return
    fi
    if command -v gnome-terminal >/dev/null 2>&1; then
        gnome-terminal --wait -- sh -c 'printf "%s\n\nPress Enter to close.\n" "$1"; read -r answer' sh "$launcher_message" && return
    fi
    if command -v xfce4-terminal >/dev/null 2>&1; then
        xfce4-terminal --hold --execute sh -c 'printf "%s\n" "$1"' sh "$launcher_message" && return
    fi
    if command -v notify-send >/dev/null 2>&1; then
        notify-send --urgency=critical Delegatus "$launcher_message" 2>/dev/null || :
    fi
}
if ! command -v python3 >/dev/null 2>&1; then
    launcher_error 'Python 3.10+ is required. Ubuntu: sudo apt install python3 python3-tk. Arch Linux: sudo pacman -S python tk. Run these yourself; the launcher does not install system packages.'
    exit 1
fi
if ! python3 -c 'import sys; assert sys.version_info >= (3, 10); import tkinter' >/dev/null 2>&1; then
    launcher_error 'Python 3.10+ with Tk is required. Ubuntu: sudo apt install python3-tk. Arch Linux: sudo pacman -S python tk. Run these yourself, then open Delegatus again.'
    exit 1
fi
launcher_capture=$(mktemp "${TMPDIR:-/tmp}/delegatus-error.XXXXXXXX") || exit 1
trap 'rm -f -- "$launcher_capture"' EXIT HUP INT TERM
python3 "$launcher_here/delegatus.py" "$@" 2>"$launcher_capture"
launcher_status=$?
if [ "$launcher_status" -ne 0 ]; then
    launcher_detail=$(tail -c 6000 "$launcher_capture")
    launcher_error "Delegatus could not start.

$launcher_detail"
fi
exit "$launcher_status"
