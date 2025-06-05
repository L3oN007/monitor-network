#!/bin/bash

# Config
SERVER_ID=$(hostname)                                   # Dùng hostname làm server_id
PLATFORM_WS_URL="ws://your-platform.com:3000"           # Thay bằng WebSocket URL
PLATFORM_API_URL="http://your-platform.com/api/monitor" # Thay bằng API URL
DEBUG_API_URL="http://your-platform.com/api/debug"      # API debug
GENERATE_KEY_URL="http://your-platform.com/api/generate-key"
NETWORK_RANGE="192.168.1.0/24" # Thay bằng dải IP mạng
INTERFACE="wlan0"              # Thay bằng interface mạng
AGENT_SCRIPT="/usr/local/bin/monitor.py"
CONFIG_FILE="/etc/monitor.conf"
USER_NAME="monitor-agent"

# 1. Tạo user monitor
echo "Creating user $USER_NAME..."
if ! id "$USER_NAME" &>/dev/null; then
    sudo useradd -m -s /bin/bash "$USER_NAME"
    sudo usermod -aG sudo "$USER_NAME" # Cần sudo cho arp-scan
fi

# 2. Lấy IP của server
SERVER_IP=$(ip addr show $INTERFACE | grep -oP 'inet \K[\d.]+')
if [ -z "$SERVER_IP" ]; then
    echo "Error: Cannot detect server IP"
    curl -s -X POST "$DEBUG_API_URL" -H "Content-Type: application/json" -d "{\"server_id\": \"$SERVER_ID\", \"ip\": \"$SERVER_IP\", \"message\": \"Cannot detect server IP\"}"
    exit 1
fi

# 3. Gọi API để lấy API key
echo "Fetching API key for IP $SERVER_IP..."
API_KEY=$(curl -s -X POST "$GENERATE_KEY_URL" \
    -H "Content-Type: application/json" \
    -d "{\"ip\": \"$SERVER_IP\"}" | grep -oP '(?<=api_key":")[^"]+')
if [ -z "$API_KEY" ]; then
    echo "Error: Failed to fetch API key"
    curl -s -X POST "$DEBUG_API_URL" -H "Content-Type: application/json" -d "{\"server_id\": \"$SERVER_ID\", \"ip\": \"$SERVER_IP\", \"message\": \"Failed to fetch API key\"}"
    exit 1
fi

# 4. Save configuration to config file
echo "Saving configuration to $CONFIG_FILE..."
sudo bash -c "cat > $CONFIG_FILE" <<EOF
# Monitor Agent Configuration
API_KEY=$API_KEY
API_URL=$PLATFORM_API_URL
WS_URL=$PLATFORM_WS_URL
DEBUG_API_URL=$DEBUG_API_URL
NETWORK_RANGE=$NETWORK_RANGE
SCAN_INTERFACE=$INTERFACE
SERVER_IP=$SERVER_IP
EOF

sudo chown $USER_NAME:$USER_NAME $CONFIG_FILE
sudo chmod 600 $CONFIG_FILE

# 5. Install required packages and dependencies
echo "Installing required packages..."
sudo apt update
sudo apt install -y curl arp-scan python3 python3-pip net-tools

# Install Python packages
echo "Installing Python dependencies..."
sudo pip3 install websocket-client psutil requests pyshark

# Install tshark (required by pyshark)
echo "Installing tshark for packet capture..."
sudo apt install -y tshark

# Configure tshark to allow non-root users (requires interaction)
echo "Configuring tshark permissions..."
echo "wireshark-common wireshark-common/install-setuid boolean true" | sudo debconf-set-selections
sudo dpkg-reconfigure -f noninteractive wireshark-common
sudo usermod -aG wireshark $USER_NAME

# Setup arp-scan permissions to run without sudo
echo "Configuring arp-scan permissions..."
# Add user to netdev group for network operations
sudo usermod -aG netdev $USER_NAME

