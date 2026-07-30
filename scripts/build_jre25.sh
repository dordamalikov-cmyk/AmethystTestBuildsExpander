#!/usr/bin/env bash
# Downloads the pinned iOS-built OpenJDK 25 release used by this repository.
# scripts/jdk25_ios_fixups.py contains the matching source-level fixes for the
# next runtime rebuild; this downloader installs and validates the published
# iOS artifact rather than retagging a macOS JRE.

set -euo pipefail

JRE_URL="${JRE_URL:-https://github.com/catsruledogs/JRE25/releases/download/JRE25/jre25-ios-arm64-20260509-release.tar.xz}"
JRE_SHA256="${JRE_SHA256:-7a58825b72916fabe1530618e4e662f1d7906944b5066eda446944f0751b55dd}"
SOURCE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DEST_DIR="${DEST_DIR:-$SOURCE_DIR/depends/java-25-openjdk}"
DEST_PARENT="$(dirname "$DEST_DIR")"
COMPLETE_MARKER=".amethyst-jre25.complete"
MIRROR_MARKER=".amethyst-mirror-mapping"

dest_name="$(basename "$DEST_DIR")"
if [ "$dest_name" != "java-25-openjdk" ]; then
    echo "[jre25] ERROR: DEST_DIR must end in java-25-openjdk" >&2
    exit 1
fi
mkdir -p "$DEST_PARENT"
DEST_PARENT="$(cd "$DEST_PARENT" && pwd -P)"
DEST_DIR="$DEST_PARENT/$dest_name"

work_dir_owned=0
if [ -n "${WORK_DIR:-}" ]; then
    mkdir -p "$WORK_DIR"
else
    WORK_DIR="$(mktemp -d -t jre25-work.XXXXXX)"
    work_dir_owned=1
fi

staging_root=""
backup_root=""
backup_dir=""
install_in_progress=0

cleanup() {
    status=$?
    trap - EXIT
    if [ "$install_in_progress" = "1" ] &&
            [ -n "$backup_dir" ] &&
            [ -e "$backup_dir" ]; then
        if [ ! -e "$DEST_DIR" ]; then
            mv "$backup_dir" "$DEST_DIR"
        else
            echo "[jre25] interrupted after installing the new runtime;" \
                "previous runtime preserved at $backup_dir" >&2
            backup_root=""
        fi
    fi
    if [ -n "$staging_root" ] && [ -d "$staging_root" ]; then
        rm -rf -- "$staging_root"
    fi
    if [ -n "$backup_root" ] && [ -d "$backup_root" ]; then
        rm -rf -- "$backup_root"
    fi
    if [ "$work_dir_owned" = "1" ] && [ -d "$WORK_DIR" ]; then
        rm -rf -- "$WORK_DIR"
    fi
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

runtime_complete() {
    runtime_dir="$1"
    [ -f "$runtime_dir/release" ] &&
        [ -x "$runtime_dir/bin/java" ] &&
        [ -s "$runtime_dir/lib/modules" ] &&
        [ -f "$runtime_dir/lib/libjli.dylib" ] &&
        [ -f "$runtime_dir/lib/server/libjvm.dylib" ] &&
        [ -d "$runtime_dir/conf" ]
}

if [ -e "$DEST_DIR" ] && ! runtime_complete "$DEST_DIR"; then
    echo "[jre25] ERROR: refusing to replace a non-JRE destination: $DEST_DIR" >&2
    exit 1
fi

marker_matches() {
    marker="$1/$COMPLETE_MARKER"
    [ -f "$marker" ] &&
        grep -Fxq "archive_sha256=$JRE_SHA256" "$marker"
}

verify_ios_binary() {
    jvm="$1/lib/server/libjvm.dylib"
    if ! vtool -show "$jvm" 2>/dev/null | grep -q "platform IOS"; then
        echo "[jre25] ERROR: libjvm.dylib is not tagged for iOS" >&2
        vtool -show "$jvm" >&2 || true
        return 1
    fi
}

if runtime_complete "$DEST_DIR" && marker_matches "$DEST_DIR"; then
    echo "[jre25] using validated cached runtime: $DEST_DIR"
    python3 "$SOURCE_DIR/scripts/patch_jre25_runtime.py" \
        --check "$DEST_DIR/lib/server/libjvm.dylib"
    verify_ios_binary "$DEST_DIR"
    printf 'amethyst-mirror-mapping-v1\n' > "$DEST_DIR/$MIRROR_MARKER"
else
    archive="$WORK_DIR/jre25.tar.xz"
    echo "[jre25] downloading pinned iOS OpenJDK 25 artifact..."
    echo "[jre25]   $JRE_URL"
    curl -L --fail -o "$archive" "$JRE_URL"

    actual_sha256="$(shasum -a 256 "$archive" | awk '{print $1}')"
    if [ "$actual_sha256" != "$JRE_SHA256" ]; then
        echo "[jre25] ERROR: archive SHA-256 mismatch" >&2
        echo "[jre25] expected: $JRE_SHA256" >&2
        echo "[jre25] actual:   $actual_sha256" >&2
        exit 1
    fi

    staging_root="$(mktemp -d "$DEST_PARENT/.jre25-staging.XXXXXX")"
    staged_runtime="$staging_root/runtime"
    mkdir -p "$staged_runtime"
    echo "[jre25] extracting into staging directory..."
    tar xf "$archive" -C "$staged_runtime"

    if ! runtime_complete "$staged_runtime"; then
        echo "[jre25] ERROR: extracted runtime is incomplete" >&2
        exit 1
    fi

    staged_jvm="$staged_runtime/lib/server/libjvm.dylib"
    python3 "$SOURCE_DIR/scripts/patch_jre25_runtime.py" "$staged_jvm"
    python3 "$SOURCE_DIR/scripts/patch_jre25_runtime.py" --check "$staged_jvm"
    verify_ios_binary "$staged_runtime"
    printf 'amethyst-mirror-mapping-v1\n' \
        > "$staged_runtime/$MIRROR_MARKER"
    printf 'archive_sha256=%s\n' "$JRE_SHA256" \
        > "$staged_runtime/$COMPLETE_MARKER"

    if [ -e "$DEST_DIR" ]; then
        backup_root="$(mktemp -d "$DEST_PARENT/.jre25-backup.XXXXXX")"
        backup_dir="$backup_root/runtime"
        install_in_progress=1
        mv "$DEST_DIR" "$backup_dir"
    fi
    mv "$staged_runtime" "$DEST_DIR"
    install_in_progress=0
    if [ -n "$backup_root" ]; then
        rm -rf -- "$backup_root"
        backup_root=""
        backup_dir=""
    fi
    echo "[jre25] installed validated runtime: $DEST_DIR"
fi

echo "[jre25] done. Final size:"
du -sh "$DEST_DIR"
