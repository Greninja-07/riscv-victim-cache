#!/usr/bin/env python3
"""
live_bridge.py - Real-Time FPGA Telemetry Bridge to Interactive Web Dashboard
Group 14: RISC-V Memory Hierarchy Evaluation

Description:
  Reads 28-byte binary telemetry frames from the Nexys A7 USB-UART port (115200 baud)
  and pushes structured JSON telemetry frames over a local WebSocket server (ws://localhost:8765)
  to the interactive web dashboard.

Frame Format (28 bytes):
  [0]:      0xAA (Sync Header 1)
  [1]:      0x55 (Sync Header 2)
  [2..5]:   total_cycles  [31:0]
  [6..9]:   stall_cycles  [31:0]
  [10..13]: l1_accesses   [31:0]
  [14..17]: l1_misses     [31:0]
  [18..21]: victim_hits   [31:0]
  [22..25]: prefetch_hits [31:0]
  [26..27]: sw            [15:0]

Usage:
  python scripts/live_bridge.py [--port COM6] [--baud 115200]
"""

import sys
import time
import struct
import argparse
import asyncio
import threading
import json
import os

try:
    import serial
    import serial.tools.list_ports
except ImportError:
    print("[ERROR] pyserial is not installed. Please run: pip install pyserial")
    sys.exit(1)

try:
    import websockets
except ImportError:
    print("[ERROR] websockets is not installed. Please run: pip install websockets")
    sys.exit(1)

CONNECTED_CLIENTS = set()
TELEMETRY_QUEUE = None
ASYNC_LOOP = None

def get_active_workload():
    """Detect workload staged by load_workload.bat or active in BRAM."""
    try:
        active_path = os.path.join(os.path.dirname(__file__), "..", "dashboard", "active_workload.json")
        if os.path.exists(active_path):
            with open(active_path, "r") as f:
                data = json.load(f)
                return data.get("workload", "conflict_thrash")
    except Exception:
        pass
    return "conflict_thrash"

def find_default_com_port():
    """Auto-detect FTDI / Digilent Nexys A7 USB serial port."""
    ports = list(serial.tools.list_ports.comports())
    for p in ports:
        desc = p.description.lower()
        hwid = p.hwid.lower()
        if "0403:6010" in hwid or "usb serial" in desc or "ftdi" in desc or "digilent" in desc:
            return p.device
    if ports:
        return ports[0].device
    return "COM6"

async def register_client(websocket):
    CONNECTED_CLIENTS.add(websocket)
    print(f"[*] Dashboard client connected: {websocket.remote_address}")
    try:
        # Send initial handshake with active workload name
        init_frame = {
            "type": "init",
            "workload": get_active_workload()
        }
        await websocket.send(json.dumps(init_frame))
        await websocket.wait_closed()
    finally:
        CONNECTED_CLIENTS.remove(websocket)
        print(f"[-] Dashboard client disconnected: {websocket.remote_address}")

def parse_telemetry_packet(raw_bytes):
    """Unpack 28-byte frame into Python dictionary."""
    if len(raw_bytes) != 28:
        return None
    if raw_bytes[0] != 0xAA or raw_bytes[1] != 0x55:
        return None

    total_cycles, stall_cycles, l1_accesses, l1_misses, victim_hits, prefetch_hits, sw = struct.unpack(">IIIIIIH", raw_bytes[2:28])

    # Decode switch states
    lat_code = sw & 0x03
    lat_map = {0: 1, 1: 10, 2: 100, 3: 200}
    latency = lat_map.get(lat_code, 100)

    cache_bypass = bool((sw >> 2) & 0x01)
    vc_en        = bool((sw >> 7) & 0x01)
    prefetch_en  = bool((sw >> 8) & 0x01)

    return {
        "timestamp": time.time(),
        "workload": get_active_workload(),
        "total_cycles": total_cycles,
        "stall_cycles": stall_cycles,
        "l1_accesses": l1_accesses,
        "l1_misses": l1_misses,
        "victim_hits": victim_hits,
        "prefetch_hits": prefetch_hits,
        "raw_sw": sw,
        "switches": {
            "cache_bypass": cache_bypass,
            "vc_en": vc_en,
            "prefetch_en": prefetch_en,
            "latency": latency
        }
    }

