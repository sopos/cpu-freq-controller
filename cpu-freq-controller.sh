#!/bin/bash

###############################################################################
# CPU Frequency Controller
# Monitors CPU temperature and dynamically adjusts maximum CPU frequency
# to maintain temperature within a defined range.
###############################################################################

set -euo pipefail

# Configuration file
CONFIG_FILE="/etc/cpu-freq-controller.conf"

# Default configuration values
TEMP_CHECK_INTERVAL=2           # Temperature check interval in seconds
TEMP_UPPER_LIMIT=66000          # Upper temperature limit in millidegrees (66°C)
TEMP_HYSTERESIS=2000            # Temperature hysteresis in millidegrees (2°C)
INITIAL_DELAY=30                # Delay before first frequency change (seconds)
FREQ_STEP=100000                # Frequency step in kHz (100MHz)
FREQ_DECREASE_INTERVAL=20       # Interval for decreasing frequency (seconds)
FREQ_INCREASE_INTERVAL=10       # Interval for increasing frequency (seconds)
MAX_FREQ_OVERRIDE=0             # Override max frequency in kHz (0=use hardware max)
REQUIRE_FAN_ACTIVE=1            # Require fan to be active before frequency reduction (1=yes, 0=no)
VERBOSE=${VERBOSE:-0}           # Verbose logging (0=minimal, 1=debug) - can be set via environment

# Load configuration from file if it exists
if [[ -f "$CONFIG_FILE" ]]; then
    # Source the config file in a safe way
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
fi

# Global variables
ORIGINAL_MAX_FREQ=""
CURRENT_MAX_FREQ=""
CPU_COUNT=0
CPUINFO_MIN_FREQ=0
CPUINFO_MAX_FREQ=0
TEMP_ABOVE_START_TIME=0
LAST_FREQ_CHANGE_TIME=0
ACTIVE_CONTROL=false
PREV_TEMP=0
ALLOWED_FREQS=()

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

build_allowed_frequency_map() {
    log "Building allowed frequency map..."

    # Start with empty array
    ALLOWED_FREQS=()

    # Test frequencies from min to max in FREQ_STEP increments
    local test_freq=$CPUINFO_MIN_FREQ

    while [[ $test_freq -le $CPUINFO_MAX_FREQ ]]; do
        # Try to set the frequency
        set_scaling_max_freq $test_freq

        # Read back what was actually set
        local actual_freq=$(get_current_scaling_max_freq)

        # Check if this frequency is already in our list (to avoid duplicates from clamping)
        local already_exists=false
        for freq in "${ALLOWED_FREQS[@]}"; do
            if [[ $freq -eq $actual_freq ]]; then
                already_exists=true
                break
            fi
        done

        # Add to list if not already there
        if [[ $already_exists == false ]]; then
            ALLOWED_FREQS+=($actual_freq)
        fi

        test_freq=$(($test_freq + $FREQ_STEP))
    done

    # Restore original frequency
    set_scaling_max_freq $ORIGINAL_MAX_FREQ
    CURRENT_MAX_FREQ=$ORIGINAL_MAX_FREQ

    log "Found ${#ALLOWED_FREQS[@]} allowed frequencies: ${ALLOWED_FREQS[0]} - ${ALLOWED_FREQS[-1]} kHz"
    debug "Allowed frequencies: ${ALLOWED_FREQS[*]}"
}

find_next_lower_freq() {
    local current=$1
    local result=$current

    # Find the highest frequency in ALLOWED_FREQS that is lower than current
    for freq in "${ALLOWED_FREQS[@]}"; do
        if [[ $freq -lt $current ]] && [[ $freq -gt $result || $result -eq $current ]]; then
            result=$freq
        fi
    done

    echo $result
}

find_next_higher_freq() {
    local current=$1
    local result=$CPUINFO_MAX_FREQ

    # Find the lowest frequency in ALLOWED_FREQS that is higher than current
    for freq in "${ALLOWED_FREQS[@]}"; do
        if [[ $freq -gt $current ]] && [[ $freq -lt $result ]]; then
            result=$freq
        fi
    done

    echo $result
}

initialize_frequency_control() {
    # Cache static CPU frequency information
    CPUINFO_MIN_FREQ=$(get_cpuinfo_min_freq)
    CPUINFO_MAX_FREQ=$(get_cpuinfo_max_freq)

    local hardware_max=$CPUINFO_MAX_FREQ

    # Apply manual override if configured
    if [[ $MAX_FREQ_OVERRIDE -gt 0 ]]; then
        if [[ $MAX_FREQ_OVERRIDE -lt $CPUINFO_MAX_FREQ ]]; then
            CPUINFO_MAX_FREQ=$MAX_FREQ_OVERRIDE
            log "Max frequency overridden: $hardware_max -> $CPUINFO_MAX_FREQ kHz ($(($CPUINFO_MAX_FREQ / 1000)) MHz)"
        else
            log "Max frequency override ($MAX_FREQ_OVERRIDE kHz) ignored: higher than hardware max ($CPUINFO_MAX_FREQ kHz)"
        fi
    fi

    ORIGINAL_MAX_FREQ=$(get_current_scaling_max_freq)
    CURRENT_MAX_FREQ=$ORIGINAL_MAX_FREQ
    log "Original max frequency: $ORIGINAL_MAX_FREQ kHz ($(($ORIGINAL_MAX_FREQ / 1000)) MHz)"

    log "CPU frequency range: $CPUINFO_MIN_FREQ - $CPUINFO_MAX_FREQ kHz ($(($CPUINFO_MIN_FREQ / 1000)) - $(($CPUINFO_MAX_FREQ / 1000)) MHz)"

    # Build map of allowed frequencies
    build_allowed_frequency_map
}

