/*
 * SPDX-FileCopyrightText: Copyright 2026 Arm Limited and/or its
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
#include "hal.h"
#include "mps4_gpio.h"
#include "timer_mps4.h"
#include "mlek/log/log_macros.h"

#include <cinttypes>
#include <cstdint>

#ifndef MPS4_CALIBRATION_DURATION_MS
#define MPS4_CALIBRATION_DURATION_MS 500U
#endif

#ifndef MPS4_CALIBRATION_PULSE_COUNT
#define MPS4_CALIBRATION_PULSE_COUNT 1U
#endif

#ifndef MPS4_CALIBRATION_GAP_MS
#define MPS4_CALIBRATION_GAP_MS 100U
#endif

#ifndef MPS4_CALIBRATION_GPIO_PORT
#define MPS4_CALIBRATION_GPIO_PORT 0U
#endif

#ifndef MPS4_CALIBRATION_GPIO_PIN
#define MPS4_CALIBRATION_GPIO_PIN 2U
#endif

namespace {

static uint64_t WaitForCycles(uint64_t cycles)
{
    const uint64_t start = get_mps4_systick_cycle_count();
    while ((get_mps4_systick_cycle_count() - start) < cycles) {
        __NOP();
    }
    return get_mps4_systick_cycle_count() - start;
}

static uint64_t MillisecondsToCycles(uint32_t milliseconds, uint32_t clockHz)
{
    return (static_cast<uint64_t>(milliseconds) * clockHz) / 1000U;
}

static uint64_t CyclesToMicroseconds(uint64_t cycles, uint32_t clockHz)
{
    return (cycles * 1000000ULL + (clockHz / 2U)) / clockHz;
}

} /* namespace */

void MainLoop()
{
    /* This standalone use case does not create the normal Profiler object. */
    hal_pmu_init();

    const uint32_t coreClockHz = get_mps4_core_clock();
    const uint32_t durationMs = static_cast<uint32_t>(MPS4_CALIBRATION_DURATION_MS);
    const uint32_t pulseCount = static_cast<uint32_t>(MPS4_CALIBRATION_PULSE_COUNT);
    const uint32_t gapMs = static_cast<uint32_t>(MPS4_CALIBRATION_GAP_MS);
    const uint32_t gpioPort = static_cast<uint32_t>(MPS4_CALIBRATION_GPIO_PORT);
    const uint32_t gpioPin = static_cast<uint32_t>(MPS4_CALIBRATION_GPIO_PIN);
    const uint64_t pulseCycles = MillisecondsToCycles(durationMs, coreClockHz);
    const uint64_t gapCycles = MillisecondsToCycles(gapMs, coreClockHz);

    if (durationMs == 0U || pulseCount == 0U ||
        !mps4_gpio_init_output(gpioPort, gpioPin)) {
        printf_err("Invalid MPS4 clock calibration configuration\n");
        return;
    }

    mps4_gpio_write(gpioPort, gpioPin, false);

    constexpr uint32_t userPb1 = 0U;
    uint32_t measurementCount = 0U;
    bool previousButtonState = platform_button_is_pressed(userPb1);

    info("MPS4 clock calibration is ready.\n");
    info("Reported core clock: %" PRIu32 " Hz\n", coreClockHz);
    info("Output: GPIO%" PRIu32 "_%" PRIu32
         " (FI101 SH0_IO2 default)\n",
         gpioPort, gpioPin);
    info("Expected high pulse: %" PRIu32 " ms; pulses per trigger: %" PRIu32
         "; low gap: %" PRIu32 " ms\n",
         durationMs, pulseCount, gapMs);
    info("Press USER PB1 to start one calibration measurement.\n");
    info("Measure the GPIO high-pulse width with Kingst.\n");

    while (true) {
        const bool buttonState = platform_button_is_pressed(userPb1);
        if (buttonState && !previousButtonState) {
            ++measurementCount;
            info("USER PB1 pressed; starting measurement %" PRIu32 ".\n",
                 measurementCount);

            for (uint32_t pulse = 0U; pulse < pulseCount; ++pulse) {
                mps4_gpio_write(gpioPort, gpioPin, true);
                const uint64_t measuredCycles = WaitForCycles(pulseCycles);
                mps4_gpio_write(gpioPort, gpioPin, false);

                info("Measurement %" PRIu32 ", pulse %" PRIu32 "/%" PRIu32
                     ": cycles=%" PRIu64 ", software_us=%" PRIu64 "\n",
                     measurementCount, pulse + 1U, pulseCount, measuredCycles,
                     CyclesToMicroseconds(measuredCycles, coreClockHz));

                if (pulse + 1U < pulseCount) {
                    WaitForCycles(gapCycles);
                }
            }

            info("Measurement %" PRIu32 " complete; GPIO output is low.\n",
                 measurementCount);
        }

        previousButtonState = buttonState;
        __WFI();
    }
}
