#!/usr/bin/env bash
# bundle-deps.sh — copy ffmpeg/ffprobe/whisper-cli + the Whisper model INTO a
# .app bundle and rewrite their dylib links so the app is self-contained
# (no Homebrew required on the target machine).
#
# Usage: bundle-deps.sh /path/to/Clip\ Editor.app
# Requires: dylibbundler (brew install dylibbundler), and ffmpeg/ffprobe/whisper-cli
#           + the model present on THIS (build) machine.

set -euo pipefail
APP="${1:?usage: bundle-deps.sh <App.app>}"
HELP="$APP/Contents/Helpers"
FW="$APP/Contents/Frameworks"
RES="$APP/Contents/Resources"
mkdir -p "$HELP" "$FW" "$RES"

command -v dylibbundler >/dev/null || { echo "Need dylibbundler: brew install dylibbundler" >&2; exit 1; }

copy_tool() {  # name
  local src; src="$(command -v "$1")" || { echo "missing tool: $1" >&2; exit 1; }
  # resolve symlinks (e.g. whisper-cli -> Cellar)
  src="$(python3 -c "import os,sys;print(os.path.realpath(sys.argv[1]))" "$src")"
  cp -f "$src" "$HELP/$1"; chmod u+w "$HELP/$1"
}
echo "==> copying tools into $HELP"
copy_tool ffmpeg; copy_tool ffprobe; copy_tool whisper-cli

echo "==> bundling dylibs into $FW (recursive, with @rpath fix-ups)"
# Search paths so dylibbundler can resolve whisper/ggml's @rpath libs (else it
# prompts and hangs). Harmless if a path doesn't exist.
SEARCH=()
for d in "$(brew --prefix whisper-cpp 2>/dev/null)/lib" "$(brew --prefix ggml 2>/dev/null)/lib" \
         "/opt/homebrew/lib" "/usr/local/lib"; do
  [ -d "$d" ] && SEARCH+=(-s "$d")
done
for bin in ffmpeg ffprobe whisper-cli; do
  # </dev/null guards against any residual interactive prompt.
  dylibbundler -of -cd -b -x "$HELP/$bin" -d "$FW" -p "@executable_path/../Frameworks/" "${SEARCH[@]}" </dev/null
done

echo "==> bundling ggml runtime backend plugins (.so, dlopen'd by whisper)"
# These provide the CPU/Metal/BLAS compute backends. ggml auto-discovers them in
# the directory of the running executable — so they go in Helpers/ next to
# whisper-cli (their dylib deps still point at ../Frameworks). This works with no
# env vars and with no Homebrew on the target machine.
GGEXE="$(brew --prefix ggml 2>/dev/null)/libexec"
if [ -d "$GGEXE" ]; then
  for so in "$GGEXE"/libggml-*.so; do
    [ -e "$so" ] || continue
    bn="$(basename "$so")"; cp -f "$so" "$HELP/$bn"; chmod u+w "$HELP/$bn"
    dylibbundler -of -b -x "$HELP/$bn" -d "$FW" -p "@executable_path/../Frameworks/" "${SEARCH[@]}" </dev/null
  done
else
  echo "WARNING: ggml libexec not found; transcription may lack a compute backend on other Macs." >&2
fi

# Some backends pull in extra libs (e.g. libomp for the CPU backend) that get
# referenced but not copied. Make sure every @executable_path/../Frameworks dep
# actually exists in the bundle; copy any missing one from Homebrew.
echo "==> resolving any missing referenced libs"
for pass in 1 2 3; do
  for f in "$FW"/*.dylib "$FW"/*.so "$HELP"/*; do
    [ -e "$f" ] || continue
    while IFS= read -r dep; do
      bn="$(basename "$dep")"
      [ -e "$FW/$bn" ] && continue
      src="$(find /opt/homebrew/opt /opt/homebrew/lib -name "$bn" 2>/dev/null | head -1)"
      if [ -n "$src" ]; then
        cp -f "$src" "$FW/$bn"; chmod u+w "$FW/$bn"
        install_name_tool -id "@executable_path/../Frameworks/$bn" "$FW/$bn" 2>/dev/null || true
        dylibbundler -of -b -x "$FW/$bn" -d "$FW" -p "@executable_path/../Frameworks/" "${SEARCH[@]}" </dev/null || true
        echo "  + bundled missing $bn"
      fi
    done < <(otool -L "$f" 2>/dev/null | awk 'NR>1{print $1}' | grep "@executable_path/../Frameworks/")
  done
done

echo "==> copying Whisper model into $RES"
MODEL="${MODEL_PATH:-$HOME/.hermes/skills/media/ffmpeg/models/ggml-base.en.bin}"
[ -s "$MODEL" ] || { echo "model not found at $MODEL (run scripts/fetch-model.sh)" >&2; exit 1; }
cp -f "$MODEL" "$RES/ggml-base.en.bin"

echo "==> verify: no Homebrew paths remain in bundled binaries"
if otool -L "$HELP/ffmpeg" "$HELP/whisper-cli" "$FW"/*.dylib 2>/dev/null | grep -E "/opt/homebrew|/usr/local/Cellar"; then
  echo "WARNING: some links still point at Homebrew (above)." >&2
else
  echo "OK — fully relocated to @executable_path/../Frameworks"
fi
echo "==> done bundling into $APP"
