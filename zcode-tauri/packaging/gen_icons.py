import os
import struct
import zlib


def gen(n):
    rows = []
    s = n / 128.0
    for y in range(n):
        row = bytearray([0])
        Y = y / s
        for x in range(n):
            X = x / s
            t = (X + Y) / 254.0
            r = int(109 * (1 - t) + 34 * t)
            g = int(94 * (1 - t) + 184 * t)
            b = int(252 * (1 - t) + 207 * t)
            inside = (32 <= Y < 46 and 30 <= X < 98) or (82 <= Y < 96 and 30 <= X < 98)
            if 46 <= Y < 82:
                cx = 98 - (Y - 46) * (68.0 / 36.0)
                inside = inside or abs(X - cx) < 9
            if inside:
                r = g = b = 255
            row += bytes([r, g, b, 255])
        rows.append(bytes(row))
    raw = b"".join(rows)

    def chunk(t, d):
        return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xFFFFFFFF)

    return (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", n, n, 8, 6, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(raw, 9))
        + chunk(b"IEND", b"")
    )


d = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "src-tauri", "icons")
os.makedirs(d, exist_ok=True)
for name, n in [("icon.png", 128), ("32x32.png", 32), ("128x128.png", 128), ("128x128@2x.png", 256)]:
    with open(os.path.join(d, name), "wb") as f:
        f.write(gen(n))
print(os.listdir(d))
