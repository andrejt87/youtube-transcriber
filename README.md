# YouTube Transcriber

CLI tool to download YouTube videos and transcribe them using whisper-cpp.

## Requirements

- [yt-dlp](https://github.com/yt-dlp/yt-dlp) - YouTube downloader
- [whisper-cpp](https://github.com/ggerganov/whisper.cpp) - Fast Whisper inference
- [ffmpeg](https://ffmpeg.org/) - Audio conversion

### macOS Installation

```bash
brew install yt-dlp whisper-cpp ffmpeg

# Download whisper model (medium recommended)
whisper-cpp-download-model medium
# Or manually: https://huggingface.co/ggerganov/whisper.cpp/tree/main
```

## Usage

```bash
# Basic usage - outputs transcript to stdout
./youtube-transcribe.sh "https://www.youtube.com/watch?v=VIDEO_ID"

# Save transcript to file
./youtube-transcribe.sh "https://youtube.com/watch?v=..." -o ./transcripts

# Force specific language
./youtube-transcribe.sh "https://youtube.com/watch?v=..." -l de

# Transcript only (no VTT timestamps)
./youtube-transcribe.sh "https://youtube.com/watch?v=..." -t
```

## Options

| Flag | Description |
|------|-------------|
| `-o, --output DIR` | Output directory for transcript files |
| `-l, --language LANG` | Force language (e.g., `en`, `de`, `ru`) |
| `-t, --transcript` | Output plain transcript (no timestamps) |
| `-h, --help` | Show help |

## Environment Variables

Override default paths:

```bash
export YTDLP="/path/to/yt-dlp"
export WHISPER="/path/to/whisper-cli"
export WHISPER_MODEL="$HOME/.whisper/ggml-large.bin"
```

## How It Works

1. Downloads audio from YouTube using yt-dlp (Android client to bypass restrictions)
2. Converts to 16kHz mono WAV (whisper requirement)
3. Transcribes using whisper-cpp with specified model
4. Outputs transcript to stdout and/or file

## License

MIT
