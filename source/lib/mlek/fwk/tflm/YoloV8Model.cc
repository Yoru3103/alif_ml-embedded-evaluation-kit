/*
 * SPDX-FileCopyrightText: Copyright 2026 Arm Limited and/or its affiliates
 * <open-source-office@arm.com>
 * SPDX-License-Identifier: Apache-2.0
 */
#include "mlek/fwk/tflm/YoloV8Model.hpp"

#include "mlek/log/log_macros.h"

namespace arm::app::fwk::tflm {

const tflite::MicroOpResolver& YoloV8Model::GetOpResolver()
{
    return m_opResolver;
}

bool YoloV8Model::EnlistOperations()
{
    /* The Vela model contains QUANTIZE -> ethos-u -> DEQUANTIZE. */
    if (m_opResolver.AddQuantize() != kTfLiteOk ||
        m_opResolver.AddEthosU() != kTfLiteOk ||
        m_opResolver.AddDequantize() != kTfLiteOk) {
        printf_err("Failed to register the YOLOv8 Vela model operators\n");
        return false;
    }

    info("Registered QUANTIZE, Ethos-U and DEQUANTIZE operators\n");
    return true;
}

} /* namespace arm::app::fwk::tflm */
