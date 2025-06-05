# Network Monitor Agent

A Python-based network monitoring agent that tracks system metrics, network interface statistics, and per-device bandwidth usage. The agent sends data to both REST API (for historical storage) and WebSocket (for real-time monitoring).

## Features

- **System Metrics**: CPU, Memory, Disk usage, and uptime monitoring
- **Network Interface Monitoring**: Traffic rates, utilization, and link speeds
- **Device Discovery**: Automatic discovery of connected devices using ARP scan
- **Per-Device Bandwidth Tracking**: Real-time bandwidth monitoring for each connected device using packet capture
- **Dual Data Transmission**: Sends data to both REST API and WebSocket endpoints
- **Non-Privileged Operation**: Runs without sudo after initial setup
- **Automated Setup**: Easy installation and removal scripts

## 🚀 Quick Reference

| Action | Command |
|--------|---------|
| **Install** | `sudo ./setup_agent.sh` |
| **Start** | `sudo systemctl start monitor.service` |
| **Stop** | `sudo systemctl stop monitor.service` |
| **Restart** | `sudo systemctl restart monitor.service` |
| **Status** | `sudo systemctl status monitor.service` |
| **Logs** | `sudo journalctl -u monitor.service -f` |
| **Remove** | `sudo ./remove_agent.sh` |

## Requirements

### System Dependencies

1. **arp-scan**: Required for device discovery
   ```bash
   # Ubuntu/Debian
   sudo apt-get install arp-scan
   
   # CentOS/RHEL
   sudo yum install arp-scan
   ```

2. **tshark/Wireshark**: Required for packet capture (pyshark dependency)
   ```bash
   # Ubuntu/Debian
   sudo apt-get install tshark
   
   # CentOS/RHEL
   sudo yum install wireshark-cli
   ```

3. **Python 3.7+**: Required for the script

### Python Dependencies

Install Python dependencies using pip:

```bash
pip install -r requirements.txt
```

Or install manually:
```bash
pip install psutil>=5.9.0 requests>=2.28.0 pyshark>=0.6.0
```

## Quick Start

### 1. Configuration Setup

Before installation, edit the configuration variables in `setup_agent.sh`:

```bash
# Platform URLs - CHANGE THESE TO YOUR ACTUAL ENDPOINTS
PLATFORM_WS_URL="ws://your-platform.com:3000"           # WebSocket URL for real-time data
PLATFORM_API_URL="http://your-platform.com/api/monitor" # REST API URL for historical data
DEBUG_API_URL="http://your-platform.com/api/debug"      # Debug API URL
GENERATE_KEY_URL="http://your-platform.com/api/generate-key" # API key generation endpoint

# Network Configuration - ADJUST TO YOUR NETWORK
NETWORK_RANGE="192.168.1.0/24"  # Your network range to scan
INTERFACE="wlan0"                # Your network interface (eth0, enp2s0, etc.)
```

### 2. Install the Agent

Run the setup script with root privileges:

```bash
sudo ./setup_agent.sh
```

**What the setup script does:**
- ✅ Creates a dedicated `monitor-agent` user
- ✅ Detects server IP automatically
- ✅ Generates API key from your platform
- ✅ Installs all required dependencies (Python packages, tshark, arp-scan)
- ✅ Configures permissions for non-sudo operation
- ✅ Creates and starts systemd service
- ✅ Sets up WebSocket and API connectivity

## Files and Structure

After installation, the following files are created:

```
/usr/local/bin/monitor.py          # Main agent script
/etc/monitor.conf                  # Configuration file
/etc/systemd/system/monitor.service # Systemd service file
/etc/sudoers.d/monitor-agent-arp-scan # Sudoers rule for arp-scan
```

The agent runs as user `monitor-agent` (created during setup) and requires no sudo privileges during operation.

## Agent Management

### ▶️ Starting the Agent

After installation, the agent starts automatically. To manually start:

```bash
sudo systemctl start monitor.service
```

### ⏹️ Stopping the Agent

```bash
sudo systemctl stop monitor.service
```

### 🔄 Restarting the Agent

```bash
sudo systemctl restart monitor.service
```

### 🔍 Monitoring the Agent

