/*
 * SPDX-FileCopyrightText: Copyright 2026 Arm Limited and/or its affiliates
 * <open-source-office@arm.com>
 * SPDX-License-Identifier: Apache-2.0
 */
#include "mlek/use_case/yolov8_detection/YoloV8PreProcessing.hpp"
#include "mlek/log/log_macros.h"

#include <algorithm>
#include <cmath>
#include <cstdint>

namespace arm::app {
namespace {

struct InputDescription {
    fwk::iface::TensorLayout layout{fwk::iface::TensorLayout::INVALID};
    size_t height{0};
    size_t width{0};
};

bool GetInputDescription(const std::vector<size_t>& shape, InputDescription& description)
{
    if (shape.size() != 4 || shape[0] != 1) {
        return false;
    }

    /* TFLite does not carry a reliable layout annotation. Infer it from the RGB channel. */
    if (shape[1] == 3 && shape[3] != 3) {
        description.layout = fwk::iface::TensorLayout::NCHW;
        description.height = shape[2];
        description.width = shape[3];
        return true;
    }

    if (shape[3] == 3 && shape[1] != 3) {
        description.layout = fwk::iface::TensorLayout::NHWC;
        description.height = shape[1];
        description.width = shape[2];
        return true;
    }

    return false;
}

int8_t QuantizeInput(const uint8_t value, const fwk::iface::QuantParams& quantParams)
{
    const float realValue = static_cast<float>(value) / 255.0F;
    const long quantizedValue = std::lround(realValue / quantParams.scale) + quantParams.offset;
    const long clampedValue = std::clamp(
        quantizedValue, static_cast<long>(-128), static_cast<long>(127));
    return static_cast<int8_t>(clampedValue);
}

} /* anonymous namespace */

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

    InputDescription description;
    if (!GetInputDescription(m_inputTensor->Shape(), description)) {
        printf_err("Expected YOLOv8 input shape [1, 3, H, W] or [1, H, W, 3]\n");
        return false;
    }

    const size_t planeSize = description.height * description.width;
    const size_t requiredBytes = planeSize * 3;
    if (inputSize < requiredBytes) {
        printf_err("Input image is too small\n");
        return false;
    }

    const auto* source = static_cast<const uint8_t*>(input);
    const auto tensorType = m_inputTensor->Type();
    const auto quantParams = m_inputTensor->GetQuantParams();

    if (tensorType == fwk::iface::TensorType::INT8 && quantParams.scale <= 0.0F) {
        printf_err("YOLOv8 INT8 input has invalid quantization parameters\n");
        return false;
    }

    if (tensorType != fwk::iface::TensorType::FP32 &&
        tensorType != fwk::iface::TensorType::INT8) {
        printf_err("YOLOv8 input tensor must be float32 or int8\n");
        return false;
    }

    for (size_t pixel = 0; pixel < planeSize; ++pixel) {
        for (size_t channel = 0; channel < 3; ++channel) {
            const uint8_t sourceValue = source[pixel * 3 + channel];
            const size_t destinationIndex = description.layout == fwk::iface::TensorLayout::NCHW
                                                ? channel * planeSize + pixel
                                                : pixel * 3 + channel;

            if (tensorType == fwk::iface::TensorType::FP32) {
                m_inputTensor->GetData<float>()[destinationIndex] =
                    static_cast<float>(sourceValue) / 255.0F;
            } else {
                m_inputTensor->GetData<int8_t>()[destinationIndex] =
                    QuantizeInput(sourceValue, quantParams);
            }

        }
    }

    return true;
}
} /* namespace arm::app */
