#!/system/bin/sh
# Central runtime feature registry and lifecycle operations.

FEATURE_KEYS="module_enabled uperf powercfg powercfg_once kernel_tweaks system_tweaks gms_freeze gms_doze thermal_guard ram_clean zram_compact google_jobs"
STARTUP_FEATURES="powercfg_once kernel_tweaks system_tweaks gms_freeze gms_doze thermal_guard powercfg uperf"

run_startup_feature() {
    case "$1" in
        powercfg_once)
            sh "$SCRIPT_PATH/powercfg_once.sh"
            ;;
        kernel_tweaks)
            sh "$SCRIPT_PATH/ktweak_opt.sh"
            ;;
        system_tweaks)
            sh "$SCRIPT_PATH/sys_opt.sh"
            ;;
        gms_freeze)
            sh "$SCRIPT_PATH/gms_freeze.sh" freeze &
            ;;
        gms_doze)
            sh "$SCRIPT_PATH/gms_doze.sh" &
            ;;
        thermal_guard)
            sh "$SCRIPT_PATH/thermal_guard.sh" &
            ;;
        powercfg)
            sh "$SCRIPT_PATH/powercfg_main.sh" auto
            ;;
        uperf)
            uperf_start
            ;;
        ram_clean|zram_compact|google_jobs|module_enabled)
            return 0
            ;;
        *)
            return 2
            ;;
    esac
}

stop_feature_runtime() {
    case "$1" in
        uperf)
            killall -9 uperf >/dev/null 2>&1
            ;;
        gms_freeze)
            sh "$SCRIPT_PATH/gms_freeze.sh" unfreeze >/dev/null 2>&1
            ;;
        gms_doze)
            stop_managed_process gms_doze
            dumpsys deviceidle unforce >/dev/null 2>&1
            ;;
        thermal_guard)
            stop_managed_process thermal_guard
            ;;
        powercfg)
            stop_managed_process smart_auto
            ;;
        ram_clean|zram_compact|google_jobs|module_enabled)
            return 0
            ;;
    esac
}

stop_all_features() {
    stop_feature_runtime gms_doze
    stop_feature_runtime thermal_guard
    stop_feature_runtime gms_freeze
    stop_feature_runtime uperf
    stop_feature_runtime powercfg
    dumpsys deviceidle unforce >/dev/null 2>&1
}

apply_feature_runtime() {
    case "$1" in
        uperf)
            uperf_stop >/dev/null 2>&1
            uperf_start
            ;;
        *)
            run_startup_feature "$1"
            ;;
    esac
}

reapply_enabled_features() {
    feature_enabled module_enabled || return 0
    for feature in $STARTUP_FEATURES; do
        feature_enabled "$feature" && apply_feature_runtime "$feature" >/dev/null 2>&1
    done
}
