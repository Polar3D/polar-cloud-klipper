# Changelog

All notable changes to this project will be documented in this file.

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
