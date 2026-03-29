#!/usr/bin/env bash
# Wrapper for `libtool -static` that uses `ar` to combine archives.
#
# Xcode 26.4's libtool (cctools_ld-1266.8) silently drops misaligned
# 64-bit mach-o members when combining static archives, causing
# undefined symbol errors at link time.
#
# This wrapper intercepts `libtool -static -o <output> <inputs...>`,
# extracts all objects from each input archive with `ar x`, and
# creates a combined archive with `ar rcs`.
#
# Non-static invocations are passed through to the real libtool.

set -euo pipefail

REAL_LIBTOOL="/usr/bin/libtool"

# Save original args for fallback
ORIGINAL_ARGS=("$@")

# Pass through if not a `-static` invocation
if [[ "${1:-}" != "-static" ]]; then
    exec "$REAL_LIBTOOL" "$@"
fi

# Parse arguments: libtool -static -o <output> <input1> <input2> ...
shift  # consume "-static"

OUTPUT=""
INPUTS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        -o)
            shift
            OUTPUT="${1:-}"
            ;;
        -*)
            # Skip unknown flags
            ;;
        *)
            INPUTS+=("$1")
            ;;
    esac
    shift
done

# Fallback: if we couldn't parse, delegate to real libtool
if [[ -z "$OUTPUT" ]] || [[ ${#INPUTS[@]} -eq 0 ]]; then
    exec "$REAL_LIBTOOL" "${ORIGINAL_ARGS[@]}"
fi

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

# Extract objects from each input archive/file into a uniquely-prefixed
# subdirectory to avoid name collisions between archives.
INDEX=0
for INPUT in "${INPUTS[@]}"; do
    SUBDIR="$WORKDIR/$INDEX"
    mkdir -p "$SUBDIR"
    # Resolve relative paths to absolute (ar x runs in a temp dir)
    if [[ "$INPUT" != /* ]]; then
        INPUT="$(pwd)/$INPUT"
    fi
    if file "$INPUT" 2>/dev/null | grep -q "ar archive"; then
        (cd "$SUBDIR" && ar x "$INPUT" 2>/dev/null || true)
    else
        # Plain object file — copy it directly
        cp "$INPUT" "$SUBDIR/" 2>/dev/null || true
    fi
    # Zig-produced archives contain read-only objects; make them readable
    chmod -R u+r "$SUBDIR"
    INDEX=$((INDEX + 1))
done

# Combine all extracted objects into the output archive.
OBJECT_LIST=$(find "$WORKDIR" -name '*.o' -type f | sort)
if [[ -z "$OBJECT_LIST" ]]; then
    # No objects found — fall back to real libtool
    exec "$REAL_LIBTOOL" "${ORIGINAL_ARGS[@]}"
fi

ar rcs "$OUTPUT" $OBJECT_LIST
