#!/bin/bash

###############################################################################
# CPU Frequency Controller
# Monitors CPU temperature and dynamically adjusts maximum CPU frequency
# to maintain temperature within a defined range.
###############################################################################

set -euo pipefail

# Configuration
TEMP_CHECK_INTERVAL=2           # Temperature check interval in seconds
TEMP_UPPER_LIMIT=65000          # Upper temperature limit in millidegrees (65°C)
TEMP_HYSTERESIS=5000            # Temperature hysteresis in millidegrees (5°C)
INITIAL_DELAY=30                # Delay before first frequency change (seconds)
FREQ_STEP=100000                # Frequency step in kHz (100MHz)
FREQ_DECREASE_INTERVAL=20       # Interval for decreasing frequency (seconds)
FREQ_INCREASE_INTERVAL=10       # Interval for increasing frequency (seconds)
MAX_FREQ_LIMIT=2000000          # Maximum frequency limit in kHz (2GHz)

# Global variables
ORIGINAL_MAX_FREQ=""
CURRENT_MAX_FREQ=""
CPU_COUNT=0
TEMP_ABOVE_START_TIME=0
LAST_FREQ_CHANGE_TIME=0
ACTIVE_CONTROL=false

# Logging
VERBOSE=${VERBOSE:-1}

###############################################################################
# Logging functions
###############################################################################

log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
    echo "$msg" >&2
}

debug() {
    if [[ $VERBOSE -ge 1 ]]; then
        local msg="[$(date '+%Y-%m-%d %H:%M:%S')] DEBUG: $*"
        echo "$msg" >&2
    fi
}

###############################################################################
# System detection and initialization
###############################################################################

detect_cpu_count() {
    CPU_COUNT=$(nproc)
    log "Detected $CPU_COUNT CPU cores"
}

get_cpu_freq_path() {
    local cpu_id=$1
    echo "/sys/devices/system/cpu/cpu${cpu_id}/cpufreq"
}

get_cpuinfo_min_freq() {
    local cpu_path=$(get_cpu_freq_path 0)
    cat "${cpu_path}/cpuinfo_min_freq"
}

get_cpuinfo_max_freq() {
    local cpu_path=$(get_cpu_freq_path 0)
    cat "${cpu_path}/cpuinfo_max_freq"
}

get_current_scaling_max_freq() {
    local cpu_path=$(get_cpu_freq_path 0)
    cat "${cpu_path}/scaling_max_freq"
}

set_scaling_max_freq() {
    local freq=$1
    for ((i=0; i<CPU_COUNT; i++)); do
        local cpu_path=$(get_cpu_freq_path $i)
        echo "$freq" > "${cpu_path}/scaling_max_freq"
    done
    CURRENT_MAX_FREQ=$freq
}

###############################################################################
# Temperature monitoring
###############################################################################

get_cpu_temperature() {
    local max_temp=0
    local temp

    for zone in /sys/class/thermal/thermal_zone*/temp; do
        if [[ -f "$zone" ]]; then
            temp=$(cat "$zone")
            if [[ $temp -gt $max_temp ]]; then
                max_temp=$temp
            fi
        fi
    done

    echo "$max_temp"
}

###############################################################################
# Fan detection (ThinkPad-specific)
###############################################################################

is_fan_active() {
    # Try ThinkPad-specific ACPI interface
    if [[ -f /proc/acpi/ibm/fan ]]; then
        local fan_speed=$(grep "^speed:" /proc/acpi/ibm/fan | awk '{print $2}')
        if [[ -n "$fan_speed" && "$fan_speed" != "0" ]]; then
            return 0  # Fan is active
        fi
    fi

    # Try hwmon interface
    for hwmon in /sys/class/hwmon/hwmon*/fan*_input; do
        if [[ -f "$hwmon" ]]; then
            local fan_rpm=$(cat "$hwmon")
            if [[ $fan_rpm -gt 0 ]]; then
                return 0  # Fan is active
            fi
        fi
    done

    return 1  # Fan is not active or cannot be detected
}

###############################################################################
# Frequency control logic
###############################################################################

initialize_frequency_control() {
    ORIGINAL_MAX_FREQ=$(get_current_scaling_max_freq)
    CURRENT_MAX_FREQ=$ORIGINAL_MAX_FREQ
    log "Original max frequency: $ORIGINAL_MAX_FREQ kHz ($(($ORIGINAL_MAX_FREQ / 1000)) MHz)"

    local min_freq=$(get_cpuinfo_min_freq)
    local max_freq=$(get_cpuinfo_max_freq)
    log "CPU frequency range: $min_freq - $max_freq kHz ($(($min_freq / 1000)) - $(($max_freq / 1000)) MHz)"
    log "Frequency will be limited to max $MAX_FREQ_LIMIT kHz ($(($MAX_FREQ_LIMIT / 1000)) MHz)"
}

decrease_frequency() {
    local min_freq=$(get_cpuinfo_min_freq)
    local new_freq

    # If we're above MAX_FREQ_LIMIT (2GHz), jump directly to MAX_FREQ_LIMIT
    # This skips the excluded range between 2GHz and cpuinfo_max_freq
    if [[ $CURRENT_MAX_FREQ -gt $MAX_FREQ_LIMIT ]]; then
        new_freq=$MAX_FREQ_LIMIT
    else
        # Normal decrement by FREQ_STEP
        new_freq=$(($CURRENT_MAX_FREQ - $FREQ_STEP))

        if [[ $new_freq -lt $min_freq ]]; then
            new_freq=$min_freq
        fi
    fi

    if [[ $new_freq -ne $CURRENT_MAX_FREQ ]]; then
        set_scaling_max_freq $new_freq
        log "Decreased max frequency to $new_freq kHz ($(($new_freq / 1000)) MHz)"
        LAST_FREQ_CHANGE_TIME=$(date +%s)
    else
        debug "Already at minimum frequency"
    fi
}