# Create sudoers rule for arp-scan specifically
echo "Creating sudoers rule for arp-scan..."
sudo bash -c "echo '$USER_NAME ALL=(ALL) NOPASSWD: /usr/bin/arp-scan' > /etc/sudoers.d/monitor-agent-arp-scan"
sudo chmod 440 /etc/sudoers.d/monitor-agent-arp-scan

# Set capabilities for arp-scan (alternative approach)
sudo setcap cap_net_raw=ep /usr/bin/arp-scan 2>/dev/null || echo "Note: setcap not available, using sudo approach"

# 6. Tạo agent script (monitor.py)
echo "Creating monitor.py..."
sudo bash -c "cat > $AGENT_SCRIPT" <<'EOF'
#!/usr/bin/env python3
import time
import psutil
import subprocess
import socket
import requests
import json
import threading
import websocket
import os
import pyshark
from collections import defaultdict
from datetime import datetime, timezone

# =============================================================================
# CONFIGURATION SECTION
# =============================================================================

# Read configuration from environment or config file
def load_config():
    config = {}
    config_file = "/etc/monitor.conf"
    
    # Load from config file if exists
    if os.path.exists(config_file):
        with open(config_file, 'r') as f:
            for line in f:
                if '=' in line and not line.strip().startswith('#'):
                    key, value = line.strip().split('=', 1)
                    config[key] = value
    
    # Default values with environment variable fallbacks
    config.setdefault('API_KEY', os.getenv('API_KEY', 'local_test_key_123'))
    config.setdefault('API_URL', os.getenv('API_URL', 'https://65ec7c1b0ddee626c9b055b1.mockapi.io/api/v1/monitor-agent'))
    config.setdefault('WS_URL', os.getenv('WS_URL', 'ws://localhost:3000/ws/monitor'))
    config.setdefault('DEBUG_API_URL', os.getenv('DEBUG_API_URL', 'http://localhost:3000/api/debug'))
    
    return config

# Load configuration
CONFIG = load_config()
API_KEY = CONFIG['API_KEY']
API_URL = CONFIG['API_URL']
WS_URL = CONFIG['WS_URL']
DEBUG_API_URL = CONFIG['DEBUG_API_URL']

# Server identification
SERVER_ID = subprocess.check_output("hostname", shell=True).decode().strip()
CYCLE_TIME = 5  # 5 seconds fixed interval

# Network configuration - these will be passed as command line arguments
NETWORK_RANGE = "192.168.1.0/24"  # Default, will be overridden
SCAN_INTERFACE = "enp2s0"          # Default, will be overridden

# =============================================================================
# GLOBAL VARIABLES FOR PACKET MONITORING
# =============================================================================

# Packet tracking with pyshark for detailed analysis
packet_stats = defaultdict(lambda: {"rx_bytes": 0, "tx_bytes": 0})
capture_active = False

def packet_handler(packet):
    """
    Handler function for captured packets to track bandwidth per device
    """
    global packet_stats, capture_active
    
    if not capture_active:
        return
        
    try:
        # Get packet size
        packet_size = int(packet.length)
        
        # Extract IP addresses
        if hasattr(packet, 'ip'):
            src_ip = packet.ip.src
            dst_ip = packet.ip.dst
            
            # Check if source IP is in our network range (outgoing traffic)
            if src_ip.startswith('192.168.1.'):
                packet_stats[src_ip]["tx_bytes"] += packet_size
                
            # Check if destination IP is in our network range (incoming traffic)
            if dst_ip.startswith('192.168.1.'):
                packet_stats[dst_ip]["rx_bytes"] += packet_size
                
    except Exception as e:
        # Ignore packet parsing errors
        pass

def start_packet_capture(interface, duration):
    """
    Start packet capture for the specified duration using pyshark
    """
    global packet_stats, capture_active
    
    # Reset stats
    packet_stats.clear()
    capture_active = True
    
    try:
        # Create capture object
        capture = pyshark.LiveCapture(interface=interface)
        
        # Start capture with timeout
        capture.apply_on_packets(packet_handler, timeout=duration)
        
    except Exception as e:
        print(f"Packet capture error: {e}")
    finally:
        capture_active = False

