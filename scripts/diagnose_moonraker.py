#!/usr/bin/env python3
"""
Diagnostic script for Polar Cloud Moonraker integration
"""

import requests
import json
import sys

def test_moonraker_endpoints():
    """Test various Moonraker endpoints to diagnose the issue"""
    
    base_url = "http://localhost:7125"
    
    print("=== Moonraker Polar Cloud Diagnostics ===\n")
    
    # Test basic server info
    print("1. Testing basic Moonraker server info...")
    try:
        response = requests.get(f"{base_url}/server/info", timeout=5)
        if response.status_code == 200:
            print("✓ Moonraker server is responding")
            server_info = response.json()
            print(f"   Moonraker version: {server_info.get('result', {}).get('moonraker_version', 'Unknown')}")
        else:
            print(f"✗ Moonraker server error: {response.status_code}")
            return False
    except Exception as e:
        print(f"✗ Cannot connect to Moonraker: {e}")
        return False
    
    # Test available endpoints
    print("\n2. Testing available endpoints...")
    try:
        response = requests.get(f"{base_url}/server/endpoints", timeout=5)
        if response.status_code == 200:
            endpoints = response.json().get('result', {})
            polar_endpoints = [ep for ep in endpoints if 'polar_cloud' in ep]
            if polar_endpoints:
                print("✓ Found Polar Cloud endpoints:")
                for ep in polar_endpoints:
                    print(f"   - {ep}")
            else:
                print("✗ No Polar Cloud endpoints found")
                print("   Available endpoints containing 'server':")
                server_endpoints = [ep for ep in endpoints if 'server' in ep][:10]  # Show first 10
                for ep in server_endpoints:
                    print(f"   - {ep}")
        else:
            print(f"✗ Could not get endpoints: {response.status_code}")
    except Exception as e:
        print(f"✗ Error getting endpoints: {e}")
    
    # Test specific Polar Cloud endpoints
    print("\n3. Testing Polar Cloud endpoints...")
    
    polar_endpoints = [
        "/server/polar_cloud/status",
        "/server/polar_cloud/config",
        "/server/polar_cloud/register"
    ]
    
    for endpoint in polar_endpoints:
        try:
            if endpoint == "/server/polar_cloud/register":
                # Skip POST endpoint in diagnostic
                print(f"   {endpoint}: Skipped (POST endpoint)")
                continue
                
            response = requests.get(f"{base_url}{endpoint}", timeout=5)
            if response.status_code == 200:
                print(f"✓ {endpoint}: Working")
            elif response.status_code == 404:
                print(f"✗ {endpoint}: Not Found (404)")
            else:
                print(f"? {endpoint}: Status {response.status_code}")
        except Exception as e:
            print(f"✗ {endpoint}: Error - {e}")
    
    # Test component status
    print("\n4. Testing component status...")
    try:
        response = requests.get(f"{base_url}/server/components", timeout=5)
        if response.status_code == 200:
            components = response.json().get('result', {})
            if 'polar_cloud' in components:
                polar_status = components['polar_cloud']
                print(f"✓ Polar Cloud component status: {polar_status}")
            else:
                print("✗ Polar Cloud component not found")
                print("   Available components:")
                for comp in list(components.keys())[:10]:  # Show first 10
                    print(f"   - {comp}")
        else:
            print(f"✗ Could not get component status: {response.status_code}")
    except Exception as e:
        print(f"✗ Error getting component status: {e}")
    
    print("\n=== Diagnostic Complete ===")

if __name__ == "__main__":
    test_moonraker_endpoints() 