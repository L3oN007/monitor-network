#!/usr/bin/env python3
import time
import psutil
import subprocess
import socket
import requests
import pyshark
import threading
from collections import defaultdict
from datetime import datetime, timezone

# Configuration
API_KEY = "local_test_key_123"  # Thay bằng API key thật nếu cần
API_URL = "https://65ec7c1b0ddee626c9b055b1.mockapi.io/api/v1/monitor-agent"
SERVER_ID = subprocess.check_output("hostname", shell=True).decode().strip()
CYCLE_TIME = 5  # 5 giây cố định

# Định nghĩa mạng để quét và interface sử dụng cho arp-scan
NETWORK_RANGE = "192.168.1.0/24"
SCAN_INTERFACE = "enp2s0"

# Global variables for packet capture
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
    Start packet capture for the specified duration
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

def getDeviceBandwidthStats(device_ip, duration_seconds, interface_link_speed_bps):
    """
    Get bandwidth statistics for a specific device
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

def getSystemMetricsNonblocking():
    """
    Lấy CPU, RAM, Disk và Uptime mà không block lâu.
    cpu_percent(interval=None) sẽ trả ngay giá trị phần trăm CPU so với lần gọi trước.
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
    Đọc counters tích lũy (bytes sent/received) cho mỗi interface.
    Trả về dict: { ifaceName: {"rxBytesTotal": <bytes>, "txBytesTotal": <bytes>} }
    """
    pernic = psutil.net_io_counters(pernic=True)
    counters = {}
    for iface, stats in pernic.items():
        counters[iface] = {
            "rxBytesTotal": stats.bytes_recv,
            "txBytesTotal": stats.bytes_sent
        }
    return counters

def getConnectedDevices(interface, ip_range, duration_seconds=0, scan_interface_speed_bps=0):
    """
    Sử dụng arp-scan để quét các thiết bị trong ip_range qua interface.
    Trả về danh sách devices, mỗi device có: ip, mac, deviceName, status, timeChecked, bandwidth.
    """
    devices = []
    time_checked = datetime.now(timezone.utc).isoformat()
    try:
        # Chạy lệnh arp-scan
        result = subprocess.run(
            ["arp-scan", f"--interface={interface}", ip_range],
            capture_output=True,
            text=True,
            check=True
        )
        output = result.stdout.splitlines()
        # Kết quả thường có header và footer, ta chỉ quan tâm các dòng chứa "<IP>  <MAC>"
        for line in output:
            parts = line.strip().split()
            if len(parts) >= 2 and parts[0].count('.') == 3 and len(parts[1]) == 17:
                ip_addr = parts[0]
                mac_addr = parts[1]
                # Thử lookup hostname ngược
                try:
                    hostname = socket.gethostbyaddr(ip_addr)[0]
                except Exception:
                    hostname = ""
                
                # Get bandwidth statistics for this device
                bandwidth_stats = getDeviceBandwidthStats(ip_addr, duration_seconds, scan_interface_speed_bps)
                
                devices.append({
                    "ip": ip_addr,
                    "mac": mac_addr,
                    "deviceName": hostname,
                    "status": "active",
                    "timeChecked": time_checked,
                    "bandwidth": bandwidth_stats
                })
    except Exception:
        # Nếu arp-scan không cài đặt hoặc lỗi, trả về list rỗng
        return []
    return devices

def main():
    # --- BƯỚC 0: Khởi động CPU counter để cpu_percent(interval=None) lần sau trả đúng giá trị ---
    psutil.cpu_percent(interval=None)

    print(f"Starting monitor-agent for server '{SERVER_ID}' (interval = {CYCLE_TIME}s)\n")

    while True:
        try:
            # --- BƯỚC 1: Ghi lại thời gian và counters mạng ban đầu ---
            startDt = datetime.now(timezone.utc)
            startTs = startDt.isoformat()
            startCounters = getAllInterfaceCounters()

            # --- BƯỚC 1.5: Bắt đầu packet capture trong background thread ---
            capture_thread = threading.Thread(
                target=start_packet_capture, 
                args=(SCAN_INTERFACE, CYCLE_TIME)
            )
            capture_thread.daemon = True
            capture_thread.start()

            # --- BƯỚC 2: Ngủ đúng CYCLE_TIME giây ---
            time.sleep(CYCLE_TIME)

            # --- BƯỚC 3: Ghi lại thời gian và counters mạng sau khi ngủ ---
            endDt = datetime.now(timezone.utc)
            endTs = endDt.isoformat()
            endCounters = getAllInterfaceCounters()

            # Đợi capture thread hoàn thành
            capture_thread.join(timeout=1)

            # Tính actualDuration (xấp xỉ CYCLE_TIME, có thể chênh vài ms)
            actualDuration = (endDt - startDt).total_seconds()
            if actualDuration <= 0:
                actualDuration = CYCLE_TIME  # đề phòng trường hợp hi hữu

            # --- BƯỚC 4: Tính rate và các thông số cho mỗi interface ---
            interfacesData = []
            ifStats = psutil.net_if_stats()

            for iface, endVals in endCounters.items():
                startVals = startCounters.get(iface, {"rxBytesTotal": 0, "txBytesTotal": 0})
                rxDelta = endVals["rxBytesTotal"] - startVals["rxBytesTotal"]
                txDelta = endVals["txBytesTotal"] - startVals["txBytesTotal"]

                rxRate = rxDelta / actualDuration  # bytes/sec
                txRate = txDelta / actualDuration  # bytes/sec

                # Lấy link speed (Mbps); nếu không có thông tin, đặt về 0
                stats = ifStats.get(iface)
                speedMbps = stats.speed if (stats and stats.speed is not None) else 0

                # Tính utilization (%) = (max(rxRate, txRate) * 8) / (speedMbps * 1_000_000) * 100
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

            # --- BƯỚC 5: Lấy system metrics không block lâu ---
            systemMetrics = getSystemMetricsNonblocking()

            # --- BƯỚC 6: Quét các thiết bị đang kết nối qua arp-scan với bandwidth data ---
            # Get the speed of the SCAN_INTERFACE to pass to getConnectedDevices
            scan_interface_details = ifStats.get(SCAN_INTERFACE)
            scan_interface_speed_mbps = scan_interface_details.speed if (scan_interface_details and scan_interface_details.speed is not None) else 0
            scan_interface_link_speed_bps = scan_interface_speed_mbps * 1_000_000
            
            connectedDevices = getConnectedDevices(SCAN_INTERFACE, NETWORK_RANGE, actualDuration, scan_interface_link_speed_bps)

            # --- BƯỚC 7: Đóng gói payload JSON theo định dạng camelCase ---
            payload = {
                "messageType": "realtimeSnapshot",
                "serverId": SERVER_ID,
                "snapshotTime": datetime.now(timezone.utc).isoformat(),
                "metrics": systemMetrics,
                "network": {
                    "collectionStartTime": startTs,
                    "collectionEndTime": endTs,
                    "collectionDurationSeconds": int(actualDuration),
                    "interfaces": interfacesData,
                    "connectedDevices": connectedDevices
                }
            }

            # --- BƯỚC 8: In ra console để debug ---
            print(f"[{payload['snapshotTime']}] System Metrics:")
            print(f"  CPU: {systemMetrics['cpu']['percent']}%")
            print(
                f"  RAM: {systemMetrics['memory']['usedBytes'] // (1024*1024)}MB/"
                f"{systemMetrics['memory']['totalBytes'] // (1024*1024)}MB "
                f"({systemMetrics['memory']['percentUsed']}%)"
            )
            print(
                f"  Disk(/): {systemMetrics['disk'][0]['usedBytes'] // (1024*1024)}MB/"
                f"{systemMetrics['disk'][0]['totalBytes'] // (1024*1024)}MB "
                f"({systemMetrics['disk'][0]['percentUsed']}%)"
            )
            print(
                f"  Uptime: {systemMetrics['uptimeSeconds'] // 3600}h "
                f"{(systemMetrics['uptimeSeconds'] % 3600) // 60}m"
            )

            print(f"\nNetwork Collection Window: {startTs} → {endTs} (≈ {int(actualDuration)}s)")
            for ifaceObj in interfacesData:
                print(
                    f"  - {ifaceObj['interfaceName']}: "
                    f"LinkSpeed={ifaceObj['linkSpeedMbps']}Mbps, "
                    f"RX_total={ifaceObj['rxBytesTotal']}B, "
                    f"TX_total={ifaceObj['txBytesTotal']}B, "
                    f"RX_rate={ifaceObj['rxRateBps']}bps, "
                    f"TX_rate={ifaceObj['txRateBps']}bps, "
                    f"Utilization={ifaceObj['utilizationPercent']}%"
                )

            print("\nConnected Devices:")
            for dev in connectedDevices:
                bandwidth = dev.get('bandwidth', {})
                print(
                    f"  - IP: {dev['ip']}, MAC: {dev['mac']}, "
                    f"Name: {dev['deviceName'] or 'N/A'}, Status: {dev['status']}"
                )
                print(
                    f"    Bandwidth: RX={bandwidth.get('rxBytesTotal', 0)}B, "
                    f"TX={bandwidth.get('txBytesTotal', 0)}B, "
                    f"RX_rate={bandwidth.get('rxRateBps', 0)}bps, "
                    f"TX_rate={bandwidth.get('txRateBps', 0)}bps, "
                    f"Utilization={bandwidth.get('utilizationPercent', 0)}%"
                )
                print(f"    Checked: {dev['timeChecked']}")

            # --- BƯỚC 9: Gửi payload lên API nếu cần ---
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
                print(f"\nAPI Response: {response.status_code}")
                if response.status_code in (200, 201):
                    print("  Data sent successfully.")
                else:
                    print(f"  Error response: {response.text}")
            except Exception as e:
                print(f"\nAPI Error: {e}")

            print("\nWaiting for next cycle...\n")

        except KeyboardInterrupt:
            print("\nMonitoring stopped by user.")
            break
        except Exception as e:
            print(f"Error in main loop: {e}")
            time.sleep(5)  # Chờ rồi thử lại

if __name__ == "__main__":
    main()
