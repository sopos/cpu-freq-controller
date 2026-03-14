# CPU Frequency Controller

A Linux bash script that monitors CPU temperature and dynamically adjusts maximum CPU frequency to maintain temperature within a defined range.

## Features

- **Automatic temperature management**: Monitors CPU temperature every 2 seconds
- **Smart frequency control**: Adjusts CPU frequency in 100MHz increments
- **Fan-aware operation**: Initial frequency reduction only triggers when cooling fan is active (ThinkPad)
- **Hysteresis support**: Prevents frequency oscillation with configurable temperature hysteresis
- **Graceful shutdown**: Restores original frequency limits on exit
- **Systemd integration**: Can run as a system service
- **Comprehensive logging**: Logs all frequency changes and temperature events to stderr

## Requirements

- Linux system with cpufreq support
- Root/sudo access
- Bash 4.0 or higher
- Systemd (optional, for service mode)

## Configuration

Key parameters can be configured at the top of `cpu-freq-controller.sh`:

| Parameter | Default | Description |
|-----------|---------|-------------|
| `TEMP_UPPER_LIMIT` | 65000 | Upper temperature limit in millidegrees (65°C) |
| `TEMP_HYSTERESIS` | 5000 | Temperature hysteresis in millidegrees (5°C) |
| `INITIAL_DELAY` | 30 | Delay before first frequency change (seconds) |
| `FREQ_STEP` | 100000 | Frequency adjustment step in kHz (100MHz) |
| `FREQ_DECREASE_INTERVAL` | 20 | Interval for decreasing frequency (seconds) |
| `FREQ_INCREASE_INTERVAL` | 10 | Interval for increasing frequency (seconds) |
| `MAX_FREQ_LIMIT` | 2000000 | Maximum frequency limit in kHz (2GHz) |

## Installation

### Systemd Service (Recommended)

1. Make the installation script executable:
   ```bash
   chmod +x install.sh
   ```

2. Run the installation script as root:
   ```bash
   sudo ./install.sh
   ```

3. Enable and start the service:
   ```bash
   sudo systemctl enable cpu-freq-controller
   sudo systemctl start cpu-freq-controller
   ```

4. Check service status:
   ```bash
   sudo systemctl status cpu-freq-controller
   ```

### Manual Execution

1. Make the script executable:
   ```bash
   chmod +x cpu-freq-controller.sh
   ```

2. Run the script as root:
   ```bash
   sudo ./cpu-freq-controller.sh
   ```

## Usage

### Viewing Logs

**Systemd journal** (when running as a service):
```bash
sudo journalctl -u cpu-freq-controller -f
```

**Manual execution** (logs to stderr):
```bash
sudo ./cpu-freq-controller.sh 2>&1 | tee cpu-freq.log
```

### Stopping the Service

```bash
sudo systemctl stop cpu-freq-controller
```

### Disabling Auto-start

```bash
sudo systemctl disable cpu-freq-controller
```

## Uninstallation

1. Make the uninstallation script executable:
   ```bash
   chmod +x uninstall.sh
   ```

2. Run the uninstallation script as root:
   ```bash
   sudo ./uninstall.sh
   ```

## How It Works

1. **Temperature Monitoring**: The script continuously monitors CPU temperature from `/sys/class/thermal/thermal_zone*/temp`

2. **Initial Trigger**: When temperature exceeds the upper limit for 30 seconds AND the cooling fan is active, frequency reduction begins

3. **Frequency Reduction**: Every 20 seconds, the maximum CPU frequency is reduced by 100MHz until temperature drops

4. **Frequency Increase**: When temperature drops below (upper limit - hysteresis), the frequency is increased by 100MHz every 10 seconds

5. **Frequency Range**: The script respects hardware limits (cpuinfo_min_freq to cpuinfo_max_freq) with an additional configurable limit (default 2GHz)

6. **Graceful Shutdown**: On exit (Ctrl+C or service stop), the script restores the original frequency limits

## ThinkPad Support

The script includes specific support for ThinkPad laptops:
- Detects fan activity from `/proc/acpi/ibm/fan`
- Falls back to hwmon interface if ThinkPad interface is unavailable

## Troubleshooting

### Script requires root access
The script needs root permissions to modify CPU frequency settings in `/sys/devices/system/cpu/cpu*/cpufreq/`.

### Fan detection not working
If you're not on a ThinkPad or the fan interface is different, the script will fall back to detecting any fan activity in `/sys/class/hwmon/hwmon*/fan*_input`. You may need to adjust the `is_fan_active()` function for your specific hardware.

### Frequency not changing
- Check that cpufreq is enabled: `ls /sys/devices/system/cpu/cpu0/cpufreq/`
- Verify current governor: `cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor`
- Some governors may prevent frequency changes

### Temperature not detected
- Check available thermal zones: `ls /sys/class/thermal/thermal_zone*/temp`
- The script uses the maximum temperature across all zones

## License

This script is provided as-is for educational and personal use.

## Contributing

This is a project-specific tool. For bugs or improvements, modify the script according to your needs.
