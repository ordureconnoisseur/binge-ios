#!/usr/bin/env bash
# Re-encode every VP9-coded video in the given path to H.264.
# Replace originals atomically (temp file + rename). Designed for the
# Instagram VP9 batch on mini — fixes binge auto-start by removing the
# codec AVPlayer + Stash's VP9→HLS pipeline get stuck on.
#
# Usage:
#   ./convert-vp9.sh                       # default path
#   ./convert-vp9.sh /Volumes/Ethan/foo    # custom path
set -uo pipefail

# Homebrew on Apple Silicon installs to /opt/homebrew/bin; non-login
# SSH sessions don't pick that up. Prepend so ffmpeg/ffprobe resolve.
export PATH="/opt/homebrew/bin:$PATH"

ROOT="${1:-/Volumes/Ethan/Media/instagram}"
LOG="/tmp/vp9-convert-$(date +%Y%m%d-%H%M%S).log"

if ! command -v ffmpeg >/dev/null 2>&1; then
    echo "ffmpeg not on PATH — install via: brew install ffmpeg" >&2
    exit 1
fi
if [[ ! -d "$ROOT" ]]; then
    echo "directory not found: $ROOT" >&2
    exit 1
fi

echo "[$(date +%H:%M:%S)] scanning $ROOT" | tee -a "$LOG"

CONVERTED=0
SKIPPED=0
FAILED=0

while IFS= read -r -d '' f; do
    # Skip our own in-flight tmp files if a previous run aborted.
    case "$f" in
        *.vp9-converting.tmp.mp4) continue ;;
    esac

    codec=$(ffprobe -v error -select_streams v:0 \
        -show_entries stream=codec_name \
        -of default=nw=1:nk=1 "$f" 2>/dev/null || true)

    if [[ "$codec" != "vp9" ]]; then
        SKIPPED=$((SKIPPED + 1))
        continue
    fi

    tmp="${f%.*}.vp9-converting.tmp.mp4"
    rm -f "$tmp"

    echo "[$(date +%H:%M:%S)] converting $f" | tee -a "$LOG"

    if ffmpeg -hide_banner -loglevel error -nostdin -y \
        -i "$f" \
        -c:v libx264 -preset veryfast -crf 23 \
        -pix_fmt yuv420p \
        -c:a aac -b:a 192k \
        -movflags +faststart \
        "$tmp" 2>>"$LOG"; then
        # Replace the original. If the original had a non-.mp4
        # extension (e.g. .webm), this keeps the original path so
        # Stash doesn't pick it up as a brand new file — but the
        # container is now mp4, so a rescan picks up the codec
        # change cleanly.
        if mv -f "$tmp" "$f"; then
            CONVERTED=$((CONVERTED + 1))
            echo "[$(date +%H:%M:%S)] OK $f" | tee -a "$LOG"
        else
            rm -f "$tmp"
            FAILED=$((FAILED + 1))
            echo "[$(date +%H:%M:%S)] RENAME-FAILED $f" | tee -a "$LOG"
        fi
    else
        rm -f "$tmp"
        FAILED=$((FAILED + 1))
        echo "[$(date +%H:%M:%S)] FFMPEG-FAILED $f (see log)" | tee -a "$LOG"
    fi
done < <(find "$ROOT" -type f \( \
    -iname '*.mp4' -o \
    -iname '*.mkv' -o \
    -iname '*.webm' -o \
    -iname '*.mov' \
\) -print0)

echo "[$(date +%H:%M:%S)] done converted=$CONVERTED skipped=$SKIPPED failed=$FAILED log=$LOG" | tee -a "$LOG"
