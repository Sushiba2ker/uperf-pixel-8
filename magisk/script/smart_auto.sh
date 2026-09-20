#!/system/bin/sh
#
# Smart auto: clamp GPU / MIF / DSU from screen, camera ISP, MFC
# video codec, Mali util, battery temp, and foreground per-app rules.
# Does not write cur_powermode.txt — uperf CPU switcher keeps inode "auto".
# Author: Sushiba
#

BASEDIR="$(dirname $(readlink -f "$0"))"
. "$BASEDIR/pathinfo.sh"
. "$BASEDIR/libcommon.sh"

feature_enabled powercfg || exit 0
acquire_daemon_lock smart_auto || exit 0

CAM_CUR="/sys/class/devfreq/17000050.devfreq_cam/cur_freq"
CAM_MIN="/sys/class/devfreq/17000050.devfreq_cam/min_freq"
INTCAM_CUR="/sys/class/devfreq/17000030.devfreq_intcam/cur_freq"
INTCAM_MIN="/sys/class/devfreq/17000030.devfreq_intcam/min_freq"
TNR_CUR="/sys/class/devfreq/17000060.devfreq_tnr/cur_freq"
TNR_MIN="/sys/class/devfreq/17000060.devfreq_tnr/min_freq"
MFC_CUR="/sys/class/devfreq/17000070.devfreq_mfc/cur_freq"
MFC_MIN="/sys/class/devfreq/17000070.devfreq_mfc/min_freq"
JPEG_RT="/sys/class/video4linux/video12/device/power/runtime_status"
BL_NODE="/sys/class/backlight/panel0-backlight/brightness"
GPU_MAX_NODE="/sys/devices/platform/1f000000.mali/scaling_max_freq"
GPU_UTIL_NODE="/sys/devices/platform/1f000000.mali/utilization"
BAT_TEMP_NODE="/sys/class/power_supply/battery/temp"
TOP_PROCS="/dev/cpuset/top-app/cgroup.procs"
PERAPP="$USER_PATH/perapp_powermode.txt"
[ -f "$PERAPP" ] || PERAPP="$MODULE_PATH/config/perapp_powermode.txt"
MODE_FILE="$RUNTIME_PATH/smart_auto.mode"
REASON_FILE="$RUNTIME_PATH/smart_auto.reason"

LAST_HW=""
CAM_HOLD=0
UTIL_HOLD=0

# Battery temp is decidegrees (318 = 31.8C).
THERMAL_BALANCE=400
THERMAL_POWERSAVE=450

cleanup() {
    rm -f "$PID_FILE"
}
trap cleanup EXIT
trap 'exit 0' INT TERM

gt_min() {
    local cur min
    [ -f "$1" ] && [ -f "$2" ] || return 1
    cur="$(cat "$1" 2>/dev/null)"
    min="$(cat "$2" 2>/dev/null)"
    case "$cur" in ''|*[!0-9]*) return 1 ;; esac
    case "$min" in ''|*[!0-9]*) return 1 ;; esac
    [ "$cur" -gt "$min" ]
}

is_screen_off() {
    local bl=0
    [ -f "$BL_NODE" ] && bl="$(cat "$BL_NODE" 2>/dev/null)"
    case "$bl" in
        0) return 0 ;;
        *) return 1 ;;
    esac
}

is_camera_busy() {
    gt_min "$CAM_CUR" "$CAM_MIN" && return 0
    gt_min "$INTCAM_CUR" "$INTCAM_MIN" && return 0
    gt_min "$TNR_CUR" "$TNR_MIN" && return 0
    [ -f "$JPEG_RT" ] && [ "$(cat "$JPEG_RT" 2>/dev/null)" = "active" ] && return 0
    return 1
}

is_video_busy() {
    gt_min "$MFC_CUR" "$MFC_MIN"
}

gpu_util() {
    local u=0
    [ -f "$GPU_UTIL_NODE" ] && u="$(cat "$GPU_UTIL_NODE" 2>/dev/null)"
    case "$u" in
        ''|*[!0-9]*) echo 0 ;;
        *) echo "$u" ;;
    esac
}

battery_temp() {
    local t=0
    [ -f "$BAT_TEMP_NODE" ] && t="$(cat "$BAT_TEMP_NODE" 2>/dev/null)"
    case "$t" in
        ''|*[!0-9]*) echo 0 ;;
        *) echo "$t" ;;
    esac
}

fg_package() {
    local p cmd pkg
    [ -f "$TOP_PROCS" ] || return 0
    for p in $(cat "$TOP_PROCS" 2>/dev/null); do
        cmd="$(tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null)"
        [ -n "$cmd" ] || continue
        pkg="${cmd%% *}"
        pkg="${pkg##*/}"
        pkg="${pkg%%:*}"
        case "$pkg" in
            system_server|surfaceflinger|zygote*|app_process*) continue ;;
            android.hardware.*|vendor.google.*) continue ;;
            *inputmethod*|*systemui*) continue ;;
        esac
        case "$pkg" in
            *.*)
                echo "$pkg"
                return 0
                ;;
        esac
    done
}

