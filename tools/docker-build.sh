#!/bin/bash
# docker-build.sh — Build a joypad-os RP2040/RP2350 app using the pinned
# Docker toolchain (same image the CI workflow builds), without installing
# the ARM GNU Toolchain or pico-sdk submodules on the host.
#
# ESP32-S3 (esp/) and nRF52840 (nrf/) targets are NOT covered — this image
# only carries the ARM GNU Toolchain for RP2040/RP2350 (pico-sdk); those
# other two platforms use ESP-IDF/nRF Connect SDK instead (see `make
# init-esp` / `make init-nrf`).
#
# Usage:
#   ./tools/docker-build.sh              # interactive menu (Enter = default app)
#   ./tools/docker-build.sh [app]        # skip the menu, build this app directly
#   ./tools/docker-build.sh bt2usb_pico_w
#   ./tools/docker-build.sh list         # print every buildable app and exit
#   ./tools/docker-build.sh all          # build every app in Makefile's APPS list
#   ./tools/docker-build.sh shell        # drop into an interactive shell in the container
#
# Output UF2s land in releases/, owned by the current host user (the
# container runs as your uid/gid, not root).

set -e

cd "$(dirname "$0")/.."

DEFAULT_APP="usb2usb_pico"

# Source of truth is the Makefile's own APPS list (what `make all` builds) —
# parsed here instead of duplicated, so this stays in sync automatically.
_raw_apps() {
    awk -F':=' '/^APPS[[:space:]]*:=/{print $2; exit}' Makefile | tr -s ' ' '\n' | sed '/^$/d'
}

# Board for an app, read from its "APP_<name> := <board> ..." line.
_app_board() {
    grep -E "^APP_$1[[:space:]]*:=" Makefile | head -1 | sed -E 's/^APP_[^=]*:=[[:space:]]*//' | awk '{print $1}'
}

# True if the app name already hints at its board — matched word-by-word
# (board split on '_') rather than as one literal substring, so spelling/
# naming variants of the SAME board (usb_host vs usbhost, xiao vs
# seeed_xiao_rp2040) still count as "already said". Only a board hiding
# behind an unrelated product name (Retro Frog == rp2040zero) fails this.
_name_implies_board() {
    local name="$1" board="$2" tok
    IFS='_' read -ra toks <<< "$board"
    for tok in "${toks[@]}"; do
        case "$name" in
            *"$tok"*) return 0 ;;
        esac
    done
    return 1
}

# Every buildable app with its board, one "app<TAB>board" pair per line,
# grouped by board (kb2040, pico, pico_w, pico2_w, rp2040zero, feather, ...)
# instead of the Makefile's naming-family order, so boards you actually own
# sit together.
list_apps_with_board() {
    local app board
    while IFS= read -r app; do
        board="$(_app_board "$app")"
        printf '%s\t%s\n' "${board:-zzz_unknown}" "$app"
    done < <(_raw_apps) | sort -t $'\t' -k1,1 -s | awk -F'\t' '{print $2"\t"$1}'
}

list_apps() {
    list_apps_with_board | cut -f1
}

if [ "$1" = "list" ]; then
    list_apps
    exit 0
fi

if [ -z "$1" ]; then
    mapfile -t PAIRS_ARR < <(list_apps_with_board)
    total=${#PAIRS_ARR[@]}
    cols=3
    rows=$(( (total + cols - 1) / cols ))

    labels=()
    for i in "${!PAIRS_ARR[@]}"; do
        a="${PAIRS_ARR[$i]%%$'\t'*}"
        board="${PAIRS_ARR[$i]#*$'\t'}"
        label="$(printf '%2d) %s' "$((i + 1))" "$a")"
        if ! _name_implies_board "$a" "$board"; then
            label="$label ($board)"
        fi
        if [ "$a" = "$DEFAULT_APP" ]; then
            label="${label}*"
        fi
        labels[i]="$label"
    done

    max_len=0
    for l in "${labels[@]}"; do
        [ "${#l}" -gt "$max_len" ] && max_len=${#l}
    done
    col_width=$((max_len + 3))

    echo "Available apps: (* = default)"
    for ((r = 0; r < rows; r++)); do
        line=""
        for ((c = 0; c < cols; c++)); do
            idx=$((c * rows + r))
            if [ "$idx" -lt "$total" ]; then
                line+="$(printf '%-*s' "$col_width" "${labels[$idx]}")"
            fi
        done
        echo "  $line"
    done
    echo ""
    echo "   A) all — build every app above"
    echo "   C) cancel"
    echo ""
    read -rp "Choose a number, A, or C [Enter = $DEFAULT_APP]: " CHOICE

    case "$CHOICE" in
        "")
            APP="$DEFAULT_APP"
            ;;
        [Aa]|[Aa][Ll][Ll])
            APP="all"
            ;;
        [Cc]|[Cc][Aa][Nn][Cc][Ee][Ll])
            echo "Cancelled."
            exit 0
            ;;
        *[!0-9]*)
            echo "Invalid selection: $CHOICE" >&2
            exit 1
            ;;
        *)
            if [ "$CHOICE" -ge 1 ] 2>/dev/null && [ "$CHOICE" -le "${#PAIRS_ARR[@]}" ]; then
                APP="${PAIRS_ARR[$((CHOICE - 1))]%%$'\t'*}"
            else
                echo "Invalid selection: $CHOICE" >&2
                exit 1
            fi
            ;;
    esac
else
    APP="$1"
fi
IMAGE_TAG="joypad:latest"

if [ ! -f src/lib/pico-sdk/CMakeLists.txt ]; then
    # Can't shell out to 'make init' here: the top-level Makefile refuses to
    # parse at all without an ARM toolchain on the host (see the $(error ...)
    # near the top), which defeats the point of building inside Docker. CI
    # doesn't call 'make init' either — it just checks out submodules
    # recursively, which is enough since the pico-sdk/tinyusb pins are
    # already the tagged commits recorded in the superproject's git index.
    echo "==> Submodules not initialized, running 'git submodule update --init --recursive'..."
    git submodule update --init --recursive
fi

echo "==> Building Docker image ($IMAGE_TAG)..."
docker build -t "$IMAGE_TAG" .

# Deliberately NOT passing -e GIT_COMMIT here: the Makefile computes it
# itself via `git rev-parse --short=7 HEAD` (Makefile line ~264). Overriding
# it from the host with a plain `--short HEAD` can pick a different length
# than the Makefile's pinned --short=7 for the same commit, producing two
# differently-named .uf2s for one build.
if [ "$APP" = "shell" ]; then
    echo "==> Dropping into container shell (make <app> to build from here)..."
    exec docker run --rm -it \
        --user "$(id -u):$(id -g)" \
        -e HOME=/tmp \
        -v "$(pwd):/workspace" \
        -w /workspace \
        "$IMAGE_TAG" /bin/bash
fi

echo "==> Building '$APP' inside container..."
docker run --rm \
    --user "$(id -u):$(id -g)" \
    -e HOME=/tmp \
    -v "$(pwd):/workspace" \
    -w /workspace \
    "$IMAGE_TAG" \
    make "$APP"

echo "==> Done. Output:"
if [ "$APP" = "all" ]; then
    ls -la releases/*.uf2 2>/dev/null || echo "(no .uf2 found in releases/ — check build output above)"
else
    ls -la releases/*"$APP"*.uf2 2>/dev/null || echo "(no matching .uf2 found in releases/ — check build output above)"
fi
