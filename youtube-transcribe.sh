#!/bin/bash
# youtube-transcribe.sh - YouTube Video Transkription & Zusammenfassung
# Nutzt yt-dlp für Audio-Download und whisper-cpp für Transkription

set -e

# === CONFIGURATION ===
YTDLP="${YTDLP:-/opt/homebrew/bin/python3.11 -m yt_dlp}"
COOKIES_MASTER="$HOME/.config/yt-dlp/cookies_master.txt"
COOKIES_TMP="/tmp/yt_cookies_$$.txt"
YTDLP_OPTS="--cookies $COOKIES_TMP --remote-components ejs:github"
WHISPER="${WHISPER:-/opt/homebrew/bin/whisper-cli}"
WHISPER_MODEL="${WHISPER_MODEL:-$HOME/.whisper/ggml-medium.bin}"
TMP_DIR="${TMP_DIR:-/tmp/yt_transcribe}"
OUTPUT_DIR="${OUTPUT_DIR:-/tmp/yt_transcripts}"

# Telegram notification config
TELEGRAM_BOT_TOKEN="8380074958:AAFyNGGpYnx5Ts-pAnZvhKN3W2lVs0MyOIo"
TELEGRAM_CHAT_ID="472279328"

# === FUNCTIONS ===
usage() {
    echo "Usage: $0 <youtube-url> [options]"
    echo ""
    echo "Options:"
    echo "  -o, --output DIR     Output directory (default: ~/transcripts)"
    echo "  -l, --language LANG  Force language (default: auto)"
    echo "  -b, --background     Run in background, notify via Telegram"
    echo "  --factcheck y|n      Include factcheck flag in notification"
    echo "  -h, --help           Show this help"
    exit 1
}

cleanup() {
    rm -rf "$TMP_DIR"
}

notify() {
    local message="$1"
    if $BACKGROUND; then
        curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
            -d "chat_id=${TELEGRAM_CHAT_ID}" \
            -d "text=${message}" \
            -d "parse_mode=HTML" > /dev/null 2>&1 || true
    fi
}

notify_error() {
    local step="$1"
    local reason="$2"
    notify "❌ Fehler bei ${step}: ${reason}"
    # Also ping agent about error
    if $BACKGROUND; then
        ping_agent "YOUTUBE_ERROR|${step}|${reason}|${URL}"
    fi
}

# Ping the AI agent via system event
ping_agent() {
    local message="$1"
    /opt/homebrew/bin/openclaw system event --text "$message" --mode now 2>/dev/null || true
}

# Estimate whisper transcription time (roughly 1 min processing per 10 min audio)
estimate_time() {
    local duration="$1"
    # Parse duration (formats: "1:23:45" or "23:45" or "45")
    local hours=0 mins=0 secs=0
    if [[ "$duration" =~ ^([0-9]+):([0-9]+):([0-9]+)$ ]]; then
        hours="${BASH_REMATCH[1]}"
        mins="${BASH_REMATCH[2]}"
        secs="${BASH_REMATCH[3]}"
    elif [[ "$duration" =~ ^([0-9]+):([0-9]+)$ ]]; then
        mins="${BASH_REMATCH[1]}"
        secs="${BASH_REMATCH[2]}"
    elif [[ "$duration" =~ ^([0-9]+)$ ]]; then
        secs="${BASH_REMATCH[1]}"
    fi
    
    local total_mins=$((hours * 60 + mins + secs / 60))
    local estimate=$((total_mins / 10 + 1))
    echo "$estimate"
}