lookup_mode() {
    local pkg="$1" key mode def="balance"
    [ -f "$PERAPP" ] || { echo "$def"; return 0; }
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            \#*|'') continue ;;
        esac
        set -- $line
        key="$1"
        mode="$2"
        [ -n "$mode" ] || continue
        case "$key" in
            \*) def="$mode" ;;
            "$pkg")
                echo "$mode"
                return 0
                ;;
        esac
    done < "$PERAPP"
    echo "$def"
}

normalize_hw() {
    case "$1" in
        powersave) echo powersave ;;
        balance) echo balance ;;
        performance|fast|pedestal) echo performance ;;
        *) echo powersave ;;
    esac
}

rank_of() {
    case "$1" in
        powersave) echo 0 ;;
        balance) echo 1 ;;
        performance) echo 2 ;;
        *) echo 0 ;;
    esac
}

mode_from_rank() {
    case "$1" in
        0) echo powersave ;;
        1) echo balance ;;
        *) echo performance ;;
    esac
}

# Never let a lift exceed the thermal ceiling.
clamp_thermal() {
    local mode="$1" temp cap rank capr
    mode="$(normalize_hw "$mode")"
    temp="$(battery_temp)"
    cap=""
    if [ "$temp" -ge "$THERMAL_POWERSAVE" ]; then
        cap="powersave"
    elif [ "$temp" -ge "$THERMAL_BALANCE" ]; then
        cap="balance"
    else
        echo "$mode"
        return 0
    fi
    rank="$(rank_of "$mode")"
    capr="$(rank_of "$cap")"
    if [ "$rank" -gt "$capr" ]; then
        echo "$cap"
    else
        echo "$mode"
    fi
}

# Raise floor without dropping a higher per-app request.
lift_floor() {
    local mode="$1" floor="$2" rank floorr
    mode="$(normalize_hw "$mode")"
    floor="$(normalize_hw "$floor")"
    rank="$(rank_of "$mode")"
    floorr="$(rank_of "$floor")"
    if [ "$floorr" -gt "$rank" ]; then
        echo "$floor"
    else
        echo "$mode"
    fi
}

expected_gpu() {
    case "$1" in
        powersave) echo 580000 ;;
        balance) echo 649000 ;;
        performance) echo 890000 ;;
        *) echo 580000 ;;
    esac
}

apply_hw() {
    local mode want have reason="$2"
    mode="$(normalize_hw "$1")"
    want="$(expected_gpu "$mode")"
    have="$(cat "$GPU_MAX_NODE" 2>/dev/null)"
    if [ "$mode" = "$LAST_HW" ] && [ "$have" = "$want" ]; then
        return 0
    fi
    sh "$SCRIPT_PATH/powercfg_main.sh" _hw "$mode"
    LAST_HW="$mode"
    mkdir -p "$RUNTIME_PATH" 2>/dev/null
    printf '%s\n' "$mode" > "$MODE_FILE"
    printf '%s\n' "${reason:-$mode}" > "$REASON_FILE"
}

inode_is_auto() {
    local cur=""
    [ -f "$USER_PATH/cur_powermode.txt" ] && cur="$(tr -d '[:space:]' < "$USER_PATH/cur_powermode.txt" 2>/dev/null)"
    [ "$cur" = "auto" ]
}

decide() {
    local mode util pkg

    PICKED="powersave"
    REASON="idle"

    if is_screen_off; then
        CAM_HOLD=0
        UTIL_HOLD=0
        PICKED="powersave"
        REASON="screen_off"
        return 0
    fi

    if is_camera_busy; then
        CAM_HOLD=5
    elif [ "$CAM_HOLD" -gt 0 ]; then
        CAM_HOLD=$((CAM_HOLD - 1))
    fi

    if [ "$CAM_HOLD" -gt 0 ]; then
        PICKED="performance"
        REASON="camera"
        return 0
    fi

    if is_video_busy; then
        PICKED="balance"
        REASON="video"
        return 0
    fi

    util="$(gpu_util)"
    if [ "$util" -ge 55 ]; then
        UTIL_HOLD=3
    elif [ "$UTIL_HOLD" -gt 0 ]; then
        UTIL_HOLD=$((UTIL_HOLD - 1))
    fi

    pkg="$(fg_package)"
    mode="$(lookup_mode "$pkg")"
    PICKED="$(normalize_hw "$mode")"
    REASON="app:${pkg:-none}:$mode"

    if [ "$UTIL_HOLD" -gt 0 ]; then
        PICKED="$(lift_floor "$PICKED" balance)"
        REASON="$REASON gpu_util:$util"
    fi
}

while feature_enabled powercfg; do
    if ! inode_is_auto; then
        sleep 2
        continue
    fi

    decide
    apply_hw "$(clamp_thermal "$PICKED")" "$REASON temp:$(battery_temp)"

    if is_screen_off; then
        sleep 2
    else
        sleep 1
    fi
done
