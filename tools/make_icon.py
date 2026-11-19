"""AppIcon（1024x1024、アルファなし）を標準ライブラリのみで生成する。字幕バーを模した単純な意匠。"""
import struct, sys, zlib

W = H = 1024

def rrect(x, y, x0, y0, x1, y1, r):
    if not (x0 <= x < x1 and y0 <= y < y1):
        return False
    cx = min(max(x, x0 + r), x1 - r)
    cy = min(max(y, y0 + r), y1 - r)
    return (x - cx) ** 2 + (y - cy) ** 2 <= r * r

bars = [(192, 600, 832, 700, 50), (292, 740, 732, 840, 50)]
rows = []
for y in range(H):
    t = y / (H - 1)
    bg = (int(24 + 36 * t), int(38 + 72 * t), int(78 + 90 * t))
    row = bytearray([0])  # フィルタなし
    for x in range(W):
        px = bg
        # PiP の小窓を模した枠（右上）
        if rrect(x, y, 560, 150, 860, 330, 36) and not rrect(x, y, 580, 170, 840, 310, 24):
            px = (235, 242, 255)
        for (x0, y0, x1, y1, r) in bars:
            if rrect(x, y, x0, y0, x1, y1, r):
                px = (255, 255, 255)
        row += bytes(px)
    rows.append(bytes(row))

def chunk(tag, data):
    c = struct.pack(">I", len(data)) + tag + data
    return c + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)

png = b"\x89PNG\r\n\x1a\n"
png += chunk(b"IHDR", struct.pack(">IIBBBBB", W, H, 8, 2, 0, 0, 0))  # 8bit RGB（アルファなし）
png += chunk(b"IDAT", zlib.compress(b"".join(rows), 9))
png += chunk(b"IEND", b"")
open(sys.argv[1], "wb").write(png)
