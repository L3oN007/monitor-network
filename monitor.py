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

def get_system_metrics_nonblocking():
    """
    Lấy CPU, RAM, Disk và Uptime mà không block lâu.
    cpu_percent(interval=None) sẽ trả ngay giá trị phần trăm CPU so với lần gọi trước.
    """
    cpu_pct = psutil.cpu_percent(interval=None)  # không block 1s
    vm = psutil.virtual_memory()
    du = psutil.disk_usage('/')
    return {
        "cpu": {
            "percent": cpu_pct
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

def get_all_interface_counters():
    """
    Đọc counters tích lũy (bytes sent/received) cho mỗi interface.
    Trả về dict: { iface_name: {"rx_bytes_total": <bytes>, "tx_bytes_total": <bytes>} }
    """
    pernic = psutil.net_io_counters(pernic=True)
    counters = {}
    for iface, stats in pernic.items():
        counters[iface] = {
            "rx_bytes_total": stats.bytes_recv,
            "tx_bytes_total": stats.bytes_sent
        }
    return counters

def main():
    # --- BƯỚC 0: Khởi động CPU counter để cpu_percent(interval=None) lần sau trả đúng giá trị ---
    psutil.cpu_percent(interval=None)

    print(f"Starting monitor-agent for server '{SERVER_ID}' (interval = {CYCLE_TIME}s)\n")

    while True:
        try:
            # --- BƯỚC 1: Ghi lại thời gian và counters mạng ban đầu ---
            start_dt = datetime.now(timezone.utc)
            start_ts = start_dt.isoformat()
            start_counters = get_all_interface_counters()

            # --- BƯỚC 2: Ngủ đúng CYCLE_TIME giây ---
            time.sleep(CYCLE_TIME)

            # --- BƯỚC 3: Ghi lại thời gian và counters mạng sau khi ngủ ---
            end_dt = datetime.now(timezone.utc)
            end_ts = end_dt.isoformat()
            end_counters = get_all_interface_counters()

            # Tính actual_duration (xấp xỉ CYCLE_TIME, có thể chênh vài ms)
            actual_duration = (end_dt - start_dt).total_seconds()
            if actual_duration <= 0:
                actual_duration = CYCLE_TIME  # đề phòng trường hợp hi hữu

            # --- BƯỚC 4: Tính rate và các thông số cho mỗi interface ---
            interfaces_data = []
            # Lấy tốc độ link (Mbps) cho từng interface
            if_stats = psutil.net_if_stats()

            for iface, end_vals in end_counters.items():
                start_vals = start_counters.get(iface, {"rx_bytes_total": 0, "tx_bytes_total": 0})
                rx_delta = end_vals["rx_bytes_total"] - start_vals["rx_bytes_total"]
                tx_delta = end_vals["tx_bytes_total"] - start_vals["tx_bytes_total"]

                rx_rate = rx_delta / actual_duration  # bytes/sec
                tx_rate = tx_delta / actual_duration  # bytes/sec

                # Lấy link speed (Mbps); nếu không có thông tin, đặt về 0
                speed_mbps = if_stats.get(iface).speed if (iface in if_stats and if_stats.get(iface).speed is not None) else 0

                # Tính utilization (%) = max(rx_rate, tx_rate) (bytes/sec) → bit/sec: *8, chia cho speed_mbps*1e6
                if speed_mbps and speed_mbps > 0:
                    utilization = (max(rx_rate, tx_rate) * 8) / (speed_mbps * 1_000_000) * 100
                else:
                    utilization = 0.0

                interfaces_data.append({
                    "interface": iface,
                    "link_speed_mbps": speed_mbps,
                    "rx_bytes_total": end_vals["rx_bytes_total"],
                    "tx_bytes_total": end_vals["tx_bytes_total"],
                    "rx_rate_bps": int(rx_rate * 8),   # chuyển từ bytes/sec sang bits/sec
                    "tx_rate_bps": int(tx_rate * 8),   # chuyển từ bytes/sec sang bits/sec
                    "utilization_percent": round(utilization, 2)
                })

            # --- BƯỚC 5: Lấy system metrics không block lâu ---
            system_metrics = get_system_metrics_nonblocking()

            # --- BƯỚC 6: Đóng gói payload JSON theo đúng định dạng mong muốn ---
            payload = {
                "messageType": "realtime_snapshot",
                "serverId": SERVER_ID,
                "snapshotTime": datetime.now(timezone.utc).isoformat(),
                "metrics": system_metrics,
                "network": {
                    "collectionStartTime": start_ts,
                    "collectionEndTime": end_ts,
                    "collectionDurationSeconds": int(actual_duration),
                    "interfaces": interfaces_data
                }
            }

            # --- BƯỚC 7: In ra console để debug ---
            print(f"[{payload['snapshotTime']}] System Metrics:")
            print(f"  CPU: {system_metrics['cpu']['percent']}%")
            print(f"  RAM: {system_metrics['memory']['usedBytes'] // (1024*1024)}MB/"
                  f"{system_metrics['memory']['totalBytes'] // (1024*1024)}MB "
                  f"({system_metrics['memory']['percentUsed']}%)")
            print(f"  Disk(/): {system_metrics['disk'][0]['usedBytes'] // (1024*1024)}MB/"
                  f"{system_metrics['disk'][0]['totalBytes'] // (1024*1024)}MB "
                  f"({system_metrics['disk'][0]['percentUsed']}%)")
            print(f"  Uptime: {system_metrics['uptimeSeconds'] // 3600}h "
                  f"{(system_metrics['uptimeSeconds'] % 3600) // 60}m")

            print(f"\nNetwork Collection Window: {start_ts} → {end_ts} "
                  f"(≈ {int(actual_duration)}s)")
            for iface_obj in interfaces_data:
                print(f"  - {iface_obj['interface']}: "
                      f"Link Speed={iface_obj['link_speed_mbps']}Mbps, "
                      f"RX_total={iface_obj['rx_bytes_total']}B, "
                      f"TX_total={iface_obj['tx_bytes_total']}B, "
                      f"RX_rate={iface_obj['rx_rate_bps']}bps, "
                      f"TX_rate={iface_obj['tx_rate_bps']}bps, "
                      f"Utilization={iface_obj['utilization_percent']}%")

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