#### Check Service Status
```bash
# Check if service is running
sudo systemctl status monitor.service

# Check if service is enabled (auto-start on boot)
sudo systemctl is-enabled monitor.service

# Check service logs
sudo journalctl -u monitor.service -f
```

#### View Real-time Logs
```bash
# Follow live logs
sudo journalctl -u monitor.service -f

# View last 50 lines
sudo journalctl -u monitor.service -n 50

# View logs from last hour
sudo journalctl -u monitor.service --since "1 hour ago"
```

#### Check Agent Performance
```bash
# Check CPU and memory usage of the agent
ps aux | grep monitor.py

# Check network connections
netstat -tulpn | grep python3

# Check if agent is sending data
sudo journalctl -u monitor.service | grep "Data sent successfully"
```

### 🛠️ Troubleshooting Commands

#### Test Manual Execution
```bash
# Run agent manually for testing (as monitor-agent user)
sudo -u monitor-agent /usr/local/bin/monitor.py

# Run with debug output
sudo -u monitor-agent python3 /usr/local/bin/monitor.py
```

#### Check Configuration
```bash
# View current configuration
sudo cat /etc/monitor.conf

# Check if API key is set
sudo grep "API_KEY" /etc/monitor.conf
```

#### Test Network Connectivity
```bash
# Test if arp-scan works
sudo -u monitor-agent arp-scan --interface=wlan0 192.168.1.0/24

# Test API connectivity
curl -X POST "http://your-platform.com/api/monitor" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer YOUR_API_KEY" \
  -d '{"test": "connectivity"}'
```

### 🗑️ Completely Remove the Agent

To completely uninstall the monitor agent:

```bash
sudo ./remove_agent.sh
```

**What the removal script does:**
- ⏹️ Stops and disables the service
- 🗑️ Removes the monitor-agent user and home directory
- 🧹 Cleans up all configuration files
- 🔐 Removes sudoers rules and permissions
- 📦 Optionally removes installed packages
- 🧽 Cleans up any remaining files

### 📊 Monitoring Dashboard

The agent sends data to two endpoints:

1. **REST API** (`PLATFORM_API_URL`): For historical data storage
2. **WebSocket** (`PLATFORM_WS_URL`): For real-time monitoring dashboard

**Data is sent every 5 seconds** containing:
- System metrics (CPU, RAM, Disk, Uptime)
- Network interface statistics
- Connected device list with bandwidth usage
- Per-device traffic analysis

## Output Data Structure

The script generates JSON payloads with the following structure:

```json
{
  "messageType": "realtimeSnapshot",
  "serverId": "hostname",
  "snapshotTime": "2024-01-01T12:00:00.000Z",
  "metrics": {
    "cpu": {"percent": 25.5},
    "memory": {
      "totalBytes": 8589934592,
      "usedBytes": 4294967296,
      "freeBytes": 4294967296,
      "percentUsed": 50.0
    },
    "disk": [...],
    "uptimeSeconds": 86400
  },
  "network": {
    "collectionStartTime": "2024-01-01T12:00:00.000Z",
    "collectionEndTime": "2024-01-01T12:00:05.000Z",
    "collectionDurationSeconds": 5,
    "interfaces": [...],
    "connectedDevices": [
      {
        "ip": "192.168.1.100",
        "mac": "00:11:22:33:44:55",
        "deviceName": "device-hostname",
        "status": "active",
        "timeChecked": "2024-01-01T12:00:05.000Z",
        "bandwidth": {
          "rxBytesTotal": 1024,
          "txBytesTotal": 2048,
          "rxRateBps": 1638400,
          "txRateBps": 3276800,
          "utilizationPercent": 3.28
        }
      }
    ]
  }
}
```

## 🔧 Advanced Troubleshooting

### Common Issues and Solutions

#### 1. Service Won't Start
```bash
# Check service status and errors
sudo systemctl status monitor.service
sudo journalctl -u monitor.service --no-pager

# Common fixes:
sudo systemctl daemon-reload
sudo systemctl restart monitor.service
```

#### 2. Permission Denied Errors
```bash
# Check if monitor-agent user exists
id monitor-agent

# Verify sudoers rule for arp-scan
sudo cat /etc/sudoers.d/monitor-agent-arp-scan

# Check wireshark group membership
groups monitor-agent
```

