#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright 2026 Arm Limited and/or its affiliates
# <open-source-office@arm.com>
# SPDX-License-Identifier: Apache-2.0

# Simulate the MPS4 board build on FVP; this does not flash a physical board.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

# -----------------------------------------------------------------------------
# User configuration: select the build produced by the build script.
#   best_int8      - TensorFlow Lite Micro model, 256 MACs
#   best_int8_new  - TensorFlow Lite Micro model, 512 MACs
#   gesture_pte    - ExecuTorch PTE model, 1024 MACs
# -----------------------------------------------------------------------------
MODEL_VARIANT="${YOLOV8_MODEL_VARIANT:-best_int8}"
case "${MODEL_VARIANT}" in
best_int8)
    BUILD_DIR="${REPO_ROOT}/build-mps4-yolov8-best"
    RUN_NAME=yolov8_best
    NPU_MACS=256
    ML_FRAMEWORK=TensorFlowLiteMicro
    ;;
best_int8_new)
    BUILD_DIR="${REPO_ROOT}/build-mps4-yolov8-best-new"
    RUN_NAME=yolov8_best_new
    NPU_MACS=512
    ML_FRAMEWORK=TensorFlowLiteMicro
    ;;
gesture_pte)
    BUILD_DIR="${REPO_ROOT}/build-mps4-yolov8-gesture-pte"
    RUN_NAME=yolov8_gesture_pte
    NPU_MACS=1024
    ML_FRAMEWORK=ExecuTorch
    ;;
*)
    printf 'Unsupported YOLOv8 model variant: %s\n' "${MODEL_VARIANT}" >&2
    exit 1
    ;;
esac

BUILD_DIR="${YOLOV8_BUILD_DIR:-${BUILD_DIR}}"
NPU_MACS="${YOLOV8_NPU_MACS:-${NPU_MACS}}"

FVP_ROOT=/home/xx/FVP_Corstone_SSE-320
FVP_RUNTIME="${FVP_ROOT}/scripts/runtime.sh"
FVP_BINARY="${FVP_ROOT}/models/Linux64_GCC-9.3/FVP_Corstone_SSE-320"
APPLICATION="${BUILD_DIR}/bin/mlek_yolov8_detection.axf"
LOG_FILE="${REPO_ROOT}/logs/${RUN_NAME}_fvp320.log"

# Headless mode (enabled by default).
BOARD_VISUALISATION_DISABLED="${YOLOV8_BOARD_VISUALISATION_DISABLED:-0}"
HDLCD_VISUALISATION_DISABLED="${YOLOV8_HDLCD_VISUALISATION_DISABLED:-0}"
SHUTDOWN_ON_EOT="${YOLOV8_SHUTDOWN_ON_EOT:-1}"

# GUI mode: comment the three values above and uncomment these values.
# The board panel stays disabled while the independent HDLCD window is enabled.
# BOARD_VISUALISATION_DISABLED=1
# HDLCD_VISUALISATION_DISABLED=0
# SHUTDOWN_ON_EOT=0

# Optional FVP diagnostics. Add pairs of "-C" and "component.option=value".
EXTRA_FVP_OPTIONS=(
    # "-C" "mps4_board.pl370_hdlcd.diagnostics=1"
    # "-C" "vis_hdlcd.diagnostics=1"
    # "-C" "mps4_board.subsystem.ethosu.extra_args=--fast"
)

if [[ ! -f "${FVP_RUNTIME}" ]]; then
    printf 'FVP runtime script not found: %s\n' "${FVP_RUNTIME}" >&2
    exit 1
fi

if [[ ! -x "${FVP_BINARY}" ]]; then
    printf 'FVP executable not found: %s\n' "${FVP_BINARY}" >&2
    exit 1
fi

if [[ ! -f "${APPLICATION}" ]]; then
    printf 'Application not found: %s\n' "${APPLICATION}" >&2
    printf 'Run scripts/build_yolov8_mps4.sh first.\n' >&2
    exit 1
fi

mkdir -p "${REPO_ROOT}/logs"

# The Arm FVP runtime script prepares the required shared libraries and paths.
# shellcheck source=/dev/null
export LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-}"
set +e
source "${FVP_RUNTIME}"
set -e

printf 'Running Corstone-320 FVP\n'
printf '  Application: %s\n' "${APPLICATION}"
printf '  Framework:   %s\n' "${ML_FRAMEWORK}"
printf '  NPU MACs:    %s\n' "${NPU_MACS}"
printf '  Log:         %s\n' "${LOG_FILE}"

"${FVP_BINARY}" \
    -a "${APPLICATION}" \
    -C mps4_board.subsystem.ethosu.num_macs="${NPU_MACS}" \
    -C mps4_board.telnetterminal0.start_telnet=0 \
    -C mps4_board.uart0.out_file=- \
    -C mps4_board.uart0.shutdown_on_eot="${SHUTDOWN_ON_EOT}" \
    -C mps4_board.visualisation.disable-visualisation="${BOARD_VISUALISATION_DISABLED}" \
    -C vis_hdlcd.disable_visualisation="${HDLCD_VISUALISATION_DISABLED}" \
    "${EXTRA_FVP_OPTIONS[@]}"
    # --stat 2>&1 | tee "${LOG_FILE}"
