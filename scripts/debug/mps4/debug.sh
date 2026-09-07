#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright 2026 Arm Limited and/or its affiliates <open-source-office@arm.com>
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
mode=${1:-help}
if [[ $# -gt 0 ]]; then shift; fi
case "$mode" in
    server)
        pyocd_bin=${MPS4_PYOCD:-$HOME/.venvs/mps4-debug/bin/pyocd}
        if [[ ! -x "$pyocd_bin" ]]; then
            echo "pyOCD not found: $pyocd_bin" >&2
            exit 1
        fi
        # Escalate only the USB server; GDB stays under the normal user.
        runner=()
        if [[ ${MPS4_NO_SUDO:-0} != 1 && $EUID -ne 0 ]]; then runner=(sudo); fi
        exec "${runner[@]}" "$pyocd_bin" gdbserver --no-config \
            --script "$script_dir/pyocd_fi101.py" --target cortex_m \
            --frequency 1000000 --port 3333 --persist \
            -O connect_mode=attach -O dap_protocol=swd \
            -O dap_swj_use_dormant=true -O auto_unlock=false "$@"
        ;;
    gdb)
        gdb_bin=${MPS4_GDB:-arm-none-eabi-gdb}
        gdb_compat_lib=${MPS4_GDB_COMPAT_LIB:-$HOME/.local/share/arm-gdb-compat/lib/x86_64-linux-gnu}
        gdb_env=()
        if [[ -f "$gdb_compat_lib/libncursesw.so.5" && -f "$gdb_compat_lib/libtinfo.so.5" ]]; then
            gdb_env=(env "LD_LIBRARY_PATH=$gdb_compat_lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}")
        fi
        if [[ $# -gt 1 ]]; then echo "Usage: $0 gdb [matching.elf|matching.axf]" >&2; exit 2; fi
        image_args=()
        if [[ $# -eq 1 ]]; then
            if [[ ! -f "$1" ]]; then echo "ELF/AXF not found: $1" >&2; exit 1; fi
            image_args=("$1")
        fi
        exec "${gdb_env[@]}" "$gdb_bin" -q "${image_args[@]}" \
            -ex 'target extended-remote localhost:3333'
        ;;
    help|--help|-h)
        echo "Usage: $0 server [-vv] | gdb [matching.elf|matching.axf]"
        echo "Start server in terminal 1, then gdb in terminal 2. No image is downloaded."
        echo "After USB permissions are configured: MPS4_NO_SUDO=1 $0 server"
        ;;
    *) echo "Unknown mode: $mode" >&2; exit 2 ;;
esac
