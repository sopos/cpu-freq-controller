# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

CPU frequency controller - a bash script that monitors CPU temperature and dynamically adjusts maximum CPU frequency to maintain temperature within a defined range.

**Target Platform**: Linux systems (specifically tested on ThinkPad)

## Project Status

This is a greenfield project. The requirements are documented in `popis.txt` (in Czech).

## Requirements Summary

The script must:
- Monitor CPU temperature at 2-second intervals (uses average of last two readings to smooth fluctuations)
- Use Linux cpufreq standard paths for frequency control
- Maintain temperature within a defined range (upper limit + hysteresis)
- Adjust frequency in 100MHz increments
- Initial frequency change: after 30s of elevated temperature AND when cooling fan is active (applies at startup and when at cpuinfo_max_freq; fan requirement is configurable)
- Frequency reduction interval: 20s
- Frequency increase interval: 10s
- Operating range: uses allowed frequency map built at startup; automatically adapts to CPU-specific frequencies, gaps, and discrete frequency points
- Fast recovery: if temperature drops below (upper limit - 2×hysteresis), jump directly to cpuinfo_max_freq

## Technical Details

**CPU Frequency Control**:
- Use Linux sysfs cpufreq interface: `/sys/devices/system/cpu/cpu*/cpufreq/`
- Key files: `cpuinfo_min_freq`, `cpuinfo_max_freq`, `scaling_max_freq`, `scaling_min_freq`

**Temperature Monitoring**:
- Read from `/sys/class/thermal/thermal_zone*/temp`
- ThinkPad-specific: detect fan state from `/proc/acpi/ibm/fan` or hwmon

**Permissions**:
- Script will require root/sudo access to modify cpufreq scaling parameters
- Consider implementing as systemd service for production use

## Development Notes

- The script should handle graceful shutdown and restore original frequency limits
- Implement proper logging for debugging temperature/frequency changes
- Consider using `cpupower` as fallback/alternative to direct sysfs manipulation
