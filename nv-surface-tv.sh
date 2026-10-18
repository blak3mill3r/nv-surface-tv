#!/usr/bin/env bash
set -u

# nv-surface-tv.sh
#
# Live top-screen -> minidlna, as a .ts item that is really a fifo.
#
# When no DLNA client is reading, nothing expensive runs: no x11grab, no
# NVENC, no ffmpeg. A small helper (fifo-watch) blocks on the fifo's write
# end and reports reader connect/disconnect; when your TV opens the item,
# ffmpeg starts and streams until the TV stops.
#
# Commands:
#   setup             (root, once)  build/install shim + minidlna config + fifo
#   install-service   (user)        install and enable the systemd --user unit
#   uninstall-service (user)        remove the unit
#   run               (user)        the capture loop (normally run by systemd)
#   status            (user)        show current state
#   stop              (user)        stop a running loop / the service
#
# See README.org for the full story.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ------------------------------------------------------------------ config --
MEDIA_DIR=/big1/movies
ITEM_NAME=00-LiveCapture.ts
FIFO="$MEDIA_DIR/$ITEM_NAME"
RUN_USER="${SUDO_USER:-blake}"

# Top screen (DP-0 at +0+0, verified with xrandr).
SCREEN_DISPLAY=:0
SCREEN_GEOMETRY=3840x2160
SCREEN_OFFSET=+0,0

# TV-friendly 1080p, low frame rate to keep the stream light so the TV
# never stalls and (cumulatively) falls behind. Sacrifice fps/bitrate,
# NOT resolution.
OUT_WIDTH=1920
OUT_HEIGHT=1080
FPS=10
GOP=20
VIDEO_BITRATE=2M
VIDEO_BUFSIZE=4M

# Capture the system's audio OUTPUT so the stream carries real sound.
#
# IMPORTANT: capture the default SINK's MONITOR, not the default SOURCE.
# When a headset connects, PipeWire switches the default SOURCE to the
# headset MIC -- `-f pulse -i default` would then broadcast Blake's own
# voice back to the TV (the "echo"). The default sink's monitor is always
# "what the system is currently playing".
#
# If the audio server is unreachable (or no monitor resolves), ffmpeg falls
# back to a silent track so the TV still gets a playable A/V stream.
AUDIO_ENABLED=1
AUDIO_BITRATE=160k
# Optional explicit monitor name. Empty = resolve the default sink's monitor
# at stream start (recommended).
# e.g. "alsa_output.pci-0000_00_1f.3.analog-stereo.monitor"
AUDIO_MONITOR=""

# 0 = unlimited. Set to e.g. 7200 to cap each session at 2h.
MAX_SESSION_SECONDS=0

# Placeholder duration. minidlna probes the placeholder before we swap it
# for the fifo; the TV then browses the item as a LONG file (so seeking /
# fast-forward has somewhere to go) instead of a 2-second clip that it
# considers already-finished. Kept small by encoding 0.1 fps for this many
# seconds (real timestamps, ~560 KB for 2h).
PLACEHOLDER_SECONDS=7200

# -------------------------------------------------------------- system paths --
SHIM_SRC="$SCRIPT_DIR/fifo-lseek-shim.c"
SHIM_SO=/usr/local/lib/minidlna-fifo-shim.so

WATCH_SRC="$SCRIPT_DIR/fifo-watch.c"
WATCH_BIN="$SCRIPT_DIR/fifo-watch"

MINIDLNA_CONF=/etc/minidlna.conf
MINIDLNA_SERVICE=minidlna.service
MINIDLNA_DB=/var/cache/minidlna/files.db
MINIDLNA_DROPIN_DIR=/etc/systemd/system/minidlna.service.d
MINIDLNA_DROPIN="$MINIDLNA_DROPIN_DIR/live-capture.conf"

PID_DIR="${TMPDIR:-/tmp}/minidlna-live-capture-$RUN_USER"
RUN_PID_FILE="$PID_DIR/run.pid"
WATCH_PID_FILE="$PID_DIR/watch.pid"
FFMPEG_PID_FILE="$PID_DIR/ffmpeg.pid"
EVENT_FIFO="$PID_DIR/events.fifo"
STATE_FILE="$PID_DIR/state"

