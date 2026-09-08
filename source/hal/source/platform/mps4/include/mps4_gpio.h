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
#ifndef MPS4_GPIO_H
#define MPS4_GPIO_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/**
 * @brief Configure one MPS4 CMSDK GPIO pin as a push-pull output.
 * @param port GPIO port number, from 0 to 3.
 * @param pin  GPIO pin number, from 0 to 15.
 * @return true when the pin is valid and configured successfully.
 */
bool mps4_gpio_init_output(uint32_t port, uint32_t pin);

/**
 * @brief Drive one configured MPS4 CMSDK GPIO pin.
 * @param port GPIO port number, from 0 to 3.
 * @param pin  GPIO pin number, from 0 to 15.
 * @param value Output level; false is low and true is high.
 * @return true when the pin is valid.
 */
bool mps4_gpio_write(uint32_t port, uint32_t pin, bool value);

#ifdef __cplusplus
}
#endif

#endif /* MPS4_GPIO_H */