decrease_frequency() {
    local new_freq=$(find_next_lower_freq $CURRENT_MAX_FREQ)

    if [[ $new_freq -ne $CURRENT_MAX_FREQ ]]; then
        set_scaling_max_freq $new_freq
        log "Decreased max frequency to $new_freq kHz ($(($new_freq / 1000)) MHz)"
        LAST_FREQ_CHANGE_TIME=$(date +%s)
    else
        debug "Already at minimum frequency"
    fi
}

increase_frequency() {
    # If we're already at maximum frequency, nothing to do
    if [[ $CURRENT_MAX_FREQ -ge $CPUINFO_MAX_FREQ ]]; then
        debug "Already at maximum frequency"
        return
    fi

    local new_freq=$(find_next_higher_freq $CURRENT_MAX_FREQ)

    if [[ $new_freq -ne $CURRENT_MAX_FREQ ]]; then
        set_scaling_max_freq $new_freq
        log "Increased max frequency to $new_freq kHz ($(($new_freq / 1000)) MHz)"
        LAST_FREQ_CHANGE_TIME=$(date +%s)
    fi
}

jump_to_max_frequency() {
    # If we're already at or above max_freq, nothing to do
    if [[ $CURRENT_MAX_FREQ -ge $CPUINFO_MAX_FREQ ]]; then
        debug "Already at maximum frequency"
        return
    fi

    # Jump directly to max_freq
    set_scaling_max_freq $CPUINFO_MAX_FREQ
    log "Temperature very low - jumping to max frequency $CPUINFO_MAX_FREQ kHz ($(($CPUINFO_MAX_FREQ / 1000)) MHz)"
    LAST_FREQ_CHANGE_TIME=$(date +%s)
}

###############################################################################
# Main control loop
###############################################################################

control_loop() {
    local temp_raw
    local temp
    local current_time
    local temp_above_threshold=false

    while true; do
        temp_raw=$(get_cpu_temperature)
        current_time=$(date +%s)

        # Calculate average of current and previous temperature to smooth out wiggles
        if [[ $PREV_TEMP -eq 0 ]]; then
            # First reading - use raw value
            temp=$temp_raw
        else
            # Average of current and previous
            temp=$(( ($temp_raw + $PREV_TEMP) / 2 ))
        fi

        debug "Temperature: $(($temp_raw / 1000))°C (avg: $(($temp / 1000))°C), Max Freq: $(($CURRENT_MAX_FREQ / 1000)) MHz"

        # Check if temperature is above upper limit
        if [[ $temp -gt $TEMP_UPPER_LIMIT ]]; then
            if [[ $temp_above_threshold == false ]]; then
                # Temperature just crossed the threshold
                TEMP_ABOVE_START_TIME=$current_time
                temp_above_threshold=true
                log "Temperature above threshold: $(($temp / 1000))°C"
            fi

            # Check if we're at max_freq - if so, require initial delay + fan check
            local at_max_freq=false
            if [[ $CURRENT_MAX_FREQ -ge $CPUINFO_MAX_FREQ ]]; then
                at_max_freq=true
            fi

            # Apply initial delay + fan check when:
            # 1. Active control not yet started, OR
            # 2. We're at max_freq (requires delay before decreasing from max)
            if [[ $ACTIVE_CONTROL == false ]] || [[ $at_max_freq == true ]]; then
                local elapsed=$(($current_time - $TEMP_ABOVE_START_TIME))
                if [[ $elapsed -ge $INITIAL_DELAY ]]; then
                    # Check fan requirement if enabled
                    local fan_ok=true
                    if [[ $REQUIRE_FAN_ACTIVE -eq 1 ]]; then
                        if ! is_fan_active; then
                            fan_ok=false
                            debug "Waiting for fan to activate before controlling frequency"
                        fi
                    fi

                    if [[ $fan_ok == true ]]; then
                        if [[ $ACTIVE_CONTROL == false ]]; then
                            if [[ $REQUIRE_FAN_ACTIVE -eq 1 ]]; then
                                log "Initiating active frequency control (temp elevated for ${elapsed}s, fan active)"
                            else
                                log "Initiating active frequency control (temp elevated for ${elapsed}s)"
                            fi
                            ACTIVE_CONTROL=true
                        fi
                        decrease_frequency
                    fi
                fi
            else
                # Active control and not at max_freq - decrease frequency if interval elapsed
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

                # If temperature is very low (below UPPER_LIMIT - 2*HYSTERESIS), jump directly to max
                if [[ $temp -lt $(($TEMP_UPPER_LIMIT - 2 * $TEMP_HYSTERESIS)) ]]; then
                    if [[ $time_since_change -ge $FREQ_INCREASE_INTERVAL ]]; then
                        jump_to_max_frequency
                    fi
                # Otherwise, normal incremental increase
                elif [[ $time_since_change -ge $FREQ_INCREASE_INTERVAL ]]; then
                    increase_frequency
                fi
            fi
        fi

        # Update previous temperature for next iteration
        PREV_TEMP=$temp_raw

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