increase_frequency() {
    local max_freq=$(get_cpuinfo_max_freq)
    local new_freq

    # If we're at MAX_FREQ_LIMIT (2GHz) and cpuinfo_max_freq is higher, jump to cpuinfo_max_freq
    # This skips the excluded range between 2GHz and cpuinfo_max_freq
    if [[ $CURRENT_MAX_FREQ -eq $MAX_FREQ_LIMIT && $max_freq -gt $MAX_FREQ_LIMIT ]]; then
        new_freq=$max_freq
    else
        # Normal increment by FREQ_STEP
        new_freq=$(($CURRENT_MAX_FREQ + $FREQ_STEP))

        # Don't enter the excluded range - cap at MAX_FREQ_LIMIT if we would exceed it
        if [[ $new_freq -gt $MAX_FREQ_LIMIT && $MAX_FREQ_LIMIT -lt $max_freq ]]; then
            new_freq=$MAX_FREQ_LIMIT
        fi

        # Overall cap at cpuinfo_max_freq
        if [[ $new_freq -gt $max_freq ]]; then
            new_freq=$max_freq
        fi
    fi

    if [[ $new_freq -ne $CURRENT_MAX_FREQ ]]; then
        set_scaling_max_freq $new_freq
        log "Increased max frequency to $new_freq kHz ($(($new_freq / 1000)) MHz)"
        LAST_FREQ_CHANGE_TIME=$(date +%s)
    else
        debug "Already at maximum frequency"
    fi
}

###############################################################################
# Main control loop
###############################################################################

control_loop() {
    local temp
    local current_time
    local temp_above_threshold=false

    while true; do
        temp=$(get_cpu_temperature)
        current_time=$(date +%s)

        debug "Temperature: $(($temp / 1000))°C, Max Freq: $(($CURRENT_MAX_FREQ / 1000)) MHz"

        # Check if temperature is above upper limit
        if [[ $temp -gt $TEMP_UPPER_LIMIT ]]; then
            if [[ $temp_above_threshold == false ]]; then
                # Temperature just crossed the threshold
                TEMP_ABOVE_START_TIME=$current_time
                temp_above_threshold=true
                log "Temperature above threshold: $(($temp / 1000))°C"
            fi

            # Check if we should start active control
            if [[ $ACTIVE_CONTROL == false ]]; then
                local elapsed=$(($current_time - $TEMP_ABOVE_START_TIME))
                if [[ $elapsed -ge $INITIAL_DELAY ]]; then
                    if is_fan_active; then
                        log "Initiating active frequency control (temp elevated for ${elapsed}s, fan active)"
                        ACTIVE_CONTROL=true
                        decrease_frequency
                    else
                        debug "Waiting for fan to activate before controlling frequency"
                    fi
                fi
            else
                # Active control - decrease frequency if interval elapsed
                local time_since_change=$(($current_time - $LAST_FREQ_CHANGE_TIME))
                if [[ $time_since_change -ge $FREQ_DECREASE_INTERVAL ]]; then
                    decrease_frequency
                fi
            fi
        # Check if temperature is below lower limit (upper - hysteresis)
        elif [[ $temp -lt $(($TEMP_UPPER_LIMIT - $TEMP_HYSTERESIS)) ]]; then
            if [[ $temp_above_threshold == true ]]; then
                log "Temperature below threshold: $(($temp / 1000))°C"
                temp_above_threshold=false
                TEMP_ABOVE_START_TIME=0
            fi

            # Increase frequency if we're in active control
            if [[ $ACTIVE_CONTROL == true ]]; then
                local time_since_change=$(($current_time - $LAST_FREQ_CHANGE_TIME))
                if [[ $time_since_change -ge $FREQ_INCREASE_INTERVAL ]]; then
                    increase_frequency
                fi
            fi
        fi

        sleep $TEMP_CHECK_INTERVAL
    done
}

###############################################################################
# Cleanup and signal handling
###############################################################################

cleanup() {
    log "Shutting down CPU frequency controller"

    if [[ -n "$ORIGINAL_MAX_FREQ" ]]; then
        log "Restoring original max frequency: $ORIGINAL_MAX_FREQ kHz"
        set_scaling_max_freq "$ORIGINAL_MAX_FREQ"
    fi

    exit 0
}

trap cleanup SIGINT SIGTERM EXIT

###############################################################################
# Main entry point
###############################################################################

main() {
    # Check if running as root
    if [[ $EUID -ne 0 ]]; then
        echo "This script must be run as root (requires access to cpufreq sysfs)" >&2
        exit 1
    fi

    log "=== CPU Frequency Controller Starting ==="
    log "Configuration:"
    log "  Temperature upper limit: $(($TEMP_UPPER_LIMIT / 1000))°C"
    log "  Temperature hysteresis: $(($TEMP_HYSTERESIS / 1000))°C"
    log "  Initial delay: ${INITIAL_DELAY}s"
    log "  Frequency step: $(($FREQ_STEP / 1000)) MHz"
    log "  Decrease interval: ${FREQ_DECREASE_INTERVAL}s"
    log "  Increase interval: ${FREQ_INCREASE_INTERVAL}s"

    detect_cpu_count
    initialize_frequency_control

    log "Starting temperature monitoring loop..."
    control_loop
}

main "$@"
