#!/usr/bin/env python3
import time
import psutil
import subprocess
import requests
from datetime import datetime, timezone

# Configuration
API_KEY = "local_test_key_123"  # Thay bằng API key thật nếu cần
API_URL = "https://65ec7c1b0ddee626c9b055b1.mockapi.io/api/v1/monitor-agent"
SERVER_ID = subprocess.check_output("hostname", shell=True).decode().strip()
CYCLE_TIME = 5  # 5 giây cố định

def getSystemMetricsNonblocking():
    """
    Lấy CPU, RAM, Disk và Uptime mà không block lâu.
    cpu_percent(interval=None) sẽ trả ngay giá trị phần trăm CPU so với lần gọi trước.
    """
    cpuPct = psutil.cpu_percent(interval=None)  # không block 1s
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

            # --- BƯỚC 2: Ngủ đúng CYCLE_TIME giây ---
            time.sleep(CYCLE_TIME)

            # --- BƯỚC 3: Ghi lại thời gian và counters mạng sau khi ngủ ---
            endDt = datetime.now(timezone.utc)
            endTs = endDt.isoformat()
            endCounters = getAllInterfaceCounters()

            # Tính actualDuration (xấp xỉ CYCLE_TIME, có thể chênh vài ms)
            actualDuration = (endDt - startDt).total_seconds()
            if actualDuration <= 0:
                actualDuration = CYCLE_TIME  # đề phòng trường hợp hi hữu

            # --- BƯỚC 4: Tính rate và các thông số cho mỗi interface ---
            interfacesData = []
            # Lấy tốc độ link (Mbps) cho từng interface
            ifStats = psutil.net_if_stats()

            for iface, endVals in endCounters.items():
                startVals = startCounters.get(iface, {"rxBytesTotal": 0, "txBytesTotal": 0})
                rxDelta = endVals["rxBytesTotal"] - startVals["rxBytesTotal"]
                txDelta = endVals["txBytesTotal"] - startVals["txBytesTotal"]

                rxRate = rxDelta / actualDuration  # bytes/sec
                txRate = txDelta / actualDuration  # bytes/sec

                # Lấy link speed (Mbps); nếu không có thông tin, đặt về 0
                speedMbps = (
                    ifStats.get(iface).speed
                    if (iface in ifStats and ifStats.get(iface).speed is not None)
                    else 0
                )

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
                    "rxRateBps": int(rxRate * 8),   # chuyển từ bytes/sec sang bits/sec
                    "txRateBps": int(txRate * 8),   # chuyển từ bytes/sec sang bits/sec
                    "utilizationPercent": round(utilization, 2)
                })

            # --- BƯỚC 5: Lấy system metrics không block lâu ---
            systemMetrics = getSystemMetricsNonblocking()

            # --- BƯỚC 6: Đóng gói payload JSON theo định dạng camelCase ---
            payload = {
                "messageType": "realtimeSnapshot",
                "serverId": SERVER_ID,
                "snapshotTime": datetime.now(timezone.utc).isoformat(),
                "metrics": systemMetrics,
                "network": {
                    "collectionStartTime": startTs,
                    "collectionEndTime": endTs,
                    "collectionDurationSeconds": int(actualDuration),
                    "interfaces": interfacesData
                }
            }

            # --- BƯỚC 7: In ra console để debug ---
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

            # --- BƯỚC 8: Gửi payload lên API nếu cần ---
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