# ------------------------------------------------------------------ helpers --
log()  { echo "[$(date '+%F %T')] $*"; }
die()  { echo "ERROR: $*" >&2; exit 1; }

need_root() { [ "$(id -u)" -eq 0 ] || die "this command needs root: sudo $0 $*"; }

pid_alive() {
    local f="$1" p
    [ -f "$f" ] || return 1
    p="$(cat "$f" 2>/dev/null)" || return 1
    [ -n "$p" ] && kill -0 "$p" 2>/dev/null
}

kill_pid_file() {
    local f="$1" p
    [ -f "$f" ] || return 0
    p="$(cat "$f" 2>/dev/null)" || p=""
    if [ -n "$p" ] && kill -0 "$p" 2>/dev/null; then
        kill "$p" 2>/dev/null
        sleep 0.5
        kill -0 "$p" 2>/dev/null && kill -9 "$p" 2>/dev/null
    fi
    rm -f "$f"
}

x_ready() {
    local n="${SCREEN_DISPLAY#:}"
    n="${n%%.*}"
    [ -S "/tmp/.X11-unix/X${n}" ]
}

ensure_watcher() {
    if [ ! -x "$WATCH_BIN" ] || [ "$WATCH_SRC" -nt "$WATCH_BIN" ]; then
        log "building fifo-watch"
        command -v gcc >/dev/null 2>&1 || die "gcc is required"
        gcc -O2 -o "$WATCH_BIN" "$WATCH_SRC" || die "fifo-watch build failed"
    fi
}

start_watcher() {
    "$WATCH_BIN" "$FIFO" > "$EVENT_FIFO" &
    echo $! > "$WATCH_PID_FILE"
}

start_ffmpeg() {
    local args=(
        -y -hide_banner -loglevel warning
        -thread_queue_size 512
        -f x11grab -framerate "$FPS" -video_size "$SCREEN_GEOMETRY"
        -i "${SCREEN_DISPLAY}${SCREEN_OFFSET}"
    )
    if [ "$AUDIO_ENABLED" = 1 ]; then
        if pactl info >/dev/null 2>&1; then
            local monitor sink
            if [ -n "$AUDIO_MONITOR" ]; then
                monitor="$AUDIO_MONITOR"
            else
                sink=$(pactl get-default-sink 2>/dev/null || true)
                monitor="${sink:+${sink}.monitor}"
            fi
            if [ -n "$monitor" ]; then
                args+=(-f pulse -i "$monitor")
            else
                log "no default-sink monitor; falling back to silent audio"
                args+=(-f lavfi -i "anullsrc=channel_layout=stereo:sample_rate=48000")
            fi
        else
            log "audio server unreachable; falling back to silent audio"
            args+=(-f lavfi -i "anullsrc=channel_layout=stereo:sample_rate=48000")
        fi
    fi
    args+=(
        -vf "scale=${OUT_WIDTH}:${OUT_HEIGHT}"
        -c:v h264_nvenc -preset p1 -tune ll -rc cbr
        -b:v "$VIDEO_BITRATE" -maxrate "$VIDEO_BITRATE" -bufsize "$VIDEO_BUFSIZE"
        -g "$GOP" -bf 0 -pix_fmt yuv420p
    )
    if [ "$AUDIO_ENABLED" = 1 ]; then
        args+=(-c:a aac -b:a "$AUDIO_BITRATE" -map 0:v -map 1:a)
    else
        args+=(-map 0:v)
    fi
    args+=(-f mpegts -flush_packets 1 -muxdelay 0 -muxpreload 0 "$FIFO")

    log "starting ffmpeg (${OUT_WIDTH}x${OUT_HEIGHT} ${FPS}fps ${VIDEO_BITRATE} nvenc)"
    if [ "$MAX_SESSION_SECONDS" -gt 0 ]; then
        timeout --signal=TERM --kill-after=10 "$MAX_SESSION_SECONDS" ffmpeg "${args[@]}" &
    else
        ffmpeg "${args[@]}" &
    fi
    echo $! > "$FFMPEG_PID_FILE"
}

