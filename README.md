# Polar Cloud Klipper Integration

A standalone installer that adds Polar Cloud connectivity to existing Klipper installations. Works with Mainsail, Fluidd, and other Klipper web interfaces.

## Overview

This integration connects your Klipper-based 3D printer to the Polar Cloud service, enabling remote monitoring, print job management, and cloud-based slicing. Unlike maintaining a custom firmware image, this installer works with your existing Klipper setup.

## Compatibility

- ✅ **Mainsail** - Full compatibility
- ✅ **Fluidd** - Full compatibility  
- ✅ **OctoPrint + OctoKlipper** - Compatible
- ✅ **Custom Klipper setups** - Compatible
- ✅ **KIAUH installations** - Compatible
- ✅ **MainsailOS** - Fully compatible

### Supported Platforms
- Raspberry Pi OS (Debian-based)
- Ubuntu
- Other Debian/Ubuntu derivatives
- Systems with systemd init

## Features

- **Socket.IO Integration** - Real-time communication with Polar Cloud servers
- **Web Interface** - Standalone configuration UI at `/polar-cloud/`
- **Moonraker Plugin** - REST API integration for web interfaces
- **Automatic Registration** - Seamless printer registration with Polar Cloud
- **Status Monitoring** - Real-time connection and authentication status
- **Security** - RSA key-based authentication and secure communication

## Installation

### Prerequisites

Your system should have:
- Klipper installed and running
- Moonraker installed and running
- nginx web server (usually installed with Mainsail/Fluidd)
- Python 3.7+ with pip and venv

### Quick Install

```bash
# Download the installer
git clone https://github.com/Polar3D/polar-cloud-klipper.git
cd polar-cloud-klipper

# Run the installer
./install.sh
```

The installer will:
1. Detect your system configuration (user, paths, etc.)
2. Install required Python dependencies
3. Set up the Polar Cloud service
4. Configure Moonraker integration
5. Provide nginx configuration instructions

### Manual Steps

After installation, you may need to manually add nginx configuration. The installer will provide the exact configuration snippet to add to your nginx config.

> [!NOTE]
> If the installer cannot automatically configure nginx, it will create a standalone configuration on port 8080. You can access the web interface at `http://your-printer-ip:8080/polar-cloud/`.

## Usage

### Web Interface Setup

