#!/bin/bash
# mkvendorboot-flat.sh
#
# Takes an existing vendor_kernel_boot.img whose ramdisk already has modules
# at /lib/modules/*.ko (flat, no kver subdirectory) and adds a
# /lib/modules/$KVER -> . symlink. Then repacks.
#
# Usage:
#   mkvendorboot-flat.sh <kver> [dtb_override]
#
# Example:
#   mkvendorboot-flat.sh 6.1.145-android14-11-gec45f20f38ea-ab15260282
#
set -e

KVER="$1"
DTB_ARG="$2"

if [ -z "$KVER" ]; then
        echo "Usage: $0 <kver> [dtb_override]" >&2
        echo "  kver: kernel version string for the symlink (e.g. \$(uname -r) target)" >&2
        exit 1
fi

HERE=`pwd`
INSTALL_MOD_PATH="$HERE/../lineage"
TMPDIR="$HERE/out/target/product/panther/tmp"
MKBOOTIMG="python3 $HERE/system/tools/mkbootimg/mkbootimg.py"
UNPACK_BOOTIMG="python3 $HERE/system/tools/mkbootimg/unpack_bootimg.py"

COMPRESSION_CMD="lz4 -l -9"

SRC_VBOOT="$INSTALL_MOD_PATH/vendor_kernel_boot.img"
OUT_VBOOT="$HERE/vendor_kernel_boot.img"
VENDOR_RAMDISK="$HERE/out/target/product/panther/ramdisk-vendor_boot.img"

if [ ! -f "$SRC_VBOOT" ]; then
        echo "ERROR: $SRC_VBOOT not found" >&2
        exit 1
fi

WORK="$TMPDIR/vboot-flat"
rm -rf "$WORK"
mkdir -p "$WORK"

UNPACK_DIR="$WORK/unpacked"
STAGE="$WORK/stage"
mkdir -p "$UNPACK_DIR" "$STAGE"

# --- 1. Unpack existing vendor_kernel_boot.img -------------------------------
echo ">> Unpacking $SRC_VBOOT"
$UNPACK_BOOTIMG --boot_img "$SRC_VBOOT" --out "$UNPACK_DIR" >/dev/null

FRAG=""
for cand in "$UNPACK_DIR"/vendor_ramdisk00 \
            "$UNPACK_DIR"/vendor_ramdisk \
            "$UNPACK_DIR"/vendor_ramdisk_fragments/*/ramdisk; do
        if [ -f "$cand" ]; then
                FRAG="$cand"
                break
        fi
done

if [ -z "$FRAG" ]; then
        echo "ERROR: could not locate vendor ramdisk fragment under $UNPACK_DIR" >&2
        ls -la "$UNPACK_DIR" >&2
        exit 1
fi
echo ">> Found ramdisk fragment: $FRAG"

# --- 2. Decompress ramdisk fragment to cpio ----------------------------------
RAMDISK_CPIO="$WORK/ramdisk.cpio"
magic=$(head -c 4 "$FRAG" | od -An -tx1 | tr -d ' \n')
case "$magic" in
        04224d18*) lz4 -d "$FRAG" "$RAMDISK_CPIO" ;;
        02214c18*) lz4 -d "$FRAG" "$RAMDISK_CPIO" ;;
        1f8b*)     gunzip -c "$FRAG" > "$RAMDISK_CPIO" ;;
        fd377a*)   xz -dc "$FRAG" > "$RAMDISK_CPIO" ;;
        28b52ffd*) zstd -dc "$FRAG" > "$RAMDISK_CPIO" ;;
        *)         echo "Unknown ramdisk compression magic=$magic" >&2; exit 1 ;;
esac

# --- 3. Extract cpio into STAGE (preserve everything as-is) ------------------
( cd "$STAGE" && cpio -idm --quiet < "$RAMDISK_CPIO" )

# --- 4. Verify ramdisk is actually flattened ---------------------------------
if [ ! -d "$STAGE/lib/modules" ]; then
        echo "ERROR: $STAGE/lib/modules does not exist - is this really a flattened ramdisk?" >&2
        exit 1
fi

KO_COUNT=$(find "$STAGE/lib/modules" -maxdepth 1 -type f -name '*.ko' | wc -l)
if [ "$KO_COUNT" -eq 0 ]; then
        echo "ERROR: no .ko files at $STAGE/lib/modules/ (top level)" >&2
        echo "       This script expects an already-flattened ramdisk." >&2
        echo "       Contents of lib/modules:" >&2
        ls -la "$STAGE/lib/modules" >&2
        exit 1
fi
echo ">> Found $KO_COUNT modules at lib/modules/ (flat layout confirmed)"

# --- 5. Add the kver symlink -------------------------------------------------
SYMLINK_PATH="$STAGE/lib/modules/$KVER"
if [ -e "$SYMLINK_PATH" ] || [ -L "$SYMLINK_PATH" ]; then
        echo ">> Removing existing lib/modules/$KVER"
        rm -rf "$SYMLINK_PATH"
fi
( cd "$STAGE/lib/modules" && ln -s . "$KVER" )
echo ">> Created symlink lib/modules/$KVER -> ."

# --- 6. Build the new vendor ramdisk fragment --------------------------------
mkdir -p "$(dirname "$VENDOR_RAMDISK")"
( cd "$STAGE" && find . | cpio -o -H newc --quiet | $COMPRESSION_CMD > "$VENDOR_RAMDISK" )
echo ">> Wrote new vendor ramdisk: $VENDOR_RAMDISK"

# --- 7. Pick DTB -------------------------------------------------------------
if [ -n "$DTB_ARG" ] && [ -f "$INSTALL_MOD_PATH/$DTB_ARG" ]; then
        DTB_PATH="$INSTALL_MOD_PATH/$DTB_ARG"
elif [ -f "$UNPACK_DIR/dtb" ]; then
        DTB_PATH="$UNPACK_DIR/dtb"
else
        echo "ERROR: no DTB available (arg='$DTB_ARG', unpacked dtb missing)" >&2
        exit 1
fi
echo ">> Using DTB: $DTB_PATH"

# --- 8. Repack with mkbootimg ------------------------------------------------
EXTRA_VENDOR_ARGS="--base 0x00000000 --kernel_offset 0x10008000 --ramdisk_offset 0x11000000 --tags_offset 0x10000100 --pagesize 0x800 --dtb $DTB_PATH --dtb_offset 0x0000000011f00000"

VENDOR_RAMDISK_ARGS=(--ramdisk_type platform --ramdisk_name '' --vendor_ramdisk_fragment "$VENDOR_RAMDISK")
$MKBOOTIMG "${VENDOR_RAMDISK_ARGS[@]}" --header_version 4 --vendor_boot "$OUT_VBOOT" $EXTRA_VENDOR_ARGS

echo ">> Done: $OUT_VBOOT"