# Detect language by sampling random positions in the audio (max 10 attempts)
detect_language() {
    local wav_file="$1"
    local duration_secs="$2"
    local max_attempts=10
    local sample_duration=10  # 10 second samples
    
    for attempt in $(seq 1 $max_attempts); do
        # Random start position (avoid first 10% and last 10%)
        local safe_start=$((duration_secs / 10))
        local safe_end=$((duration_secs * 9 / 10 - sample_duration))
        if [[ $safe_end -le $safe_start ]]; then
            safe_start=0
            safe_end=$((duration_secs - sample_duration))
        fi
        local random_start=$((RANDOM % (safe_end - safe_start + 1) + safe_start))
        
        # Extract sample
        local sample_file="/tmp/lang_sample_${attempt}.wav"
        ffmpeg -i "$wav_file" -ss "$random_start" -t "$sample_duration" -y "$sample_file" 2>/dev/null
        
        # Try to detect language with whisper
        local result=$("$WHISPER" -m "$WHISPER_MODEL" -f "$sample_file" --no-timestamps -l auto 2>/dev/null | head -20)
        rm -f "$sample_file"
        
        # Check if we got actual content (not just "foreign language")
        if [[ ! "$result" =~ "foreign language" ]] && [[ -n "$result" ]] && [[ ! "$result" =~ ^[[:space:]]*$ ]]; then
            # Try to detect language from content
            # If mostly German characters/words, return de
            if echo "$result" | grep -qiE "(und|der|die|das|ist|nicht|ein|ich|wir|sie|haben|werden|kann|auch|nach|für|auf|mit|sind|war|bei|oder|wie|noch|aber|dann|wenn|nur|schon|mehr|über|diese|durch|vor|hier|muss|immer|gegen|heute|weil|unter|viel)"; then
                echo "de"
                return 0
            # If mostly English, return en
            elif echo "$result" | grep -qiE "(the|and|that|this|with|from|have|are|was|were|been|being|what|when|where|which|who|will|would|could|should|there|their|about|into|some|than|them|then|these|time|very|just|know|take|come|made|find|here|many|only|other|over|such|than|through)"; then
                echo "en"
                return 0
            # If we got content but couldn't match DE or EN, keep trying
            fi
        fi
        
        echo "Attempt $attempt: No clear language detected, trying another position..." >&2
    done
    
    # After max attempts, return empty to signal failure
    echo ""
}

# Get duration in seconds for language detection
get_duration_seconds() {
    local duration="$1"
    local hours=0 mins=0 secs=0
    if [[ "$duration" =~ ^([0-9]+):([0-9]+):([0-9]+)$ ]]; then
        hours="${BASH_REMATCH[1]}"
        mins="${BASH_REMATCH[2]}"
        secs="${BASH_REMATCH[3]}"
    elif [[ "$duration" =~ ^([0-9]+):([0-9]+)$ ]]; then
        mins="${BASH_REMATCH[1]}"
        secs="${BASH_REMATCH[2]}"
    elif [[ "$duration" =~ ^([0-9]+)$ ]]; then
        secs="${BASH_REMATCH[1]}"
    fi
    echo $((hours * 3600 + mins * 60 + secs))
}

# === ARGUMENT PARSING ===
URL=""
LANG="auto"
BACKGROUND=false
FACTCHECK="n"

while [[ $# -gt 0 ]]; do
    case $1 in
        -o|--output) OUTPUT_DIR="$2"; shift 2 ;;
        -l|--language) LANG="$2"; shift 2 ;;
        -b|--background) BACKGROUND=true; shift ;;
        --factcheck) FACTCHECK="$2"; shift 2 ;;
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

# Copy master cookies to temp (so yt-dlp doesn't overwrite the original)
if [[ -f "$COOKIES_MASTER" ]]; then
    cp "$COOKIES_MASTER" "$COOKIES_TMP"
else
    echo "Warning: No master cookies file found at $COOKIES_MASTER" >&2
fi

trap 'notify_error "Unbekannt" "Script abgebrochen"; rm -f "$COOKIES_TMP"; cleanup' ERR
trap 'rm -f "$COOKIES_TMP"; cleanup' EXIT

echo "=== YouTube Transcriber ===" >&2
echo "URL: $URL" >&2

# Get video info
echo "Fetching video info..." >&2
TITLE=$($YTDLP $YTDLP_OPTS --get-title "$URL" 2>/dev/null || echo "Unknown")
DURATION=$($YTDLP $YTDLP_OPTS --get-duration "$URL" 2>/dev/null || echo "?")
VIDEO_ID=$($YTDLP $YTDLP_OPTS --get-id "$URL" 2>/dev/null || echo "video")

echo "Title: $TITLE" >&2
echo "Duration: $DURATION" >&2

# === CHECKPOINT 1: Start ===
notify "🎬 <b>YouTube Transkription</b>
Titel: ${TITLE}
Dauer: ${DURATION}
Status: Download gestartet..."

