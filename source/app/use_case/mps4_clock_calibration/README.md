<!--
SPDX-FileCopyrightText: Copyright 2026 Arm Limited and/or its affiliates
<open-source-office@arm.com>
SPDX-License-Identifier: Apache-2.0
-->

# MPS4 clock calibration example

This use case generates a measurable HIGH pulse on an MPS4 CMSDK GPIO and
prints the corresponding SysTick-derived CPU cycle count. It is intended for
the ARM MPS4 HPI-0376B / FI101 SSE-320 board with a Kingst logic analyzer.

The default output is `GPIO0_2`, corresponding to `SH0_IO2`. The MPS4
technical reference manual maps this signal to:

- HAT connector `J41 pin 3`
- Shield 0 digital connector `J32 pin 3`

If you are looking at HAT connector J41, `J41 pin 19` is the previous
`SH0_IO10` signal, which the FI101 BSP names `SH0_SPI_SS` and maps to
`GPIO0_10`. `J41 pin 2` is 5V, not `SH0_IO2`.

Connect the Kingst input to `SH0_IO2` and connect Kingst GND to a board GND.
The example configures the selected pin as a normal GPIO output. Do not use
the same signal simultaneously from another Shield, Pmod, or HAT device.

Build the standalone target with the MPS4 SSE-320 configuration:

```sh
cmake -S . -B build-mps4-clock \
  -DTARGET_PLATFORM=mps4 \
  -DTARGET_SUBSYSTEM=sse-320 \
  -DUSE_CASE_BUILD=mps4_clock_calibration \
  -DETHOS_U_NPU_ENABLED=OFF \
  -DMPS4_HDLCD_ENABLED=OFF \
  -DCMAKE_TOOLCHAIN_FILE=scripts/cmake/toolchains/bare-metal-armclang.cmake
cmake --build build-mps4-clock --target mlek_mps4_clock_calibration
```

After boot, press USER PB1 once to generate one 500 ms HIGH pulse. Each new
press generates another measurement, so the board does not need to be reset
between captures. The complete measurement fits inside a 1-second Kingst
capture. For each pulse, calculate:

```text
measured_clock_hz = software_cycles / kingst_measured_seconds
```

The printed `software_us` is derived from the configured core clock and is a
sanity check. The Kingst pulse width is the external reference for validating
the duration conversion. The GPIO, duration, and pulse count remain configurable
with the CMake options `mps4_clock_calibration_GPIO_PORT`,
`mps4_clock_calibration_GPIO_PIN`, `mps4_clock_calibration_DURATION_MS`, and
`mps4_clock_calibration_PULSE_COUNT`.
