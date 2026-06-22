#!/usr/bin/env bash
#
# Regenerate every screenshot referenced in README.md by launching the real Kyde app in
# each documented UI state and capturing its window with macOS `screencapture`.
#
#   ./scripts/screenshots.sh            # all shots, release build
#   ./scripts/screenshots.sh git-diff   # one shot by name
#   PROFILE=debug ./scripts/screenshots.sh
#
# How it works: the app reads KYDE_SHOT=<name> at launch (see apply_shot in src/main.rs) and
# drives itself straight into the right view. We run it against THIS repo under a throwaway
# XDG_CONFIG_HOME (so the user's real ~/.config/kyde is untouched), find its window via
# scripts/winid.swift, screencapture it, then kill it.
#
# REQUIREMENT: the terminal running this needs macOS Screen Recording permission
# (System Settings → Privacy & Security → Screen Recording), or screencapture silently
# produces black/empty images.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
export PATH="$HOME/.cargo/bin:$PATH"

OUT="$ROOT/assets/screenshots"
WINID="$ROOT/scripts/winid.swift"
FIX="$ROOT/target/shot-fixtures"
LOCK="$FIX/package-lock.json"
CFG_ROOT="$(mktemp -d)"
CFG="$CFG_ROOT/config"
PROFILE="${PROFILE:-release}"

# Throwaway config: seed a keymap so first-run onboarding doesn't cover the shot.
mkdir -p "$CFG/kyde"
printf '{\n  "preset": "webstorm",\n  "overrides": {}\n}\n' > "$CFG/kyde/keymap.json"

cleanup() { rm -rf "$CFG_ROOT"; }
trap cleanup EXIT

echo "==> building ($PROFILE)"
if [ "$PROFILE" = release ]; then
    cargo build --release >/dev/null
    BIN="$ROOT/target/release/kyde"
else
    cargo build >/dev/null
    BIN="$ROOT/target/debug/kyde"
fi

echo "==> generating FPS fixture"
mkdir -p "$FIX"
python3 "$ROOT/scripts/gen_lock.py" "$LOCK" 37000 >/dev/null
LOCK_REL="${LOCK#$ROOT/}"

# git-diff fixture: a throwaway repo with one committed Rust file, then a working-tree edit,
# so the git-diff shot always has a real side-by-side diff to render (the live repo is often
# clean). Passed to the shot via KYDE_SHOT_REPO; apply_shot opens it before entering commit.
echo "==> generating git-diff fixture repo"
DIFF_REPO="$FIX/diff-repo"
rm -rf "$DIFF_REPO"
mkdir -p "$DIFF_REPO/src"
git -C "$DIFF_REPO" init -q
git -C "$DIFF_REPO" config user.email shot@kyde.local
git -C "$DIFF_REPO" config user.name "Kyde Shots"
cat > "$DIFF_REPO/src/main.rs" <<'EOF'
fn main() {
    let name = "world";
    println!("Hello, {}!", name);
    let total = add(2, 3);
    println!("sum = {}", total);
}

fn add(a: i32, b: i32) -> i32 {
    a + b
}
EOF
git -C "$DIFF_REPO" add -A
git -C "$DIFF_REPO" commit -qm "baseline" >/dev/null
cat > "$DIFF_REPO/src/main.rs" <<'EOF'
fn main() {
    let name = "Kyde";
    println!("Hello, {}!", name);
    let total = add(2, 3) + add(4, 5);
    println!("total = {}", total);
    log("done");
}

fn add(a: i32, b: i32) -> i32 {
    a + b
}

fn log(msg: &str) {
    eprintln!("[kyde] {}", msg);
}
EOF

