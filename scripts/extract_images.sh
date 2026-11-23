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
echo "   Samsung Images Extractor"
echo "═══════════════════════════════════════"

URL="$1"
COMPRESSION_LEVEL="${2:-6}"
SELECTED_PARTITIONS="$3"

[ -z "$URL" ] && { echo "❌ No URL"; exit 1; }
[ -z "$SELECTED_PARTITIONS" ] && { echo "❌ No partitions selected"; exit 1; }

case "$COMPRESSION_LEVEL" in
  0) XZ_FLAGS="-0" ;;
  3) XZ_FLAGS="-3" ;;
  6) XZ_FLAGS="-6" ;;
  9) XZ_FLAGS="-9" ;;
  *) XZ_FLAGS="-6" ;;
esac

echo "Compression level: $COMPRESSION_LEVEL"
echo "Files to extract:"
for P in $SELECTED_PARTITIONS; do
  echo "- $P"
done
echo ""

chmod +x tools/android-tools/* tools/erofs-utils/* 2>/dev/null || true

SUPER_PARTS="system system_ext product vendor vendor_dlkm system_dlkm odm odm_dlkm"
NEED_SUPER=false
for PART in $SELECTED_PARTITIONS; do
  for SP in $SUPER_PARTS; do
    if [ "$PART" = "$SP" ]; then
      NEED_SUPER=true
      break 2
    fi
  done
done

echo "[1/8] Downloading..."
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

mv "$ZIP_FILE" firmware.zip

echo ""
echo "[2/8] Extracting ZIP..."
unzip -o "firmware.zip" >/dev/null 2>&1
rm -f "firmware.zip"
echo "✓ Done"

echo ""
echo "[3/8] Extracting AP..."
AP_FILE=$(find . -name "AP_*.tar.md5" -o -name "AP_*.tar" | head -n 1)
[ -z "$AP_FILE" ] && { echo "❌ AP file not found"; exit 1; }
echo "  Extracting: $(basename "$AP_FILE")"

EXTRACT_ARGS=()
for PART in $SELECTED_PARTITIONS; do
  EXTRACT_ARGS+=("*${PART}.img*" "*${PART}_a.img*" "*${PART}_b.img*")
done
$NEED_SUPER && EXTRACT_ARGS+=("*super.img*")

tar --no-anchored --wildcards -xf "$AP_FILE" "${EXTRACT_ARGS[@]}" 2>/dev/null || tar -xf "$AP_FILE" >/dev/null 2>&1
echo "  Contents:"
for file in *.img *.img.lz4; do
  [ -f "$file" ] && echo "    $file"
done
rm -f "$AP_FILE"
echo "✓ Done"

echo ""
echo "[4/8] Extracting partitions..."
mkdir -p raw_parts

for PART in $SELECTED_PARTITIONS; do
  FILE=$(find . -maxdepth 1 \( -name "${PART}.img.lz4" -o -name "${PART}.img" -o -name "${PART}_a.img.lz4" -o -name "${PART}_a.img" -o -name "${PART}_b.img.lz4" -o -name "${PART}_b.img" \) | head -n 1)
  if [ -n "$FILE" ] && [ -f "$FILE" ]; then
    if [[ "$FILE" == *.lz4 ]]; then
      lz4 -d "$FILE" "${FILE%.lz4}" 2>/dev/null || true
      FILE="${FILE%.lz4}"
    fi
    BASENAME=$(basename "$FILE")
    mv "$FILE" "raw_parts/${BASENAME}"
    echo "    - $BASENAME"
  fi
done

SUPER_FILE=$(find . -maxdepth 1 -name "super.img*" | head -n 1)
if $NEED_SUPER && [ -n "$SUPER_FILE" ] && [ -f "$SUPER_FILE" ]; then
  echo ""
  echo "  Extracting super.img..."
  echo "  File: $(basename "$SUPER_FILE")"

  if [[ "$SUPER_FILE" == *.lz4 ]]; then
    lz4 -d "$SUPER_FILE" "super.img" 2>/dev/null || { echo "  ❌ LZ4 failed"; exit 1; }
    SUPER_FILE="super.img"
  fi

  if file "$SUPER_FILE" 2>/dev/null | grep -q "sparse"; then
    if command -v simg2img &>/dev/null; then
      simg2img "$SUPER_FILE" "super.raw.img" 2>/dev/null
    elif [ -f "tools/android-tools/simg2img" ]; then
      tools/android-tools/simg2img "$SUPER_FILE" "super.raw.img" 2>/dev/null
    else
      echo "  ❌ simg2img not found"
      exit 1
    fi
    [ -f "super.raw.img" ] && SUPER_FILE="super.raw.img"
  fi

  echo "  Format: sparse → raw → erofs"
  mkdir -p super_dump
  if [ -f "tools/android-tools/lpunpack" ]; then
    tools/android-tools/lpunpack "$SUPER_FILE" super_dump >/dev/null 2>&1 || { echo "  ❌ lpunpack failed"; exit 1; }
  else
    echo "  ❌ lpunpack not found"
    exit 1
  fi

  echo "  Partitions:"
  for IMG in super_dump/*.img; do
    [ -f "$IMG" ] || continue
    PNAME=$(basename "$IMG" .img)
    PSIZE=$(numfmt --to=iec "$(stat -c%s "$IMG")" 2>/dev/null || echo "?")
    FS=$(blkid -o value -s TYPE "$IMG" 2>/dev/null || echo "?")
    [ -z "$FS" ] && FS="?"
    printf "    - %-15s %-6s %s\n" "$PNAME" "$FS" "$PSIZE"
    mv "$IMG" "raw_parts/${PNAME}.img"
  done
  rm -rf super_dump super.img super.raw.img
fi
echo "✓ Done"

echo ""
echo "[5/8] Extracting super partitions..."

echo "✓ Done"

echo ""
echo "[6/8] Compressing partitions..."
mkdir -p compression_room
cd raw_parts
for FILE in *; do
  [ -f "$FILE" ] || continue
  if xz $XZ_FLAGS -T0 "$FILE" 2>/dev/null; then
    mv "${FILE}.xz" "../compression_room/${FILE}.xz"
    echo "    - ${FILE}.xz"
  else
    mv "$FILE" "../compression_room/${FILE}"
    echo "    - ${FILE}"
  fi
done
cd ..
rm -rf raw_parts
echo "✓ Done"

echo ""
echo "[7/8] Saving to output/..."
mkdir -p output
COUNT=0
for FILE in compression_room/*; do
  [ -f "$FILE" ] || continue
  mv "$FILE" "output/"
  COUNT=$((COUNT + 1))
done
rm -rf compression_room
echo "    - $COUNT files"
echo "✓ Done"

echo ""
echo "[8/8] Results:"
cd output
FILE_COUNT=$(ls -1 | wc -l)
[ "$FILE_COUNT" -eq 0 ] && { echo "❌ Nothing extracted!"; exit 1; }
TOTAL_SIZE=$(du -sh . | cut -f1)
echo "═══════════════════════════════════════"
echo "✓ Extracted $FILE_COUNT partitions"
echo "Total size: $TOTAL_SIZE"
echo ""
echo "Files:"
ls -lh
echo "═══════════════════════════════════════"
echo "✓ Done!"
