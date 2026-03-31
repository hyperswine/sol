# Network download with progress bar

echo "=== Downloading Files with Progress ===".
echo "".

# Download without progress (fast, no bar)
echo "1. Quick download (no progress bar):".
content1 = wget "https://api.github.com/zen".
echo "Got: {content1}".
echo "".

# Download with progress bar (shows download progress)
echo "2. Download with progress bar:".
content2 = wget "https://api.github.com/zen" 1.
echo "Got: {content2}".
echo "".

echo "=== Download Complete ===".