# =============================================================================
# WEBSOCKET CONNECTION HANDLER
# =============================================================================

class WebSocketHandler:
    def __init__(self, url, server_id):
        self.url = url
        self.server_id = server_id
        self.ws = None
        self.connected = False
        self.reconnect_interval = 5
        
    def connect(self):
        """Establish WebSocket connection"""
        try:
            self.ws = websocket.WebSocketApp(
                self.url,
                on_open=self.on_open,
                on_message=self.on_message,
                on_error=self.on_error,
                on_close=self.on_close
            )
            return True
        except Exception as e:
            print(f"WebSocket connection error: {e}")
            return False
    
    def on_open(self, ws):
        """Called when WebSocket connection is opened"""
        self.connected = True
        print(f"WebSocket connected to {self.url}")
        # Send initial connection message
        self.send_message({
            "type": "agent_connect",
            "serverId": self.server_id,
            "timestamp": datetime.now(timezone.utc).isoformat()
        })
    
    def on_message(self, ws, message):
        """Handle incoming WebSocket messages"""
        try:
            data = json.loads(message)
            print(f"WebSocket message received: {data.get('type', 'unknown')}")
        except Exception as e:
            print(f"WebSocket message parse error: {e}")
    
    def on_error(self, ws, error):
        """Handle WebSocket errors"""
        print(f"WebSocket error: {error}")
        self.connected = False
    
    def on_close(self, ws, close_status_code, close_msg):
        """Handle WebSocket connection close"""
        print("WebSocket connection closed")
        self.connected = False
    
    def send_message(self, data):
        """Send message via WebSocket"""
        if self.ws and self.connected:
            try:
                self.ws.send(json.dumps(data))
                return True
            except Exception as e:
                print(f"WebSocket send error: {e}")
                self.connected = False
                return False
        return False
    
    def run_forever(self):
        """Run WebSocket connection in a separate thread"""
        if self.ws:
            self.ws.run_forever()

# Global WebSocket handler
ws_handler = None

# =============================================================================
# NETWORK MONITORING FUNCTIONS (Non-privileged)
# =============================================================================

def get_network_connections():
    """Get network connections without requiring root privileges"""
    connections = defaultdict(lambda: {"rx_bytes": 0, "tx_bytes": 0})
    
    try:
        # Use netstat or ss to get connection info (non-privileged)
        result = subprocess.run(
            ["ss", "-tuln"], 
            capture_output=True, 
            text=True, 
            timeout=2
        )
        
        # Parse connections and estimate traffic based on interface stats
        net_io = psutil.net_io_counters(pernic=True)
        if SCAN_INTERFACE in net_io:
            stats = net_io[SCAN_INTERFACE]
            # Distribute stats among known connections (simplified approach)
            connections["total"] = {
                "rx_bytes": stats.bytes_recv,
                "tx_bytes": stats.bytes_sent
            }
    except Exception as e:
        print(f"Network connection monitoring error: {e}")
    
    return connections

def getDeviceBandwidthStats(device_ip, duration_seconds, interface_link_speed_bps):
    """
    Get bandwidth statistics for a specific device using pyshark packet capture data
    """
    global packet_stats
    
    stats = packet_stats.get(device_ip, {"rx_bytes": 0, "tx_bytes": 0})
    
    # Calculate rates (bits per second)
    rx_rate_bps = int((stats["rx_bytes"] * 8) / duration_seconds) if duration_seconds > 0 else 0
    tx_rate_bps = int((stats["tx_bytes"] * 8) / duration_seconds) if duration_seconds > 0 else 0
    
    # Calculate utilization using the provided interface link speed
    max_bandwidth_bps = interface_link_speed_bps
    utilization = (max(rx_rate_bps, tx_rate_bps) / max_bandwidth_bps * 100) if max_bandwidth_bps > 0 else 0
    
    return {
        "rxBytesTotal": stats["rx_bytes"],
        "txBytesTotal": stats["tx_bytes"],
        "rxRateBps": rx_rate_bps,
        "txRateBps": tx_rate_bps,
        "utilizationPercent": round(utilization, 2)
    }

