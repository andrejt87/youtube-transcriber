#!/bin/bash
# youtube-transcribe.sh - YouTube Video Transkription & Zusammenfassung
# Nutzt yt-dlp für Audio-Download und whisper-cpp für Transkription
#
# Requirements:
#   - yt-dlp (pip install yt-dlp)
#   - whisper-cpp (brew install whisper-cpp)
#   - ffmpeg (brew install ffmpeg)
#   - Whisper model (download via whisper-cpp)

set -e

# === CONFIGURATION ===
# Adjust paths to match your system
YTDLP="${YTDLP:-yt-dlp}"
WHISPER="${WHISPER:-whisper-cli}"
WHISPER_MODEL="${WHISPER_MODEL:-$HOME/.whisper/ggml-medium.bin}"
TMP_DIR="${TMP_DIR:-/tmp/yt_transcribe}"
OUTPUT_DIR="${OUTPUT_DIR:-.}"

# === FUNCTIONS ===
usage() {
    echo "Usage: $0 <youtube-url> [options]"
    echo ""
    echo "Options:"
    echo "  -o, --output DIR    Output directory (default: current dir)"
    echo "  -l, --language LANG Force language (default: auto)"
    echo "  -t, --transcript    Output transcript only (no VTT)"
    echo "  -h, --help          Show this help"
    exit 1
}

cleanup() {
    rm -rf "$TMP_DIR"
}

# === ARGUMENT PARSING ===
URL=""
LANG="auto"
TRANSCRIPT_ONLY=false

while [[ $# -gt 0 ]]; do
    case $1 in
        -o|--output) OUTPUT_DIR="$2"; shift 2 ;;
        -l|--language) LANG="$2"; shift 2 ;;
        -t|--transcript) TRANSCRIPT_ONLY=true; shift ;;
        -h|--help) usage ;;
        -*) echo "Unknown option: $1"; usage ;;
        *) URL="$1"; shift ;;
    esac
done

if [[ -z "$URL" ]]; then
    usage
fi

# === MAIN ===
mkdir -p "$TMP_DIR"
mkdir -p "$OUTPUT_DIR"
trap cleanup EXIT

echo "=== YouTube Transcriber ===" >&2
echo "URL: $URL" >&2

# Get video info
echo "Fetching video info..." >&2
TITLE=$("$YTDLP" --get-title "$URL" 2>/dev/null || echo "Unknown")
DURATION=$("$YTDLP" --get-duration "$URL" 2>/dev/null || echo "?")
VIDEO_ID=$("$YTDLP" --get-id "$URL" 2>/dev/null || echo "video")

echo "Title: $TITLE" >&2
echo "Duration: $DURATION" >&2

# Download audio (Android client bypasses 403 blocks)
echo "Downloading audio..." >&2
"$YTDLP" --extractor-args "youtube:player_client=android" \
    -x --audio-format mp3 \
    -o "$TMP_DIR/audio.%(ext)s" "$URL" 2>/dev/null

DOWNLOADED=$(ls "$TMP_DIR"/audio.* 2>/dev/null | head -1)
if [[ -z "$DOWNLOADED" ]]; then
    echo "Error: Could not download audio" >&2
    exit 1
fi

# Convert to WAV for whisper
echo "Converting to WAV..." >&2
WAV_FILE="$TMP_DIR/audio.wav"
ffmpeg -i "$DOWNLOADED" -ar 16000 -ac 1 -f wav "$WAV_FILE" -y 2>/dev/null

# Transcribe
echo "Transcribing with Whisper..." >&2
LANG_FLAG=""
if [[ "$LANG" != "auto" ]]; then
    LANG_FLAG="-l $LANG"
fi

if $TRANSCRIPT_ONLY; then
    "$WHISPER" -m "$WHISPER_MODEL" -f "$WAV_FILE" $LANG_FLAG --no-timestamps 2>/dev/null
else
    # Output VTT format
    "$WHISPER" -m "$WHISPER_MODEL" -f "$WAV_FILE" $LANG_FLAG --output-vtt 2>/dev/null
    
    # Also save to file
    SAFE_TITLE=$(echo "$VIDEO_ID" | tr -cd '[:alnum:]-_')
    "$WHISPER" -m "$WHISPER_MODEL" -f "$WAV_FILE" $LANG_FLAG --no-timestamps 2>/dev/null > "$OUTPUT_DIR/${SAFE_TITLE}.txt"
    echo "" >&2
    echo "Saved transcript to: $OUTPUT_DIR/${SAFE_TITLE}.txt" >&2
fi

echo "Done!" >&2
