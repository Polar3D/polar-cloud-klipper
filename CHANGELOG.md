# Changelog

All notable changes to this project will be documented in this file.

## [1.5.1] - 2026-04-07

### Fixed
- **Web UI (`/polar-cloud/`) was completely broken** since the WebSocket
  JSON-RPC migration, showing "Not Found" / loading errors on every call.
  Three interacting bugs caused this:
  - The agent's `_on_message` treated any JSON-RPC frame with an `id` as
    a response, silently dropping every incoming request from the web UI.
  - Handler return values were discarded, so even if dispatch had worked
    Moonraker's `call_method_with_response` would have hung until the
    websocket dropped.
  - The web UI posted to `/printer/jsonrpc` (which doesn't exist) using
    bare method names. Agent methods must be invoked via Moonraker's
    `server.extensions.request` wrapper.
- The web page now correctly reflects real-time service / connection /
  registration status on first load and across refreshes.

### Changed
- Agent no longer calls `connection.register_remote_method` on Moonraker
  for frontend handler registration. That endpoint registered methods as
  Klippy-bridged one-way calls — the wrong contract for request/response.
  Pre-registration isn't required for `server.extensions.request`;
  Moonraker forwards arbitrary method names to the agent's WebSocket
  connection. Startup is slightly faster and quieter as a result.

### Technical Notes
- `_on_message` now correctly distinguishes JSON-RPC requests, responses,
  and notifications and replies to requests with proper `result` /
  `error` envelopes (`-32601` for unknown method, `-32000` for handler
  exceptions).
- Both `_on_message` and `register_remote_method` now have docstrings
  explaining the protocol contract so this doesn't drift again.
- Verified end-to-end on Creality K1C with Moonraker v0.9.3-128. Fix is
  in shared code with no printer-specific assumptions; safe for all
  supported printer types.

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
- Smart cryptography handling: uses system packages or copies from Moonraker's environment
- Falls back to cryptography 3.3.2 (last version without Rust requirement) if needed
- Installs packages individually with graceful failure handling

## [1.1.0] - 2025-11-26

### Added
- **Export Logs button** in web interface for easy troubleshooting - generates comprehensive diagnostic file
- **Last Error display** in Connection Status section showing recent connection failures
- **Update instructions** in README for both UI and manual updates
- Bootstrap script for easier curl-based installation

### Changed
- **Manufacturer codes** now use proper Polar Cloud format (`kl`, `el`, `CR`, `ac`)
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
