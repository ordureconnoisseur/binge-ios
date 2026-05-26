#!/usr/bin/env bash
# Rewrite HEVC codec tag to hvc1 (from hev1 / untagged) and move the
# moov atom to the front via +faststart. No re-encoding — just a
# container remux, runs in seconds per file. Makes AVPlayer treat the
# file as first-class HEVC; reportedly resolves the autoplay flakiness.
#
# Only mp4 / mov containers can carry hvc1 — MKV skipped.
#
# Usage:
#   ./fix-hevc-tag.sh                       # default path
#   ./fix-hevc-tag.sh /Volumes/Ethan/foo    # custom path
set -uo pipefail

export PATH="/opt/homebrew/bin:$PATH"

ROOT="${1:-/Volumes/Ethan/Media/instagram}"
LOG="/tmp/hevc-tag-$(date +%Y%m%d-%H%M%S).log"

if ! command -v ffmpeg >/dev/null 2>&1; then
    echo "ffmpeg not on PATH — install via: brew install ffmpeg" >&2
    exit 1
fi
if [[ ! -d "$ROOT" ]]; then
    echo "directory not found: $ROOT" >&2
    exit 1
fi

echo "[$(date +%H:%M:%S)] scanning $ROOT" | tee -a "$LOG"

FIXED=0
SKIPPED=0
FAILED=0

while IFS= read -r -d '' f; do
    case "$f" in
        *.hevc-fixing.tmp.mp4) continue ;;
    esac

    # Single ffprobe call: codec name + container tag.
    info=$(ffprobe -v error -select_streams v:0 \
        -show_entries stream=codec_name,codec_tag_string \
        -of default=nw=1 "$f" 2>/dev/null || true)
    codec=$(echo "$info" | awk -F= '/codec_name/{print $2}')
    tag=$(echo "$info" | awk -F= '/codec_tag_string/{print $2}')

    if [[ "$codec" != "hevc" ]]; then
        SKIPPED=$((SKIPPED + 1))
        continue
    fi
    if [[ "$tag" == "hvc1" ]]; then
        # Already tagged hvc1 — no fix needed.
        SKIPPED=$((SKIPPED + 1))
        continue
    fi

    tmp="${f%.*}.hevc-fixing.tmp.mp4"
    rm -f "$tmp"

    echo "[$(date +%H:%M:%S)] retagging $f (was tag=$tag)" | tee -a "$LOG"

    if ffmpeg -hide_banner -loglevel error -nostdin -y \
        -i "$f" \
        -c:v copy -tag:v hvc1 \
        -c:a copy \
        -movflags +faststart \
        "$tmp" 2>>"$LOG"; then
        if mv -f "$tmp" "$f"; then
            FIXED=$((FIXED + 1))
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
    -iname '*.mov' \
\) -print0)

echo "[$(date +%H:%M:%S)] done fixed=$FIXED skipped=$SKIPPED failed=$FAILED log=$LOG" | tee -a "$LOG"
