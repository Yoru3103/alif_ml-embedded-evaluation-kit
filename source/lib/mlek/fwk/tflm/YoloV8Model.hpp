/*
 * SPDX-FileCopyrightText: Copyright 2026 Arm Limited and/or its affiliates
 * <open-source-office@arm.com>
 * SPDX-License-Identifier: Apache-2.0
 */
#ifndef YOLOV8_MODEL_HPP
#define YOLOV8_MODEL_HPP

#include "mlek/fwk/tflm/TflmModel.hpp"

namespace arm::app::fwk::tflm {

class YoloV8Model : public TflmModel {
public:
    /* Indices for the expected model - based on input tensor shape */
    static constexpr uint32_t ms_inputChannelsIdx = 1;
    static constexpr uint32_t ms_inputRowsIdx = 2;
    static constexpr uint32_t ms_inputColsIdx = 3;

protected:
    /** @brief   Gets the reference to op resolver interface class. */
    const tflite::MicroOpResolver& GetOpResolver() override;

    /** @brief   Adds operations to the op resolver instance. */
    bool EnlistOperations() override;

private:
    /* Maximum number of individual operations that can be enlisted. */
    static constexpr int ms_maxOpCnt = 3;

    /* A mutable op resolver instance. */
    tflite::MicroMutableOpResolver<ms_maxOpCnt> m_opResolver;
};

} /* namespace arm::app::fwk::tflm */

#endif /* YOLOV8_MODEL_HPP */
