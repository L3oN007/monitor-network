# Network Monitor Agent

A Python-based network monitoring agent that tracks system metrics, network interface statistics, and per-device bandwidth usage.

## Features

- **System Metrics**: CPU, Memory, Disk usage, and uptime monitoring
- **Network Interface Monitoring**: Traffic rates, utilization, and link speeds
- **Device Discovery**: Automatic discovery of connected devices using ARP scan
- **Per-Device Bandwidth Tracking**: Real-time bandwidth monitoring for each connected device using packet capture
- **API Integration**: Sends monitoring data to remote API endpoints

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

## Configuration

Edit the configuration variables in `monitor.py`:

```python
# API Configuration
API_KEY = "your_api_key_here"
API_URL = "https://your-api-endpoint.com/api/v1/monitor-agent"

# Server identification
SERVER_ID = "your_server_id"  # or leave as hostname

# Monitoring interval
CYCLE_TIME = 5  # seconds

# Network configuration
NETWORK_RANGE = "192.168.1.0/24"  # Adjust to your network
SCAN_INTERFACE = "enp2s0"  # Your network interface
```

## Permissions

The script requires elevated privileges for:
- Packet capture (pyshark/tshark)
- ARP scanning
- Network interface access

### Option 1: Run with sudo
```bash
sudo python3 monitor.py
```

### Option 2: Grant specific capabilities (Linux)
```bash
# Allow packet capture without sudo
sudo setcap cap_net_raw,cap_net_admin=eip /usr/bin/dumpcap

# Add user to appropriate groups
sudo usermod -a -G wireshark $USER
```

## Usage

1. **Basic monitoring**:
   ```bash
   sudo python3 monitor.py
   ```

2. **Background execution**:
   ```bash
   sudo nohup python3 monitor.py > monitor.log 2>&1 &
   ```

3. **With systemd service** (recommended for production):
   ```bash
   # Create service file
   sudo cp monitor.service /etc/systemd/system/
   sudo systemctl enable monitor
   sudo systemctl start monitor
   ```

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

## Troubleshooting

### Common Issues

1. **Permission denied errors**:
   - Ensure script runs with sufficient privileges
   - Check tshark/dumpcap permissions

2. **No devices found**:
   - Verify `arp-scan` is installed
   - Check network interface name and range
   - Ensure interface is up and connected

3. **Packet capture errors**:
   - Verify tshark/Wireshark is installed
   - Check interface permissions
   - Ensure pyshark can access the network interface

4. **High CPU usage**:
   - Packet capture can be CPU intensive
   - Consider reducing monitoring frequency
   - Monitor specific interfaces only

### Debug Mode

Add debug output by modifying the packet_handler function to include:
```python
print(f"Captured packet: {src_ip} -> {dst_ip}, Size: {packet_size}")
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