#!/system/bin/sh
#
# Uperf Sushiba Core Hardware Profile Dispatcher
# Google Tensor G3 (Zuma)
# Author: Sushiba
#

BASEDIR="$(dirname $(readlink -f "$0"))"
. "$BASEDIR/pathinfo.sh"
. "$BASEDIR/libcommon.sh"
feature_enabled powercfg || exit 0
GPU_MAX_NODE="/sys/devices/platform/1f000000.mali/scaling_max_freq"
MIF_MAX_NODE="/sys/class/devfreq/17000010.devfreq_mif/max_freq"
DSU_MAX_NODE="/sys/class/devfreq/17000090.devfreq_dsu/max_freq"

set_hardware_clocks() {
    local gpu="$1" mif="$2" dsu="$3"
    [ -f "$GPU_MAX_NODE" ] && { chmod 644 "$GPU_MAX_NODE" 2>/dev/null; echo "$gpu" > "$GPU_MAX_NODE" 2>/dev/null; }
    [ -f "$MIF_MAX_NODE" ] && { chmod 644 "$MIF_MAX_NODE" 2>/dev/null; echo "$mif" > "$MIF_MAX_NODE" 2>/dev/null; }
    [ -f "$DSU_MAX_NODE" ] && { chmod 644 "$DSU_MAX_NODE" 2>/dev/null; echo "$dsu" > "$DSU_MAX_NODE" 2>/dev/null; }
}

apply_hardware_profile() {
    local mode="$1"

    # 1. Update active mode flag atomically
    [ -d "$USER_PATH" ] && echo "$mode" > "$USER_PATH/cur_powermode.txt" 2>/dev/null
    echo "$mode" > "/data/cur_powermode.txt" 2>/dev/null

    # 2. Hardware DVFS Node Clamps
    case "$mode" in
        "powersave")
            set_hardware_clocks 580000 2288000 1328000
            ;;
        "balance")
            set_hardware_clocks 649000 2730000 1548000
            ;;
        "auto")
            set_hardware_clocks 723000 3172000 1704000
            ;;
        "performance"|"fast"|"pedestal")
            set_hardware_clocks 890000 3744000 1800000
            ;;
    esac
}

action="$1"
case "$1" in
    "powersave" | "balance" | "performance" | "fast" | "auto")
        apply_hardware_profile "$1"
        ;;
    "pedestal")
        apply_hardware_profile "performance"
        ;;
    "init")
        apply_hardware_profile "powersave"
        ;;
    *)
        echo "Failed to apply unknown action '$1'."
        ;;
esac
