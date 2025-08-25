#!/usr/bin/env python3
"""
Moonraker Plugin for Polar Cloud Configuration
Provides API endpoints for the UI to configure Polar Cloud settings
"""

import logging
import configparser
import os
import asyncio
import subprocess
import json

class PolarCloudPlugin:
    def __init__(self, config):
        self.server = config.get_server()
        self.name = config.get_name()
        self.config_file = os.path.expanduser("~/printer_data/config/polar_cloud.conf")
        self.config = configparser.ConfigParser()
        self.load_config()
        
        # Register API endpoints using the correct Moonraker method
        self.server.register_endpoint(
            "/server/polar_cloud/status", ["GET"],
            self._handle_status_request
        )
        self.server.register_endpoint(
            "/server/polar_cloud/register", ["POST"],
            self._handle_register_request
        )
        self.server.register_endpoint(
            "/server/polar_cloud/unregister", ["POST"],
            self._handle_unregister_request
        )
        self.server.register_endpoint(
            "/server/polar_cloud/config", ["GET", "POST"],
            self._handle_config_request
        )
        self.server.register_endpoint(
            "/server/polar_cloud/export_logs", ["GET"],
            self._handle_export_logs_request
        )
        
        logging.info("Polar Cloud plugin loaded successfully")

    async def component_init(self):
        """Called when all components have been loaded"""
        pass

    async def close(self):
        """Called when shutting down"""
        pass
    
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
                'max_image_size': '150000'
            }
            self.save_config()
    
    def save_config(self):
        """Save configuration to file"""
        os.makedirs(os.path.dirname(self.config_file), exist_ok=True)
        with open(self.config_file, 'w') as f:
            self.config.write(f)
    
    async def _handle_status_request(self, web_request):
        """Handle status requests"""
        try:
            # Reload config to get latest values (in case service updated it)
            self.load_config()
            
            # Check if service is running
            result = subprocess.run(
                ["systemctl", "is-active", "polar_cloud.service"],
                capture_output=True, text=True
            )
            
            service_status = "active" if result.returncode == 0 else "inactive"
            
            # Try to read real-time status from the service's status file
            status_file = os.path.expanduser('~/printer_data/logs/polar_cloud_status.json')
            realtime_status = {}
            try:
                if os.path.exists(status_file):
                    with open(status_file, 'r') as f:
                        realtime_status = json.load(f)
            except Exception as e:
                logging.debug(f"Could not read status file: {e}")
            
            # Get values from config and realtime status
            serial_number = self.config.get('polar_cloud', 'serial_number', fallback='')
            username = self.config.get('polar_cloud', 'username', fallback='')
            
            # Prefer realtime status if available, otherwise use config
            return {
                "service_status": service_status,
                "connected": realtime_status.get('connected', False),
                "authenticated": realtime_status.get('authenticated', bool(serial_number)),
                "registered": bool(serial_number),
                "serial_number": serial_number,
                "username": username,
                "machine_type": self.config.get('polar_cloud', 'machine_type', fallback='Cartesian'),
                "printer_type": self.config.get('polar_cloud', 'printer_type', fallback='Cartesian'),
                "last_update": realtime_status.get('last_update', ''),
                "webcam_enabled": self.config.get('polar_cloud', 'webcam_enabled', fallback='true').lower() == 'true'
            }
        except Exception as e:
            logging.error(f"Error getting polar cloud status: {e}")
            return {"error": str(e)}
    
    async def _handle_register_request(self, web_request):
        """Handle registration requests"""
        try:
            # Use the web_request methods to get parameters
            username = web_request.get_str('username', '')
            pin = web_request.get_str('pin', '')
            machine_type = web_request.get_str('machine_type', 'Cartesian')
            printer_type = web_request.get_str('printer_type', 'Cartesian')
            
            if not username or not pin:
                return {"error": "Username and PIN are required"}
            
            # Update config
            self.config['polar_cloud']['username'] = username
            self.config['polar_cloud']['pin'] = pin
            self.config['polar_cloud']['machine_type'] = machine_type
            self.config['polar_cloud']['printer_type'] = printer_type
            self.save_config()
            
            # Restart service to pick up new config
            try:
                subprocess.run(["systemctl", "restart", "polar_cloud.service"], check=True)
            except subprocess.CalledProcessError as e:
                logging.error(f"Error restarting polar cloud service: {e}")
                return {"error": "Failed to restart service"}
            
            return {"success": True, "message": "Registration initiated"}
            
        except Exception as e:
            logging.error(f"Error handling registration: {e}")
            return {"error": str(e)}
    
    async def _handle_unregister_request(self, web_request):
        """Handle unregistration requests"""
        try:
            # Clear registration data
            self.config['polar_cloud']['username'] = ''
            self.config['polar_cloud']['pin'] = ''
            self.config['polar_cloud']['serial_number'] = ''
            self.save_config()
            
            # Restart service
            try:
                subprocess.run(["systemctl", "restart", "polar_cloud.service"], check=True)
            except subprocess.CalledProcessError as e:
                logging.error(f"Error restarting polar cloud service: {e}")
                return {"error": "Failed to restart service"}
            
            return {"success": True, "message": "Unregistered successfully"}
            
        except Exception as e:
            logging.error(f"Error handling unregistration: {e}")
            return {"error": str(e)}
    
    async def _handle_config_request(self, web_request):
        """Handle configuration requests"""
        try:
            if web_request.get_action() == "GET":
                # Return current configuration
                return {
                    "server_url": self.config.get('polar_cloud', 'server_url', fallback='https://printer4.polar3d.com'),
                    "username": self.config.get('polar_cloud', 'username', fallback=''),
                    "machine_type": self.config.get('polar_cloud', 'machine_type', fallback='Cartesian'),
                    "printer_type": self.config.get('polar_cloud', 'printer_type', fallback='Cartesian'),
                    "max_image_size": self.config.get('polar_cloud', 'max_image_size', fallback='150000'),
                    "verbose": self.config.get('polar_cloud', 'verbose', fallback='false'),
                    "serial_number": self.config.get('polar_cloud', 'serial_number', fallback='')
                }
            else:
                # Update configuration
                for key in ['server_url', 'machine_type', 'printer_type', 'max_image_size', 'verbose']:
                    value = web_request.get_str(key, None)
                    if value is not None:
                        self.config['polar_cloud'][key] = value
                
                self.save_config()
                
                # Restart service if needed
                try:
                    subprocess.run(["systemctl", "restart", "polar_cloud.service"], check=True)
                except subprocess.CalledProcessError as e:
                    logging.error(f"Error restarting polar cloud service: {e}")
                    return {"error": "Failed to restart service"}
                
                return {"success": True, "message": "Configuration updated"}
                
        except Exception as e:
            logging.error(f"Error handling config request: {e}")
            return {"error": str(e)}

    async def _handle_export_logs_request(self, web_request):
        """Handle logs export request"""
        try:
            import datetime
            import socket
            
            # Get current timestamp
            timestamp = datetime.datetime.now().strftime("%Y-%m-%d_%H-%M-%S")
            hostname = socket.gethostname()
            
            logs = []
            logs.append("=" * 60)
            logs.append(f"POLAR CLOUD DIAGNOSTIC LOGS")
            logs.append(f"Generated: {datetime.datetime.now().isoformat()}")
            logs.append(f"Hostname: {hostname}")
            logs.append("=" * 60)
            logs.append("")
            
            # 1. System Information
            logs.append("=== SYSTEM INFORMATION ===")
            try:
                result = subprocess.run(['uname', '-a'], capture_output=True, text=True, timeout=5)
                logs.append(f"System: {result.stdout.strip()}")
            except:
                logs.append("System: Unable to retrieve")
            
            try:
                result = subprocess.run(['uptime'], capture_output=True, text=True, timeout=5)
                logs.append(f"Uptime: {result.stdout.strip()}")
            except:
                logs.append("Uptime: Unable to retrieve")
            logs.append("")
            
            # 2. Network Connectivity Tests
            logs.append("=== NETWORK CONNECTIVITY ===")
            
            # Test DNS resolution
            try:
                import socket
                socket.gethostbyname('printer4.polar3d.com')
                logs.append("✓ DNS Resolution: printer4.polar3d.com resolved successfully")
            except Exception as e:
                logs.append(f"✗ DNS Resolution: Failed to resolve printer4.polar3d.com - {e}")
            
            # Test ping to Polar Cloud
            try:
                result = subprocess.run(['ping', '-c', '3', '-W', '5', 'printer4.polar3d.com'], 
                                      capture_output=True, text=True, timeout=20)
                if result.returncode == 0:
                    logs.append("✓ Ping Test: printer4.polar3d.com is reachable")
                    # Extract packet loss info
                    for line in result.stdout.split('\n'):
                        if 'packet loss' in line:
                            logs.append(f"  {line.strip()}")
                else:
                    logs.append("✗ Ping Test: printer4.polar3d.com is not reachable")
            except Exception as e:
                logs.append(f"✗ Ping Test: Failed - {e}")
            
            # Test HTTPS connectivity
            try:
                import requests
                response = requests.get('https://printer4.polar3d.com', timeout=10)
                logs.append(f"✓ HTTPS Test: printer4.polar3d.com responded with status {response.status_code}")
            except Exception as e:
                logs.append(f"✗ HTTPS Test: Failed to connect - {e}")
            logs.append("")
            
            # 3. Service Status
            logs.append("=== SERVICE STATUS ===")
            try:
                result = subprocess.run(['systemctl', 'is-active', 'polar_cloud'], 
                                      capture_output=True, text=True, timeout=5)
                status = result.stdout.strip()
                logs.append(f"Polar Cloud Service: {status}")
                
                if status == "active":
                    # Get service details
                    result = subprocess.run(['systemctl', 'status', 'polar_cloud', '--no-pager', '-l'], 
                                          capture_output=True, text=True, timeout=10)
                    logs.append("Service Details:")
                    for line in result.stdout.split('\n')[:10]:  # First 10 lines
                        if line.strip():
                            logs.append(f"  {line}")
                            
            except Exception as e:
                logs.append(f"Service Status: Error checking - {e}")
            logs.append("")
            
            # 4. Current Status File
            logs.append("=== CURRENT STATUS ===")
            status_file = os.path.expanduser('~/printer_data/logs/polar_cloud_status.json')
            try:
                if os.path.exists(status_file):
                    with open(status_file, 'r') as f:
                        status_content = f.read()
                    logs.append("Status File Contents:")
                    logs.append(status_content)
                else:
                    logs.append("Status File: Not found")
            except Exception as e:
                logs.append(f"Status File: Error reading - {e}")
            logs.append("")
            
            # 5. Configuration
            logs.append("=== CONFIGURATION ===")
            config_file = os.path.expanduser('~/printer_data/config/polar_cloud.conf')
            try:
                if os.path.exists(config_file):
                    with open(config_file, 'r') as f:
                        config_lines = f.readlines()
                    logs.append("Configuration (sensitive data masked):")
                    for line in config_lines:
                        # Mask sensitive information
                        if 'pin' in line.lower() and '=' in line:
                            key, value = line.split('=', 1)
                            logs.append(f"{key}=***MASKED***")
                        else:
                            logs.append(line.rstrip())
                else:
                    logs.append("Configuration: File not found")
            except Exception as e:
                logs.append(f"Configuration: Error reading - {e}")
            logs.append("")
            
            # 6. Recent Service Logs
            logs.append("=== RECENT SERVICE LOGS (Last 200 lines) ===")
            try:
                result = subprocess.run(['journalctl', '-u', 'polar_cloud', '-n', '200', '--no-pager'], 
                                      capture_output=True, text=True, timeout=15)
                if result.returncode == 0:
                    logs.append(result.stdout)
                else:
                    logs.append("Unable to retrieve service logs")
            except Exception as e:
                logs.append(f"Service Logs: Error retrieving - {e}")
            logs.append("")
            
            # 7. Moonraker Logs (last few lines mentioning polar_cloud)
            logs.append("=== MOONRAKER LOGS (Polar Cloud related) ===")
            try:
                result = subprocess.run(['grep', '-i', 'polar', os.path.expanduser('~/printer_data/logs/moonraker.log')], 
                                      capture_output=True, text=True, timeout=10)
                if result.returncode == 0:
                    # Get last 20 lines
                    lines = result.stdout.strip().split('\n')
                    logs.append("Recent Polar Cloud related entries:")
                    for line in lines[-20:]:
                        logs.append(line)
                else:
                    logs.append("No Polar Cloud related entries found in Moonraker logs")
            except Exception as e:
                logs.append(f"Moonraker Logs: Error retrieving - {e}")
            
            logs.append("")
            logs.append("=" * 60)
            logs.append("END OF DIAGNOSTIC LOGS")
            logs.append("=" * 60)
            
            # Combine all logs
            log_content = '\n'.join(logs)
            
            # Create response with proper headers for file download
            filename = f"polar_cloud_logs_{hostname}_{timestamp}.txt"
            
            # Return logs as text data for download - Moonraker will handle the file response
            return {
                'logs': log_content,
                'filename': filename,
                'content_type': 'text/plain'
            }
            
        except Exception as e:
            logging.error(f"Error generating logs export: {e}")
            return {"error": f"Failed to export logs: {str(e)}"}

def load_component(config):
    return PolarCloudPlugin(config) 