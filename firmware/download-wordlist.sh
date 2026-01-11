#!/bin/bash
set -e

WORDLIST_URL="https://www.eff.org/files/2016/07/18/eff_large_wordlist.txt"
OUTPUT_FILE="$(dirname "$0")/mock-accel-wordlist.txt"

echo "Downloading EFF long wordlist..."
curl -L -o "$OUTPUT_FILE.tmp" "$WORDLIST_URL"

# Extract just the words (column 2)
awk '{print $2}' "$OUTPUT_FILE.tmp" > "$OUTPUT_FILE"
rm "$OUTPUT_FILE.tmp"

# Verify
WORD_COUNT=$(wc -l < "$OUTPUT_FILE")
if [ "$WORD_COUNT" -ne 7776 ]; then
    echo "ERROR: Expected 7776 words, got $WORD_COUNT"
    exit 1
fi

echo "✓ Downloaded $WORD_COUNT words to $OUTPUT_FILE"