# =============================================================================
# SYSTEM METRICS FUNCTIONS
# =============================================================================

def getSystemMetricsNonblocking():
    """
    Get CPU, RAM, Disk and Uptime metrics without blocking
    """
    cpuPct = psutil.cpu_percent(interval=None)
    vm = psutil.virtual_memory()
    du = psutil.disk_usage('/')
    return {
        "cpu": {
            "percent": cpuPct
        },
        "memory": {
            "totalBytes": vm.total,
            "usedBytes": vm.used,
            "freeBytes": vm.available,
            "percentUsed": vm.percent
        },
        "disk": [
            {
                "mount": "/",
                "totalBytes": du.total,
                "usedBytes": du.used,
                "freeBytes": du.free,
                "percentUsed": du.percent
            }
        ],
        "uptimeSeconds": int(time.time() - psutil.boot_time())
    }

def getAllInterfaceCounters():
    """
    Read cumulative counters (bytes sent/received) for each interface
    """
    pernic = psutil.net_io_counters(pernic=True)
    counters = {}
    for iface, stats in pernic.items():
        counters[iface] = {
            "rxBytesTotal": stats.bytes_recv,
            "txBytesTotal": stats.bytes_sent
        }
    return counters

# =============================================================================
# DEVICE DISCOVERY FUNCTIONS
# =============================================================================

def getConnectedDevices(interface, ip_range, duration_seconds=0, scan_interface_speed_bps=0, time_checked_iso=None):
    """
    Use arp-scan to discover devices in the network (requires sudo setup for arp-scan)
    """
    devices = []
    final_time_checked = time_checked_iso if time_checked_iso else datetime.now(timezone.utc).isoformat()
    
    try:
        # Try to use arp-scan with timeout
        result = subprocess.run(
            ["arp-scan", f"--interface={interface}", ip_range],
            capture_output=True,
            text=True,
            timeout=10,
            check=False  # Don't raise exception on non-zero exit
        )
        
        if result.returncode == 0:
            output = result.stdout.splitlines()
            for line in output:
                parts = line.strip().split()
                if len(parts) >= 2 and parts[0].count('.') == 3 and len(parts[1]) == 17:
                    ip_addr = parts[0]
                    mac_addr = parts[1]
                    
                    # Try hostname lookup
                    try:
                        hostname = socket.gethostbyaddr(ip_addr)[0]
                    except Exception:
                        hostname = ""
                    
                    # Get bandwidth statistics
                    bandwidth_stats = getDeviceBandwidthStats(ip_addr, duration_seconds, scan_interface_speed_bps)
                    
                    devices.append({
                        "ip": ip_addr,
                        "mac": mac_addr,
                        "deviceName": hostname,
                        "status": "active",
                        "timeChecked": final_time_checked,
                        "bandwidth": bandwidth_stats
                    })
        else:
            print(f"arp-scan failed (exit code {result.returncode}): {result.stderr}")
            
    except subprocess.TimeoutExpired:
        print("arp-scan timeout - network scan took too long")
    except FileNotFoundError:
        print("arp-scan not found - please install arp-scan package")
    except Exception as e:
        print(f"Device discovery error: {e}")
    
    return devices

# =============================================================================
# DATA TRANSMISSION FUNCTIONS
# =============================================================================

