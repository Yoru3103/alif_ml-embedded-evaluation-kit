/*
 * SPDX-FileCopyrightText: Copyright 2026 Arm Limited and/or its affiliates
 * <open-source-office@arm.com>
 * SPDX-License-Identifier: Apache-2.0
 */

#include <stdio.h>

#include "uart_stdout.h"

int main(void)
{
    UartStdOutInit();
    printf("hello world\r\n");

    for (;;) {
    }
}
