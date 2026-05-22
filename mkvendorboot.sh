#!/bin/bash
set -e

HERE=`pwd`
INSTALL_MOD_PATH="$HERE/device/google/pantah-kernels/6.1"
TMPDIR="$HERE/out/target/product/panther/tmp"
MKBOOTIMG="python3 $HERE/system/tools/mkbootimg/mkbootimg.py"
UNPACK_BOOTIMG="python3 $HERE/system/tools/mkbootimg/unpack_bootimg.py"
DTB_ARG="$1"

COMPRESSION_CMD="lz4 -l -9"

SRC_VBOOT="$INSTALL_MOD_PATH/vendor_kernel_boot.img"
OUT_VBOOT="$HERE/vendor_kernel_boot.img"
VENDOR_RAMDISK="$HERE/out/target/product/panther/ramdisk-vendor_boot.img"

if [ ! -f "$SRC_VBOOT" ]; then
        echo "ERROR: $SRC_VBOOT not found"
        exit 1
fi

WORK="$TMPDIR/vboot-rework"
rm -rf "$WORK"
mkdir -p "$WORK"

UNPACK_DIR="$WORK/unpacked"
STAGE="$WORK/stage"        # cpio source for the new ramdisk
mkdir -p "$UNPACK_DIR" "$STAGE"

# --- 1. Unpack existing vendor_kernel_boot.img -------------------------------
echo ">> Unpacking $SRC_VBOOT"
$UNPACK_BOOTIMG --boot_img "$SRC_VBOOT" --out "$UNPACK_DIR" >/dev/null

# unpack_bootimg lays things out as:
#   $UNPACK_DIR/dtb
#   $UNPACK_DIR/vendor_ramdisk00            (the fragment, compressed)
#   $UNPACK_DIR/vendor_ramdisk_fragments/.. (sometimes)
# Find the ramdisk fragment file.
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
        echo "ERROR: could not locate vendor ramdisk fragment under $UNPACK_DIR"
        ls -la "$UNPACK_DIR"
        exit 1
fi
echo ">> Found ramdisk fragment: $FRAG"

# Detect compression and decompress to a cpio archive.
RAMDISK_CPIO="$WORK/ramdisk.cpio"
magic=$(head -c 4 "$FRAG" | od -An -tx1 | tr -d ' \n')
case "$magic" in
        04224d18*) lz4 -d "$FRAG" "$RAMDISK_CPIO" ;;            # LZ4 frame
        02214c18*) lz4 -d "$FRAG" "$RAMDISK_CPIO" ;;            # legacy LZ4
        1f8b*)     gunzip -c "$FRAG" > "$RAMDISK_CPIO" ;;
        fd377a*)   xz -dc "$FRAG" > "$RAMDISK_CPIO" ;;
        28b52ffd*) zstd -dc "$FRAG" > "$RAMDISK_CPIO" ;;
        *)         echo "Unknown ramdisk compression magic=$magic"; exit 1 ;;
esac

# Extract the cpio contents
EXTRACT="$WORK/extracted"
mkdir -p "$EXTRACT"
( cd "$EXTRACT" && cpio -idm --quiet < "$RAMDISK_CPIO" )

# --- 2. Locate lib/modules/<kver>/ in the unpacked tree ----------------------
SRC_MOD_DIR="$(find "$EXTRACT/lib/modules" -mindepth 1 -maxdepth 1 -type d | head -n1)"
if [ -z "$SRC_MOD_DIR" ]; then
        echo "ERROR: no lib/modules/<kver>/ found in unpacked ramdisk"
        exit 1
fi
echo ">> Source modules dir: $SRC_MOD_DIR"

SRC_DEP="$SRC_MOD_DIR/modules.dep"
SRC_LOAD="$SRC_MOD_DIR/modules.load"
SRC_ALIAS="$SRC_MOD_DIR/modules.alias"
SRC_SOFTDEP="$SRC_MOD_DIR/modules.softdep"

if [ ! -f "$SRC_DEP" ] || [ ! -f "$SRC_LOAD" ]; then
        echo "ERROR: missing modules.dep or modules.load under $SRC_MOD_DIR"
        exit 1
fi

# --- 3. Build a flat staging tree of all modules present, mirroring the source
# Copy EVERY .ko* under SRC_MOD_DIR to a flat staging dir. We keep modules
# outside modules.load (per your choice) but with rewritten dep entries.
STAGE_MOD_DIR="$STAGE/lib/modules"
mkdir -p "$STAGE_MOD_DIR"

declare -A present_basenames=()
while IFS= read -r ko; do
        [ -z "$ko" ] && continue
        b="$(basename "$ko")"
        cp "$ko" "$STAGE_MOD_DIR/$b"
        present_basenames[$b]=1
done < <(find "$SRC_MOD_DIR" -type f \( -name "*.ko" -o -name "*.ko.*" \))

echo ">> Staged ${#present_basenames[@]} modules"

KVER="$(basename "$SRC_MOD_DIR")"
( cd "$STAGE_MOD_DIR" && ln -sfn . "$KVER" )
echo ">> Created symlink lib/modules/$KVER -> ."

# --- 4. Build basename-keyed view of original modules.dep --------------------
declare -A dep_by_base=()
while IFS= read -r line; do
        key="${line%%:*}"
        rest="${line#*:}"
        [ "$key" = "$line" ] && continue
        kb="$(basename "$key")"
        # First occurrence wins
        if [ -z "${dep_by_base[$kb]:-}" ]; then
                dep_by_base[$kb]="$rest"
        fi
done < "$SRC_DEP"

