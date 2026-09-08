#----------------------------------------------------------------------------
#  SPDX-FileCopyrightText: Copyright 2026 Arm Limited and/or its
#  affiliates <open-source-office@arm.com>
#  SPDX-License-Identifier: Apache-2.0
#
#  Licensed under the Apache License, Version 2.0 (the "License");
#  you may not use this file except in compliance with the License.
#  You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
#  Unless required by applicable law or agreed to in writing, software
#  distributed under the License is distributed on an "AS IS" BASIS,
#  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#  See the License for the specific language governing permissions and
#  limitations under the License.
#----------------------------------------------------------------------------

if (NOT TARGET_PLATFORM STREQUAL mps4)
    set(${use_case}_supports_${ML_FRAMEWORK} OFF)
    return()
endif()

# This use case does not depend on an ML framework or a model. The application
# target still requires the framework selector to be declared by the common
# use-case build logic.
set(${use_case}_ML_FRAMEWORK "TensorFlowLiteMicro;ExecuTorch")
set(${use_case}_supports_${ML_FRAMEWORK} ON)
set(${use_case}_MODEL_IN_EXT_FLASH OFF)
set(${use_case}_ACTIVATION_BUF_SZ 0)
set(${use_case}_LINK_LIBS mlek_log ml_framework_iface)

USER_OPTION(${use_case}_DURATION_MS
    "High pulse width used for one clock calibration measurement."
    500
    STRING)

USER_OPTION(${use_case}_PULSE_COUNT
    "Number of calibration pulses to generate."
    1
    STRING)

USER_OPTION(${use_case}_GAP_MS
    "Low gap between calibration pulses."
    100
    STRING)

USER_OPTION(${use_case}_GPIO_PORT
    "MPS4 GPIO port used for the calibration output."
    0
    STRING)

USER_OPTION(${use_case}_GPIO_PIN
    "MPS4 GPIO pin used for the calibration output."
    2
    STRING)

set(${use_case}_COMPILE_DEFS
    "MPS4_CALIBRATION_DURATION_MS=${${use_case}_DURATION_MS}"
    "MPS4_CALIBRATION_PULSE_COUNT=${${use_case}_PULSE_COUNT}"
    "MPS4_CALIBRATION_GAP_MS=${${use_case}_GAP_MS}"
    "MPS4_CALIBRATION_GPIO_PORT=${${use_case}_GPIO_PORT}"
    "MPS4_CALIBRATION_GPIO_PIN=${${use_case}_GPIO_PIN}")
