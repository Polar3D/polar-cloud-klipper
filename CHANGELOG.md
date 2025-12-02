# Changelog

All notable changes to this project will be documented in this file.

## [1.2.0] - 2025-12-02

### Added
- **Creality K1/K1C/K1 Max support** with dedicated `install_k1.sh` installer
- **K1-specific service scripts** using init.d instead of systemd
- **K1 uninstaller** (`uninstall_k1.sh`) for clean removal
- **Automatic K1 detection** in bootstrap.sh to select appropriate installer

### Changed
- Bootstrap script now auto-detects K1 series and uses K1-specific installer
- README updated with comprehensive K1 installation instructions
- File structure documentation updated to include K1-specific files

### Technical Details (K1 Support)
- Uses system Python3 (pre-installed on K1 firmware)
- Uses virtualenv with `--system-site-packages` for better compatibility
- Service managed via `/usr/data/polar_cloud_service.sh` script
- Startup via `/etc/init.d/S99polar_cloud`
- Logs stored at `/usr/data/printer_data/logs/polar_cloud.log`
- Works with K1's pre-installed Moonraker at `/usr/data/moonraker`

## [1.1.0] - 2025-11-26

### Added
- **Export Logs button** in web interface for easy troubleshooting - generates comprehensive diagnostic file
- **Last Error display** in Connection Status section showing recent connection failures
- **Update instructions** in README for both UI and manual updates
- Bootstrap script for easier curl-based installation

### Changed
- **Manufacturer codes** now use proper Polar Cloud format (`kl`, `el`, `cre`, `ac`)
- **Improved error messaging** - connection failures now show specific error details instead of "Unknown error"
- **Faster service shutdown** - added 5-second timeout to prevent hanging during stop/restart
- **Better dropdown styling** for Windows compatibility (dark background on select options)
- **Connection Status panel** now uses vertical layout for better text fitting at various screen widths
- Uninstaller now prompts for sudo password upfront to avoid mid-process hangs

### Fixed
- Manufacturer dropdown now correctly restores saved values (handles both old and new config formats)
- Fixed nginx configuration detection and backup location
- Improved proxy detection for web interface

## [1.0.2] - Previous Release

See git history for earlier changes.