# shoot <shot-name> <output-file> <capture-mode> [extra env KEY=VAL ...]
#   capture-mode: window  → screencapture -l<frontmost window>   (full-bleed window)
#                 region  → screencapture -R<main-window bounds + margin>  (window over desktop)
shoot() {
    local name="$1" outfile="$2" mode="$3"; shift 3
    local out="$OUT/$outfile"
    echo "==> $name → $outfile"

    local fpsfile="$CFG_ROOT/fps-$name"
    rm -f "$fpsfile"
    env XDG_CONFIG_HOME="$CFG" KYDE_SHOT="$name" KYDE_FPS_FILE="$fpsfile" "$@" "$BIN" "$ROOT" >/dev/null 2>&1 &
    local pid=$!

    # rollback opens a second (modal) window; everything else has just the main window.
    local need=1
    [ "$name" = rollback ] && need=2

    local tries=0 count=0
    while [ $tries -lt 80 ]; do
        count=$(swift "$WINID" "$pid" 2>/dev/null | grep -c . || true)
        [ "$count" -ge "$need" ] && break
        sleep 0.25; tries=$((tries + 1))
    done
    if [ "$count" -lt "$need" ]; then
        echo "    !! window never appeared (pid $pid) — skipping"
        kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true
        return 1
    fi
    sleep 1  # let async layout / modal open / first paint settle

    # Wait for the FPS EMA to climb out of the launch transient and settle at the display
    # cap, so the captured reading is steady instead of a frozen sub-cap jitter. The app
    # writes its live value to $fpsfile each frame (KYDE_FPS_FILE). The cap is whatever the
    # active monitor refreshes at (120, 60, 144…), so we settle on *stability* — the reading
    # stops climbing — rather than a hard-coded 120. Settled = above the launch transient
    # (>=30) and two consecutive samples within 1.0 of each other. Bail after ~6s either way.
    local ftries=0 prev=0
    while [ $ftries -lt 60 ]; do
        local fps; fps="$(cat "$fpsfile" 2>/dev/null || echo 0)"
        awk -v v="$fps" -v p="$prev" 'BEGIN { d = v - p; if (d < 0) d = -d; exit !(v >= 30 && d <= 1.0) }' && break
        prev="$fps"
        sleep 0.1; ftries=$((ftries + 1))
    done

    local lines; lines="$(swift "$WINID" "$pid" 2>/dev/null)"

    if [ "$mode" = window ]; then
        # Frontmost window (first line) captured edge-to-edge, no shadow.
        local id; id="$(printf '%s\n' "$lines" | head -1 | awk '{print $1}')"
        screencapture -x -o -l"$id" "$out"
    else
        # Region: exactly the main window's bounds (largest-area window). The rollback modal
        # is a smaller, centered sibling window floating within those bounds, so capturing the
        # main window's screen rect grabs the modal over the diff — full-bleed, no desktop
        # chrome (dock / menu bar), consistent with the other window-only shots.
        local rect; rect="$(printf '%s\n' "$lines" | awk '
            { area = $4 * $5; if (area > max) { max = area; x = $2; y = $3; w = $4; h = $5 } }
            END { printf "%d,%d,%d,%d", x, y, w, h }')"
        screencapture -x -R"$rect" "$out"
    fi

    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    [ -f "$out" ] && echo "    wrote $out ($(du -h "$out" | awk '{print $1}'))"
}

# Map each README screenshot to its shot. (file ← state)
declare -a ALL=(git-diff plugins markdown-support go-to-file find-in-files rollback fps)
want="${1:-all}"

run_one() {
    case "$1" in
        git-diff)         shoot git-diff         git-diff.png         window KYDE_SHOT_REPO="$DIFF_REPO" ;;
        plugins)          shoot plugins          plugins.png          window ;;
        markdown-support) shoot markdown-support markdown-support.png window ;;
        go-to-file)       shoot go-to-file       go-to-file.png       window ;;
        find-in-files)    shoot find-in-files    find-in-files.png    window ;;
        rollback)         shoot rollback         rollback.png         region ;;
        fps)              shoot fps              fps.png              window KYDE_SHOT_FILE="$LOCK_REL" ;;
        *) echo "unknown shot: $1"; exit 2 ;;
    esac
}

if [ "$want" = all ]; then
    for s in "${ALL[@]}"; do run_one "$s"; done
else
    run_one "$want"
fi

echo "==> done"