1. Navigate to `http://your-printer-ip/polar-cloud/`
2. Enter your Polar Cloud credentials:
   - Username: Your Polar Cloud username
   - PIN: Get from [https://polar3d.com/](https://polar3d.com/)
3. Select your machine type, manufacturer, and printer model
4. Save settings and wait for connection

### API Integration

The Moonraker plugin provides REST API endpoints:

```bash
# Get status
GET /printer/polar_cloud/status

# Update configuration  
POST /printer/polar_cloud/config
```

### Service Management

```bash
# Check service status
sudo systemctl status polar_cloud

# View logs
sudo journalctl -u polar_cloud -f

# Restart service
sudo systemctl restart polar_cloud

# Test connection
cd ~/polar-cloud && ./venv/bin/python test_socketio.py
```

## Configuration

Configuration is stored in `~/printer_data/config/polar_cloud.conf`:

```ini
[polar_cloud]
# Server configuration
server_url = https://printer4.polar3d.com

# Credentials
username = your_username
pin = your_pin
serial_number = auto_generated

# Printer settings
machine_type = Cartesian
printer_type = Ender 3
manufacturer = generic
webcam_enabled = true

# Webcam settings
# flip_horizontal = false
# flip_vertical = false
# rotation = 0

# Advanced settings
verbose = false
status_interval = 60
max_image_size = 150000
```

## Troubleshooting

### Exporting Diagnostic Logs

The easiest way to troubleshoot connection issues is to use the **Export Logs** button in the web interface. This generates a comprehensive diagnostic file containing:
- System information
- Network connectivity tests
- Service status
- Recent log entries
- Configuration (with PIN masked)

### Viewing Logs

**Real-time logs:**
```bash
sudo journalctl -u polar_cloud -f
```

**Recent log entries:**
```bash
sudo journalctl -u polar_cloud --since "10 minutes ago"
```

**Application log file:**
```bash
cat ~/printer_data/logs/polar_cloud.log
```

### Connection Issues

1. **Service not starting**:
   ```bash
   sudo systemctl status polar_cloud
   sudo journalctl -u polar_cloud -f
   ```

2. **Registration failures**:
   - Verify credentials at [https://polar3d.com/](https://polar3d.com/)
   - Check firewall settings (port 443 outbound)
   - Review service logs for specific error messages
   - The web interface will display the last error in the Connection Status section

3. **Web interface not accessible**:
   - Ensure nginx configuration was added correctly
   - Test nginx config: `sudo nginx -t`
   - Restart nginx: `sudo systemctl restart nginx`

4. **Printer not in dropdown list**:
   - Printer types are loaded from Polar Cloud's database
   - If your exact printer model isn't listed, select a similar model or use "Cartesian" as a generic option
   - CoreXY printers (like Voron) can use the "Cartesian" machine type

### Common Issues

- **"Registration failed: SUCCESS"**: Indicates server format mismatch, check logs for details
- **"Authentication failed"**: Verify your username and PIN are correct, and that your account is active on polar3d.com
- **Repeated registration attempts**: Service unable to save serial number, check file permissions for `~/printer_data/config/`
- **Web interface shows incorrect status**: Status file may not be updating, restart both services

### Debug Mode

Enable verbose logging in configuration:
```ini
verbose = true
```

Then restart the service and monitor logs:
```bash
sudo systemctl restart polar_cloud
sudo journalctl -u polar_cloud -f
```

## Uninstallation

To remove the Polar Cloud integration:

```bash
./uninstall.sh
```

This will:
- Stop and remove the systemd service
- Remove all Polar Cloud files
- Remove the Moonraker plugin
- Optionally remove configuration (preserves credentials by default)

## Development

### File Structure

```
polar-cloud-klipper/
├── install.sh              # Main installer script
├── uninstall.sh            # Removal script
├── requirements.txt        # Python dependencies
├── src/                    # Source files
│   ├── polar_cloud.py     # Main service
│   ├── polar_cloud_moonraker.py  # Moonraker plugin
│   └── polar_cloud_web.html      # Web interface
├── config/                 # Configuration templates
│   ├── polar_cloud.service.template
│   ├── polar_cloud.conf.template
│   └── nginx-snippet.conf
└── scripts/                # Utility scripts
    ├── test_socketio.py    # Connection testing
    └── diagnose_moonraker.py  # Diagnostics
```

### Socket.IO Protocol

The integration uses Socket.IO to communicate with Polar Cloud servers:

1. **Registration Flow**:
   - Connect to `https://printer4.polar3d.com`
   - Receive `welcome` event with challenge
   - Send `register` event with credentials and public key
   - Handle `registerResponse` with assigned serial number
   - Reconnect and authenticate with `hello` event

2. **Event Handlers**:
   - `connect` / `disconnect` - Connection state management
   - `welcome` - Server challenge reception
   - `registerResponse` - Registration result processing
   - `helloResponse` - Authentication confirmation

### Contributing

1. Fork the repository
2. Create a feature branch
3. Test on multiple platforms (Pi OS, Ubuntu, etc.)
4. Test with both Mainsail and Fluidd
5. Submit a pull request

## Support

- **Issues**: Report bugs and feature requests via GitHub Issues
- **Documentation**: Check the troubleshooting section above
- **Community**: Polar Cloud community forums

## License

[Insert your preferred license here]

## Credits

Based on the Polar Cloud integration originally developed for MainsailOS. This standalone version enables broader compatibility across Klipper installations.
