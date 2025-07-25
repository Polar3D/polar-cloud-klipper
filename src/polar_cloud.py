#!/usr/bin/env python3
"""
Polar Cloud Service for MainsailOS
Connects printers to the Polar Cloud via Socket.IO
"""

import asyncio
import socketio
import json
import logging
import os
import sys
import uuid
import hashlib
import base64
from datetime import datetime
import configparser
import requests
from PIL import Image
import io
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa, padding
from cryptography.hazmat.backends import default_backend
import socket
import time
import signal
import subprocess


# --- Patch: Set logging level based on config verbose flag ---
def get_verbose_flag(config_file=None):
    if config_file is None:
        config_file = os.path.expanduser('~/printer_data/config/polar_cloud.conf')
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
        logging.FileHandler(os.path.expanduser('~/printer_data/logs/polar_cloud.log')),
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
            config_file = os.path.expanduser('~/printer_data/config/polar_cloud.conf')
        self.config_file = config_file
        self.config = configparser.ConfigParser()
        self.sio = socketio.AsyncClient(
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
        self.status_interval = 10  # Send status every 10 seconds
        self.moonraker_url = "http://localhost:7125"
        self.last_status = None
        self.disconnect_on_register = True  # Enable disconnect after registration as per protocol
        self.disconnect_on_unregister = False
        self.status_file = os.path.expanduser('~/printer_data/logs/polar_cloud_status.json')  # Status file for Moonraker plugin
        
        # Image upload functionality
        self.upload_urls = {}  # Store pre-signed URLs by type
        self.last_image_upload = {}  # Track last upload time by type
        self.image_upload_intervals = {
            'idle': 60,      # Upload idle images every 60 seconds (1 minute)
            'printing': 10   # Upload printing images every 10 seconds
        }
        self.current_job_id = None
        self.is_printing_cloud_job = False
        
        # Job progress tracking
        self.job_start_time = None
        self.job_file_size = 0
        self.job_bytes_read = 0
        self.job_filament_used = 0
        
        # Load configuration
        self.load_config()
        
        # Generate or load keys
        self.ensure_keys()
        
        # Set up Socket.IO event handlers
        self.setup_socketio_handlers()
        
    def setup_socketio_handlers(self):
        """Set up Socket.IO event handlers"""
        
        @self.sio.event
        async def connect():
            logger.info("Connected to Polar Cloud Socket.IO server")
            self.connected = True
            self.hello_sent = False
            self.challenge = None
        
        @self.sio.event
        async def disconnect():
            logger.warning("Disconnected from Polar Cloud Socket.IO server")
            self.connected = False
            self.hello_sent = False
        
        @self.sio.event
        async def connect_error(data):
            logger.error(f"Socket.IO connection error: {data}")
            self.connected = False
        
        @self.sio.event
        async def message(data):
            """Handle incoming messages from Polar Cloud"""
            try:
                if isinstance(data, str):
                    message_data = json.loads(data)
                else:
                    message_data = data
                
                await self.handle_message(message_data)
            except Exception as e:
                logger.error(f"Error handling Socket.IO message: {e}")
        
        # Handle specific Polar Cloud events
        @self.sio.event
        async def connect():
            """Handle successful connection"""
            logger.info("Connected to Polar Cloud Socket.IO server")
            self.connected = True
            self.write_status_file()
        
        @self.sio.event
        async def disconnect(data=None):
            """Handle disconnection"""
            logger.warning("Disconnected from Polar Cloud Socket.IO server")
            self.connected = False
            self.hello_sent = False
            self.write_status_file()
        
        @self.sio.event
        async def connect_error(data):
            """Handle connection error"""
            logger.error(f"Connection error: {data}")
            self.connected = False
        
        @self.sio.event
        async def welcome(data):
            """Handle welcome message with challenge"""
            try:
                self.challenge = data.get("challenge")
                logger.info(f"Received welcome from Polar Cloud with challenge: {self.challenge}")
                
                # Check if we need to register
                self.serial_number = self.config.get('polar_cloud', 'serial_number', fallback=None)
                username = self.config.get('polar_cloud', 'username', fallback='')
                pin = self.config.get('polar_cloud', 'pin', fallback='')
                
                logger.debug(f"Serial number from config: {self.serial_number}")
                logger.debug(f"Username configured: {'Yes' if username else 'No'}")
                logger.debug(f"PIN configured: {'Yes' if pin else 'No'}")
                
                if not self.serial_number and username and pin:
                    # Need to register
                    logger.info("No serial number found, attempting registration")
                    await self.register_printer(username, pin)
                elif self.serial_number:
                    # Already registered, send hello
                    logger.info("Serial number found, sending hello")
                    await self.send_hello()
                else:
                    logger.warning("No credentials configured for registration")
            except Exception as e:
                logger.error(f"Error handling welcome: {e}")
        
        @self.sio.event
        async def registerResponse(data):
            """Handle registration response
            Expected format: {"serialNumber": "printer-serial-number", "status": "SUCCESS", "reason": "SUCCESS"}
            """
            try:
                logger.info(f"Registration response received: {data}")
                logger.info(f"Registration response type: {type(data)}")
                
                if isinstance(data, dict):
                    # Expected format: JSON object with serialNumber, status, and reason
                    status = data.get("status", "")
                    reason = data.get("reason", "")
                    serial_number = data.get("serialNumber", "")
                    
                    logger.info(f"Response status: {status}")
                    logger.info(f"Response reason: {reason}")
                    logger.info(f"Response serialNumber: {serial_number}")
                    
                    if status == "SUCCESS" and reason == "SUCCESS" and serial_number:
                        # Save serial number to config
                        self.serial_number = serial_number
                        self.config['polar_cloud']['serial_number'] = self.serial_number
                        self.save_config()
                        self.write_status_file()
                        
                        logger.info(f"Successfully registered with serial number: {self.serial_number}")
                        
                        # Disconnect and reconnect as per protocol
                        logger.info("Disconnecting after registration as per protocol - will reconnect automatically")
                        await self.sio.disconnect()
                        # Wait for disconnect to complete before allowing reconnection
                        await asyncio.sleep(2)
                    else:
                        logger.error(f"Registration failed - Status: {status}, Reason: {reason}, SerialNumber: {serial_number}")
                        
                elif isinstance(data, str):
                    # Response is just a string - this might indicate an issue with the request format
                    logger.warning(f"Received string response instead of expected JSON object: {data}")
                    if data.upper() == "SUCCESS":
                        logger.error("Registration appears successful but no serial number provided - this suggests the registration request may be malformed")
                    else:
                        logger.error(f"Registration failed with string response: {data}")
                        
                else:
                    # Unexpected response format
                    logger.error(f"Unexpected registration response format: {type(data)} = {data}")
                    
            except Exception as e:
                logger.error(f"Error handling registration response: {e}")
        
        @self.sio.event
        async def helloResponse(data):
            """Handle hello response"""
            try:
                logger.info(f"Hello response received: {data}")
                logger.info(f"Hello response type: {type(data)}")
                
                # Check for success based on protocol specification
                # Expected format: {"status": "SUCCESS"} or {"status": "FAILED", "message": "error"}
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
                    reason = f"Unexpected response type: {type(data)} = {data}"
                
                if success:
                    logger.info("Hello response received successfully")
                    self.hello_sent = True
                    self.write_status_file()
                    
                    # Start sending status updates and request initial upload URLs
                    if not hasattr(self, '_status_task') or self._status_task.done():
                        self._status_task = asyncio.create_task(self.status_loop())
                    
                    # Request initial upload URLs
                    await self.request_upload_url("idle")
                    
                else:
                    logger.error(f"Hello failed - Response: {data}")
                    if reason:
                        logger.error(f"Failure reason: {reason}")
                    self.hello_sent = False
            except Exception as e:
                logger.error(f"Error handling hello response: {e}")
        
        @self.sio.event
        async def getUrlResponse(data):
            """Handle upload URL response"""
            try:
                upload_type = data.get("type")
                url_data = data.get("url")
                
                if upload_type and url_data:
                    self.upload_urls[upload_type] = url_data
                    logger.debug(f"Received upload URL for type: {upload_type}")
                else:
                    logger.warning(f"Invalid upload URL response: {data}")
            except Exception as e:
                logger.error(f"Error handling upload URL response: {e}")
        
        @self.sio.event
        async def print(data):
            """Handle print command"""
            try:
                await self.execute_print_command(data)
            except Exception as e:
                logger.error(f"Error handling print command: {e}")
        
        @self.sio.event
        async def cancel(data):
            """Handle cancel command"""
            try:
                await self.execute_cancel_command()
            except Exception as e:
                logger.error(f"Error handling cancel command: {e}")
        
        @self.sio.event
        async def pause(data):
            """Handle pause command"""
            try:
                await self.execute_pause_command()
            except Exception as e:
                logger.error(f"Error handling pause command: {e}")
        
        @self.sio.event
        async def resume(data):
            """Handle resume command"""
            try:
                await self.execute_resume_command()
            except Exception as e:
                logger.error(f"Error handling resume command: {e}")
        
        @self.sio.event
        async def delete(data):
            """Handle delete command"""
            try:
                await self.execute_delete_command()
            except Exception as e:
                logger.error(f"Error handling delete command: {e}")
        
        @self.sio.event
        async def temperature(data):
            """Handle temperature command"""
            try:
                await self.execute_temperature_command(data)
            except Exception as e:
                logger.error(f"Error handling temperature command: {e}")
    
    def load_config(self):
        """Load configuration from file"""
        if os.path.exists(self.config_file):
            self.config.read(self.config_file)
        else:
            # Create default config
            self.config['polar_cloud'] = {
                'server_url': 'https://printer4.polar3d.com',
                'username': '',
                'pin': '',
                'machine_type': 'Cartesian',
                'printer_type': 'Cartesian',
                'verbose': 'false',
                'max_image_size': '150000',
                'webcam_enabled': 'true'
            }
            self.save_config()
    
    def save_config(self):
        """Save configuration to file"""
        os.makedirs(os.path.dirname(self.config_file), exist_ok=True)
        with open(self.config_file, 'w') as f:
            self.config.write(f)
    
    def write_status_file(self):
        """Write current status to file for Moonraker plugin"""
        try:
            status = {
                "connected": self.connected,
                "authenticated": self.hello_sent,
                "serial_number": self.serial_number or "",
                "username": self.config.get('polar_cloud', 'username', fallback=''),
                "machine_type": self.config.get('polar_cloud', 'machine_type', fallback='Cartesian'),
                "printer_type": self.config.get('polar_cloud', 'printer_type', fallback='Cartesian'),
                "last_update": datetime.now().isoformat(),
                "challenge": self.challenge or "",
                "webcam_enabled": self.config.get('polar_cloud', 'webcam_enabled', fallback='true').lower() == 'true'
            }
            
            with open(self.status_file, 'w') as f:
                json.dump(status, f)
                
        except Exception as e:
            logger.debug(f"Error writing status file: {e}")
    
    def ensure_keys(self):
        """Generate or load RSA key pair"""
        key_file = os.path.expanduser('~/printer_data/config/polar_cloud_key.pem')
        
        if os.path.exists(key_file):
            # Load existing key
            with open(key_file, 'rb') as f:
                self.private_key = serialization.load_pem_private_key(
                    f.read(), password=None, backend=default_backend()
                )
        else:
            # Generate new key pair
            self.private_key = rsa.generate_private_key(
                public_exponent=65537,
                key_size=2048,
                backend=default_backend()
            )
            
            # Save private key
            with open(key_file, 'wb') as f:
                f.write(self.private_key.private_bytes(
                    encoding=serialization.Encoding.PEM,
                    format=serialization.PrivateFormat.PKCS8,
                    encryption_algorithm=serialization.NoEncryption()
                ))
            
            # Set permissions
            os.chmod(key_file, 0o600)
        
        # Get public key
        self.public_key = self.private_key.public_key()
    
    def get_mac_address(self):
        """Get MAC address for printer identification"""
        mac = ':'.join(('%012X' % uuid.getnode())[i:i+2] for i in range(0, 12, 2))
        return mac
    
    def get_ip_address(self):
        """Get local IP address"""
        try:
            # Connect to a remote address to determine local IP
            with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
                s.connect(("8.8.8.8", 80))
                return s.getsockname()[0]
        except Exception:
            return "127.0.0.1"
    
    async def get_moonraker_data(self, endpoint):
        """Get data from Moonraker API"""
        try:
            response = requests.get(f"{self.moonraker_url}/{endpoint}", timeout=5)
            if response.status_code == 200:
                return response.json()
        except Exception as e:
            logger.error(f"Error getting Moonraker data from {endpoint}: {e}")
        return None
    
    async def get_job_progress(self):
        """Get detailed job progress information from Moonraker"""
        try:
            # Get virtual SD card info for file progress
            virtual_sdcard = await self.get_moonraker_data("printer/objects/query?virtual_sdcard")
            if virtual_sdcard and 'result' in virtual_sdcard and 'virtual_sdcard' in virtual_sdcard['result']:
                sdcard_data = virtual_sdcard['result']['virtual_sdcard']
                
                # Update job progress tracking
                if 'file_size' in sdcard_data:
                    self.job_file_size = sdcard_data['file_size']
                if 'file_position' in sdcard_data:
                    self.job_bytes_read = sdcard_data['file_position']
            
            # Get filament sensor data if available
            filament_data = await self.get_moonraker_data("printer/objects/query?filament_switch_sensor")
            if filament_data and 'result' in filament_data:
                # This would need to be customized based on actual filament sensor setup
                pass
            
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
    
    async def get_printer_status(self):
        """Get current printer status from Moonraker"""
        try:
            # Get printer state
            printer_info = await self.get_moonraker_data("printer/info")
            print_stats = await self.get_moonraker_data("printer/objects/query?print_stats")
            toolhead = await self.get_moonraker_data("printer/objects/query?toolhead")
            heaters = await self.get_moonraker_data("printer/objects/query?heater_bed&extruder")
            
            # Determine printer status
            status = self.PSTATE_IDLE
            progress = ""
            progress_detail = ""
            estimated_time = "0"
            print_seconds = "0"
            
            if print_stats and 'result' in print_stats and 'print_stats' in print_stats['result']:
                stats = print_stats['result']['print_stats']
                state = stats.get('state', 'standby')
                
                if state == 'printing':
                    if self.is_printing_cloud_job:
                        status = self.PSTATE_PRINTING
                    else:
                        status = self.PSTATE_SERIAL
                    
                    # Calculate progress
                    if stats.get('total_duration', 0) > 0 and stats.get('print_duration', 0) > 0:
                        progress_pct = (stats['print_duration'] / stats['total_duration']) * 100
                        progress = f"{progress_pct:.1f}%"
                        progress_detail = f"{stats['print_duration']:.0f}s / {stats['total_duration']:.0f}s"
                        estimated_time = str(int(stats.get('total_duration', 0)))
                        print_seconds = str(int(stats.get('print_duration', 0)))
                
                elif state == 'paused':
                    status = self.PSTATE_PAUSED
                elif state == 'complete':
                    status = self.PSTATE_COMPLETE
                elif state == 'error':
                    status = self.PSTATE_ERROR
            
            # Get temperature data
            temps = []
            if heaters and 'result' in heaters:
                result = heaters['result']
                
                # Extruder temperature
                if 'extruder' in result:
                    extruder = result['extruder']
                    temps.append({
                        "name": "extruder",
                        "actual": round(extruder.get('temperature', 0), 1),
                        "target": round(extruder.get('target', 0), 1)
                    })
                
                # Bed temperature
                if 'heater_bed' in result:
                    bed = result['heater_bed']
                    temps.append({
                        "name": "bed",
                        "actual": round(bed.get('temperature', 0), 1),
                        "target": round(bed.get('target', 0), 1)
                    })
            
            # Get position data
            position = [0, 0, 0]
            if toolhead and 'result' in toolhead and 'toolhead' in toolhead['result']:
                toolhead_data = toolhead['result']['toolhead']
                position = toolhead_data.get('position', [0, 0, 0])[:3]  # X, Y, Z
            
            return {
                "serialNumber": self.serial_number or "",
                "status": status,
                "temps": temps,
                "position": [round(p, 2) for p in position],
                "progress": progress,
                "progressDetail": progress_detail,
                "estimatedTime": estimated_time,
                "printSeconds": print_seconds,
                "macAddress": self.get_mac_address(),
                "localIP": self.get_ip_address()
            }
            
        except Exception as e:
            logger.error(f"Error getting printer status: {e}")
            return {
                "serialNumber": self.serial_number or "",
                "status": self.PSTATE_ERROR,
                "temps": [],
                "position": [0, 0, 0],
                "progress": "",
                "progressDetail": "",
                "estimatedTime": "0",
                "printSeconds": "0",
                "macAddress": self.get_mac_address(),
                "localIP": self.get_ip_address()
            }
    
    async def capture_webcam_image(self):
        """Capture image from webcam"""
        try:
            # Try to get image from Moonraker webcam
            response = requests.get(f"{self.moonraker_url}/webcam/?action=snapshot", timeout=10)
            if response.status_code == 200:
                return response.content
            
            # Fallback: try direct webcam access
            response = requests.get("http://localhost:8080/?action=snapshot", timeout=10)
            if response.status_code == 200:
                return response.content
            
            logger.debug("No webcam available for snapshot")
            return None
            
        except requests.exceptions.ConnectionError as e:
            # This is expected when no webcam is configured
            logger.debug("Webcam not configured or unavailable")
            return None
        except Exception as e:
            logger.warning(f"Unexpected error capturing webcam image: {e}")
            return None
    
    async def resize_image(self, image_data, max_size=None):
        """Resize image to fit within max_size bytes"""
        try:
            if not max_size:
                max_size = int(self.config.get('polar_cloud', 'max_image_size', fallback='150000'))
            
            if len(image_data) <= max_size:
                return image_data
            
            # Open image and resize
            image = Image.open(io.BytesIO(image_data))
            
            # Start with 80% quality and reduce until size is acceptable
            for quality in range(80, 10, -10):
                output = io.BytesIO()
                image.save(output, format='JPEG', quality=quality, optimize=True)
                resized_data = output.getvalue()
                
                if len(resized_data) <= max_size:
                    logger.debug(f"Resized image to {len(resized_data)} bytes with quality {quality}")
                    return resized_data
            
            # If still too large, resize dimensions
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
            return image_data[:max_size]  # Truncate as last resort
            
        except Exception as e:
            logger.error(f"Error resizing image: {e}")
            return image_data
    
    async def request_upload_url(self, upload_type, job_id=None):
        """Request a pre-signed POST URL for uploading images"""
        try:
            if not self.connected or not self.serial_number:
                return None
            
            request_data = {
                "serialNumber": self.serial_number,
                "method": "post",
                "type": upload_type
            }
            
            # Add jobId for printing and timelapse uploads
            if upload_type in ['printing', 'timelapse'] and job_id:
                request_data["jobId"] = job_id
            
            await self.sio.emit("getUrl", request_data)
            
            logger.debug(f"Requested upload URL for type: {upload_type}")
            return True
        except Exception as e:
            logger.error(f"Error requesting upload URL: {e}")
            return False
    
    async def upload_image_to_cloud(self, image_data, upload_type):
        """Upload image to Polar Cloud using pre-signed URL"""
        try:
            if upload_type not in self.upload_urls:
                logger.warning(f"No upload URL available for type: {upload_type}")
                return False
            
            url_data = self.upload_urls[upload_type]
            
            # Resize image if needed
            resized_image = await self.resize_image(image_data)
            
            # Upload using pre-signed POST
            files = {'file': ('image.jpg', resized_image, 'image/jpeg')}
            data = url_data.get('fields', {})
            
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
    
    async def handle_image_uploads(self):
        """Handle periodic image uploads based on printer state"""
        try:
            # Check if webcam is disabled in config
            webcam_enabled = self.config.get('polar_cloud', 'webcam_enabled', fallback='true').lower() == 'true'
            if not webcam_enabled:
                return
                
            status = await self.get_printer_status()
            printer_status = status.get("status", self.PSTATE_IDLE)
            current_time = time.time()
            
            # Determine upload type based on printer state
            if printer_status == self.PSTATE_PRINTING:
                upload_type = "printing"
                interval = self.image_upload_intervals['printing']
            else:
                upload_type = "idle"
                interval = self.image_upload_intervals['idle']
            
            # Check if it's time to upload
            last_upload = self.last_image_upload.get(upload_type, 0)
            if current_time - last_upload < interval:
                return
            
            # Capture and upload image
            image_data = await self.capture_webcam_image()
            if image_data:
                # Request upload URL if we don't have one
                if upload_type not in self.upload_urls:
                    job_id = self.current_job_id if upload_type == "printing" else None
                    await self.request_upload_url(upload_type, job_id)
                    # Wait a bit for the URL response
                    await asyncio.sleep(1)
                
                # Upload the image
                if await self.upload_image_to_cloud(image_data, upload_type):
                    self.last_image_upload[upload_type] = current_time
                    
                    # Request a new URL for next upload
                    job_id = self.current_job_id if upload_type == "printing" else None
                    await self.request_upload_url(upload_type, job_id)
            
        except Exception as e:
            logger.error(f"Error handling image uploads: {e}")
    
    async def register_printer(self, username, pin):
        """Register printer with Polar Cloud"""
        try:
            # Create registration message
            public_key_pem = self.public_key.public_bytes(
                encoding=serialization.Encoding.PEM,
                format=serialization.PublicFormat.SubjectPublicKeyInfo
            ).decode('utf-8')
            
            registration_data = {
                "mfg": "mnsl",
                "email": username,
                "pin": pin,
                "publicKey": public_key_pem,
                "mfgSn": "1234567890", 
                "myInfo": {
                    "MAC": self.get_mac_address()
                },
                # "machineType": self.config.get('polar_cloud', 'machine_type', fallback='Cartesian'),
                # "printerType": self.config.get('polar_cloud', 'printer_type', fallback='Cartesian'),
            }
            
            await self.sio.emit("register", registration_data)
            logger.info("Registration request sent to Polar Cloud with MNSL client identifier")
            return True
        except Exception as e:
            logger.error(f"Error registering printer: {e}")
        
        return False
    
    async def send_hello(self):
        """Send hello message to Polar Cloud"""
        try:
            if not self.challenge:
                logger.error("Cannot send hello: no challenge received")
                return
                
            # Check if webcam is enabled
            webcam_enabled = self.config.get('polar_cloud', 'webcam_enabled', fallback='true').lower() == 'true'
            
            hello_data = {
                "serialNumber": self.serial_number,
                "protocol": "2",
                "MAC": self.get_mac_address(),  # Changed from macAddress to MAC
                "localIP": self.get_ip_address(),
                "signature": base64.b64encode(
                    self.private_key.sign(
                        self.challenge.encode('utf-8'),
                        padding.PKCS1v15(),
                        hashes.SHA256()
                    )
                ).decode('utf-8'),
                "mfgSn": "MNSL-" + self.get_mac_address().replace(":", ""),  # Add manufacturer serial
                "printerMake": self.config.get('polar_cloud', 'printer_type', fallback='Cartesian'),  # Use actual printer type
                "version": "1.0.0",
                "camOff": 0 if webcam_enabled else 1  # 0=camera on, 1=camera off
            }
            
            await self.sio.emit("hello", hello_data)
            self.hello_sent = True
            logger.info("Hello message sent to Polar Cloud")
        except Exception as e:
            logger.error(f"Error sending hello: {e}")
    
    async def send_status(self):
        """Send printer status to Polar Cloud"""
        try:
            status = await self.get_printer_status()
            
            # Only send status if something has changed or it's been a while
            if self.last_status and status == self.last_status:
                return
            
            await self.sio.emit("status", status)
            self.last_status = status.copy()
            logger.debug("Status sent to Polar Cloud")
        except Exception as e:
            logger.error(f"Error sending status: {e}")
    
    async def handle_message(self, data):
        """Handle incoming message from Polar Cloud (legacy support)"""
        try:
            logger.debug(f"Received legacy message: {data}")
            
            # Handle legacy message format for backward compatibility
            if isinstance(data, dict):
                if "welcome" in data:
                    await self.sio.emit('welcome', data["welcome"])
                elif "registerResponse" in data:
                    await self.sio.emit('registerResponse', data["registerResponse"])
                elif "helloResponse" in data:
                    await self.sio.emit('helloResponse', data["helloResponse"])
                elif "getUrlResponse" in data:
                    await self.sio.emit('getUrlResponse', data["getUrlResponse"])
                elif "print" in data:
                    await self.sio.emit('print', data["print"])
                elif "cancel" in data:
                    await self.sio.emit('cancel', data["cancel"])
                elif "pause" in data:
                    await self.sio.emit('pause', data["pause"])
                elif "resume" in data:
                    await self.sio.emit('resume', data["resume"])
                elif "delete" in data:
                    await self.sio.emit('delete', data["delete"])
                elif "temperature" in data:
                    await self.sio.emit('temperature', data["temperature"])
            
        except Exception as e:
            logger.error(f"Error handling message: {e}")
    
    async def connect_socketio(self):
        """Connect to Polar Cloud Socket.IO server"""
        server_url = self.config.get('polar_cloud', 'server_url', fallback='https://printer4.polar3d.com')
        
        try:
            await self.sio.connect(server_url, transports=['websocket'])
            # Connection status will be updated by the connect event handler
            return self.connected
        except Exception as e:
            logger.error(f"Error connecting to Polar Cloud Socket.IO server: {e}")
            self.connected = False
            return False
    
    async def status_loop(self):
        """Send status updates and handle image uploads periodically"""
        while self.running and self.connected and self.hello_sent:
            try:
                await self.send_status()
                await self.handle_image_uploads()
                await self.monitor_print_completion()
                await asyncio.sleep(self.status_interval)
            except Exception as e:
                logger.error(f"Error in status loop: {e}")
                break
    
    async def run(self):
        """Main service loop"""
        logger.info("Starting Polar Cloud Service")
        
        while self.running:
            try:
                if not self.connected:
                    await self.connect_socketio()
                
                if self.connected:
                    # Socket.IO handles the connection automatically
                    # Just wait and let the event handlers do their work
                    await asyncio.sleep(1)
                else:
                    await asyncio.sleep(5)  # Wait before trying to connect
            
            except Exception as e:
                logger.error(f"Error in main loop: {e}")
                await asyncio.sleep(5)
    
    def stop(self):
        """Stop the service"""
        logger.info("Stopping Polar Cloud Service")
        self.running = False

    async def send_job_completion(self, job_id, state, print_seconds=0, filament_used=0, bytes_read=0, file_size=0):
        """Send job completion notification to Polar Cloud"""
        try:
            if not self.connected or not self.serial_number:
                return False
            
            # Get current printer status for additional fields
            status = await self.get_printer_status()
            
            job_data = {
                "serialNumber": self.serial_number,
                "jobId": job_id,
                "state": state,  # "completed" or "canceled"
            }
            
            # Add optional fields if available
            if print_seconds > 0:
                job_data["printSeconds"] = print_seconds
            if filament_used > 0:
                job_data["filamentUsed"] = filament_used
            if bytes_read > 0:
                job_data["bytesRead"] = bytes_read
            if file_size > 0:
                job_data["fileSize"] = file_size
            
            # Add temperature information if available
            temps = status.get("temps", [])
            for temp in temps:
                if temp["name"] == "extruder":
                    job_data["tool0"] = temp["actual"]
                    job_data["targetTool0"] = temp["target"]
                elif temp["name"] == "bed":
                    job_data["bed"] = temp["actual"]
                    job_data["targetBed"] = temp["target"]
            
            # Add progress information
            progress = status.get("progress", "")
            if progress:
                job_data["progress"] = progress
            
            progress_detail = status.get("progressDetail", "")
            if progress_detail:
                job_data["progressDetail"] = progress_detail
            
            # Add estimated time if available
            estimated_time = status.get("estimatedTime", "0")
            if estimated_time and estimated_time != "0":
                job_data["estimatedTime"] = estimated_time
            
            await self.sio.emit("job", job_data)
            
            logger.info(f"Sent job completion for {job_id}: {state}")
            return True
        except Exception as e:
            logger.error(f"Error sending job completion: {e}")
            return False
    
    async def monitor_print_completion(self):
        """Monitor for print completion and send job notifications"""
        try:
            status = await self.get_printer_status()
            printer_status = status.get("status", self.PSTATE_IDLE)
            
            # Check if a cloud job has completed
            if self.is_printing_cloud_job and self.current_job_id:
                # Get current job progress
                job_progress = await self.get_job_progress()
                
                if printer_status == self.PSTATE_COMPLETE:
                    # Cloud job completed successfully
                    print_seconds = int(status.get("printSeconds", "0"))
                    await self.send_job_completion(
                        self.current_job_id, 
                        "completed", 
                        print_seconds,
                        job_progress['filament_used'],
                        job_progress['bytes_read'],
                        job_progress['file_size']
                    )
                    
                    # Reset cloud job state
                    self.is_printing_cloud_job = False
                    self.current_job_id = None
                    self.job_start_time = None
                    
                elif printer_status in [self.PSTATE_IDLE, self.PSTATE_ERROR]:
                    # Cloud job was cancelled or failed
                    print_seconds = int(status.get("printSeconds", "0"))
                    await self.send_job_completion(
                        self.current_job_id, 
                        "canceled", 
                        print_seconds,
                        job_progress['filament_used'],
                        job_progress['bytes_read'],
                        job_progress['file_size']
                    )
                    
                    # Reset cloud job state
                    self.is_printing_cloud_job = False
                    self.current_job_id = None
                    self.job_start_time = None
                    
        except Exception as e:
            logger.error(f"Error monitoring print completion: {e}")

    async def execute_print_command(self, print_data):
        """Execute print command via Moonraker API"""
        try:
            # Extract print job information
            job_id = print_data.get("jobId")
            gcode_file = print_data.get("gcodeFile")
            stl_file = print_data.get("stlFile")
            config_file = print_data.get("configFile")
            
            logger.info(f"Executing print command for job {job_id}")
            
            if gcode_file:
                # Download and print gcode file
                logger.info(f"Downloading gcode file: {gcode_file}")
                
                # Download the gcode file
                response = requests.get(gcode_file, timeout=30)
                if response.status_code == 200:
                    # Save gcode file to printer
                    filename = f"polar_cloud_{job_id}.gcode"
                    filepath = os.path.expanduser(f"~/printer_data/gcodes/{filename}")
                    
                    with open(filepath, 'wb') as f:
                        f.write(response.content)
                    
                    logger.info(f"Downloaded gcode file to {filepath}")
                    
                    # Start print via Moonraker
                    print_response = requests.post(
                        f"{self.moonraker_url}/printer/print/start",
                        json={"filename": filename},
                        timeout=10
                    )
                    
                    if print_response.status_code == 200:
                        # Mark as cloud job
                        self.is_printing_cloud_job = True
                        self.current_job_id = job_id
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
    
    async def execute_cancel_command(self):
        """Execute cancel command via Moonraker API"""
        try:
            response = requests.post(f"{self.moonraker_url}/printer/print/cancel", timeout=10)
            if response.status_code == 200:
                logger.info("Print cancelled successfully")
                
                # If it was a cloud job, send completion notification
                if self.is_printing_cloud_job and self.current_job_id:
                    await self.send_job_completion(self.current_job_id, "canceled")
                    self.is_printing_cloud_job = False
                    self.current_job_id = None
                    self.job_start_time = None
            else:
                logger.error(f"Failed to cancel print: {response.text}")
        except Exception as e:
            logger.error(f"Error executing cancel command: {e}")
    
    async def execute_pause_command(self):
        """Execute pause command via Moonraker API"""
        try:
            response = requests.post(f"{self.moonraker_url}/printer/print/pause", timeout=10)
            if response.status_code == 200:
                logger.info("Print paused successfully")
            else:
                logger.error(f"Failed to pause print: {response.text}")
        except Exception as e:
            logger.error(f"Error executing pause command: {e}")
    
    async def execute_resume_command(self):
        """Execute resume command via Moonraker API"""
        try:
            response = requests.post(f"{self.moonraker_url}/printer/print/resume", timeout=10)
            if response.status_code == 200:
                logger.info("Print resumed successfully")
            else:
                logger.error(f"Failed to resume print: {response.text}")
        except Exception as e:
            logger.error(f"Error executing resume command: {e}")
    
    async def execute_delete_command(self):
        """Execute delete command - reset printer to unregistered state"""
        try:
            # Cancel any active print first
            await self.execute_cancel_command()
            
            # Clear registration data
            if 'polar_cloud' in self.config:
                if 'serial_number' in self.config['polar_cloud']:
                    del self.config['polar_cloud']['serial_number']
                self.save_config()
            
            # Reset internal state
            self.serial_number = None
            self.is_printing_cloud_job = False
            self.current_job_id = None
            self.job_start_time = None
            self.hello_sent = False
            
            # Clear upload URLs
            self.upload_urls.clear()
            
            logger.info("Printer reset to unregistered state")
            
            # Disconnect from cloud
            if self.connected:
                await self.sio.disconnect()
            
            return True
        except Exception as e:
            logger.error(f"Error executing delete command: {e}")
            return False
    
    async def execute_temperature_command(self, temp_data):
        """Execute temperature command via Moonraker API"""
        try:
            # Set extruder temperature
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
            
            # Set bed temperature
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

def signal_handler(signum, frame):
    """Handle shutdown signals"""
    logger.info(f"Received signal {signum}, shutting down...")
    sys.exit(0)

async def main():
    """Main entry point"""
    # Set up signal handlers
    signal.signal(signal.SIGINT, signal_handler)
    signal.signal(signal.SIGTERM, signal_handler)
    
    # Create and run service
    service = PolarCloudService()
    
    try:
        await service.run()
    except KeyboardInterrupt:
        logger.info("Received keyboard interrupt, shutting down...")
    finally:
        service.stop()
        if service.connected:
            await service.sio.disconnect()

if __name__ == "__main__":
    asyncio.run(main()) 