def send_to_api(payload):
    """Send data to REST API for historical storage"""
    try:
        response = requests.post(
            API_URL,
            headers={
                "Content-Type": "application/json",
                "Authorization": f"Bearer {API_KEY}"
            },
            json=payload,
            timeout=5
        )
        
        if response.status_code in (200, 201):
            print(f"✓ API: Data sent successfully (HTTP {response.status_code})")
            return True
        else:
            print(f"✗ API: Error response (HTTP {response.status_code}): {response.text}")
            return False
            
    except requests.exceptions.Timeout:
        print("✗ API: Request timeout")
        return False
    except requests.exceptions.ConnectionError:
        print("✗ API: Connection error")
        return False
    except Exception as e:
        print(f"✗ API: Unexpected error: {e}")
        return False

def send_to_websocket(payload):
    """Send data to WebSocket for real-time monitoring"""
    global ws_handler
    
    if ws_handler and ws_handler.send_message(payload):
        print("✓ WebSocket: Real-time data sent successfully")
        return True
    else:
        print("✗ WebSocket: Failed to send real-time data")
        return False

def send_debug_message(message):
    """Send debug message to debug API"""
    try:
        debug_payload = {
            "server_id": SERVER_ID,
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "message": message
        }
        
        response = requests.post(
            DEBUG_API_URL,
            headers={"Content-Type": "application/json"},
            json=debug_payload,
            timeout=3
        )
        
        if response.status_code in (200, 201):
            print(f"✓ Debug: Message sent - {message}")
        else:
            print(f"✗ Debug: Failed to send message - {message}")
            
    except Exception as e:
        print(f"✗ Debug API error: {e}")

# =============================================================================
# MAIN MONITORING LOOP
# =============================================================================