cleanup() {
    kill_pid_file "$FFMPEG_PID_FILE"
    kill_pid_file "$WATCH_PID_FILE"
    exec 9>&- 2>/dev/null || true
    rm -f "$EVENT_FIFO" "$STATE_FILE" "$RUN_PID_FILE"
}

# ------------------------------------------------------------------- setup --
install_shim() {
    log "building and installing shim: $SHIM_SO"
    command -v gcc >/dev/null 2>&1 || die "gcc is required"
    gcc -shared -fPIC -O2 -o "$SHIM_SO" "$SHIM_SRC" -ldl || die "shim build failed"
    chmod 644 "$SHIM_SO"
}

configure_inotify_off() {
    log "ensuring inotify=no in $MINIDLNA_CONF"
    if grep -qE '^[[:space:]]*inotify[[:space:]]*=' "$MINIDLNA_CONF"; then
        sed -i -E 's|^([[:space:]]*inotify[[:space:]]*=).*|\1no|' "$MINIDLNA_CONF"
    else
        printf '\ninotify=no\n' >> "$MINIDLNA_CONF"
    fi
}

install_minidlna_dropin() {
    log "installing minidlna drop-in: $MINIDLNA_DROPIN"
    mkdir -p "$MINIDLNA_DROPIN_DIR"
    cat > "$MINIDLNA_DROPIN" <<EOF
[Service]
Environment=LD_PRELOAD=$SHIM_SO
EOF
    systemctl daemon-reload
}

create_placeholder() {
    log "creating placeholder: $FIFO"
    rm -f "$FIFO"
    # Video-only placeholder with REAL timestamps spanning PLACEHOLDER_SECONDS
    # at 0.1 fps. minidlna probes it as a long-duration file, but it stays
    # tiny (a few hundred KB). The audio-less container still indexes as
    # video/mpeg; the LIVE stream carries audio via the shim+fifo path.
    ffmpeg -hide_banner -loglevel error -y \
        -f lavfi -i "color=c=black:s=${OUT_WIDTH}x${OUT_HEIGHT}" \
        -r 0.1 -t "$PLACEHOLDER_SECONDS" \
        -c:v libx264 -preset ultrafast -crf 40 -pix_fmt yuv420p \
        -f mpegts "$FIFO" \
        || die "placeholder creation failed"
    chown "$RUN_USER":"$RUN_USER" "$FIFO"
    chmod 644 "$FIFO"
}

wait_for_index() {
    log "waiting for minidlna to index the placeholder"
    local i
    for i in $(seq 1 120); do
        if sqlite3 "$MINIDLNA_DB" \
            "select id from details where path like '%${ITEM_NAME}%' limit 1;" 2>/dev/null \
            | grep -q .; then
            log "placeholder indexed"
            return 0
        fi
        sleep 1
    done
    die "minidlna did not index the placeholder; check the service and db path"
}

swap_to_fifo() {
    log "swapping placeholder -> fifo: $FIFO"
    rm -f "$FIFO"
    mkfifo "$FIFO"
    chown "$RUN_USER":"$RUN_USER" "$FIFO"
    chmod 644 "$FIFO"
}

setup() {
    need_root setup
    if pid_alive "$RUN_PID_FILE" || pid_alive "$WATCH_PID_FILE" || pid_alive "$FFMPEG_PID_FILE"; then
        die "the capture loop is running; stop it first with: $0 stop"
    fi
    command -v ffmpeg >/dev/null 2>&1 || die "ffmpeg is required"
    command -v sqlite3 >/dev/null 2>&1 || die "sqlite3 is required"

    install_shim
    configure_inotify_off
    install_minidlna_dropin
    create_placeholder

    log "stopping minidlna to clear any stale index row for the item"
    systemctl stop "$MINIDLNA_SERVICE"

    # Remove the old detail/object rows so the rescan re-probes the new
    # placeholder (resolution, DLNA_PN).
    sqlite3 "$MINIDLNA_DB" \
        "delete from objects where detail_id in (select id from details where path like '%${ITEM_NAME}%');
         delete from details where path like '%${ITEM_NAME}%';" \
        || true

    log "starting minidlna (indexes the placeholder)"
    systemctl start "$MINIDLNA_SERVICE"

    wait_for_index
    swap_to_fifo
    log "setup complete. Now: $0 install-service"
}

