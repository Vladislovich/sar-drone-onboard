#!/usr/bin/env bash
# run_onboard.sh - запуск бортового пайплайна на Orange Pi с USB-камерой.
#
#   USB-камера -> tee -+-> appsink: YOLO на NPU + ArUco -> находки на землю (TCP 5700)
#                      +-> H.264 -> живое видео по TCP (порт 5000)
#
# Видео отдаёт сам дрон (tcpserversink): ноутбук подключается к нему, когда
# хочет, и отключается без последствий. Обратное направление (дрон сам
# подключается к ноутбуку) не годится: если ноутбук не слушает, GStreamer
# остановит пайплайн целиком, а с ним и детекцию.
#
# Ветка видео сидит за протекающей очередью: если кодер или сеть не успевают,
# теряются кадры видео, а не кадры детекции.
#
#   ./run_onboard.sh                                   # /dev/video0, MJPEG 1280x720@30
#   CAMERA=/dev/v4l/by-id/usb-...-video-index0 ./run_onboard.sh
#   VIDEO_PORT=0 ./run_onboard.sh                      # без видео
#   ./run_onboard.sh --print                           # только показать пайплайн
#
# На ноутбуке смотреть видео:
#   gst-launch-1.0 tcpclientsrc host=<IP платы> port=5000 ! matroskademux \
#       ! avdec_h264 ! videoconvert ! autovideosink sync=false
set -euo pipefail
cd "$(dirname "$0")"

CAMERA=${CAMERA:-/dev/video0}
CAM_FORMAT=${CAM_FORMAT:-mjpeg}   # mjpeg (30 fps на большинстве камер) | yuyv (обычно 10 fps на 720p)
CAM_FPS=${CAM_FPS:-30}
VIDEO_PORT=${VIDEO_PORT:-5000}    # 0 = видео не отдавать
ENCODER=${ENCODER:-auto}          # auto | mpp (аппаратный кодер RK3566) | x264 (процессор)

have() { gst-inspect-1.0 "$1" >/dev/null 2>&1; }

# Размер кадра детектора - ровно тот, под который в main.cpp посчитана
# камера (FRAME_W/FRAME_H и угол обзора). Другой размер - другая геопривязка.
W=1280 H=720

if [[ $ENCODER == auto ]]; then
    if have mpph264enc && have h264parse; then ENCODER=mpp; else ENCODER=x264; fi
fi
# Аппаратный кодер почти не грузит процессор - можно отдавать полный кадр.
# x264 на ядрах A55 отнимает процессор у ArUco, поэтому кадр меньше и одна нить.
if [[ $ENCODER == mpp ]]; then
    STREAM_W=${STREAM_W:-1280} STREAM_H=${STREAM_H:-720} STREAM_FPS=${STREAM_FPS:-30} STREAM_KBPS=${STREAM_KBPS:-2500}
else
    STREAM_W=${STREAM_W:-640}  STREAM_H=${STREAM_H:-360} STREAM_FPS=${STREAM_FPS:-15} STREAM_KBPS=${STREAM_KBPS:-800}
fi

case $CAM_FORMAT in
    mjpeg) SRC="v4l2src device=$CAMERA ! image/jpeg,width=$W,height=$H,framerate=$CAM_FPS/1 ! jpegdec" ;;
    yuyv)  SRC="v4l2src device=$CAMERA ! video/x-raw,format=YUY2,width=$W,height=$H,framerate=$CAM_FPS/1" ;;
    *) echo "CAM_FORMAT: mjpeg или yuyv, а не '$CAM_FORMAT'" >&2; exit 1 ;;
esac
# GstCamera читает только NV12.
SRC="$SRC ! videoconvert ! video/x-raw,format=NV12"
DETECT="queue max-size-buffers=1 leaky=downstream ! appsink name=sink max-buffers=1 drop=true sync=false"