def main():
    global ws_handler, NETWORK_RANGE, SCAN_INTERFACE
    
    # Parse command line arguments if provided
    import sys
    if len(sys.argv) >= 6:
        SERVER_ID = sys.argv[1]
        WS_URL_ARG = sys.argv[2]
        NETWORK_RANGE = sys.argv[3]
        SCAN_INTERFACE = sys.argv[4]
        DEBUG_API_URL_ARG = sys.argv[5]
        SERVER_IP = sys.argv[6] if len(sys.argv) > 6 else "unknown"
    
    # Initialize CPU counter for accurate readings
    psutil.cpu_percent(interval=None)
    
    # Initialize WebSocket connection
    ws_handler = WebSocketHandler(WS_URL, SERVER_ID)
    ws_thread = None
    
    # Try to establish WebSocket connection
    if ws_handler.connect():
        ws_thread = threading.Thread(target=ws_handler.run_forever, daemon=True)
        ws_thread.start()
        print(f"WebSocket thread started for {WS_URL}")
    else:
        print(f"Failed to initialize WebSocket connection to {WS_URL}")
    
    print(f"Starting monitor-agent for server '{SERVER_ID}' (interval = {CYCLE_TIME}s)")
    print(f"Network scan: {NETWORK_RANGE} via {SCAN_INTERFACE}")
    print(f"API endpoint: {API_URL}")
    print(f"WebSocket endpoint: {WS_URL}")
    print("-" * 60)
    
    # Send startup debug message
    send_debug_message(f"Monitor agent started - Server: {SERVER_ID}, Interface: {SCAN_INTERFACE}")
    
    cycle_count = 0
    
    while True:
        try:
            cycle_count += 1
            print(f"\n[Cycle {cycle_count}] Starting monitoring cycle...")
            
                         # STEP 1: Record start time and network counters
             startDt = datetime.now(timezone.utc)
             startTs = startDt.isoformat()
             startCounters = getAllInterfaceCounters()
             
             # STEP 1.5: Start packet capture in background thread
             capture_thread = threading.Thread(
                 target=start_packet_capture, 
                 args=(SCAN_INTERFACE, CYCLE_TIME)
             )
             capture_thread.daemon = True
             capture_thread.start()
             
             # STEP 2: Sleep for the monitoring interval
             print(f"Collecting data for {CYCLE_TIME} seconds...")
             time.sleep(CYCLE_TIME)
            
                         # STEP 3: Record end time and network counters
             endDt = datetime.now(timezone.utc)
             endTs = endDt.isoformat()
             endCounters = getAllInterfaceCounters()
             
             # Wait for packet capture thread to complete
             capture_thread.join(timeout=1)
            
            # Calculate actual duration
            actualDuration = (endDt - startDt).total_seconds()
            if actualDuration <= 0:
                actualDuration = CYCLE_TIME
            
            print(f"Data collection completed ({actualDuration:.2f}s)")
            
            # STEP 4: Calculate network interface statistics
            interfacesData = []
            ifStats = psutil.net_if_stats()
            
            for iface, endVals in endCounters.items():
                startVals = startCounters.get(iface, {"rxBytesTotal": 0, "txBytesTotal": 0})
                rxDelta = endVals["rxBytesTotal"] - startVals["rxBytesTotal"]
                txDelta = endVals["txBytesTotal"] - startVals["txBytesTotal"]
                
                rxRate = rxDelta / actualDuration  # bytes/sec
                txRate = txDelta / actualDuration  # bytes/sec
                
                # Get link speed (Mbps)
                stats = ifStats.get(iface)
                speedMbps = stats.speed if (stats and stats.speed is not None) else 0
                
                # Calculate utilization percentage
                if speedMbps and speedMbps > 0:
                    utilization = (max(rxRate, txRate) * 8) / (speedMbps * 1_000_000) * 100
                else:
                    utilization = 0.0
                
                interfacesData.append({
                    "interfaceName": iface,
                    "linkSpeedMbps": speedMbps,
                    "rxBytesTotal": endVals["rxBytesTotal"],
                    "txBytesTotal": endVals["txBytesTotal"],
                    "rxRateBps": int(rxRate * 8),
                    "txRateBps": int(txRate * 8),
                    "utilizationPercent": round(utilization, 2)
                })
            
            # STEP 5: Get system metrics
            print("Collecting system metrics...")
            systemMetrics = getSystemMetricsNonblocking()
            
            # STEP 6: Scan for connected devices
            print(f"Scanning for devices on {NETWORK_RANGE}...")
            current_snapshot_time = datetime.now(timezone.utc).isoformat()
            
            scan_interface_details = ifStats.get(SCAN_INTERFACE)
            scan_interface_speed_mbps = scan_interface_details.speed if (scan_interface_details and scan_interface_details.speed is not None) else 0
            scan_interface_link_speed_bps = scan_interface_speed_mbps * 1_000_000
            
            connectedDevices = getConnectedDevices(
                SCAN_INTERFACE,
                NETWORK_RANGE,
                actualDuration,
                scan_interface_link_speed_bps,
                current_snapshot_time
            )
            
            # Add current device information
            local_ip_on_scan_interface = "N/A"
            local_mac_on_scan_interface = "N/A"
            
            if_addrs = psutil.net_if_addrs()
            if SCAN_INTERFACE in if_addrs:
                for addr_info in if_addrs[SCAN_INTERFACE]:
                    if addr_info.family == socket.AF_INET:
                        local_ip_on_scan_interface = addr_info.address
                    elif addr_info.family == socket.AF_PACKET:
                        local_mac_on_scan_interface = addr_info.address
            
            if local_ip_on_scan_interface != "N/A":
                local_device_bandwidth = getDeviceBandwidthStats(
                    local_ip_on_scan_interface,
                    actualDuration,
                    scan_interface_link_speed_bps
                )
                current_device_info = {
                    "ip": local_ip_on_scan_interface,
                    "mac": local_mac_on_scan_interface,
                    "deviceName": SERVER_ID,
                    "status": "active",
                    "timeChecked": current_snapshot_time,
                    "bandwidth": local_device_bandwidth
                }
                connectedDevices.append(current_device_info)
            
            # STEP 7: Prepare payload
            payload = {
                "messageType": "realtimeSnapshot",
                "serverId": SERVER_ID,
                "snapshotTime": current_snapshot_time,
                "metrics": systemMetrics,
                "network": {
                    "collectionStartTime": startTs,
                    "collectionEndTime": endTs,
                    "collectionDurationSeconds": int(actualDuration),
                    "interfaces": interfacesData,
                    "connectedDevices": connectedDevices
                }
            }
            
            # STEP 8: Display monitoring results
            print(f"\n[{payload['snapshotTime']}] System Metrics:")
            print(f"  CPU: {systemMetrics['cpu']['percent']:.1f}%")
            print(f"  RAM: {systemMetrics['memory']['usedBytes'] // (1024*1024)}MB/{systemMetrics['memory']['totalBytes'] // (1024*1024)}MB ({systemMetrics['memory']['percentUsed']:.1f}%)")
            print(f"  Disk: {systemMetrics['disk'][0]['usedBytes'] // (1024*1024)}MB/{systemMetrics['disk'][0]['totalBytes'] // (1024*1024)}MB ({systemMetrics['disk'][0]['percentUsed']:.1f}%)")
            print(f"  Uptime: {systemMetrics['uptimeSeconds'] // 3600}h {(systemMetrics['uptimeSeconds'] % 3600) // 60}m")
            
            print(f"\nNetwork Interfaces ({len(interfacesData)} found):")
            for ifaceObj in interfacesData:
                print(f"  • {ifaceObj['interfaceName']}: {ifaceObj['linkSpeedMbps']}Mbps, Util: {ifaceObj['utilizationPercent']}%")
            
            print(f"\nConnected Devices ({len(connectedDevices)} found):")
            for dev in connectedDevices:
                bandwidth = dev.get('bandwidth', {})
                print(f"  • {dev['ip']} ({dev['mac']}) - {dev['deviceName'] or 'Unknown'}")
                print(f"    Bandwidth: {bandwidth.get('utilizationPercent', 0):.1f}% utilization")
            
            # STEP 9: Send data to both API and WebSocket
            print(f"\nTransmitting data...")
            
            # Send to API for historical storage
            api_success = send_to_api(payload)
            
            # Send to WebSocket for real-time monitoring
            ws_success = send_to_websocket(payload)
            
            # Summary
            if api_success and ws_success:
                print("✓ All data transmission successful")
            elif api_success:
                print("⚠ API successful, WebSocket failed")
            elif ws_success:
                print("⚠ WebSocket successful, API failed")
            else:
                print("✗ All data transmission failed")
            
            print(f"Waiting {CYCLE_TIME} seconds for next cycle...")
            
        except KeyboardInterrupt:
            print("\n\nMonitoring stopped by user (Ctrl+C)")
            send_debug_message(f"Monitor agent stopped by user - Server: {SERVER_ID}")
            break
            
        except Exception as e:
            print(f"\n✗ Error in monitoring cycle: {e}")
            send_debug_message(f"Monitor agent error - Server: {SERVER_ID}, Error: {str(e)}")
            print("Waiting 5 seconds before retry...")
            time.sleep(5)

if __name__ == "__main__":
    main()
EOF

# 7. Set executable permissions and ownership
sudo chown $USER_NAME:$USER_NAME $AGENT_SCRIPT
sudo chmod 755 $AGENT_SCRIPT

# 8. Tạo systemd service chạy với user monitor
echo "Creating systemd service..."
sudo bash -c "cat > /etc/systemd/system/monitor.service" <<EOF
[Unit]
Description=Network and System Monitor
After=network.target

[Service]
ExecStart=$AGENT_SCRIPT $SERVER_ID "$PLATFORM_WS_URL" "$NETWORK_RANGE" "$INTERFACE" "$DEBUG_API_URL" "$SERVER_IP"
Restart=always
User=$USER_NAME
Group=$USER_NAME

[Install]
WantedBy=multi-user.target
EOF

# 9. Khởi động service
sudo systemctl enable monitor.service
sudo systemctl start monitor.service

echo "Agent setup completed for $SERVER_ID!"