# --- 5. Resolve modules.load entries (preserve order; record basenames) ------
declare -A seen_load_basenames=()
resolved_load_basenames=()
while IFS= read -r mod; do
        [ -z "$mod" ] && continue
        mb="$(basename "$mod")"
        if [ -z "${present_basenames[$mb]:-}" ]; then
                echo "WARN: modules.load entry '$mod' (basename=$mb) not present in ramdisk; skipping"
                continue
        fi
        if [ -z "${seen_load_basenames[$mb]:-}" ]; then
                resolved_load_basenames+=("$mb")
                seen_load_basenames[$mb]=1
        fi
done < "$SRC_LOAD"

# --- 6. Write rewritten modules.dep for ALL staged modules -------------------
NEW_DEP="$STAGE_MOD_DIR/modules.dep"
: > "$NEW_DEP"
for b in "${!present_basenames[@]}"; do
        deps="${dep_by_base[$b]:-}"
        deps="${deps# }"
        printf '/lib/modules/%s:' "$b" >> "$NEW_DEP"
        if [ -n "$deps" ]; then
                for d in $deps; do
                        db="$(basename "$d")"
                        if [ -z "${present_basenames[$db]:-}" ]; then
                                echo "WARN: dep '$d' of '$b' not staged (kept in dep line anyway)" >&2
                        fi
                        printf ' /lib/modules/%s' "$db" >> "$NEW_DEP"
                done
        fi
        echo >> "$NEW_DEP"
done

# --- 7. Write rewritten modules.load (basenames only, original order) --------
NEW_LOAD="$STAGE_MOD_DIR/modules.load"
: > "$NEW_LOAD"
for b in "${resolved_load_basenames[@]}"; do
        echo "$b" >> "$NEW_LOAD"
done

# --- 8. Copy modules.alias verbatim (no paths in it, nothing to rewrite) -----
if [ -f "$SRC_ALIAS" ]; then
        cp "$SRC_ALIAS" "$STAGE_MOD_DIR/modules.alias"
fi

# --- 9. Rewrite modules.softdep (basenames, drop entries we don't have) ------
if [ -f "$SRC_SOFTDEP" ]; then
        NEW_SOFTDEP="$STAGE_MOD_DIR/modules.softdep"
        : > "$NEW_SOFTDEP"
        while IFS= read -r line; do
                case "$line" in
                        ''|\#*)
                                echo "$line" >> "$NEW_SOFTDEP"
                                continue
                                ;;
                esac
                read -r kw primary rest <<< "$line"
                if [ "$kw" != "softdep" ]; then
                        echo "$line" >> "$NEW_SOFTDEP"
                        continue
                fi
                pb="$(basename "$primary")"
                # softdep refers to module names; check both forms
                if [ -z "${present_basenames[$pb]:-}" ] && \
                   [ -z "${present_basenames[${pb}.ko]:-}" ]; then
                        continue
                fi
                new_rest=""
                for tok in $rest; do
                        case "$tok" in
                                pre:|post:)      new_rest+=" $tok" ;;
                                */*)             new_rest+=" $(basename "$tok")" ;;
                                *)               new_rest+=" $tok" ;;
                        esac
                done
                echo "softdep $pb$new_rest" >> "$NEW_SOFTDEP"
        done < "$SRC_SOFTDEP"
fi

# --- 10. Copy over any non-module files from the original ramdisk root -------
# (init scripts, fstab, etc. — anything outside lib/modules/<kver>/)
( cd "$EXTRACT" && find . -mindepth 1 -path ./lib/modules -prune -o -print | \
        cpio -pdm --quiet "$STAGE" )

# --- 11. Build the new vendor ramdisk fragment -------------------------------
mkdir -p "$(dirname "$VENDOR_RAMDISK")"
( cd "$STAGE" && find . | cpio -o -H newc --quiet | $COMPRESSION_CMD > "$VENDOR_RAMDISK" )
echo ">> Wrote new vendor ramdisk: $VENDOR_RAMDISK"

# --- 12. Pick DTB ------------------------------------------------------------
if [ -n "$DTB_ARG" ] && [ -f "$INSTALL_MOD_PATH/$DTB_ARG" ]; then
        DTB_PATH="$INSTALL_MOD_PATH/$DTB_ARG"
elif [ -f "$UNPACK_DIR/dtb" ]; then
        DTB_PATH="$UNPACK_DIR/dtb"
else
        echo "ERROR: no DTB available (arg='$DTB_ARG', unpacked dtb missing)"
        exit 1
fi
echo ">> Using DTB: $DTB_PATH"

# --- 13. Repack with mkbootimg ----------------------------------------------
# Header v4 vendor_boot: final load addr = base + offset. mkbootimg's default
# --base is 0x10000000, which would yield e.g. 0x20008000 for a kernel_offset of
# 0x10008000. The original Pantah image was built with --base 0x0, so we match
# that here to land on the documented load addresses (0x10008000, 0x11000000,
# 0x10000100, 0x11f00000).
EXTRA_VENDOR_ARGS="--base 0x00000000 --kernel_offset 0x10008000 --ramdisk_offset 0x11000000 --tags_offset 0x10000100 --pagesize 0x800 --dtb $DTB_PATH --dtb_offset 0x0000000011f00000"

VENDOR_RAMDISK_ARGS=(--ramdisk_type platform --ramdisk_name '' --vendor_ramdisk_fragment "$VENDOR_RAMDISK")
$MKBOOTIMG "${VENDOR_RAMDISK_ARGS[@]}" --header_version 4 --vendor_boot "$OUT_VBOOT" $EXTRA_VENDOR_ARGS

echo ">> Done: $OUT_VBOOT"
