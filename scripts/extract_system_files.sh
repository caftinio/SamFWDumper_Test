#!/bin/bash
# =============================================================================
# SamFWDumper - Automated Samsung Firmware Extraction
# Copyright (C) 2026 Xiatsuma
# Licensed under PolyForm Noncommercial License 1.0.0
# https://polyformproject.org/licenses/noncommercial/1.0.0
#
# You may NOT use this file except in compliance with the License.
# Commercial use, removal of this header, or distribution without attribution
# is strictly prohibited. For permissions: https://github.com/Xiatsuma
# =============================================================================
set -e

echo "═══════════════════════════════════════"
echo "   Samsung System Files Extractor"
echo "═══════════════════════════════════════"

URL="$1"
COMPRESSION_LEVEL="${2:-0}"
WANT_APP="${3:-false}"
WANT_BIN="${4:-false}"
WANT_CAMERADATA="${5:-false}"
WANT_ETC="${6:-false}"
WANT_LIB="${7:-false}"
WANT_LIB64="${8:-false}"
WANT_MEDIA="${9:-false}"
WANT_PRIV_APP="${10:-false}"
WANT_SAIV="${11:-false}"
WANT_BUILD_PROP="${12:-false}"
WANT_FRAMEWORK_RRO="${13:-false}"
WANT_PIT="${14:-false}"
WANT_WALLPAPER_RES="${15:-false}"

