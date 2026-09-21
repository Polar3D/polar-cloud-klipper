# Changelog

All notable changes to this project will be documented in this file.

## [1.6.0] - 2026-09-21

### Added
- **Printer make auto-detection on Creality K1-series printers.** The
  installers write a generic `printer_type = Cartesian`, so K1s reported a
  generic make to Polar Cloud. The agent now reads the model from Creality's
  `system_config.json` and fills in `Creality K1`, `Creality K1C`,
  `Creality K1 Max` or `Creality K1 SE` (names from the server's
  `printerMakes` list). It only replaces the placeholder value, never a
  make the user chose, and existing installs pick it up on their next start.
- **Webcam on Creality K1 firmware 1.3.5.x.** That firmware stopped
  starting `mjpg_streamer` on port 8080 and streams over WebRTC only, so
  Polar Cloud got no images and Mainsail's `/webcam/` returned 502. If the
  camera is running and nothing serves port 8080, the agent now starts
  `mjpg_streamer` the way older firmware did. It checks what is running
  rather than the firmware version, so older firmware and the Helper
  Script's camera service (which already serve 8080) are left alone. Set
  `manage_webcam_stream = false` to turn this off.
- **Visible offline reasons.** `polar_cloud_status` and
  `polar_cloud_status.json` now include a `problems` list (Moonraker
  unreachable, not registered, Polar Cloud unreachable) with a message the
  user can act on. The web UI shows them in a banner, including when
  Moonraker itself is down and the page can't reach the agent.
  Found on a K1C where a firmware update removed `moonraker.conf` and the
  Polar Cloud credentials: the printer sat offline for weeks with nothing
  visible outside the log.
- **Embedded installs report their version.** `install_embedded.sh` now
  installs the latest GitHub release (not whatever is on `main`) and writes
  its tag to a `VERSION` file, which the agent reads when there's no git.
  These installs previously reported `1.0.0-unknown` and always showed an
  update as available. Set `POLAR_CLOUD_BRANCH` to install a branch for
  testing.
- **`scripts/release.sh`** tags and publishes a GitHub release from `main`,
  using the CHANGELOG section as the release notes.

### Fixed
- **Printer showed as idle while Moonraker was down.** Failed queries fell
  through to status 0, so Polar Cloud listed the printer as ready while it
  couldn't be monitored or controlled. It now reports 13 (Disconnected).
  Status 12 (Error) was not used on purpose: job-completion handling treats
  it as terminal and would cancel a cloud job that Klipper is still printing.
- **Image uploads posted with an expired URL.** When the pre-signed URL
  expired, the agent requested a new one but posted after a fixed 1s wait,
  usually still with the old URL, which S3 rejects with
  `403 SignatureDoesNotMatch`. It now clears the old URL and waits for the
  new one.
- **Failed image uploads were retried every ~5s instead of once per
  interval.** Each retry re-captured and re-encoded the image (ffmpeg on
  embedded printers) and logged the full S3 error. On a Kobra S1 with
  `verbose = true` this ran the load average to ~12 and grew the log to
  4.6 GB, filling `/useremain`. Attempts now count against the upload
  interval whether they succeed or not, and S3 error bodies are truncated.
- **A transient error could cancel a cloud print.** Any exception while
  building the status fell back to status 12 (Error), which ends the cloud
  job. It now reports 13 (Disconnected) instead.
- **Log flooding during Moonraker outages.** Every 30s retry logged four
  lines (about 11,500 a day). The agent now logs when the outage starts, a
  summary every 10 minutes, and when Moonraker comes back; retry details
  are at debug level.
- **Status file went stale.** `polar_cloud_status.json` was only written on
  connection events, so it could show days-old state. It's now refreshed
  every minute.
- **Web UI never updated after install.** Installers copy the page to
  `web/index.html` once, and updates only change `src/`. The agent now
  refreshes the served copy at startup.
- **K1: crash output written to a rotated log.** The K1 service script
  appended stdout to `polar_cloud.log`, which the agent also rotates, so
  stdout kept writing to the rotated file. It now goes to
  `polar_cloud_console.log`, truncated on each start (new installs only).
  The embedded installer's service scripts get the same fix.
- **Two agents running during a restart.** Shutdown took up to ~12s while
  threads finished sleeping, and the service scripts started the new
  process after 2s, so both were connected to Polar Cloud under the same
  serial. Shutdown is now immediate, and the generated service scripts wait
  for the old process to exit (new installs only).
- **Re-running the embedded installer didn't load the new code.** It called
  `start`, which does nothing while the agent is running (and aborted the
  install on the init.d path). It now restarts the agent.
- **Misleading "PIL not available" warning** on every image upload when
  ffmpeg was resizing the image anyway. The agent now warns once, only when
  neither PIL nor ffmpeg can resize an oversized image.

## [1.5.3] - 2026-07-09

### Fixed
- **Reconnection recovery after a cloud outage.** The service could stay
  connected but silent after Polar Cloud dropped it: it re-sent `hello`,
  but if the response was lost it sat connected-but-unauthenticated until
  restarted. A handshake watchdog now forces a clean reconnect, a real
  `authenticated` state replaces "hello was sent", and the status loop is
  restarted if it stops while authenticated.
- **Bounded log size.** `polar_cloud.log` now rotates at 5 MB x 3 backups
  (about 20 MB). It had been seen at 300+ MB.
- **Accurate print progress.** `file_position`/`file_size` come from
  `virtual_sdcard` (falling back to `print_stats`), so the percentage is
  right on Moonraker versions that don't report them in `print_stats`.

### Platform support
- **Anycubic Kobra S1 (Rinkhals):** packages install to the persistent
  `/userdata/.../lib`, the agent starts on boot, and `LD_LIBRARY_PATH` is
  set so ffmpeg works for webcam snapshots.

## [1.5.2] - 2026-04-07

### Fixed
- **Hourly update check failing with HTTP 404.** The agent's GitHub API
  call still pointed at the pre-rename namespace
  (`vanmorris/polar-cloud-klipper`) instead of `Polar3D/polar-cloud-klipper`,
  so `latest_version` was never populated and the log was noisy with
  `Failed to check for updates: HTTP 404` once an hour. The
  `version_info.latest_version` field returned from `polar_cloud_status`
  is now populated correctly.
- **Agent identification URL** sent to Moonraker also pointed at the old
  namespace. Cosmetic, but it surfaced in `/server/extensions/list` and
  any UI that displays connected agents. Now reports the canonical
  `Polar3D/polar-cloud-klipper` URL.

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
