/*
 * SPDX-FileCopyrightText: Copyright 2021-2026 Arm Limited and/or its
 * affiliates <open-source-office@arm.com>
 * SPDX-License-Identifier: Apache-2.0
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

/****************************************************************************\
 *               Main application file for ARM NPU on MPS3 board             *
\****************************************************************************/

#include "hal.h"                    /* our hardware abstraction api */
#include "mlek/log/log_macros.h"

#include <cstdio>
#include <cstdint>
#include <new>
#include <exception>

extern void MainLoop();

/* FI101 on MPS4 only: set to 0 for builds that do not need board debug access. */
#define MPS4_FI101_DEBUG_ENABLED 1

#if MPS4_FI101_DEBUG_ENABLED
/* Run in Secure privileged state, as in the FI101 Selftest startup. */
static void EnableMps4Debug()
{
    /* Debug authentication enable register. */
    *reinterpret_cast<volatile std::uint32_t*>(0x5802125CUL) = 0xAAAAAAAAUL;
    /* LCM_DCU_FORCE_DISABLE: use the FI101 Selftest debug configuration. */
    *reinterpret_cast<volatile std::uint32_t*>(0x500A0100UL) = 0x00005555UL;
}
#endif

#if defined(__ARMCC_VERSION) && (__ARMCC_VERSION >= 6010050)
__ASM(" .global __ARM_use_no_argv\n");
#endif

/* Print application information. */
static void PrintApplicationIntro()
{
    info("%s\n", PRJ_DES_STR);
    info("Version %s Build date: " __DATE__ " @ " __TIME__ "\n", PRJ_VER_STR);
    info("Compiler: %s\n", PRJ_COMPILER);
    info("Copyright 2021-2026 Arm Limited and/or "
         "its affiliates <open-source-office@arm.com>\n\n");
}

static void out_of_heap()
{
    warn("Out of heap\n");
    std::terminate();
}

int main ()
{
#if MPS4_FI101_DEBUG_ENABLED
    EnableMps4Debug();
#endif

    if (hal_platform_init()) {
        /* Application information, UART should have been initialised. */
        PrintApplicationIntro();

        std::set_new_handler(out_of_heap);

        /* Run the application. */
        MainLoop();
    }

    /* This is unreachable without errors. */
    info("program terminating...\n");

    /* Release platform. */
    hal_platform_release();
    return 0;
}