def serial_worker_thread(port_name, baud_rate, stop_event):
    """Dedicated background thread for reading serial data without stalling asyncio."""
    print(f"[*] Serial worker thread started for {port_name} @ {baud_rate} baud...")
    while not stop_event.is_set():
        try:
            with serial.Serial(port_name, baud_rate, timeout=0.1, rtscts=False, dsrdtr=False) as ser:
                print(f"[+] Successfully opened {port_name}! Listening for telemetry frames...")
                buf = bytearray()
                last_notice = time.time()
                frames_received = 0

                while not stop_event.is_set():
                    available = ser.in_waiting
                    chunk = ser.read(available if available > 0 else 1)
                    if chunk:
                        buf.extend(chunk)

                        # Align to sync headers 0xAA 0x55
                        while len(buf) >= 28:
                            if buf[0] == 0xAA and buf[1] == 0x55:
                                packet_bytes = bytes(buf[:28])
                                data = parse_telemetry_packet(packet_bytes)
                                if data:
                                    frames_received += 1
                                    if ASYNC_LOOP and TELEMETRY_QUEUE:
                                        ASYNC_LOOP.call_soon_threadsafe(TELEMETRY_QUEUE.put_nowait, data)
                                del buf[:28]
                            else:
                                if 0xAA in buf:
                                    idx = buf.index(0xAA)
                                    del buf[:idx]
                                else:
                                    buf.clear()
                    else:
                        time.sleep(0.005)

                    if frames_received == 0 and time.time() - last_notice > 5.0:
                        print(f"[*] Listening on {port_name}... (No frames yet. Ensure Nexys A7 is programmed with UART bitstream)")
                        last_notice = time.time()

        except serial.SerialException as e:
            print(f"[!] Serial connection notice ({port_name}): {e}. Retrying in 2s...")
            time.sleep(2.0)
        except Exception as e:
            print(f"[!] Serial worker exception: {e}. Retrying in 2s...")
            time.sleep(2.0)

async def queue_broadcast_task():
    """Reads packets from thread-safe queue and broadcasts to WebSocket clients."""
    global TELEMETRY_QUEUE
    while True:
        data = await TELEMETRY_QUEUE.get()
        if CONNECTED_CLIENTS:
            msg = json.dumps(data)
            await asyncio.gather(*[c.send(msg) for c in CONNECTED_CLIENTS], return_exceptions=True)

        c = data["total_cycles"]
        s = data["stall_cycles"]
        sw = data["switches"]
        wl = data.get("workload", "unknown")
        print(f"\r[TELEMETRY] [{wl}] Cyc: {c:8,d} | Stalls: {s:8,d} | Cache: {'BYP' if sw['cache_bypass'] else 'ON '} | VC: {'ON ' if sw['vc_en'] else 'OFF'} | PF: {'ON ' if sw['prefetch_en'] else 'OFF'} | Lat: {sw['latency']:3d}", end="", flush=True)

async def main():
    global ASYNC_LOOP, TELEMETRY_QUEUE
    parser = argparse.ArgumentParser(description="Nexys A7 FPGA Telemetry WebSocket Bridge")
    parser.add_argument("--port", default=find_default_com_port(), help="Serial COM port (default: auto-detected)")
    parser.add_argument("--baud", type=int, default=115200, help="Baud rate (default: 115200)")
    parser.add_argument("--ws-port", type=int, default=8765, help="WebSocket port (default: 8765)")
    args = parser.parse_args()

    print("=" * 80)
    print("  NEXYS A7 FPGA TELEMETRY BRIDGE FOR REAL-TIME WEB DASHBOARD")
    print(f"  Target Serial Port : {args.port} @ {args.baud} baud")
    print(f"  WebSocket Server   : ws://localhost:{args.ws_port}")
    print(f"  Staged Workload    : {get_active_workload()}")
    print("=" * 80)

    ASYNC_LOOP = asyncio.get_running_loop()
    TELEMETRY_QUEUE = asyncio.Queue()

    stop_event = threading.Event()
    worker = threading.Thread(target=serial_worker_thread, args=(args.port, args.baud, stop_event), daemon=True)
    worker.start()

    server = await websockets.serve(register_client, "localhost", args.ws_port)
    print(f"[+] WebSocket server active on ws://localhost:{args.ws_port}")

    try:
        await queue_broadcast_task()
    finally:
        stop_event.set()
        server.close()
        await server.wait_closed()

if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        print("\n[*] Exiting telemetry bridge cleanly.")
