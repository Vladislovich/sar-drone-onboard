#!/usr/bin/env python3
"""
fake_drone.py - имитация борта: проверка наземной станции без платы.

Шлёт находки по тому же протоколу, что ReliableLink.hpp: сначала метка JSON,
потом кадр JPEG, и на каждую запись ждёт подтверждение (ACK) от земли.

    python3 fake_drone.py                                  # 3 находки на 127.0.0.1:5700
    python3 fake_drone.py --count 10 --interval 2
    python3 fake_drone.py --image find.jpg --json find.json   # свои файлы
    python3 fake_drone.py --host 192.168.1.100             # станция на другом ноутбуке
"""
import argparse
import io
import json
import random
import socket
import struct
import time
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont

MAGIC = b"SARL"
ACK_MAGIC = b"SARA"
REC_FRAME, REC_META = 1, 3

# Точка из MSP_BETAFLIGHT.md - вокруг неё разбрасываются находки.
BASE_LAT, BASE_LON = 59.938601, 30.314102
CLASS_ID = {"person": 0, "smoke": 2, "aruco": -1}


def record(typ, seq, event_id, payload):
    return MAGIC + bytes([1, typ]) + struct.pack("<III", seq, event_id, len(payload)) + payload


def recv_exactly(sock, n):
    buf = b""
    while len(buf) < n:
        part = sock.recv(n - len(buf))
        if not part:
            raise ConnectionError("земля закрыла соединение")
        buf += part
    return buf


def send(sock, typ, seq, event_id, payload):
    sock.sendall(record(typ, seq, event_id, payload))
    ack = recv_exactly(sock, 8)
    if ack != ACK_MAGIC + struct.pack("<I", seq):
        raise ConnectionError(f"неверный ACK: {ack!r}")


def fake_meta(event_id):
    kind = random.choice(["person", "person", "smoke", "aruco"])
    meta = {
        "event_id": event_id,
        "kind": kind,
        "class_id": CLASS_ID[kind],
        "aruco_id": random.randint(0, 49) if kind == "aruco" else -1,
        "timestamp_us": int(time.time() * 1e6),
        "confidence": 1.0 if kind == "aruco" else round(random.uniform(0.4, 0.95), 2),
        "geo_valid": random.random() > 0.15,      # иногда - без координат, как на борту
        "fix_type": 3,
        "sats": random.randint(7, 14),
    }
    if meta["geo_valid"]:
        meta["lat"] = round(BASE_LAT + random.uniform(-0.002, 0.002), 9)
        meta["lon"] = round(BASE_LON + random.uniform(-0.004, 0.004), 9)
    else:
        meta["fix_type"], meta["sats"] = 0, random.randint(0, 5)
    return meta


def fake_frame(meta, w=800, h=450):
    """Картинка как с борта: фон, цель, зелёный контур и подпись латиницей."""
    noise = Image.effect_noise((w, h), 48)
    img = Image.merge("RGB", (noise.point(lambda v: v * 0.45 + 20),
                              noise.point(lambda v: v * 0.55 + 50),
                              noise.point(lambda v: v * 0.30 + 15)))
    img = img.filter(ImageFilter.GaussianBlur(2))   # чистый шум жмётся плохо, кадр раздует
    d = ImageDraw.Draw(img)
    x, y = random.randint(80, w - 160), random.randint(80, h - 140)
    kind = meta.get("kind", "person")
    if kind == "aruco":
        s = 60
        d.rectangle([x, y, x + s, y + s], fill="black")
        d.rectangle([x + 12, y + 12, x + 30, y + 30], fill="white")
        d.rectangle([x + 34, y + 34, x + 48, y + 48], fill="white")
        box = [x, y, x + s, y + s]
        label = f"aruco {meta.get('aruco_id', 0)}"
    elif kind == "smoke":
        for _ in range(25):
            cx, cy, r = x + random.randint(0, 70), y + random.randint(0, 50), random.randint(12, 30)
            d.ellipse([cx - r, cy - r, cx + r, cy + r], fill=(200, 200, 200))
        box = [x - 25, y - 25, x + 100, y + 80]
        label = f"smoke {meta.get('confidence', 0):.2f}"
    else:
        d.ellipse([x + 8, y, x + 22, y + 14], fill=(230, 190, 160))
        d.rectangle([x + 4, y + 14, x + 26, y + 50], fill=(200, 40, 40))
        box = [x - 6, y - 6, x + 36, y + 56]
        label = f"person {meta.get('confidence', 0):.2f}"
    d.rectangle(box, outline=(0, 255, 0), width=2)
    try:
        font = ImageFont.load_default(size=16)
    except TypeError:                        # Pillow < 10.1
        font = ImageFont.load_default()
    tb = d.textbbox((box[0] + 3, box[1] - 22), label, font=font)
    d.rectangle([tb[0] - 3, tb[1] - 3, tb[2] + 3, tb[3] + 3], fill="black")
    d.text((box[0] + 3, box[1] - 22), label, fill=(0, 255, 0), font=font)

    buf = io.BytesIO()
    img.save(buf, format="JPEG", quality=65)
    return buf.getvalue()


def main():
    ap = argparse.ArgumentParser(description="Имитация борта для проверки наземной станции")
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=5700)
    ap.add_argument("--count", type=int, default=3, help="сколько находок отправить")
    ap.add_argument("--interval", type=float, default=1.5, help="пауза между находками, с")
    ap.add_argument("--start-id", type=int, default=1,
                    help="номер первой находки; на борту он с 1 при каждом запуске")
    ap.add_argument("--image", help="свой кадр (JPEG) вместо нарисованного")
    ap.add_argument("--json", help="своя JSON-метка вместо придуманной")
    a = ap.parse_args()

    user_meta = json.loads(Path(a.json).read_text(encoding="utf-8")) if a.json else None
    user_image = Path(a.image).read_bytes() if a.image else None

    sock = socket.create_connection((a.host, a.port), timeout=20)
    print(f"подключился к {a.host}:{a.port}")
    seq = 1
    for i in range(a.count):
        eid = a.start_id + i
        if user_meta is not None:
            meta = dict(user_meta, event_id=eid)
            meta.setdefault("timestamp_us", int(time.time() * 1e6))
        else:
            meta = fake_meta(eid)
        frame = user_image or fake_frame(meta)

        send(sock, REC_META, seq, eid, json.dumps(meta).encode("utf-8")); seq += 1
        send(sock, REC_FRAME, seq, eid, frame); seq += 1
        where = f"{meta['lat']:.6f} {meta['lon']:.6f}" if meta.get("geo_valid") else "без координат"
        print(f"находка {eid}: {meta.get('kind')}, {where}, кадр {len(frame)} байт - подтверждено")
        if i + 1 < a.count:
            time.sleep(a.interval)
    sock.close()


if __name__ == "__main__":
    main()
