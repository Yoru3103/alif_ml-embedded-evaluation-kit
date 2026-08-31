/*
 * SPDX-FileCopyrightText: Copyright 2026 Arm Limited and/or its affiliates
 * <open-source-office@arm.com>
 * SPDX-License-Identifier: Apache-2.0
 */
#include "mlek/use_case/yolov8_detection/YoloV8PreProcessing.hpp"
#include "mlek/log/log_macros.h"

namespace arm::app {
    YoloV8PreProcess::YoloV8PreProcess(
        const std::shared_ptr<fwk::iface::TensorIface>& inputTensor) :
        m_inputTensor{inputTensor}
    {}

    bool YoloV8PreProcess::DoPreProcess(const void* input, size_t inputSize)
    {
        if (input == nullptr || m_inputTensor == nullptr) {
            printf_err("Invalid YOLOv8 input\n");
            return false;
        }

        if (m_inputTensor->Type() != fwk::iface::TensorType::FP32) {
            printf_err("YOLOv8 input tensor must be float32\n");
            return false;
        }

        const auto shape = m_inputTensor->Shape();
        if (shape.size() != 4 || shape[0] != 1 || shape[1] != 3) {
            printf_err("Expected YOLOv8 input shape [1, 3, H, W]\n");
            return false;
        }

        const size_t height = shape[2];
        const size_t width = shape[3];
        const size_t planeSize = height * width;
        const size_t requiredBytes = planeSize * 3;

        if (inputSize < requiredBytes) {
            printf_err("Input image is too small\n");
            return false;
        }

        const auto* source = static_cast<const uint8_t*>(input);
        auto* destination = m_inputTensor->GetData<float>();

        /*
         * Source:      HWC RGBRGBRGB...
         * Destination: CHW RRR...GGG...BBB...
         */
        for (size_t pixel = 0; pixel < planeSize; ++pixel) {
            destination[pixel] = static_cast<float>(source[pixel * 3]) / 255.0F;
            destination[planeSize + pixel] = static_cast<float>(source[pixel * 3 + 1]) / 255.0F;
            destination[planeSize * 2 + pixel] = static_cast<float>(source[pixel * 3 + 2]) / 255.0F;
        }

        return true;
    }
} /* namespace arm::app */
