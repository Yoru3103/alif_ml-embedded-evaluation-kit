#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright 2026 Arm Limited and/or its affiliates
# <open-source-office@arm.com>
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

BUILD_DIR="${REPO_ROOT}/build-fvp320-asr"
RUN_NAME=asr_wav2letter

FVP_ROOT=/home/xx/FVP_Corstone_SSE-320
FVP_RUNTIME="${FVP_ROOT}/scripts/runtime.sh"
FVP_BINARY="${FVP_ROOT}/models/Linux64_GCC-9.3/FVP_Corstone_SSE-320"
APPLICATION="${BUILD_DIR}/bin/mlek_asr.axf"
LOG_FILE="${REPO_ROOT}/logs/${RUN_NAME}_fvp320.log"

# Headless mode (enabled by default).
BOARD_VISUALISATION_DISABLED=0
HDLCD_VISUALISATION_DISABLED=0
SHUTDOWN_ON_EOT=1

# GUI mode: comment the three values above and uncomment these values.
# BOARD_VISUALISATION_DISABLED=0
# HDLCD_VISUALISATION_DISABLED=0
# SHUTDOWN_ON_EOT=0

# Optional FVP diagnostics. Add pairs of "-C" and "component.option=value".
EXTRA_FVP_OPTIONS=(
    # "-C" "mps4_board.subsystem.ethosu.diagnostics=1"
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
    printf 'Run scripts/build_asr_fvp320.sh first.\n' >&2
    exit 1
fi

mkdir -p "${REPO_ROOT}/logs"

# The Arm FVP runtime script prepares the required shared libraries and paths.
# shellcheck source=/dev/null
source "${FVP_RUNTIME}"

printf 'Running Corstone-320 FVP\n'
printf '  Application: %s\n' "${APPLICATION}"
printf '  Log:         %s\n' "${LOG_FILE}"

"${FVP_BINARY}" \
    -a "${APPLICATION}" \
    -C mps4_board.subsystem.ethosu.num_macs=256 \
    -C mps4_board.telnetterminal0.start_telnet=0 \
    -C mps4_board.uart0.out_file=- \
    -C mps4_board.uart0.shutdown_on_eot="${SHUTDOWN_ON_EOT}" \
    -C mps4_board.visualisation.disable-visualisation="${BOARD_VISUALISATION_DISABLED}" \
    -C vis_hdlcd.disable_visualisation="${HDLCD_VISUALISATION_DISABLED}" \
    "${EXTRA_FVP_OPTIONS[@]}" \
    --stat \
    2>&1 | tee "${LOG_FILE}"
