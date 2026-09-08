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
#include "mps4_gpio.h"

#include "peripheral_memmap.h"

#define MPS4_GPIO_PORT_COUNT 4U
#define MPS4_GPIO_PIN_COUNT  16U

typedef struct mps4_gpio_cmsdk_reg_map_t {
    volatile uint32_t data;
    volatile uint32_t dataout;
    volatile uint32_t reserved0[2];
    volatile uint32_t outenableset;
    volatile uint32_t outenableclr;
    volatile uint32_t altfuncset;
    volatile uint32_t altfuncclr;
    volatile uint32_t intenset;
    volatile uint32_t intenclr;
    volatile uint32_t inttypeset;
    volatile uint32_t inttypeclr;
    volatile uint32_t intpolset;
    volatile uint32_t intpolclr;
    volatile uint32_t intstatus;
} mps4_gpio_cmsdk_reg_map_t;

static volatile mps4_gpio_cmsdk_reg_map_t* const gpio_ports[MPS4_GPIO_PORT_COUNT] = {
    (volatile mps4_gpio_cmsdk_reg_map_t*)GPIO0_CMSDK_BASE_S,
    (volatile mps4_gpio_cmsdk_reg_map_t*)GPIO1_CMSDK_BASE_S,
    (volatile mps4_gpio_cmsdk_reg_map_t*)GPIO2_CMSDK_BASE_S,
    (volatile mps4_gpio_cmsdk_reg_map_t*)GPIO3_CMSDK_BASE_S,
};

static bool mps4_gpio_is_valid(uint32_t port, uint32_t pin)
{
    return port < MPS4_GPIO_PORT_COUNT && pin < MPS4_GPIO_PIN_COUNT;
}

bool mps4_gpio_init_output(uint32_t port, uint32_t pin)
{
    if (!mps4_gpio_is_valid(port, pin)) {
        return false;
    }

    const uint32_t mask = 1UL << pin;
    volatile mps4_gpio_cmsdk_reg_map_t* const gpio = gpio_ports[port];

    gpio->dataout &= ~mask;
    gpio->altfuncclr = mask;
    gpio->outenableset = mask;
    return true;
}

bool mps4_gpio_write(uint32_t port, uint32_t pin, bool value)
{
    if (!mps4_gpio_is_valid(port, pin)) {
        return false;
    }

    const uint32_t mask = 1UL << pin;
    volatile mps4_gpio_cmsdk_reg_map_t* const gpio = gpio_ports[port];

    if (value) {
        gpio->dataout |= mask;
    } else {
        gpio->dataout &= ~mask;
    }
    return true;
}
