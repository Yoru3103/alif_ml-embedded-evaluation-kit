/*
 * SPDX-FileCopyrightText: Copyright 2026 Arm Limited and/or its affiliates
 * <open-source-office@arm.com>
 * SPDX-License-Identifier: Apache-2.0
 */
#ifndef YOLOV8_PRE_PROCESSING_HPP
#define YOLOV8_PRE_PROCESSING_HPP

#include "mlek/common/BaseProcessing.hpp"
#include "mlek/fwk/iface/Tensor.hpp"

#include <memory>

namespace arm::app {

class YoloV8PreProcess : public BasePreProcess {
public:
    explicit YoloV8PreProcess(const std::shared_ptr<fwk::iface::TensorIface>& inputTensor);

    bool DoPreProcess(const void* input, size_t inputSize) override;

private:
    std::shared_ptr<fwk::iface::TensorIface> m_inputTensor;
};

} /* namespace arm::app */

#endif /* YOLOV8_PRE_PROCESSING_HPP */