chmod +x tools/android-tools/* tools/erofs-utils/* 2>/dev/null || true

case "$COMPRESSION_LEVEL" in
  0) XZ_FLAGS="-0" ;;
  3) XZ_FLAGS="-3" ;;
  6) XZ_FLAGS="-6" ;;
  9) XZ_FLAGS="-9" ;;
  *) XZ_FLAGS="-0" ;;
esac

TARGETS=""
[ "$WANT_APP" = "true" ] && TARGETS="$TARGETS app"
[ "$WANT_BIN" = "true" ] && TARGETS="$TARGETS bin"
[ "$WANT_CAMERADATA" = "true" ] && TARGETS="$TARGETS cameradata"
[ "$WANT_ETC" = "true" ] && TARGETS="$TARGETS etc"
[ "$WANT_LIB" = "true" ] && TARGETS="$TARGETS lib"
[ "$WANT_LIB64" = "true" ] && TARGETS="$TARGETS lib64"
[ "$WANT_MEDIA" = "true" ] && TARGETS="$TARGETS media"
[ "$WANT_PRIV_APP" = "true" ] && TARGETS="$TARGETS priv-app"
[ "$WANT_SAIV" = "true" ] && TARGETS="$TARGETS saiv"
[ "$WANT_BUILD_PROP" = "true" ] && TARGETS="$TARGETS build.prop"
TARGETS="${TARGETS# }"

if [ -z "$TARGETS" ] && [ "$WANT_FRAMEWORK_RRO" != "true" ] && [ "$WANT_PIT" != "true" ] && [ "$WANT_WALLPAPER_RES" != "true" ]; then
  echo "❌ No targets selected!"
  exit 1
fi

echo "Compression level: $COMPRESSION_LEVEL"
echo "Files to extract:"
for T in $TARGETS; do
  echo "- $T"
done
echo ""

detect_fs_type() {
  local IMG="$1"
  local FS_TYPE=""
  FS_TYPE=$(blkid -o value -s TYPE "$IMG" 2>/dev/null)
  if [ -z "$FS_TYPE" ]; then
    local FILE_OUTPUT=$(file "$IMG" 2>/dev/null)
    if echo "$FILE_OUTPUT" | grep -qi "f2fs"; then
      FS_TYPE="f2fs"
    elif echo "$FILE_OUTPUT" | grep -qi "erofs"; then
      FS_TYPE="erofs"
    elif echo "$FILE_OUTPUT" | grep -qi "ext4\|ext3\|ext2"; then
      FS_TYPE="ext4"
    elif echo "$FILE_OUTPUT" | grep -qi "android sparse"; then
      FS_TYPE="sparse"
    fi
  fi
  if [ -z "$FS_TYPE" ]; then
    local MAGIC=$(xxd -l 4 -p "$IMG" 2>/dev/null)
    case "$MAGIC" in
      1020f5f2) FS_TYPE="f2fs" ;;
      e2e1f5e0) FS_TYPE="erofs" ;;
      53ef*)    FS_TYPE="ext4" ;;
      3aff*)    FS_TYPE="sparse" ;;
    esac
  fi
  echo "$FS_TYPE"
}

extract_f2fs() {
  local IMG="$1" OUT_DIR="$2" TARGETS="$3" SINGLE_FILES="$4"
  sudo modprobe f2fs 2>/dev/null || true
  local MNT="/tmp/f2fs_mount_$$"
  mkdir -p "$MNT"
  if ! sudo mount -t f2fs -o ro,loop "$IMG" "$MNT" 2>/dev/null; then
    echo "  ❌ f2fs mount failed"
    rm -rf "$MNT"
    return 1
  fi
  echo "  ✓ Mounted f2fs successfully"
  for TARGET in $TARGETS; do
    IS_FILE=false
    for SF in $SINGLE_FILES; do
      [ "$TARGET" = "$SF" ] && IS_FILE=true && break
    done
    if $IS_FILE; then
      BEST_SRC=""
      BEST_SIZE=0
      for SRC_PATH in "$MNT/$TARGET" "$MNT/system/$TARGET"; do
        if sudo test -f "$SRC_PATH" 2>/dev/null; then
          local SZ=$(sudo stat -c%s "$SRC_PATH" 2>/dev/null || echo 0)
          if [ "${SZ:-0}" -gt "$BEST_SIZE" ]; then
            BEST_SIZE=$SZ
            BEST_SRC="$SRC_PATH"
          fi
        fi
      done
      if [ -n "$BEST_SRC" ]; then
        mkdir -p "$OUT_DIR/$(dirname "$TARGET")"
        sudo cp "$BEST_SRC" "$OUT_DIR/$TARGET"
        sudo chown $(id -u):$(id -g) "$OUT_DIR/$TARGET"
        echo "    - $TARGET ($(numfmt --to=iec $BEST_SIZE))"
      else
        echo "  ⚠️ $TARGET not found"
      fi
    else
      BEST_SRC=""
      BEST_SIZE=0
      local DEST="$OUT_DIR/$(dirname "$TARGET")"
      mkdir -p "$DEST"
      for SRC_PATH in "$MNT/$TARGET" "$MNT/system/$TARGET"; do
        if sudo test -d "$SRC_PATH" 2>/dev/null; then
          local SZ=$(sudo du -sb "$SRC_PATH" 2>/dev/null | cut -f1 || echo 0)
          if [ "${SZ:-0}" -gt "$BEST_SIZE" ]; then
            BEST_SIZE=$SZ
            BEST_SRC="$SRC_PATH"
          fi
        fi
      done
      if [ -n "$BEST_SRC" ]; then
        sudo cp -r "$BEST_SRC" "$DEST/" 2>/dev/null
        sudo chown -R $(id -u):$(id -g) "$DEST/$(basename "$TARGET")"
        echo "    - $TARGET ($(numfmt --to=iec $BEST_SIZE))"
      else
        echo "  ⚠️ $TARGET not found"
      fi
    fi
  done
  sudo umount "$MNT"
  rm -rf "$MNT"
  return 0
}

echo "[1/10] Downloading..."
START_TS=$(date +%s)
wget -q --no-check-certificate --content-disposition "$URL"
ZIP_FILE=$(ls -t *.zip 2>/dev/null | head -1)
[ ! -f "$ZIP_FILE" ] && { echo "❌ Download failed"; exit 1; }
FILESIZE=$(stat -c%s "$ZIP_FILE")
[ "$FILESIZE" -eq 0 ] && { echo "❌ Empty file"; exit 1; }
END_TS=$(date +%s)
ELAPSED=$(( END_TS - START_TS ))
[ "$ELAPSED" -lt 1 ] && ELAPSED=1
SPEED_MB=$(( FILESIZE / ELAPSED / 1048576 ))
STAMP=$(date -d "@$END_TS" '+%Y-%m-%d | %H:%M:%S')
SIZE_HUMAN=$(numfmt --to=iec "$FILESIZE")
echo "✓ Downloaded: $ZIP_FILE"
echo "  $SIZE_HUMAN | $STAMP | ${SPEED_MB} MB/s"

CSC_CODE=$(echo "$ZIP_FILE" | sed 's/\.zip$//' | tr '_' '\n' | grep -E '^[A-Z]{3}$' | grep -v -E '^(COM|SAM|FAC)$' | head -1)
AP_CODE=$(echo "$ZIP_FILE" | sed 's/\.zip$//' | tr '_' '\n' | grep -E '^[A-Z][A-Z0-9]{11,}$' | head -1)
echo "$CSC_CODE" > csc_code.txt
echo "$AP_CODE" > ap_code.txt
echo "Firmware: $AP_CODE | CSC: $CSC_CODE"

echo ""
echo "[2/10] Extracting ZIP..."
unzip -o "$ZIP_FILE" >/dev/null 2>&1
rm -f "$ZIP_FILE"
echo "✓ Done"

mkdir -p output

echo ""
echo "[3/10] Extracting PIT from CSC..."
if [ "$WANT_PIT" = "true" ]; then
  CSC_FILE=$(find . -maxdepth 1 -name "CSC_*.tar.md5" -o -name "CSC_*.tar" | head -n 1)
  if [ -z "$CSC_FILE" ]; then
    echo "  ⚠️ CSC tar not found"
  else
    PIT_FILE=$(tar -tf "$CSC_FILE" 2>/dev/null | grep -i "\.pit$" | head -n 1)
    if [ -z "$PIT_FILE" ]; then
      echo "  ⚠️ No .pit file inside CSC"
    else
      tar -xf "$CSC_FILE" "$PIT_FILE" 2>/dev/null
      cp "$PIT_FILE" "output/$(basename "$PIT_FILE")" 2>/dev/null && echo "    - $(basename "$PIT_FILE")" || echo "  ⚠️ Extraction failed"
    fi
  fi
else
  echo "  - skipped"
fi

echo ""
echo "[4/10] Extracting AP..."
AP_FILE=$(find . -name "AP_*.tar.md5" -o -name "AP_*.tar" | head -n 1)
[ -z "$AP_FILE" ] && { echo "❌ AP file not found"; exit 1; }
echo "  Extracting: $(basename "$AP_FILE")"
tar -xf "$AP_FILE" >/dev/null 2>&1
echo "  Contents:"
for file in *.img *.img.lz4; do
  [ -f "$file" ] && echo "    $file"
done
rm -f "$AP_FILE"
echo "✓ Done"

echo ""
echo "[5/10] Extracting super.img..."
SUPER_FILE=$(find . -maxdepth 1 -name "super.img*" -o -name "super.img" | head -n 1)

SYSTEM_IMG=""
SYSTEM_FS=""
PRODUCT_IMG=""
PRODUCT_FS=""

if [ -n "$SUPER_FILE" ]; then
  echo "  File: $(basename "$SUPER_FILE")"

  if [[ "$SUPER_FILE" == *.lz4 ]]; then
    lz4 -d "$SUPER_FILE" "super.img" 2>/dev/null
    SUPER_FILE="super.img"
  fi

  SUPER_FS=$(detect_fs_type "$SUPER_FILE")

  if [ "$SUPER_FS" = "sparse" ]; then
    simg2img "$SUPER_FILE" "super.raw.img" 2>/dev/null || tools/android-tools/simg2img "$SUPER_FILE" "super.raw.img"
    SUPER_FILE="super.raw.img"
    SUPER_FS=$(detect_fs_type "$SUPER_FILE")
  fi

  echo "  Format: sparse → raw → erofs"

  mkdir -p super_dump
  tools/android-tools/lpunpack "$SUPER_FILE" super_dump >/dev/null 2>&1 || { echo "  ❌ lpunpack failed"; exit 1; }

  echo "  Partitions:"
  for img in super_dump/*.img; do
    [ -f "$img" ] || continue
    PART_NAME=$(basename "$img" .img)
    PART_FS=$(detect_fs_type "$img")
    PART_SIZE=$(numfmt --to=iec $(stat -c%s "$img") 2>/dev/null || echo "?")
    printf "    - %-14s %-6s %s\n" "$PART_NAME" "$PART_FS" "$PART_SIZE"

    case "$PART_NAME" in
      system|system_a|system_b) SYSTEM_IMG="$img"; SYSTEM_FS="$PART_FS" ;;
      product|product_a|product_b) PRODUCT_IMG="$img"; PRODUCT_FS="$PART_FS" ;;
    esac
  done

  [ -n "$SYSTEM_IMG" ] && [ -n "$PRODUCT_IMG" ] && echo "  Using: $(basename "$SYSTEM_IMG") ($SYSTEM_FS), $(basename "$PRODUCT_IMG") ($PRODUCT_FS)"
else
  echo "  - no super.img (legacy device)"

  SYSTEM_IMG=$(find . -maxdepth 1 -name "system.img.lz4" -o -name "system.img" | head -n 1)
  if [ -n "$SYSTEM_IMG" ]; then
    if [[ "$SYSTEM_IMG" == *.lz4 ]]; then
      lz4 -d "$SYSTEM_IMG" "system_raw.img" 2>/dev/null
      SYSTEM_IMG="system_raw.img"
    fi
    SYSTEM_FS=$(detect_fs_type "$SYSTEM_IMG")
    if [ "$SYSTEM_FS" = "sparse" ]; then
      simg2img "$SYSTEM_IMG" "system_unsparse.img" 2>/dev/null
      SYSTEM_IMG="system_unsparse.img"
      SYSTEM_FS=$(detect_fs_type "$SYSTEM_IMG")
    fi
  fi

  PRODUCT_IMG=$(find . -maxdepth 1 -name "product.img.lz4" -o -name "product.img" | head -n 1)
  if [ -n "$PRODUCT_IMG" ]; then
    if [[ "$PRODUCT_IMG" == *.lz4 ]]; then
      lz4 -d "$PRODUCT_IMG" "product_raw.img" 2>/dev/null
      PRODUCT_IMG="product_raw.img"
    fi
    PRODUCT_FS=$(detect_fs_type "$PRODUCT_IMG")
    if [ "$PRODUCT_FS" = "sparse" ]; then
      simg2img "$PRODUCT_IMG" "product_unsparse.img" 2>/dev/null
      PRODUCT_IMG="product_unsparse.img"
      PRODUCT_FS=$(detect_fs_type "$PRODUCT_IMG")
    fi
  fi
fi
echo "✓ Done"

echo ""
echo "[6/10] Extracting framework RRO APK..."
if [ "$WANT_FRAMEWORK_RRO" = "true" ]; then
  if [ -z "$PRODUCT_IMG" ] || [ ! -f "$PRODUCT_IMG" ]; then
    echo "  ⚠️ product.img not found"
  else
    mkdir -p product_extracted
    RRO_FOUND=false

    if [ "$PRODUCT_FS" = "f2fs" ]; then
      sudo modprobe f2fs 2>/dev/null || true
      PROD_MNT="/tmp/product_f2fs_$$"
      mkdir -p "$PROD_MNT"
      if sudo mount -t f2fs -o ro,loop "$PRODUCT_IMG" "$PROD_MNT" 2>/dev/null; then
        APK_SRC=$(sudo find "$PROD_MNT" \( -name "framework-res__*__auto_generated_rro_product.apk" -o -name "framework-res__auto_generated_rro_product.apk" \) 2>/dev/null | head -n 1)
        if [ -n "$APK_SRC" ]; then
          sudo cp "$APK_SRC" "output/$(basename "$APK_SRC")"
          sudo chown $(id -u):$(id -g) "output/$(basename "$APK_SRC")"
          echo "    - $(basename "$APK_SRC")"
          RRO_FOUND=true
        fi
        sudo umount "$PROD_MNT"
        rm -rf "$PROD_MNT"
      fi
    elif [ "$PRODUCT_FS" = "erofs" ]; then
      tools/erofs-utils/extract.erofs -i "$PRODUCT_IMG" -x -o product_extracted/ >/dev/null 2>&1
    else
      for SRC_PATH in "product/overlay" "overlay"; do
        if debugfs -R "ls $SRC_PATH" "$PRODUCT_IMG" 2>/dev/null | grep -q .; then
          mkdir -p "product_extracted/overlay"
          debugfs -R "rdump $SRC_PATH product_extracted/overlay" "$PRODUCT_IMG" 2>/dev/null
          break
        fi
      done
    fi

    if [ "$PRODUCT_FS" != "f2fs" ]; then
      for BASE in \
        "product_extracted/product_a/product/overlay" \
        "product_extracted/product_a/overlay" \
        "product_extracted/product_b/product/overlay" \
        "product_extracted/product_b/overlay" \
        "product_extracted/product/overlay" \
        "product_extracted/overlay" \
        "product_extracted/system/product/overlay" \
        "product_extracted"; do
        APK_SRC=$(find "$BASE" -maxdepth 3 \( -name "framework-res__*__auto_generated_rro_product.apk" -o -name "framework-res__auto_generated_rro_product.apk" \) 2>/dev/null | head -n 1)
        if [ -n "$APK_SRC" ]; then
          cp "$APK_SRC" "output/$(basename "$APK_SRC")"
          echo "    - $(basename "$APK_SRC")"
          RRO_FOUND=true
          break
        fi
      done
    fi
    $RRO_FOUND || echo "  ⚠️ framework-res RRO APK not found"
    rm -rf product_extracted
  fi
else
  echo "  - skipped"
fi

echo ""
echo "[7/10] Extracting system.img contents..."
if [ -z "$TARGETS" ] && [ "$WANT_WALLPAPER_RES" != "true" ]; then
  echo "  - no system targets (skipped)"
else
  [ -z "$SYSTEM_IMG" ] || [ ! -f "$SYSTEM_IMG" ] && { echo "❌ system.img not found"; exit 1; }
  mkdir -p system_extracted

  SINGLE_FILES="build.prop floating_features.xml"

  if [ "$SYSTEM_FS" = "f2fs" ]; then
    ALL_TARGETS="$TARGETS"
    [ "$WANT_WALLPAPER_RES" = "true" ] && ALL_TARGETS="$ALL_TARGETS priv-app/wallpaper-res"
    extract_f2fs "$SYSTEM_IMG" "system_extracted" "$ALL_TARGETS" "$SINGLE_FILES" || true
  elif [ "$SYSTEM_FS" = "erofs" ]; then
    tools/erofs-utils/extract.erofs -i "$SYSTEM_IMG" -x -o system_extracted/ >/dev/null 2>&1 || {
      echo "  ❌ erofs extraction failed"
      exit 1
    }
  else
    DEBUGFS_TARGETS="$TARGETS"
    [ "$WANT_WALLPAPER_RES" = "true" ] && DEBUGFS_TARGETS="$DEBUGFS_TARGETS priv-app/wallpaper-res"

    for TARGET in $DEBUGFS_TARGETS; do
      IS_FILE=false
      for SF in $SINGLE_FILES; do
        [ "$TARGET" = "$SF" ] && IS_FILE=true && break
      done
      if $IS_FILE; then
        FOUND=false
        for SRC_PATH in "system/$TARGET" "$TARGET"; do
          if debugfs -R "stat $SRC_PATH" "$SYSTEM_IMG" 2>/dev/null | grep -q "Type: regular"; then
            debugfs -R "dump $SRC_PATH system_extracted/$TARGET" "$SYSTEM_IMG" 2>/dev/null
            FOUND=true
            break
          fi
        done
        $FOUND || echo "  ⚠️ $TARGET not found"
      else
        FOUND=false
        DEST_PARENT="system_extracted/$(dirname "$TARGET")"
        mkdir -p "$DEST_PARENT"
        for SRC_PATH in "system/$TARGET" "$TARGET"; do
          if debugfs -R "ls $SRC_PATH" "$SYSTEM_IMG" 2>/dev/null | grep -q .; then
            debugfs -R "rdump $SRC_PATH $DEST_PARENT" "$SYSTEM_IMG" 2>/dev/null
            FOUND=true
            break
          fi
        done
        $FOUND || echo "  ⚠️ $TARGET not found"
      fi
    done
  fi
  echo "✓ Done"
fi

echo ""
echo "[8/10] Copying selected targets..."

if [ "$WANT_WALLPAPER_RES" = "true" ]; then
  APK_FOUND=false
  for BASE in \
    "system_extracted/priv-app/wallpaper-res" \
    "system_extracted/system/priv-app/wallpaper-res" \
    "system_extracted/system_a/priv-app/wallpaper-res" \
    "system_extracted/system_b/priv-app/wallpaper-res" \
    "system_extracted/system/system/priv-app/wallpaper-res" \
    "system_extracted/system_a/system/priv-app/wallpaper-res" \
    "system_extracted/system_b/system/priv-app/wallpaper-res"; do
    APK_SRC="$BASE/wallpaper-res.apk"
    if [ -f "$APK_SRC" ]; then
      cp "$APK_SRC" "output/wallpaper-res.apk"
      echo "    - wallpaper-res.apk"
      APK_FOUND=true
      break
    fi
  done
  $APK_FOUND || echo "  ⚠️ wallpaper-res.apk not found"
fi

for TARGET in $TARGETS; do
  if [ -e "system_extracted/$TARGET" ]; then
    cp -r "system_extracted/$TARGET" "output/"
    echo "    - $TARGET"
    continue
  fi
  for BASE in \
    "system_extracted/system" \
    "system_extracted/system_a" \
    "system_extracted/system_b" \
    "system_extracted/system/system" \
    "system_extracted/system_a/system" \
    "system_extracted/system_b/system" \
    "system_extracted"; do
    SRC="$BASE/$TARGET"
    if [ -e "$SRC" ]; then
      cp -r "$SRC" "output/"
      echo "    - $TARGET"
      break
    fi
  done
  [ ! -e "output/$TARGET" ] && echo "  ⚠️ Not found: $TARGET"
done

rm -rf system_extracted
rm -rf super_dump super.img super.raw.img system_unsparse.img product_raw.img product_unsparse.img system_raw.img
echo "✓ Done"

echo ""
echo "[9/10] Compressing targets..."
mkdir -p compression_room
for ITEM in output/*; do
  [ -e "$ITEM" ] || continue
  NAME=$(basename "$ITEM")
  if [ -d "$ITEM" ]; then
    if [ "$COMPRESSION_LEVEL" != "0" ]; then
      tar -cf - -C output "$NAME" | xz $XZ_FLAGS -T0 2>/dev/null > "compression_room/${NAME}.tar.xz" && rm -rf "$ITEM"
      echo "    - ${NAME}.tar.xz"
    else
      tar -cf "compression_room/${NAME}.tar" -C output "$NAME" && rm -rf "$ITEM"
      echo "    - ${NAME}.tar"
    fi
  elif [ -f "$ITEM" ] && [ "$COMPRESSION_LEVEL" != "0" ] && [[ "$ITEM" != *.xz ]]; then
    xz $XZ_FLAGS -T0 "$ITEM" 2>/dev/null && mv "${ITEM}.xz" "compression_room/${NAME}.xz" && echo "    - ${NAME}.xz"
  else
    mv "$ITEM" "compression_room/${NAME}"
    echo "    - ${NAME}"
  fi
done
echo "✓ Done"

echo ""
echo "[10/10] Saving to output/..."
COUNT=0
for FILE in compression_room/*; do
  [ -e "$FILE" ] || continue
  mv "$FILE" "output/"
  COUNT=$((COUNT + 1))
done
rm -rf compression_room
echo "    - $COUNT items"
echo "✓ Done"

echo ""
echo "═══════════════════════════════════════"
FILE_COUNT=$(ls -1 output 2>/dev/null | wc -l)
[ "$FILE_COUNT" -eq 0 ] && { echo "❌ Nothing extracted!"; exit 1; }
TOTAL_SIZE=$(du -sh output | cut -f1)
echo "✓ Extracted $FILE_COUNT items"
echo "Total size: $TOTAL_SIZE"
echo ""
echo "Files:"
ls -lh output
echo "═══════════════════════════════════════"
echo "✓ Done!"
