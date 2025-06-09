/*
 * SPDX-FileCopyrightText: Copyright 2022, 2025 Arm Limited and/or its affiliates <open-source-office@arm.com>
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
#ifndef ETHOSU_CPU_CACHE
#define ETHOSU_CPU_CACHE

#include <stdint.h>
#include <stddef.h>

/**
 * @brief   Clears all the cache state members.
 */
void ethosu_clear_cache_states(void);

/**
 * @brief   Flush/clean the data cache by address and size. Passing NULL as base_addr argument
 *          expects the whole cache to be flushed.
 * @param[in]   base_addr        Array of 32 byte aligned base addresses.
 * @param[in]   base_addr_size   Array with size per each base addr entry.
 * @param[in]   num_base_addr    Number of base addr entries.
 */
void ethosu_flush_dcache(const uint64_t *base_addr, const size_t *base_addr_size, int num_base_addr);

/**
 * @brief   Invalidate the data cache by address and size. Passing NULL as base_addr argument
 *          expects the whole cache to be invalidated.
 * @param[in]   base_addr        Array of 32 byte aligned base addresses.
 * @param[in]   base_addr_size   Array with size per each base addr entry.
 * @param[in]   num_base_addr    Number of base addr entries.
 */
void ethosu_invalidate_dcache(const uint64_t *base_addr, const size_t *base_addr_size, int num_base_addr);

#endif /* ETHOSU_CPU_CACHE */
