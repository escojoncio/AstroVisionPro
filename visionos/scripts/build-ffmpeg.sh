#!/usr/bin/env bash
# FFmpeg for visionOS: the emulator decodes the console's audio and video with it (AAC, ATRAC9,
# MP3, H.264, ...). The other builds download shadPS4's prebuilt FFmpeg (externals/ffmpeg-core),
# which exists for macOS but not for visionOS; this builds the same version (FFmpeg 7.1, the one
# whose headers ffmpeg-core carries) with the same set of decoders, demuxers and parsers
# (ffmpeg-core/ffmpeg.patch).
#
# Output: build/visionos/ffmpeg (include/ and lib/).
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
VERSION="${FFMPEG_VERSION:-n7.1.1}"
SRC="$ROOT/build/visionos/ffmpeg-src"
OUT="$ROOT/build/visionos/ffmpeg"
DEPLOYMENT_TARGET="${VISIONOS_DEPLOYMENT_TARGET:-26.0}"

if [[ -f "$OUT/lib/libavcodec.a" && -f "$OUT/VERSION" && $(cat "$OUT/VERSION") == "$VERSION" ]]; then
  echo "FFmpeg $VERSION for visionOS is already built"
  exit 0
fi

if [[ ! -d "$SRC/.git" ]]; then
  git clone -q --depth 1 --branch "$VERSION" https://github.com/FFmpeg/FFmpeg.git "$SRC"
fi

SDK=$(xcrun --sdk xros --show-sdk-path)
CC="$(xcrun --sdk xros --find clang)"
FLAGS="-arch arm64 -isysroot $SDK -target arm64-apple-xros$DEPLOYMENT_TARGET"

BUILD="$SRC/build-xros"
rm -rf "$BUILD" "$OUT"
mkdir -p "$BUILD"
cd "$BUILD"
../configure \
  --prefix="$OUT" \
  --enable-cross-compile --target-os=darwin --arch=aarch64 \
  --cc="$CC" --cxx="$(xcrun --sdk xros --find clang++)" --as="$CC" \
  --sysroot="$SDK" \
  --extra-cflags="$FLAGS" --extra-ldflags="$FLAGS" \
  --enable-static --disable-shared --enable-pic \
  --disable-programs --disable-doc --disable-debug --disable-autodetect \
  --disable-avdevice --disable-network \
  --disable-everything \
  --enable-decoder=aac --enable-decoder=aac_latm --enable-decoder=atrac3 --enable-decoder=atrac3p \
  --enable-decoder=atrac9 --enable-decoder=mp3 --enable-decoder=pcm_s16le --enable-decoder=pcm_s8 \
  --enable-decoder=h264 --enable-decoder=mpeg4 --enable-decoder=mpeg2video \
  --enable-decoder=mjpeg --enable-decoder=mjpegb --enable-decoder=hevc \
  --enable-encoder=pcm_s16le --enable-encoder=ffv1 --enable-encoder=mpeg4 \
  --enable-encoder=ljpeg --enable-encoder=mjpeg \
  --enable-muxer=avi \
  --enable-demuxer=h265 --enable-demuxer=h264 --enable-demuxer=m4v --enable-demuxer=mp3 \
  --enable-demuxer=mpegvideo --enable-demuxer=mpegps --enable-demuxer=mjpeg --enable-demuxer=mov \
  --enable-demuxer=avi --enable-demuxer=aac --enable-demuxer=pmp --enable-demuxer=oma \
  --enable-demuxer=pcm_s16le --enable-demuxer=pcm_s8 --enable-demuxer=wav \
  --enable-parser=h264 --enable-parser=mpeg4video --enable-parser=mpegaudio \
  --enable-parser=mpegvideo --enable-parser=mjpeg --enable-parser=aac --enable-parser=aac_latm \
  --enable-protocol=file --enable-bsf=mjpeg2jpeg \
  --enable-swscale --enable-swresample --enable-avfilter \
  || { tail -n 80 ffbuild/config.log; exit 1; }
make -j"$(sysctl -n hw.ncpu)"
make install
echo "$VERSION" > "$OUT/VERSION"
ls -la "$OUT/lib"
