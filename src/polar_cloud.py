#!/usr/bin/env python3
"""
Polar Cloud Service for Klipper
Connects printers to the Polar Cloud via Socket.IO

This version uses the synchronous Socket.IO client for maximum compatibility,
including Creality K1/K1C/K1 Max which cannot install aiohttp.
"""

import json
import logging
import os
import sys
import subprocess
import uuid
import hashlib
import base64
from datetime import datetime
import configparser
import time
import requests
import io
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa, padding
from cryptography.hazmat.backends import default_backend
import socket
import signal
import threading

# Import socketio - use sync client for universal compatibility
import socketio

# Optional PIL import for image processing
try:
    from PIL import Image
    HAS_PIL = True
except ImportError:
    HAS_PIL = False
    print("PIL not available - webcam features disabled")


def get_printer_data_path():
    """Get the printer_data path, handling K1 and standard installations."""
    # K1 series uses /usr/data/printer_data
    if os.path.exists('/usr/data/printer_data'):
        return '/usr/data/printer_data'
    # Standard installation uses ~/printer_data
    return os.path.expanduser('~/printer_data')


PRINTER_DATA_PATH = get_printer_data_path()


# --- Patch: Set logging level based on config verbose flag ---
def get_verbose_flag(config_file=None):
    if config_file is None:
        config_file = os.path.join(PRINTER_DATA_PATH, 'config/polar_cloud.conf')
    import configparser
    config = configparser.ConfigParser()
    if os.path.exists(config_file):
        config.read(config_file)
        verbose = config.get('polar_cloud', 'verbose', fallback='false').lower()
        return verbose in ('1', 'true', 'yes', 'on')
    return False

_verbose = get_verbose_flag()
_log_level = logging.DEBUG if _verbose else logging.INFO
logging.basicConfig(
    level=_log_level,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s',
    handlers=[
        logging.FileHandler(os.path.join(PRINTER_DATA_PATH, 'logs/polar_cloud.log')),
        logging.StreamHandler(sys.stdout)
    ]
)
logger = logging.getLogger('polar_cloud')

