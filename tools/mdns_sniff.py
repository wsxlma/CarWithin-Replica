#!/usr/bin/env python3
"""极简 mDNS 查询器：抓 _airplay._tcp / _carplay._tcp 的 PTR/SRV/TXT/A 记录。

不依赖第三方库，直接拼 DNS 报文。用途：把原版 App 广播的 TXT 记录原样抄下来。
"""
import socket
import struct
import sys
import time
import threading

MDNS_ADDR = "224.0.0.251"
MDNS_PORT = 5353


def encode_name(name):
    out = b""
    for part in name.rstrip(".").split("."):
        if not part:
            continue
        out += bytes([len(part)]) + part.encode()
    return out + b"\x00"


def build_query(name, qtype=12):  # PTR
    header = struct.pack(">HHHHHH", 0, 0, 1, 0, 0, 0)
    return header + encode_name(name) + struct.pack(">HH", qtype, 1)


def read_name(data, off):
    labels = []
    jumped = False
    original = off
    guard = 0
    while off < len(data) and guard < 64:
        guard += 1
        length = data[off]
        if length == 0:
            off += 1
            break
        if length & 0xC0 == 0xC0:
            ptr = struct.unpack(">H", data[off:off + 2])[0] & 0x3FFF
            if not jumped:
                original = off + 2
                jumped = True
            off = ptr
            continue
        labels.append(data[off + 1:off + 1 + length].decode("utf-8", "replace"))
        off += 1 + length
    return ".".join(labels), (original if jumped else off)


def parse_txt(raw):
    items = []
    i = 0
    while i < len(raw):
        ln = raw[i]
        if ln == 0:
            i += 1
            break
        chunk = raw[i + 1:i + 1 + ln]
        items.append(chunk.decode("utf-8", "replace"))
        i += 1 + ln
    return items


def parse_packet(data):
    if len(data) < 12:
        return []
    _, flags, qd, an, ns, ar = struct.unpack(">HHHHHH", data[:12])
    off = 12
    for _ in range(qd):
        _, off = read_name(data, off)
        off += 4
    records = []
    for _ in range(an + ns + ar):
        if off >= len(data):
            break
        name, off = read_name(data, off)
        if off + 10 > len(data):
            break
        rtype, rclass, ttl, rdlen = struct.unpack(">HHIH", data[off:off + 10])
        off += 10
        rdata = data[off:off + rdlen]
        off += rdlen
        entry = {"name": name, "type": rtype, "ttl": ttl}
        try:
            if rtype == 12:      # PTR
                target, _ = read_name(data, off - rdlen)
                entry["ptr"] = target
            elif rtype == 33:    # SRV
                prio, weight, port = struct.unpack(">HHH", rdata[:6])
                target, _ = read_name(data, off - rdlen + 6)
                entry.update({"port": port, "target": target})
            elif rtype == 16:    # TXT
                entry["txt"] = parse_txt(rdata)
            elif rtype == 1:     # A
                entry["ip"] = socket.inet_ntoa(rdata)
        except Exception:
            pass
        records.append(entry)
    return records


def main():
    services = sys.argv[1:] or ["_airplay._tcp.local", "_carplay._tcp.local",
                                "_raop._tcp.local", "_tds-carkit._tcp.local"]
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
    except Exception:
        pass
    sock.bind(("", MDNS_PORT))
    mreq = struct.pack("=4sl", socket.inet_aton(MDNS_ADDR), socket.INADDR_ANY)
    sock.setsockopt(socket.IPPROTO_IP, socket.IP_ADD_MEMBERSHIP, mreq)
    sock.settimeout(1.0)

    stop = threading.Event()

    def ask():
        while not stop.is_set():
            for svc in services:
                try:
                    sock.sendto(build_query(svc), (MDNS_ADDR, MDNS_PORT))
                except Exception:
                    pass
            time.sleep(2)

    threading.Thread(target=ask, daemon=True).start()

    seen = {}
    deadline = time.time() + 25
    print(f"查询中（25 秒）：{', '.join(services)}", flush=True)
    while time.time() < deadline:
        try:
            data, addr = sock.recvfrom(9000)
        except socket.timeout:
            continue
        except Exception:
            break
        for rec in parse_packet(data):
            key = (rec["name"], rec["type"], rec.get("port"), tuple(rec.get("txt") or []))
            if key in seen:
                continue
            seen[key] = rec
            tag = {12: "PTR", 33: "SRV", 16: "TXT", 1: "A"}.get(rec["type"], str(rec["type"]))
            if rec["type"] == 16:
                print(f"\n[TXT] {rec['name']}  (来自 {addr[0]})", flush=True)
                for item in rec.get("txt", []):
                    print("      " + item, flush=True)
            elif rec["type"] == 33:
                print(f"[SRV] {rec['name']} -> {rec.get('target')}:{rec.get('port')}", flush=True)
            elif rec["type"] == 12:
                print(f"[PTR] {rec['name']} -> {rec.get('ptr')}", flush=True)
            elif rec["type"] == 1:
                print(f"  [A] {rec['name']} -> {rec.get('ip')}", flush=True)
    stop.set()


if __name__ == "__main__":
    main()
