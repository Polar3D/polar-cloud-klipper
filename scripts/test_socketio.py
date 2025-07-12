#!/usr/bin/env python3
"""
Test script to verify Socket.IO connectivity with Polar Cloud
"""

import asyncio
import socketio
import logging
import sys

# Set up logging
logging.basicConfig(level=logging.DEBUG, format='%(asctime)s - %(levelname)s - %(message)s')
logger = logging.getLogger('test_socketio')

class TestSocketIOClient:
    def __init__(self, server_url='https://printer4.polar3d.com'):
        self.server_url = server_url
        self.sio = socketio.AsyncClient()
        self.connected = False
        self.setup_handlers()
    
    def setup_handlers(self):
        @self.sio.event
        async def connect():
            logger.info("✅ Successfully connected to Socket.IO server")
            self.connected = True
        
        @self.sio.event
        async def disconnect():
            logger.info("❌ Disconnected from Socket.IO server")
            self.connected = False
        
        @self.sio.event
        async def connect_error(data):
            logger.error(f"❌ Connection error: {data}")
        
        @self.sio.event
        async def welcome(data):
            logger.info(f"🎉 Received welcome message: {data}")
        
        @self.sio.event
        async def message(data):
            logger.info(f"📨 Received message: {data}")
    
    async def test_connection(self):
        """Test basic connection to the Socket.IO server"""
        try:
            logger.info(f"🔄 Attempting to connect to {self.server_url}")
            await self.sio.connect(self.server_url, transports=['websocket'])
            
            # Wait a bit to see if we get any messages
            await asyncio.sleep(5)
            
            if self.connected:
                logger.info("✅ Connection test successful!")
                return True
            else:
                logger.error("❌ Connection test failed - not connected")
                return False
                
        except Exception as e:
            logger.error(f"❌ Connection test failed with exception: {e}")
            return False
        finally:
            if self.connected:
                await self.sio.disconnect()

async def main():
    """Main test function"""
    logger.info("🚀 Starting Socket.IO connection test")
    
    # Test with default server
    client = TestSocketIOClient()
    success = await client.test_connection()
    
    if success:
        logger.info("🎉 All tests passed! Socket.IO client is working correctly.")
        sys.exit(0)
    else:
        logger.error("💥 Tests failed! There may be an issue with the Socket.IO setup.")
        sys.exit(1)

if __name__ == "__main__":
    asyncio.run(main()) 