#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright 2026 Arm Limited and/or its affiliates <open-source-office@arm.com>
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail

fvp_root=${FVP_ROOT:-/home/xx/FVP_Corstone_SSE-320}
fastmodels_root=${FASTMODELS_HOME:-/home/xx/FastModels_11.32_19}
fvp_runtime="$fvp_root/scripts/runtime.sh"
fvp_binary="$fvp_root/models/Linux64_GCC-9.3/FVP_Corstone_SSE-320"
gdb_server_plugin="$fastmodels_root/plugins/Linux64_GCC-9.3/GDBServer.so"
gdb_port=${FVP_GDB_PORT:-10000}
application=${1:-}
application_args=()
if [[ -n "$application" ]]; then
    if [[ ! -f "$application" ]]; then
        echo "Application not found: $application" >&2
        exit 2
    fi
    application_args=(-a "$application")
fi
for required_file in "$fvp_runtime" "$fvp_binary" "$gdb_server_plugin"; do
    if [[ ! -e "$required_file" ]]; then
        echo "Required Fast Models file not found: $required_file" >&2
        exit 1
    fi
done

# The FVP runtime script supplies its bundled Python and C++ runtime libraries.
# shellcheck source=/dev/null
export LD_LIBRARY_PATH="$fvp_root/fmtplib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
source "$fvp_runtime"

echo "Starting Corstone SSE-320 FVP for GDB"
if [[ -n "$application" ]]; then
    echo "  Application: $application"
else
    echo "  Application: loaded by GDB after connection"
fi
echo "  GDB port:    $gdb_port"

exec "$fvp_binary" \
    "${application_args[@]}" \
    --plugin "$gdb_server_plugin" \
    --allow-debug-plugin \
    -C "GDBServer.port=$gdb_port" \
    -C GDBServer.shutdown_on_disconnect=1 \
    -C mps4_board.subsystem.ethosu.num_macs=256 \
    -C mps4_board.telnetterminal0.start_telnet=0 \
    -C mps4_board.uart0.out_file=- \
    -C mps4_board.uart0.shutdown_on_eot=0 \
    -C mps4_board.visualisation.disable-visualisation=1 \
    -C vis_hdlcd.disable_visualisation=1
