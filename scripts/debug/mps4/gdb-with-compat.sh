#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright 2026 Arm Limited and/or its affiliates <open-source-office@arm.com>
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail

gdb_bin=${MPS4_GDB_REAL:-/usr/local/bin/arm-gnu-toolchain-13.3.rel1-x86_64-arm-none-eabi/bin/arm-none-eabi-gdb}
compat_lib=${MPS4_GDB_COMPAT_LIB:-$HOME/.local/share/arm-gdb-compat/lib/x86_64-linux-gnu}

if [[ ! -x "$gdb_bin" ]]; then
    echo "GDB not found or not executable: $gdb_bin" >&2
    exit 1
fi

if [[ -f "$compat_lib/libncursesw.so.5" && -f "$compat_lib/libtinfo.so.5" ]]; then
    exec env "LD_LIBRARY_PATH=$compat_lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" "$gdb_bin" "$@"
fi

echo "GDB compatibility libraries not found: $compat_lib" >&2
echo "Expected libncursesw.so.5 and libtinfo.so.5" >&2
exit 1