#### 3. No Devices Found in Network Scan
```bash
# Test arp-scan manually
sudo -u monitor-agent arp-scan --interface=wlan0 192.168.1.0/24

# Check network interface is up
ip link show wlan0

# Verify network range is correct
ip route | grep wlan0
```

#### 4. API Connection Issues
```bash
# Test API connectivity
curl -v -X POST "http://your-platform.com/api/monitor" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $(grep API_KEY /etc/monitor.conf | cut -d'=' -f2)"

# Check DNS resolution
nslookup your-platform.com

# Test WebSocket connection
telnet your-platform.com 3000
```

#### 5. High CPU/Memory Usage
```bash
# Monitor resource usage
top -u monitor-agent

# Check packet capture performance
sudo -u monitor-agent python3 -c "
import psutil
import time
proc = psutil.Process()
while True:
    print(f'CPU: {proc.cpu_percent()}%, Memory: {proc.memory_info().rss / 1024 / 1024:.1f}MB')
    time.sleep(5)
"
```

#### 6. Packet Capture Not Working
```bash
# Check tshark permissions
ls -la /usr/bin/tshark

# Test pyshark manually
sudo -u monitor-agent python3 -c "
import pyshark
capture = pyshark.LiveCapture(interface='wlan0')
capture.sniff(timeout=5)
print('Packet capture working!')
"

# Check wireshark capabilities
sudo getcap /usr/bin/dumpcap
```

### Configuration Debugging

#### View Full Configuration
```bash
sudo cat /etc/monitor.conf
```

#### Test Configuration Loading
```bash
sudo -u monitor-agent python3 -c "
import os
config_file = '/etc/monitor.conf'
if os.path.exists(config_file):
    with open(config_file, 'r') as f:
        for line in f:
            if '=' in line and not line.strip().startswith('#'):
                key, value = line.strip().split('=', 1)
                print(f'{key}: {value}')
else:
    print('Config file not found!')
"
```

### Performance Monitoring

#### Check Agent Resource Usage
```bash
# Memory usage over time
ps -o pid,ppid,cmd,%mem,%cpu -u monitor-agent

# Network connections
ss -tulpn | grep python3

# File descriptors
sudo lsof -u monitor-agent | wc -l
```

#### Monitor Data Transmission
```bash
# Count successful API transmissions
sudo journalctl -u monitor.service | grep "API: Data sent successfully" | wc -l

# Count WebSocket transmissions
sudo journalctl -u monitor.service | grep "WebSocket: Real-time data sent successfully" | wc -l

# Check for errors
sudo journalctl -u monitor.service | grep -E "(ERROR|Failed|Error)"
```

### Manual Testing

#### Run Agent in Debug Mode
```bash
# Stop service first
sudo systemctl stop monitor.service

# Run manually with full output
sudo -u monitor-agent python3 /usr/local/bin/monitor.py

# Run with custom parameters for testing
sudo -u monitor-agent /usr/local/bin/monitor.py \
  "test-server" \
  "ws://localhost:3000/ws/monitor" \
  "192.168.1.0/24" \
  "wlan0" \
  "http://localhost:3000/api/debug" \
  "192.168.1.100"
```

#### Component Testing
```bash
# Test system metrics collection
sudo -u monitor-agent python3 -c "
import psutil
print(f'CPU: {psutil.cpu_percent()}%')
print(f'Memory: {psutil.virtual_memory().percent}%')
print(f'Disk: {psutil.disk_usage(\"/\").percent}%')
"

# Test network interface detection
sudo -u monitor-agent python3 -c "
import psutil
for iface, stats in psutil.net_io_counters(pernic=True).items():
    print(f'{iface}: {stats.bytes_sent} sent, {stats.bytes_recv} received')
"
```

## Security Considerations

- Store API keys securely (environment variables recommended)
- Limit network access to monitoring interfaces only
- Consider using dedicated monitoring VLAN
- Regularly review captured data and logs
- Implement proper log rotation

## Performance Notes

- Packet capture adds CPU overhead
- Memory usage scales with network traffic volume
- Consider monitoring on dedicated network interfaces
- Adjust CYCLE_TIME based on your monitoring needs 