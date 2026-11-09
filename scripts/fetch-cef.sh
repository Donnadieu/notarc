#!/bin/bash
# Downloads and links the pinned CEF "Standard Distribution" build for macOS
# ARM64 (see README.md's "Current pin"), so the CEF version is locked by a
# script instead of a human following README text by hand. Safe to re-run:
# skips the download if third_party/cef already points at this version, and
# verifies the download's SHA-1 against the one published in CEF's own
# build index before unpacking.
set -eu
cd "$(git rev-parse --show-toplevel)"

CEF_VERSION="156.0.7+g47dbc1d+chromium-156.0.8078.17"
CEF_SHA1="b7520ed38685059e02a76c9039632c07a8925ce0"
CEF_ARCHIVE="cef_binary_${CEF_VERSION}_macosarm64.tar.bz2"
CEF_URL="https://cef-builds.spotifycdn.com/${CEF_ARCHIVE}"
CEF_DIR_NAME="cef_binary_${CEF_VERSION}_macosarm64"

mkdir -p third_party/std

if [ -L third_party/cef ] && [ "$(readlink third_party/cef)" = "std/${CEF_DIR_NAME}" ] && [ -d "third_party/std/${CEF_DIR_NAME}" ]; then
  echo "third_party/cef already linked to ${CEF_DIR_NAME}"
  exit 0
fi

ARCHIVE_PATH="third_party/std/${CEF_ARCHIVE}"
if [ ! -f "$ARCHIVE_PATH" ]; then
  echo "Downloading ${CEF_ARCHIVE} (pinned CEF ${CEF_VERSION})..."
  curl -fL -o "$ARCHIVE_PATH" "$CEF_URL"
fi

ACTUAL_SHA1=$(shasum -a 1 "$ARCHIVE_PATH" | awk '{print $1}')
if [ "$ACTUAL_SHA1" != "$CEF_SHA1" ]; then
  echo "FIX: ${CEF_ARCHIVE} sha1 was $ACTUAL_SHA1, expected $CEF_SHA1. Delete $ARCHIVE_PATH and re-run, or update" \
       "CEF_VERSION/CEF_SHA1 in this script if you're intentionally bumping the CEF pin (also update README.md)." >&2
  rm -f "$ARCHIVE_PATH"
  exit 1
fi

echo "Extracting ${CEF_ARCHIVE}..."
tar -xjf "$ARCHIVE_PATH" -C third_party/std
ln -sfn "std/${CEF_DIR_NAME}" third_party/cef
echo "third_party/cef -> std/${CEF_DIR_NAME}"
