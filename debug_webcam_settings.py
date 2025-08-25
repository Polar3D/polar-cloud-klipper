#!/usr/bin/env python3
"""
Debug script to check what webcam settings are stored in Moonraker database
"""

import requests
import json

def check_webcam_settings():
    moonraker_url = "http://localhost:7125"
    
    print("=== Checking Mainsail Webcam Settings ===")
    
    # Try different database locations where webcam settings might be stored
    endpoints_to_check = [
        "/server/database/item?namespace=mainsail&key=webcam",
        "/server/database/item?namespace=webcams&key=cameras",
        "/server/database/item?namespace=mainsail&key=cameras", 
        "/server/database/list?root=mainsail",
        "/server/database/list?root=webcams",
        "/webcam/list"
    ]
    
    for endpoint in endpoints_to_check:
        try:
            print(f"\nChecking: {endpoint}")
            response = requests.get(f"{moonraker_url}{endpoint}", timeout=5)
            
            if response.status_code == 200:
                data = response.json()
                print(f"Success! Data structure:")
                print(json.dumps(data, indent=2))
            else:
                print(f"HTTP {response.status_code}: {response.text[:200]}")
                
        except Exception as e:
            print(f"Error: {e}")
    
    print("\n=== Raw Database Dump ===")
    try:
        response = requests.get(f"{moonraker_url}/server/database/list", timeout=5)
        if response.status_code == 200:
            data = response.json()
            print("Available namespaces:")
            for ns in data.get('result', {}).get('namespaces', []):
                print(f"  - {ns}")
    except Exception as e:
        print(f"Error getting database list: {e}")

if __name__ == "__main__":
    check_webcam_settings()