if [[ $VIDEO_PORT == 0 ]]; then
    PIPELINE="$SRC ! $DETECT"
else
    RATE=""
    (( STREAM_FPS < CAM_FPS )) && RATE="! videorate drop-only=true ! video/x-raw,framerate=$STREAM_FPS/1 "
    if [[ $ENCODER == mpp ]]; then
        ENC="mpph264enc bps=$((STREAM_KBPS * 1000)) gop=$STREAM_FPS ! h264parse"
    else
        ENC="x264enc tune=zerolatency speed-preset=ultrafast bitrate=$STREAM_KBPS key-int-max=$STREAM_FPS threads=1"
    fi
    # sync-method=latest-keyframe: подключившийся ноутбук получает поток с
    # последнего ключевого кадра, а не серую кашу до следующего.
    VIDEO="queue max-size-buffers=2 leaky=downstream ! videoscale ! video/x-raw,width=$STREAM_W,height=$STREAM_H $RATE! $ENC ! video/x-h264,stream-format=avc,alignment=au ! matroskamux streamable=true ! tcpserversink host=0.0.0.0 port=$VIDEO_PORT sync=false sync-method=latest-keyframe"
    PIPELINE="$SRC ! tee name=t  t. ! $DETECT  t. ! $VIDEO"
fi

if [[ ${1:-} == --print ]]; then echo "$PIPELINE"; exit 0; fi

# ---------------------------------------------------------------- проверки

fail=0
for e in v4l2src videoconvert tee appsink jpegdec; do
    have "$e" || { echo "нет элемента GStreamer: $e" >&2; fail=1; }
done
if [[ $VIDEO_PORT != 0 ]]; then
    for e in videoscale videorate matroskamux tcpserversink; do
        have "$e" || { echo "нет элемента GStreamer: $e" >&2; fail=1; }
    done
    [[ $ENCODER == x264 ]] && ! have x264enc && { echo "нет x264enc" >&2; fail=1; }
fi
if (( fail )); then
    echo "поставить: sudo apt install gstreamer1.0-tools gstreamer1.0-plugins-base \\" >&2
    echo "    gstreamer1.0-plugins-good gstreamer1.0-plugins-bad gstreamer1.0-plugins-ugly" >&2
    exit 1
fi
[[ -e $CAMERA ]] || { echo "нет камеры $CAMERA; список: ls -l /dev/v4l/by-id/" >&2; exit 1; }
[[ -f best_i8_split.rknn ]] || { echo "нет best_i8_split.rknn в $(pwd)" >&2; exit 1; }

if [[ ! -x build/sar_yolo_pipeline ]]; then
    echo "=== сборка ==="
    cmake -B build -DCMAKE_BUILD_TYPE=Release
    cmake --build build -j4
fi

GROUND=$(grep -oP 'GROUND_STATION_IP\s*=\s*"\K[^"]+' src/main.cpp || echo "?")
MY_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
echo "камера:   $CAMERA ($CAM_FORMAT ${W}x${H}@${CAM_FPS})"
echo "находки:  на $GROUND:5700 (GROUND_STATION_IP в src/main.cpp, после правки - пересобрать)"
if [[ $VIDEO_PORT != 0 ]]; then
    echo "видео:    $ENCODER, ${STREAM_W}x${STREAM_H}@${STREAM_FPS}, ${STREAM_KBPS} кбит/с, порт $VIDEO_PORT"
    echo "          на ноутбуке: gst-launch-1.0 tcpclientsrc host=${MY_IP:-<IP платы>} port=$VIDEO_PORT" \
         "! matroskademux ! avdec_h264 ! videoconvert ! autovideosink sync=false"
fi
echo

# Запуск из корня репозитория: MODEL_PATH, queue/ и finds/ в main.cpp -
# относительные пути.
export LD_LIBRARY_PATH="$PWD/third_party/rknpu2/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
exec ./build/sar_yolo_pipeline "$PIPELINE"