# Download audio
echo "Downloading audio..." >&2
if ! $YTDLP $YTDLP_OPTS \
    -x --audio-format mp3 \
    -o "$TMP_DIR/audio.%(ext)s" "$URL" 2>/dev/null; then
    notify_error "Download" "yt-dlp fehlgeschlagen"
    exit 1
fi

DOWNLOADED=$(ls "$TMP_DIR"/audio.* 2>/dev/null | head -1)
if [[ -z "$DOWNLOADED" ]]; then
    notify_error "Download" "Keine Audio-Datei gefunden"
    exit 1
fi

# Convert to WAV for whisper
echo "Converting to WAV..." >&2
WAV_FILE="$TMP_DIR/audio.wav"
if ! ffmpeg -i "$DOWNLOADED" -ar 16000 -ac 1 -f wav "$WAV_FILE" -y 2>/dev/null; then
    notify_error "Konvertierung" "ffmpeg fehlgeschlagen"
    exit 1
fi

# === CHECKPOINT 2: Download fertig ===
EST_MINS=$(estimate_time "$DURATION")
notify "📥 Download fertig
Status: Starte Transkription...
Geschätzte Dauer: ~${EST_MINS} Min"

# Detect language if set to auto
echo "Detecting language..." >&2
if [[ "$LANG" == "auto" ]]; then
    DURATION_SECS=$(get_duration_seconds "$DURATION")
    DETECTED_LANG=$(detect_language "$WAV_FILE" "$DURATION_SECS")
    if [[ -n "$DETECTED_LANG" ]]; then
        echo "Detected language: $DETECTED_LANG" >&2
        LANG="$DETECTED_LANG"
    else
        echo "Could not detect language after 10 attempts, using auto" >&2
        # LANG stays "auto", whisper will try its best
    fi
fi

# Transcribe
echo "Transcribing with Whisper (language: $LANG)..." >&2
LANG_FLAG=""
if [[ "$LANG" != "auto" ]]; then
    LANG_FLAG="-l $LANG"
fi

# Generate output filename
SAFE_ID=$(echo "$VIDEO_ID" | tr -cd '[:alnum:]-_')
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
TRANSCRIPT_FILE="$OUTPUT_DIR/${TIMESTAMP}_${SAFE_ID}.txt"

# Create metadata header
{
    echo "# YouTube Transcript"
    echo "# Title: $TITLE"
    echo "# URL: $URL"
    echo "# Duration: $DURATION"
    echo "# Transcribed: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "# Language: $LANG"
    echo ""
    echo "---"
    echo ""
} > "$TRANSCRIPT_FILE"

# Run transcription and append to file
if ! "$WHISPER" -m "$WHISPER_MODEL" -f "$WAV_FILE" $LANG_FLAG --no-timestamps 2>/dev/null >> "$TRANSCRIPT_FILE"; then
    notify_error "Transkription" "Whisper fehlgeschlagen"
    exit 1
fi

echo "" >&2
echo "Saved transcript to: $TRANSCRIPT_FILE" >&2
echo "Done!" >&2

# === CHECKPOINT 3: Fertig (Telegram) ===
FACTCHECK_TEXT="Nein"
[[ "$FACTCHECK" == "y" ]] && FACTCHECK_TEXT="Ja"

notify "✅ <b>Transkription fertig</b>
Titel: ${TITLE}
Datei: ${TRANSCRIPT_FILE}
Faktencheck: ${FACTCHECK_TEXT}"

# === PING AGENT: Trigger automatic summary via one-shot cron job ===
if $BACKGROUND; then
    # Create a one-shot cron job that fires immediately
    /opt/homebrew/bin/openclaw cron add \
        --name "YouTube Summary" \
        --at "$(date -u -v+10S '+%Y-%m-%dT%H:%M:%SZ')" \
        --session isolated \
        --message "YOUTUBE_DONE|${TRANSCRIPT_FILE}|${FACTCHECK}|${TITLE} - Lies das Transkript, erstelle eine Zusammenfassung auf Deutsch, sende sie an Telegram (chat_id: 472279328), und lösche das Transkript." \
        --deliver \
        --channel telegram \
        --to "472279328" \
        --delete-after-run 2>/dev/null || ping_agent "YOUTUBE_DONE|${TRANSCRIPT_FILE}|${FACTCHECK}|${TITLE}"
fi

# Output file path for caller
echo "$TRANSCRIPT_FILE"