# --------------------------------------------------------------------- run --
run() {
    [ "$(id -u)" -eq 0 ] && die "run as $RUN_USER, not root, so ffmpeg can reach the X display"
    mkdir -p "$PID_DIR"
    echo $$ > "$RUN_PID_FILE"
    trap cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM

    ensure_watcher

    log "live capture loop starting (fifo=$FIFO)"

    # The fifo lives on an external drive that may not be mounted yet
    # (e.g. right after boot). Wait for it instead of dying.
    while [ ! -p "$FIFO" ]; do
        log "fifo missing; waiting: $FIFO"
        sleep 10
    done

    # Event channel between fifo-watch and this loop.
    rm -f "$EVENT_FIFO" "$STATE_FILE"
    mkfifo "$EVENT_FIFO" 2>/dev/null || true
    exec 9<>"$EVENT_FIFO"
    echo down > "$STATE_FILE"

    start_watcher

    local streaming=0 pending=0 session_start=0 ff_failures=0 now elapsed event

    while true; do
        if ! pid_alive "$WATCH_PID_FILE"; then
            if [ ! -p "$FIFO" ]; then
                while [ ! -p "$FIFO" ]; do sleep 10; done
            fi
            log "watcher died; restarting"
            start_watcher
        fi

        event=""
        if IFS= read -r -t 1 -u 9 event; then
            case "$event" in
                up)
                    echo up > "$STATE_FILE"
                    if [ "$streaming" = 0 ]; then
                        if x_ready; then
                            log "DLNA reader detected; starting ffmpeg"
                            session_start=$(date +%s); ff_failures=0
                            start_ffmpeg
                            streaming=1; pending=0
                        else
                            log "reader present but X display $SCREEN_DISPLAY not ready; waiting"
                            pending=1
                        fi
                    fi
                    ;;
                down)
                    echo down > "$STATE_FILE"
                    if [ "$streaming" = 1 ]; then
                        log "DLNA reader disconnected"
                        kill_pid_file "$FFMPEG_PID_FILE"
                        streaming=0
                    fi
                    pending=0
                    ;;
            esac
        fi

        # A reader arrived while X was down; start once X is up.
        if [ "$pending" = 1 ] && x_ready; then
            log "X display ready; starting ffmpeg"
            session_start=$(date +%s); ff_failures=0
            start_ffmpeg
            streaming=1; pending=0
        fi

        # Keep ffmpeg alive while a reader is present.
        if [ "$streaming" = 1 ]; then
            if ! pid_alive "$FFMPEG_PID_FILE"; then
                now=$(date +%s); elapsed=$((now - session_start))
                if [ "$MAX_SESSION_SECONDS" -gt 0 ] \
                   && [ "$elapsed" -ge "$MAX_SESSION_SECONDS" ]; then
                    log "max session length reached; closing stream"
                    kill_pid_file "$FFMPEG_PID_FILE"
                    kill_pid_file "$WATCH_PID_FILE"   # last writer closes -> reader EOF
                    streaming=0; pending=0
                    continue
                fi
                ff_failures=$((ff_failures + 1))
                if [ "$ff_failures" -ge 3 ]; then
                    log "ffmpeg keeps exiting; backing off 5s"
                    sleep 5
                    ff_failures=0
                fi
                log "ffmpeg exited unexpectedly (elapsed=${elapsed}s); restarting"
                session_start=$(date +%s)
                start_ffmpeg
            fi
        fi
    done
}