class PolarCloudService:
    # Polar Cloud status constants (as integers)
    PSTATE_IDLE = 0
    PSTATE_SERIAL = 1         # Printing a local print over serial
    PSTATE_PREPARING = 2      # Preparing a cloud print (slicing)
    PSTATE_PRINTING = 3       # Printing a cloud print
    PSTATE_PAUSED = 4
    PSTATE_POSTPROCESSING = 5 # Performing post-print operations
    PSTATE_CANCELLING = 6     # Canceling a print originated from the cloud
    PSTATE_COMPLETE = 7       # Completed a print originated from the cloud
    PSTATE_UPDATING = 8       # Busy updating OctoPrint and/or plugins
    PSTATE_COLDPAUSED = 9
    PSTATE_CHANGINGFILAMENT = 10
    PSTATE_TCPIP = 11         # Printing a local print over TCP/IP
    PSTATE_ERROR = 12
    PSTATE_OFFLINE = 13

    def __init__(self, config_file=None):
        if config_file is None:
            config_file = os.path.join(PRINTER_DATA_PATH, 'config/polar_cloud.conf')
        self.config_file = config_file
        self.config = configparser.ConfigParser()

        # Use synchronous Socket.IO client for universal compatibility
        self.sio = socketio.Client(
            reconnection=True,
            reconnection_attempts=0,  # Unlimited attempts
            reconnection_delay=1,
            reconnection_delay_max=30
        )

        self.connected = False
        self.running = True
        self.serial_number = None
        self.private_key = None
        self.public_key = None
        self.challenge = None
        self.hello_sent = False
        self.status_interval = 5  # Send status every 5 seconds
        self.moonraker_url = "http://localhost:7125"
        self.last_status = None
        self.disconnect_on_register = True
        self.disconnect_on_unregister = False
        self.status_file = os.path.join(PRINTER_DATA_PATH, 'logs/polar_cloud_status.json')

        # Image upload functionality
        self.upload_urls = {}
        self.upload_url_received_time = {}
        self.last_image_upload = {}
        self.image_upload_intervals = {
            'idle': 60,
            'printing': 10
        }
        self.current_job_id = None
        self.is_printing_cloud_job = False

        # Job progress tracking
        self.job_start_time = None
        self.job_file_size = 0
        self.job_bytes_read = 0
        self.job_filament_used = 0

        # Job metadata URLs
        self.current_stl_file = None
        self.current_config_file = None

        # Job state tracking
        self.job_is_cancelling = False
        self.job_is_preparing = False

        # Version tracking
        self.running_version = self.get_current_version()
        self.latest_version = None
        self.last_version_check = 0
        self.last_version_report = 0
        self.current_status_override = None

        # Error tracking
        self.last_error = None
        self.last_error_time = None

        # Status loop thread
        self._status_thread = None
        self._status_thread_running = False

        # Load configuration
        self.load_config()

        # Generate or load keys
        self.ensure_keys()

        # Set up Socket.IO event handlers
        self.setup_socketio_handlers()

    def setup_socketio_handlers(self):
        """Set up Socket.IO event handlers"""

        @self.sio.event
        def connect():
            logger.info("Connected to Polar Cloud Socket.IO server")
            self.connected = True
            self.hello_sent = False
            self.challenge = None
            self.write_status_file()

        @self.sio.event
        def disconnect():
            logger.warning("Disconnected from Polar Cloud Socket.IO server")
            self.connected = False
            self.hello_sent = False
            self.write_status_file()

        @self.sio.event
        def connect_error(data):
            logger.error(f"Socket.IO connection error: {data}")
            self.connected = False
            self.write_status_file(error=f"Connection error: {data}")

        @self.sio.event
        def message(data):
            """Handle incoming messages from Polar Cloud"""
            try:
                if isinstance(data, str):
                    message_data = json.loads(data)
                else:
                    message_data = data
                self.handle_message(message_data)
            except Exception as e:
                logger.error(f"Error handling Socket.IO message: {e}")

        @self.sio.event
        def welcome(data):
            """Handle welcome message with challenge"""
            try:
                self.challenge = data.get("challenge")
                logger.info(f"Received welcome from Polar Cloud with challenge: {self.challenge}")

                # Reload config to ensure we have latest values
                self.load_config()

                # Check if we need to register
                self.serial_number = self.config.get('polar_cloud', 'serial_number', fallback=None)
                username = self.config.get('polar_cloud', 'username', fallback='').strip()
                pin = self.config.get('polar_cloud', 'pin', fallback='').strip()

                logger.info(f"Config check - Serial: {'SET' if self.serial_number else 'MISSING'}, Username: {'SET' if username else 'MISSING'}, PIN: {'SET' if pin else 'MISSING'}")

                if not self.serial_number and username and pin:
                    logger.info("No serial number found, attempting registration")
                    self.register_printer(username, pin)
                elif self.serial_number:
                    logger.info("Serial number found, sending hello")
                    self.send_hello()
                else:
                    if not username and not pin:
                        logger.error("No username or PIN configured in polar_cloud.conf")
                        logger.error(f"Please check configuration file: {self.config_file}")
                    elif not username:
                        logger.error("Username missing in polar_cloud.conf")
                    elif not pin:
                        logger.error("PIN missing in polar_cloud.conf")
                    else:
                        logger.error("Configuration error - please check polar_cloud.conf")
                    logger.warning("Cannot register or authenticate without proper credentials")
            except Exception as e:
                logger.error(f"Error handling welcome: {e}")

        @self.sio.event
        def registerResponse(data):
            """Handle registration response"""
            try:
                logger.info(f"Registration response received: {data}")

                if isinstance(data, dict):
                    status = data.get("status", "")
                    reason = data.get("reason", "")
                    serial_number = data.get("serialNumber", "")

                    if status == "SUCCESS" and reason == "SUCCESS" and serial_number:
                        self.serial_number = serial_number
                        self.config['polar_cloud']['serial_number'] = self.serial_number
                        self.save_config()
                        self.last_error = None
                        self.last_error_time = None
                        self.write_status_file()

                        logger.info(f"Successfully registered with serial number: {self.serial_number}")

                        # Disconnect and reconnect as per protocol
                        logger.info("Disconnecting after registration as per protocol")
                        self.sio.disconnect()
                        time.sleep(2)
                    else:
                        error_msg = f"Registration failed - Status: {status}, Reason: {reason}"
                        logger.error(error_msg)
                        self.write_status_file(error=error_msg)

                elif isinstance(data, str):
                    logger.warning(f"Received string response: {data}")
                    if data.upper() == "SUCCESS":
                        logger.error("Registration appears successful but no serial number provided")
                        self.write_status_file(error="Registration error: Server response missing serial number")
                    else:
                        logger.error(f"Registration failed: {data}")
                        self.write_status_file(error=f"Registration failed: {data}")
                else:
                    logger.error(f"Unexpected registration response format: {type(data)}")
                    self.write_status_file(error="Registration error: Unexpected response format")

            except Exception as e:
                logger.error(f"Error handling registration response: {e}")

        @self.sio.event
        def helloResponse(data):
            """Handle hello response"""
            try:
                logger.info(f"Hello response received: {data}")

                success = False
                reason = None

                if isinstance(data, dict):
                    status = data.get("status", "")
                    success = (status == "SUCCESS")

                    if status == "FAILED":
                        reason = data.get("message", "No error message provided")
                    elif status == "DELETED":
                        reason = "Printer has been deleted from Polar Cloud"
                    elif not success:
                        reason = f"Unknown status: {status}"
                elif isinstance(data, str):
                    success = data.upper() == "SUCCESS"
                    reason = data if not success else None
                else:
                    reason = f"Unexpected response type: {type(data)}"

                if success:
                    logger.info("Hello response received successfully")
                    self.hello_sent = True
                    self.last_error = None
                    self.last_error_time = None
                    self.write_status_file()

                    # Start status loop in background thread
                    self.start_status_loop()

                    # Request initial upload URLs
                    self.request_upload_url("idle")
                else:
                    logger.error(f"Hello failed - Response: {data}")
                    if reason:
                        logger.error(f"Failure reason: {reason}")
                    self.hello_sent = False
                    self.write_status_file(error=f"Authentication failed: {reason}" if reason else "Authentication failed")
            except Exception as e:
                logger.error(f"Error handling hello response: {e}")
                self.write_status_file(error=f"Authentication error: {e}")

        @self.sio.event
        def getUrlResponse(data):
            """Handle upload URL response"""
            try:
                status = data.get("status")
                upload_type = data.get("type")
                url = data.get("url")
                fields = data.get("fields", {})
                expires = data.get("expires")
                max_size = data.get("maxSize")
                content_type = data.get("contentType")

                if status == "SUCCESS" and upload_type and url:
                    self.upload_urls[upload_type] = {
                        'url': url,
                        'fields': fields,
                        'expires': expires,
                        'maxSize': max_size,
                        'contentType': content_type
                    }
                    self.upload_url_received_time[upload_type] = time.time()
                    logger.debug(f"Received upload URL for type: {upload_type}")
                else:
                    logger.warning(f"Invalid or failed upload URL response: {data}")
            except Exception as e:
                logger.error(f"Error handling upload URL response: {e}")

        @self.sio.event
        def print(data):
            """Handle print command"""
            try:
                self.execute_print_command(data)
            except Exception as e:
                logger.error(f"Error handling print command: {e}")

        @self.sio.event
        def cancel(data):
            """Handle cancel command"""
            try:
                self.execute_cancel_command()
            except Exception as e:
                logger.error(f"Error handling cancel command: {e}")

        @self.sio.event
        def update(data):
            """Handle update command from cloud"""
            try:
                logger.info("Received update command from Polar Cloud")
                self.execute_update_command()
            except Exception as e:
                logger.error(f"Error handling update command: {e}")

        @self.sio.event
        def pause(data):
            """Handle pause command"""
            try:
                self.execute_pause_command()
            except Exception as e:
                logger.error(f"Error handling pause command: {e}")

        @self.sio.event
        def resume(data):
            """Handle resume command"""
            try:
                self.execute_resume_command()
            except Exception as e:
                logger.error(f"Error handling resume command: {e}")

        @self.sio.event
        def delete(data):
            """Handle delete command"""
            try:
                self.execute_delete_command()
            except Exception as e:
                logger.error(f"Error handling delete command: {e}")

        @self.sio.event
        def temperature(data):
            """Handle temperature command"""
            try:
                self.execute_temperature_command(data)
            except Exception as e:
                logger.error(f"Error handling temperature command: {e}")

    def load_config(self):
        """Load configuration from file with error handling"""
        try:
            if os.path.exists(self.config_file):
                logger.debug(f"Loading config from: {self.config_file}")

                if not os.access(self.config_file, os.R_OK):
                    logger.error(f"Cannot read config file: {self.config_file}")
                    return

                self.config.clear()
                result = self.config.read(self.config_file)

                if not result:
                    logger.error(f"Failed to parse config file: {self.config_file}")
                    return

                if not self.config.has_section('polar_cloud'):
                    logger.error(f"Config file missing [polar_cloud] section")
                    return

                logger.debug("Config loaded successfully")
            else:
                logger.info(f"Config file not found, creating default: {self.config_file}")
                self.config['polar_cloud'] = {
                    'server_url': 'https://printer4.polar3d.com',
                    'username': '',
                    'pin': '',
                    'machine_type': 'Cartesian',
                    'printer_type': 'Cartesian',
                    'manufacturer': 'kl',
                    'verbose': 'false',
                    'max_image_size': '150000',
                    'webcam_enabled': 'true'
                }
                self.save_config()
        except Exception as e:
            logger.error(f"Error loading config: {e}")

    def save_config(self):
        """Save configuration to file"""
        os.makedirs(os.path.dirname(self.config_file), exist_ok=True)
        with open(self.config_file, 'w') as f:
            self.config.write(f)

    def write_status_file(self, error=None):
        """Write current status to file for Moonraker plugin"""
        try:
            if error:
                self.last_error = error
                self.last_error_time = datetime.now().isoformat()

            status = {
                "connected": self.connected,
                "authenticated": self.hello_sent,
                "serial_number": self.serial_number or "",
                "username": self.config.get('polar_cloud', 'username', fallback=''),
                "machine_type": self.config.get('polar_cloud', 'machine_type', fallback='Cartesian'),
                "printer_type": self.config.get('polar_cloud', 'printer_type', fallback='Cartesian'),
                "manufacturer": self.config.get('polar_cloud', 'manufacturer', fallback='kl'),
                "last_update": datetime.now().isoformat(),
                "challenge": self.challenge or "",
                "webcam_enabled": self.config.get('polar_cloud', 'webcam_enabled', fallback='true').lower() == 'true',
                "last_error": self.last_error,
                "last_error_time": self.last_error_time
            }

            with open(self.status_file, 'w') as f:
                json.dump(status, f)

        except Exception as e:
            logger.debug(f"Error writing status file: {e}")

    def ensure_keys(self):
        """Generate or load RSA key pair"""
        key_file = os.path.join(PRINTER_DATA_PATH, 'config/polar_cloud_key.pem')

        if os.path.exists(key_file):
            with open(key_file, 'rb') as f:
                self.private_key = serialization.load_pem_private_key(
                    f.read(), password=None, backend=default_backend()
                )
        else:
            self.private_key = rsa.generate_private_key(
                public_exponent=65537,
                key_size=2048,
                backend=default_backend()
            )

            with open(key_file, 'wb') as f:
                f.write(self.private_key.private_bytes(
                    encoding=serialization.Encoding.PEM,
                    format=serialization.PrivateFormat.PKCS8,
                    encryption_algorithm=serialization.NoEncryption()
                ))

            os.chmod(key_file, 0o600)

        self.public_key = self.private_key.public_key()

    def get_current_version(self):
        """Get current version from git tags"""
        try:
            script_dir = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

            result = subprocess.run(
                ["git", "describe", "--tags", "--abbrev=0"],
                cwd=script_dir,
                capture_output=True,
                text=True,
                timeout=10
            )

            if result.returncode == 0:
                version = result.stdout.strip()
                if version.startswith('v'):
                    version = version[1:]
                logger.info(f"Detected version from git: {version}")
                return version
            else:
                result = subprocess.run(
                    ["git", "rev-parse", "--short", "HEAD"],
                    cwd=script_dir,
                    capture_output=True,
                    text=True,
                    timeout=10
                )
                if result.returncode == 0:
                    commit = result.stdout.strip()
                    version = f"dev-{commit}"
                    logger.info(f"Using development version: {version}")
                    return version

        except Exception as e:
            logger.warning(f"Error getting version from git: {e}")

        fallback_version = "1.0.0-unknown"
        logger.warning(f"Could not determine version, using fallback: {fallback_version}")
        return fallback_version

    def get_mac_address(self):
        """Get MAC address for printer identification"""
        mac = ':'.join(('%012X' % uuid.getnode())[i:i+2] for i in range(0, 12, 2))
        return mac

    def get_ip_address(self):
        """Get local IP address"""
        try:
            with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
                s.connect(("8.8.8.8", 80))
                return s.getsockname()[0]
        except Exception:
            return "127.0.0.1"

    def check_for_updates(self):
        """Check GitHub for the latest version"""
        try:
            current_time = time.time()
            if current_time - self.last_version_check < 3600:  # 1 hour
                return

            self.last_version_check = current_time

            response = requests.get(
                "https://api.github.com/repos/vanmorris/polar-cloud-klipper/releases/latest",
                timeout=10
            )

            if response.status_code == 200:
                release_data = response.json()
                latest_tag = release_data.get("tag_name", "")

                if latest_tag.startswith('v'):
                    latest_tag = latest_tag[1:]

                self.latest_version = latest_tag
                logger.info(f"Version check: running={self.running_version}, latest={self.latest_version}")
            else:
                logger.warning(f"Failed to check for updates: HTTP {response.status_code}")

        except Exception as e:
            logger.error(f"Error checking for updates: {e}")

    def send_version_info(self):
        """Send version information to Polar Cloud"""
        try:
            self.check_for_updates()

            version_data = {
                "serialNumber": self.serial_number or "",
                "runningVersion": self.running_version
            }

            if self.latest_version:
                version_data["latestVersion"] = self.latest_version

            self.sio.emit("setVersion", version_data)
            logger.debug(f"Sent version info: running={self.running_version}")

        except Exception as e:
            logger.error(f"Error sending version info: {e}")

    def get_moonraker_data(self, endpoint):
        """Get data from Moonraker API"""
        try:
            response = requests.get(f"{self.moonraker_url}/{endpoint}", timeout=5)
            if response.status_code == 200:
                return response.json()
        except Exception as e:
            logger.error(f"Error getting Moonraker data from {endpoint}: {e}")
        return None

    def get_job_progress(self):
        """Get detailed job progress information from Moonraker"""
        try:
            virtual_sdcard = self.get_moonraker_data("printer/objects/query?virtual_sdcard")
            if virtual_sdcard and 'result' in virtual_sdcard and 'virtual_sdcard' in virtual_sdcard['result']:
                sdcard_data = virtual_sdcard['result']['virtual_sdcard']

                if 'file_size' in sdcard_data:
                    self.job_file_size = sdcard_data['file_size']
                if 'file_position' in sdcard_data:
                    self.job_bytes_read = sdcard_data['file_position']

            return {
                'file_size': self.job_file_size,
                'bytes_read': self.job_bytes_read,
                'filament_used': self.job_filament_used
            }
        except Exception as e:
            logger.error(f"Error getting job progress: {e}")
            return {
                'file_size': 0,
                'bytes_read': 0,
                'filament_used': 0
            }

    def get_printer_status(self):
        """Get current printer status from Moonraker"""
        try:
            if self.current_status_override is not None:
                return {
                    "serialNumber": self.serial_number or "",
                    "status": self.current_status_override,
                    "progress": "Updating" if self.current_status_override == self.PSTATE_UPDATING else "Override",
                    "progressDetail": "Software update in progress...",
                    "estimatedTime": "0",
                    "printSeconds": 0,
                    "tool0": 0.0,
                    "tool1": 0.0,
                    "bed": 0.0,
                    "targetTool0": 0
                }

            printer_info = self.get_moonraker_data("printer/info")
            print_stats = self.get_moonraker_data("printer/objects/query?print_stats")
            toolhead = self.get_moonraker_data("printer/objects/query?toolhead")
            heaters = self.get_moonraker_data("printer/objects/query?heater_bed&extruder")

            status = self.PSTATE_IDLE
            progress = "Idle"
            progress_detail = "Idle"
            estimated_time = "0"
            print_seconds = 0
            filament_used = "0"
            start_time = ""
            bytes_read = 0
            file_size = 0

            if self.job_is_preparing and self.is_printing_cloud_job and self.current_job_id:
                status = self.PSTATE_PREPARING
                progress = "Preparing to print a job"
                progress_detail = f"Downloading file for job: {self.current_job_id}"
                start_time = self.job_start_time or ""
            elif print_stats and 'result' in print_stats and 'print_stats' in print_stats['result']:
                stats = print_stats['result']['print_stats']
                state = stats.get('state', 'standby')
                filename = stats.get('filename', '')

                if state == 'printing':
                    if self.job_is_cancelling and self.is_printing_cloud_job:
                        status = self.PSTATE_CANCELLING
                        progress = "Killing Job"
                    elif self.is_printing_cloud_job:
                        status = self.PSTATE_PRINTING
                        progress = "Job Printing"
                    else:
                        status = self.PSTATE_SERIAL
                        progress = "Job Printing"

                    print_seconds = int(stats.get('print_duration', 0))
                    estimated_time = str(int(stats.get('total_duration', 0)))

                    file_position = stats.get('file_position', 0)
                    file_size = stats.get('file_size', 0)
                    bytes_read = file_position

                    filament_used = str(int(stats.get('filament_used', 0)))

                    if stats.get('print_start_time'):
                        start_time = datetime.fromtimestamp(stats['print_start_time']).isoformat() + 'Z'

                    if stats.get('total_duration', 0) > 0 and stats.get('print_duration', 0) > 0:
                        progress_pct = (stats['print_duration'] / stats['total_duration']) * 100
                        if self.current_job_id:
                            progress_detail = f"Printing Job: {self.current_job_id} Percent Complete: {progress_pct:.1f}%"
                        else:
                            progress_detail = f"Printing Job: {filename.split('/')[-1] if filename else 'Unknown'} Percent Complete: {progress_pct:.1f}%"
                    else:
                        if self.current_job_id:
                            progress_detail = f"Printing Job: {self.current_job_id}"
                        else:
                            progress_detail = f"Printing Job: {filename.split('/')[-1] if filename else 'Unknown'}"

                elif state == 'paused':
                    status = self.PSTATE_PAUSED
                    progress = "Job Paused"
                    print_seconds = int(stats.get('print_duration', 0))
                    estimated_time = str(int(stats.get('total_duration', 0)))

                    file_position = stats.get('file_position', 0)
                    file_size = stats.get('file_size', 0)
                    bytes_read = file_position
                    filament_used = str(int(stats.get('filament_used', 0)))

                    if stats.get('print_start_time'):
                        start_time = datetime.fromtimestamp(stats['print_start_time']).isoformat() + 'Z'

                    if stats.get('total_duration', 0) > 0 and stats.get('print_duration', 0) > 0:
                        progress_pct = (stats['print_duration'] / stats['total_duration']) * 100
                        if self.current_job_id:
                            progress_detail = f"Printing Job: {self.current_job_id} Percent Complete: {progress_pct:.1f}%"
                        else:
                            progress_detail = f"Printing Job: {filename.split('/')[-1] if filename else 'Unknown'} Percent Complete: {progress_pct:.1f}%"

                elif state == 'complete':
                    if self.is_printing_cloud_job and self.current_job_id:
                        status = self.PSTATE_POSTPROCESSING
                        progress = "Post processing job"
                    else:
                        status = self.PSTATE_COMPLETE
                        progress = "Complete"

                    print_seconds = int(stats.get('print_duration', 0))
                    estimated_time = str(int(stats.get('total_duration', 0)))

                    file_position = stats.get('file_position', 0)
                    file_size = stats.get('file_size', 0)
                    bytes_read = file_position if file_position > 0 else file_size
                    filament_used = str(int(stats.get('filament_used', 0)))

                    if stats.get('print_start_time'):
                        start_time = datetime.fromtimestamp(stats['print_start_time']).isoformat() + 'Z'

                    if self.current_job_id:
                        progress_detail = f"Printing Job: {self.current_job_id} Percent Complete: 100.0%"
                    else:
                        progress_detail = f"Printing Job: {filename.split('/')[-1] if filename else 'Unknown'} Percent Complete: 100.0%"

                elif state == 'error':
                    status = self.PSTATE_ERROR
                    progress = "Error"
                    progress_detail = "Error"

            # Get temperature data
            tool0 = 0.0
            tool1 = 0.0
            bed_temp = 0.0
            target_tool0 = 0

            if heaters and 'result' in heaters:
                result = heaters['result']

                if 'extruder' in result:
                    extruder = result['extruder']
                    tool0 = round(extruder.get('temperature', 0), 1)
                    target_tool0 = int(extruder.get('target', 0))

                if 'extruder1' in result:
                    extruder1 = result['extruder1']
                    tool1 = round(extruder1.get('temperature', 0), 1)

                if 'heater_bed' in result:
                    bed = result['heater_bed']
                    bed_temp = round(bed.get('temperature', 0), 1)

            status_dict = {
                "serialNumber": self.serial_number or "",
                "status": status,
                "progress": progress,
                "progressDetail": progress_detail,
                "estimatedTime": estimated_time,
                "printSeconds": print_seconds,
                "tool0": tool0,
                "tool1": tool1,
                "bed": bed_temp,
                "targetTool0": target_tool0,
            }

            if filament_used != "0":
                status_dict["filamentUsed"] = filament_used
            if start_time:
                status_dict["startTime"] = start_time
            if bytes_read > 0:
                status_dict["bytesRead"] = bytes_read
            if file_size > 0:
                status_dict["fileSize"] = file_size
            if self.current_job_id:
                status_dict["jobId"] = self.current_job_id
                if self.current_stl_file:
                    status_dict["stlFile"] = self.current_stl_file
                if self.current_config_file:
                    status_dict["configFile"] = self.current_config_file

            return status_dict

        except Exception as e:
            logger.error(f"Error getting printer status: {e}")
            return {
                "serialNumber": self.serial_number or "",
                "status": self.PSTATE_ERROR,
                "progress": "Error",
                "progressDetail": "Error",
                "estimatedTime": "0",
                "printSeconds": 0,
                "tool0": 0.0,
                "tool1": 0.0,
                "bed": 0.0,
                "targetTool0": 0
            }

    def capture_webcam_image(self):
        """Capture image from webcam"""
        try:
            response = requests.get(f"{self.moonraker_url}/webcam/?action=snapshot", timeout=10)
            if response.status_code == 200:
                return response.content

            response = requests.get("http://localhost:8080/?action=snapshot", timeout=10)
            if response.status_code == 200:
                return response.content

            logger.debug("No webcam available for snapshot")
            return None

        except requests.exceptions.ConnectionError:
            logger.debug("Webcam not configured or unavailable")
            return None
        except Exception as e:
            logger.warning(f"Unexpected error capturing webcam image: {e}")
            return None

    def get_webcam_settings(self):
        """Get webcam transformation settings"""
        try:
            manual_flip_h = self.config.get('polar_cloud', 'flip_horizontal', fallback=None)
            manual_flip_v = self.config.get('polar_cloud', 'flip_vertical', fallback=None)
            manual_rotation = self.config.get('polar_cloud', 'rotation', fallback=None)

            if manual_flip_h is not None or manual_flip_v is not None or manual_rotation is not None:
                return {
                    'flip_horizontal': manual_flip_h and manual_flip_h.lower() == 'true',
                    'flip_vertical': manual_flip_v and manual_flip_v.lower() == 'true',
                    'rotation': int(manual_rotation) if manual_rotation else 0
                }

            response = requests.get(f"{self.moonraker_url}/server/database/item?namespace=webcams", timeout=5)
            if response.status_code == 200:
                data = response.json()
                webcam_config = data.get('result', {}).get('value', {})

                for camera_id, camera_data in webcam_config.items():
                    return {
                        'flip_horizontal': camera_data.get('flipX', False),
                        'flip_vertical': camera_data.get('flipY', False),
                        'rotation': camera_data.get('rotate', 0)
                    }

            response = requests.get(f"{self.moonraker_url}/server/database/item?namespace=fluidd&key=cameras", timeout=5)
            if response.status_code == 200:
                data = response.json()
                cameras = data.get('result', {}).get('value', [])
                if cameras:
                    camera = cameras[0]
                    return {
                        'flip_horizontal': camera.get('flipX', camera.get('flip_horizontal', False)),
                        'flip_vertical': camera.get('flipY', camera.get('flip_vertical', False)),
                        'rotation': camera.get('rotation', camera.get('rotate', 0))
                    }

        except Exception as e:
            logger.debug(f"Could not get frontend webcam settings: {e}")

        return {
            'flip_horizontal': False,
            'flip_vertical': False,
            'rotation': 0
        }

    def resize_image(self, image_data, max_size=None):
        """Resize and transform image to fit within max_size bytes"""
        if not HAS_PIL:
            return image_data

        try:
            if not max_size:
                max_size = int(self.config.get('polar_cloud', 'max_image_size', fallback='150000'))

            image = Image.open(io.BytesIO(image_data))

            if image.mode != 'RGB':
                image = image.convert('RGB')

            webcam_settings = self.get_webcam_settings()
            flip_horizontal = webcam_settings['flip_horizontal']
            flip_vertical = webcam_settings['flip_vertical']
            rotation = webcam_settings['rotation']

            if flip_horizontal:
                image = image.transpose(Image.Transpose.FLIP_LEFT_RIGHT)

            if flip_vertical:
                image = image.transpose(Image.Transpose.FLIP_TOP_BOTTOM)

            if rotation == 90:
                image = image.transpose(Image.Transpose.ROTATE_90)
            elif rotation == 180:
                image = image.transpose(Image.Transpose.ROTATE_180)
            elif rotation == 270:
                image = image.transpose(Image.Transpose.ROTATE_270)

            output = io.BytesIO()
            image.save(output, format='JPEG', quality=95, optimize=True)
            if output.tell() <= max_size:
                output.seek(0)
                return output.read()

            for quality in range(80, 10, -10):
                output = io.BytesIO()
                image.save(output, format='JPEG', quality=quality, optimize=True)
                resized_data = output.getvalue()

                if len(resized_data) <= max_size:
                    logger.debug(f"Resized image to {len(resized_data)} bytes with quality {quality}")
                    return resized_data

            width, height = image.size
            for scale in [0.8, 0.6, 0.4, 0.2]:
                new_width = int(width * scale)
                new_height = int(height * scale)
                resized_image = image.resize((new_width, new_height), Image.Resampling.LANCZOS)

                output = io.BytesIO()
                resized_image.save(output, format='JPEG', quality=60, optimize=True)
                resized_data = output.getvalue()

                if len(resized_data) <= max_size:
                    logger.debug(f"Resized image to {new_width}x{new_height} ({len(resized_data)} bytes)")
                    return resized_data

            logger.warning("Could not resize image to acceptable size")
            return image_data[:max_size]

        except Exception as e:
            logger.error(f"Error resizing/transforming image: {e}")
            return image_data

    def request_upload_url(self, upload_type, job_id=None):
        """Request a pre-signed POST URL for uploading images"""
        try:
            if not self.connected or not self.serial_number:
                return None

            request_data = {
                "serialNumber": self.serial_number,
                "method": "post",
                "type": upload_type
            }

            if upload_type in ['printing', 'timelapse'] and job_id:
                request_data["jobId"] = job_id

            self.sio.emit("getUrl", request_data)

            logger.debug(f"Requested upload URL for type: {upload_type}")
            return True
        except Exception as e:
            logger.error(f"Error requesting upload URL: {e}")
            return False

    def upload_image_to_cloud(self, image_data, upload_type):
        """Upload image to Polar Cloud using pre-signed URL"""
        try:
            if upload_type not in self.upload_urls:
                logger.warning(f"No upload URL available for type: {upload_type}")
                return False

            url_data = self.upload_urls[upload_type]

            if upload_type in self.upload_url_received_time and url_data.get('expires'):
                received_time = self.upload_url_received_time[upload_type]
                expires_in_seconds = url_data['expires']
                time_since_received = time.time() - received_time

                if time_since_received >= (expires_in_seconds - 30):
                    logger.info(f"Upload URL for {upload_type} has expired, requesting new one")
                    if self.request_upload_url(upload_type):
                        time.sleep(1)
                        url_data = self.upload_urls.get(upload_type)
                        if not url_data:
                            return False
                    else:
                        return False

            resized_image = self.resize_image(image_data)

            data = url_data.get('fields', {})
            files = {'file': ('image.jpg', resized_image, 'image/jpeg')}

            response = requests.post(url_data['url'], data=data, files=files, timeout=30)

            if response.status_code in [200, 204]:
                logger.debug(f"Successfully uploaded {upload_type} image ({len(resized_image)} bytes)")
                return True
            else:
                logger.error(f"Failed to upload image: {response.status_code} - {response.text}")
                return False

        except Exception as e:
            logger.error(f"Error uploading image: {e}")
            return False

    def handle_image_uploads(self):
        """Handle periodic image uploads based on printer state"""
        try:
            webcam_enabled = self.config.get('polar_cloud', 'webcam_enabled', fallback='true').lower() == 'true'
            if not webcam_enabled:
                return

            status = self.get_printer_status()
            printer_status = status.get("status", self.PSTATE_IDLE)
            current_time = time.time()

            if printer_status == self.PSTATE_PRINTING and self.is_printing_cloud_job and self.current_job_id:
                upload_type = "printing"
                interval = self.image_upload_intervals['printing']
            else:
                upload_type = "idle"
                interval = self.image_upload_intervals['idle']

            last_upload = self.last_image_upload.get(upload_type, 0)
            if current_time - last_upload < interval:
                return

            image_data = self.capture_webcam_image()
            if image_data:
                if upload_type not in self.upload_urls:
                    job_id = self.current_job_id if upload_type == "printing" else None
                    self.request_upload_url(upload_type, job_id)
                    time.sleep(1)

                if self.upload_image_to_cloud(image_data, upload_type):
                    self.last_image_upload[upload_type] = current_time

        except Exception as e:
            logger.error(f"Error handling image uploads: {e}")

    def register_printer(self, username, pin):
        """Register printer with Polar Cloud"""
        try:
            public_key_pem = self.public_key.public_bytes(
                encoding=serialization.Encoding.PEM,
                format=serialization.PublicFormat.SubjectPublicKeyInfo
            ).decode('utf-8')

            mfg_code = self.config.get('polar_cloud', 'manufacturer', fallback='kl')

            registration_data = {
                "mfg": mfg_code,
                "email": username,
                "pin": pin,
                "publicKey": public_key_pem,
                "mfgSn": "1234567890",
                "myInfo": {
                    "MAC": self.get_mac_address()
                },
            }

            self.sio.emit("register", registration_data)
            logger.info(f"Registration request sent to Polar Cloud with {mfg_code} client identifier")
            return True
        except Exception as e:
            logger.error(f"Error registering printer: {e}")

        return False

    def send_hello(self):
        """Send hello message to Polar Cloud"""
        try:
            if not self.challenge:
                logger.error("Cannot send hello: no challenge received")
                return

            webcam_enabled = self.config.get('polar_cloud', 'webcam_enabled', fallback='true').lower() == 'true'
            webcam_settings = self.get_webcam_settings()
            mfg_code = self.config.get('polar_cloud', 'manufacturer', fallback='kl')

            hello_data = {
                "serialNumber": self.serial_number,
                "protocol": "2",
                "MAC": self.get_mac_address(),
                "localIP": self.get_ip_address(),
                "signature": base64.b64encode(
                    self.private_key.sign(
                        self.challenge.encode('utf-8'),
                        padding.PKCS1v15(),
                        hashes.SHA256()
                    )
                ).decode('utf-8'),
                "mfgSn": f"{mfg_code.upper()}-" + self.get_mac_address().replace(":", ""),
                "printerMake": self.config.get('polar_cloud', 'printer_type', fallback='Cartesian'),
                "version": self.running_version,
                "camOff": 0 if webcam_enabled else 1,
                "rotateImg": 1 if webcam_settings.get('rotation', 0) != 0 else 0,
                "transformImg": 1 if (webcam_settings.get('flip_horizontal', False) or webcam_settings.get('flip_vertical', False)) else 0
            }

            self.sio.emit("hello", hello_data)
            self.hello_sent = True
            logger.info("Hello message sent to Polar Cloud")
        except Exception as e:
            logger.error(f"Error sending hello: {e}")

    def send_status(self):
        """Send printer status to Polar Cloud"""
        try:
            status = self.get_printer_status()

            current_status_code = status.get("status", self.PSTATE_IDLE)

            if current_status_code in [self.PSTATE_PRINTING, self.PSTATE_SERIAL, self.PSTATE_PAUSED]:
                self.sio.emit("status", status)
                logger.debug(f"Status sent to Polar Cloud: state={current_status_code}")
            elif self.last_status and status == self.last_status:
                return
            else:
                self.sio.emit("status", status)
                logger.debug(f"Status sent to Polar Cloud: state={current_status_code}")

            self.last_status = status.copy()
        except Exception as e:
            logger.error(f"Error sending status: {e}")

    def handle_message(self, data):
        """Handle incoming message from Polar Cloud (legacy support)"""
        try:
            logger.debug(f"Received legacy message: {data}")

            if isinstance(data, dict):
                if "welcome" in data:
                    self.sio.emit('welcome', data["welcome"])
                elif "registerResponse" in data:
                    self.sio.emit('registerResponse', data["registerResponse"])
                elif "helloResponse" in data:
                    self.sio.emit('helloResponse', data["helloResponse"])
                elif "getUrlResponse" in data:
                    self.sio.emit('getUrlResponse', data["getUrlResponse"])
                elif "print" in data:
                    self.sio.emit('print', data["print"])
                elif "cancel" in data:
                    self.sio.emit('cancel', data["cancel"])
                elif "pause" in data:
                    self.sio.emit('pause', data["pause"])
                elif "resume" in data:
                    self.sio.emit('resume', data["resume"])
                elif "delete" in data:
                    self.sio.emit('delete', data["delete"])
                elif "temperature" in data:
                    self.sio.emit('temperature', data["temperature"])

        except Exception as e:
            logger.error(f"Error handling message: {e}")

    def connect_socketio(self):
        """Connect to Polar Cloud Socket.IO server"""
        server_url = self.config.get('polar_cloud', 'server_url', fallback='https://printer4.polar3d.com')

        try:
            self.sio.connect(server_url, transports=['websocket', 'polling'])
            return self.connected
        except Exception as e:
            logger.error(f"Error connecting to Polar Cloud Socket.IO server: {e}")
            self.connected = False
            return False

    def start_status_loop(self):
        """Start the status loop in a background thread"""
        if self._status_thread is not None and self._status_thread.is_alive():
            return

        self._status_thread_running = True
        self._status_thread = threading.Thread(target=self._status_loop_worker, daemon=True)
        self._status_thread.start()

    def stop_status_loop(self):
        """Stop the status loop thread"""
        self._status_thread_running = False
        if self._status_thread is not None:
            self._status_thread.join(timeout=5)

    def _status_loop_worker(self):
        """Worker function for status loop thread"""
        while self._status_thread_running and self.running and self.connected and self.hello_sent:
            try:
                self.send_status()
                self.handle_image_uploads()
                self.monitor_print_completion()

                current_time = time.time()
                if current_time - self.last_version_report > 600:  # 10 minutes
                    self.send_version_info()
                    self.last_version_report = current_time

                time.sleep(self.status_interval)
            except Exception as e:
                logger.error(f"Error in status loop: {e}")
                break

    def run(self):
        """Main service loop"""
        logger.info("Starting Polar Cloud Service")

        while self.running:
            try:
                if not self.connected:
                    self.connect_socketio()

                if self.connected:
                    # Wait for events - the sync client handles this internally
                    # Just sleep and let handlers do their work
                    time.sleep(1)
                else:
                    time.sleep(5)  # Wait before trying to connect

            except Exception as e:
                logger.error(f"Error in main loop: {e}")
                time.sleep(5)

    def stop(self):
        """Stop the service"""
        logger.info("Stopping Polar Cloud Service")
        self.running = False
        self.stop_status_loop()

    def send_job_completion(self, job_id, state, print_seconds=0, filament_used=0, bytes_read=0, file_size=0):
        """Send job completion notification to Polar Cloud"""
        try:
            if not self.connected or not self.serial_number:
                return False

            status = self.get_printer_status()

            job_data = {
                "serialNumber": self.serial_number,
                "jobId": job_id,
                "state": state,
            }

            if print_seconds > 0:
                job_data["printSeconds"] = print_seconds
            if filament_used > 0:
                job_data["filamentUsed"] = filament_used
            if bytes_read > 0:
                job_data["bytesRead"] = bytes_read
            if file_size > 0:
                job_data["fileSize"] = file_size

            self.sio.emit("job", job_data)

            logger.info(f"Sent job completion for {job_id}: {state}")
            return True
        except Exception as e:
            logger.error(f"Error sending job completion: {e}")
            return False

    def monitor_print_completion(self):
        """Monitor for print completion and send job notifications"""
        try:
            status = self.get_printer_status()
            printer_status = status.get("status", self.PSTATE_IDLE)

            if self.is_printing_cloud_job and self.current_job_id:
                job_progress = self.get_job_progress()

                if printer_status == self.PSTATE_COMPLETE:
                    print_seconds = int(status.get("printSeconds", "0"))
                    self.send_job_completion(
                        self.current_job_id,
                        "completed",
                        print_seconds,
                        job_progress['filament_used'],
                        job_progress['bytes_read'],
                        job_progress['file_size']
                    )

                    self.is_printing_cloud_job = False
                    self.current_job_id = None
                    self.job_start_time = None
                    self.current_stl_file = None
                    self.current_config_file = None
                    self.job_is_preparing = False

                elif printer_status in [self.PSTATE_IDLE, self.PSTATE_ERROR]:
                    print_seconds = int(status.get("printSeconds", "0"))
                    self.send_job_completion(
                        self.current_job_id,
                        "canceled",
                        print_seconds,
                        job_progress['filament_used'],
                        job_progress['bytes_read'],
                        job_progress['file_size']
                    )

                    self.is_printing_cloud_job = False
                    self.current_job_id = None
                    self.job_start_time = None
                    self.current_stl_file = None
                    self.current_config_file = None
                    self.job_is_preparing = False

        except Exception as e:
            logger.error(f"Error monitoring print completion: {e}")

    def execute_print_command(self, print_data):
        """Execute print command via Moonraker API"""
        try:
            job_id = print_data.get("jobId")
            gcode_file = print_data.get("gcodeFile")
            stl_file = print_data.get("stlFile")
            config_file = print_data.get("configFile")

            self.current_stl_file = stl_file
            self.current_config_file = config_file

            logger.info(f"Executing print command for job {job_id}")

            if gcode_file:
                self.current_job_id = job_id
                self.is_printing_cloud_job = True
                self.job_is_preparing = True

                self.job_start_time = datetime.now().isoformat() + 'Z'

                logger.info(f"Downloading gcode file: {gcode_file}")

                response = requests.get(gcode_file, timeout=30)
                if response.status_code == 200:
                    filename = f"polar_cloud_{job_id}.gcode"
                    filepath = os.path.join(PRINTER_DATA_PATH, f"gcodes/{filename}")

                    with open(filepath, 'wb') as f:
                        f.write(response.content)

                    logger.info(f"Downloaded gcode file to {filepath}")

                    print_response = requests.post(
                        f"{self.moonraker_url}/printer/print/start",
                        json={"filename": filename},
                        timeout=10
                    )

                    if print_response.status_code == 200:
                        self.is_printing_cloud_job = True
                        self.current_job_id = job_id
                        self.job_is_preparing = False
                        self.job_start_time = time.time()
                        logger.info(f"Started printing cloud job {job_id}")
                    else:
                        logger.error(f"Failed to start print: {print_response.text}")
                else:
                    logger.error(f"Failed to download gcode file: {response.status_code}")

            elif stl_file:
                logger.info("STL file printing not yet implemented")
            else:
                logger.warning("No gcode or STL file provided in print command")

        except Exception as e:
            logger.error(f"Error executing print command: {e}")

    def execute_cancel_command(self):
        """Execute cancel command via Moonraker API"""
        try:
            if self.is_printing_cloud_job and self.current_job_id:
                self.job_is_cancelling = True

            response = requests.post(f"{self.moonraker_url}/printer/print/cancel", timeout=10)
            if response.status_code == 200:
                logger.info("Print cancelled successfully")

                if self.is_printing_cloud_job and self.current_job_id:
                    self.send_job_completion(self.current_job_id, "canceled")
                    self.is_printing_cloud_job = False
                    self.current_job_id = None
                    self.job_start_time = None
                    self.current_stl_file = None
                    self.current_config_file = None
                    self.job_is_preparing = False
                    self.job_is_cancelling = False
                self.job_is_preparing = False
            else:
                logger.error(f"Failed to cancel print: {response.text}")
                self.job_is_cancelling = False
                self.job_is_preparing = False
        except Exception as e:
            logger.error(f"Error executing cancel command: {e}")
            self.job_is_cancelling = False

    def execute_pause_command(self):
        """Execute pause command via Moonraker API"""
        try:
            response = requests.post(f"{self.moonraker_url}/printer/print/pause", timeout=10)
            if response.status_code == 200:
                logger.info("Print paused successfully")
            else:
                logger.error(f"Failed to pause print: {response.text}")
        except Exception as e:
            logger.error(f"Error executing pause command: {e}")

    def execute_resume_command(self):
        """Execute resume command via Moonraker API"""
        try:
            response = requests.post(f"{self.moonraker_url}/printer/print/resume", timeout=10)
            if response.status_code == 200:
                logger.info("Print resumed successfully")
            else:
                logger.error(f"Failed to resume print: {response.text}")
        except Exception as e:
            logger.error(f"Error executing resume command: {e}")

    def execute_update_command(self):
        """Execute update command - pull latest code and restart service"""
        try:
            self.current_status_override = self.PSTATE_UPDATING
            logger.info("Starting software update...")

            repo_dir = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

            result = subprocess.run(
                ["git", "pull"],
                cwd=repo_dir,
                capture_output=True,
                text=True,
                timeout=60
            )

            if result.returncode == 0:
                logger.info(f"Git pull successful: {result.stdout}")

                version_result = subprocess.run(
                    ["git", "describe", "--tags", "--abbrev=0"],
                    cwd=repo_dir,
                    capture_output=True,
                    text=True,
                    timeout=10
                )

                if version_result.returncode == 0:
                    new_version = version_result.stdout.strip()
                    if new_version.startswith('v'):
                        new_version = new_version[1:]
                    self.running_version = new_version
                    logger.info(f"Updated to version: {self.running_version}")

                # Try systemctl first, then init.d, then just restart self
                try:
                    subprocess.run(["sudo", "systemctl", "restart", "polar_cloud.service"], timeout=30)
                    logger.info("Service restart initiated via systemctl")
                except Exception:
                    try:
                        subprocess.run(["/etc/init.d/S99polar_cloud", "restart"], timeout=30)
                        logger.info("Service restart initiated via init.d")
                    except Exception:
                        logger.info("Could not restart service automatically")

            else:
                logger.error(f"Git pull failed: {result.stderr}")

        except subprocess.TimeoutExpired:
            logger.error("Update command timed out")
        except Exception as e:
            logger.error(f"Error executing update command: {e}")
        finally:
            self.current_status_override = None

    def execute_delete_command(self):
        """Execute delete command - reset printer to unregistered state"""
        try:
            self.execute_cancel_command()

            if 'polar_cloud' in self.config:
                if 'serial_number' in self.config['polar_cloud']:
                    del self.config['polar_cloud']['serial_number']
                self.save_config()

            self.serial_number = None
            self.is_printing_cloud_job = False
            self.current_job_id = None
            self.job_start_time = None
            self.current_stl_file = None
            self.current_config_file = None
            self.job_is_preparing = False
            self.hello_sent = False

            self.upload_urls.clear()

            logger.info("Printer reset to unregistered state")

            if self.connected:
                self.sio.disconnect()

            return True
        except Exception as e:
            logger.error(f"Error executing delete command: {e}")
            return False

    def execute_temperature_command(self, temp_data):
        """Execute temperature command via Moonraker API"""
        try:
            if 'tool0' in temp_data:
                temp = temp_data['tool0']
                response = requests.post(
                    f"{self.moonraker_url}/printer/gcode/script",
                    json={"script": f"SET_HEATER_TEMPERATURE HEATER=extruder TARGET={temp}"},
                    timeout=10
                )
                if response.status_code == 200:
                    logger.info(f"Set extruder temperature to {temp}°C")
                else:
                    logger.error(f"Failed to set extruder temperature: {response.text}")

            if 'bed' in temp_data:
                temp = temp_data['bed']
                response = requests.post(
                    f"{self.moonraker_url}/printer/gcode/script",
                    json={"script": f"SET_HEATER_TEMPERATURE HEATER=heater_bed TARGET={temp}"},
                    timeout=10
                )
                if response.status_code == 200:
                    logger.info(f"Set bed temperature to {temp}°C")
                else:
                    logger.error(f"Failed to set bed temperature: {response.text}")

        except Exception as e:
            logger.error(f"Error executing temperature command: {e}")


# Global flag for shutdown
_shutdown_requested = False

def main():
    """Main entry point"""
    global _shutdown_requested

    # Create and run service
    service = PolarCloudService()

    # Set up signal handlers for graceful shutdown
    def shutdown_handler(signum, frame):
        global _shutdown_requested
        logger.info(f"Received signal {signum}, shutting down...")
        _shutdown_requested = True
        service.stop()

    signal.signal(signal.SIGINT, shutdown_handler)
    signal.signal(signal.SIGTERM, shutdown_handler)

    try:
        service.run()
    except KeyboardInterrupt:
        logger.info("Received keyboard interrupt, shutting down...")
    finally:
        service.stop()
        if service.connected:
            try:
                service.sio.disconnect()
            except Exception as e:
                logger.debug(f"Disconnect error: {e}")
        logger.info("Shutdown complete")

if __name__ == "__main__":
    main()