# ----------------------------------------------------------- service mgmt --
install_service() {
    local unit_dir unit_file
    unit_dir="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
    unit_file="$unit_dir/nv-surface-tv.service"
    mkdir -p "$unit_dir"

    cat > "$unit_file" <<EOF
[Unit]
Description=Surface TV live screen capture (minidlna fifo)

[Service]
Type=simple
ExecStart=$SCRIPT_DIR/nv-surface-tv.sh run
Restart=always
RestartSec=5
Environment=DISPLAY=$SCREEN_DISPLAY
Environment=XAUTHORITY=${XAUTHORITY:-$HOME/.Xauthority}
Environment=PATH=/usr/local/bin:/usr/bin:/bin

[Install]
WantedBy=default.target
EOF

    systemctl --user daemon-reload
    systemctl --user enable --now nv-surface-tv.service
    log "installed and started nv-surface-tv.service"
    log "follow it with: journalctl --user -u nv-surface-tv -f"
}

uninstall_service() {
    systemctl --user disable --now nv-surface-tv.service 2>/dev/null || true
    rm -f "${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/nv-surface-tv.service"
    systemctl --user daemon-reload
    log "removed nv-surface-tv user service"
}

# ------------------------------------------------------------------ status --
status() {
    echo "fifo:       $FIFO"
    if [ -p "$FIFO" ]; then
        echo "  type:       fifo"
    elif [ -f "$FIFO" ]; then
        echo "  type:       regular file (placeholder, not yet swapped)"
    else
        echo "  type:       missing"
    fi

    if pid_alive "$RUN_PID_FILE"; then
        echo "loop:       running (pid $(cat "$RUN_PID_FILE"))"
    else
        echo "loop:       stopped"
    fi

    if pid_alive "$WATCH_PID_FILE"; then
        echo "watcher:    running (pid $(cat "$WATCH_PID_FILE"))"
    else
        echo "watcher:    stopped"
    fi

    if pid_alive "$FFMPEG_PID_FILE"; then
        echo "ffmpeg:     running (pid $(cat "$FFMPEG_PID_FILE"))"
    else
        echo "ffmpeg:     stopped"
    fi

    if [ -f "$STATE_FILE" ]; then
        echo "reader:     $(cat "$STATE_FILE")"
    else
        echo "reader:     unknown"
    fi

    if command -v systemctl >/dev/null 2>&1 && systemctl --user is-active --quiet nv-surface-tv.service 2>/dev/null; then
        echo "service:    active"
    else
        echo "service:    not active"
    fi

    systemctl is-active --quiet "$MINIDLNA_SERVICE" \
        && echo "minidlna:   active" \
        || echo "minidlna:   inactive"
}

stop() {
    # Service-managed: systemctl is authoritative (killing the loop pid
    # directly would just make systemd restart it).
    if command -v systemctl >/dev/null 2>&1 && systemctl --user is-active --quiet nv-surface-tv.service 2>/dev/null; then
        log "stopping nv-surface-tv user service"
        systemctl --user stop nv-surface-tv.service
        return 0
    fi

    # Manual run: kill the loop; its EXIT trap cleans up watcher/ffmpeg.
    kill_pid_file "$RUN_PID_FILE"
    kill_pid_file "$FFMPEG_PID_FILE"
    kill_pid_file "$WATCH_PID_FILE"
    rm -f "$EVENT_FIFO" "$STATE_FILE"
    log "stopped capture loop"
}

usage() {
    cat <<EOF
Usage: $0 {setup|install-service|uninstall-service|run|status|stop}

  setup             (root, once) install shim + minidlna config + fifo
  install-service   (user)       install & enable the systemd --user service
  uninstall-service (user)       remove the service
  run               (user)       the capture loop (normally run by systemd)
  status            (user)       show current state
  stop              (user)       stop the service / a manual run

Config is at the top of this script. See README.org.
EOF
}

case "${1:-}" in
    setup)             setup ;;
    install-service)   install_service ;;
    uninstall-service) uninstall_service ;;
    run)               run ;;
    status)            status ;;
    stop)              stop ;;
    *)                 usage ;;
esac
