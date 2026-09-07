/*
 * SPDX-FileCopyrightText: Copyright 2026 Arm Limited and/or its affiliates
 * <open-source-office@arm.com>
 * SPDX-License-Identifier: Apache-2.0
 */
#include "mlek/use_case/yolov8_detection/YoloV8PostProcessing.hpp"

#include "mlek/log/log_macros.h"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <limits>

namespace arm::app {

namespace {

float CalculateDetectionIoU(
    const yolov8_detection::DetectionResult& first,
    const yolov8_detection::DetectionResult& second)
{
    const int intersectionLeft = std::max(first.x, second.x);
    const int intersectionTop = std::max(first.y, second.y);
    const int intersectionRight =
        std::min(first.x + first.width, second.x + second.width);
    const int intersectionBottom =
        std::min(first.y + first.height, second.y + second.height);

    const int intersectionWidth =
        std::max(0, intersectionRight - intersectionLeft);
    const int intersectionHeight =
        std::max(0, intersectionBottom - intersectionTop);

    const float intersectionArea =
        static_cast<float>(intersectionWidth * intersectionHeight);
    const float firstArea =
        static_cast<float>(first.width * first.height);
    const float secondArea =
        static_cast<float>(second.width * second.height);
    const float unionArea = firstArea + secondArea - intersectionArea;

    return unionArea > 0.0F ? intersectionArea / unionArea : 0.0F;
}

void ApplyClassAwareNms(
    std::vector<yolov8_detection::DetectionResult>& candidates,
    std::vector<yolov8_detection::DetectionResult>& results,
    const YoloV8PostProcessParams& params)
{
    std::sort(
        candidates.begin(),
        candidates.end(),
        [](const auto& first, const auto& second) {
            return first.score > second.score;
        });

    for (const auto& candidate : candidates) {
        bool suppressed = false;

        for (const auto& selected : results) {
            if (candidate.classId != selected.classId) {
                continue;
            }

            if (CalculateDetectionIoU(candidate, selected) > params.nmsThreshold) {
                suppressed = true;
                break;
            }
        }

        if (!suppressed) {
            results.push_back(candidate);

            if (results.size() >= params.maxDetections) {
                break;
            }
        }
    }
}

float Dequantize(const int8_t value, const fwk::iface::QuantParams& quantParams)
{
    return (static_cast<float>(value) - static_cast<float>(quantParams.offset)) *
           quantParams.scale;
}

float Sigmoid(const float value)
{
    return 1.0F / (1.0F + std::exp(-value));
}

} /* anonymous namespace */

YoloV8PostProcess::YoloV8PostProcess(
    const std::shared_ptr<fwk::iface::TensorIface>& outputTensor,
    std::vector<yolov8_detection::DetectionResult>& results,
    const YoloV8PostProcessParams& params) :
    m_outputTensor{outputTensor},
    m_results{results},
    m_params{params}
{}

float YoloV8PostProcess::CalculateIoU(
    const yolov8_detection::DetectionResult& first,
    const yolov8_detection::DetectionResult& second)
{
    return CalculateDetectionIoU(first, second);
}

bool YoloV8PostProcess::DoPostProcess()
{
    m_results.clear();

    if (m_outputTensor == nullptr ||
        m_outputTensor->Type() != fwk::iface::TensorType::FP32) {
        printf_err("YOLOv8 output tensor must be float32\n");
        return false;
    }

    const auto shape = m_outputTensor->Shape();
    if (shape.size() != 3 || shape[0] != 1) {
        printf_err("Expected YOLOv8 output shape [1, 4 + classes, boxes]\n");
        return false;
    }

    const size_t attributes = shape[1];
    const size_t boxCount = shape[2];

    if (attributes != 4 + m_params.numClasses) {
        printf_err("Unexpected YOLOv8 output attribute count\n");
        return false;
    }

    const auto* output = m_outputTensor->GetData<float>();
    std::vector<yolov8_detection::DetectionResult> candidates;
    candidates.reserve(m_params.maxDetections * 4);

    for (size_t box = 0; box < boxCount; ++box) {
        float bestScore = 0.0F;
        int bestClass = -1;

        for (size_t classIndex = 0;
             classIndex < m_params.numClasses;
             ++classIndex) {
            const float score =
                output[(4 + classIndex) * boxCount + box];

            if (score > bestScore) {
                bestScore = score;
                bestClass = static_cast<int>(classIndex);
            }
        }

        if (bestScore < m_params.scoreThreshold) {
            continue;
        }

        const float centerX = output[box];
        const float centerY = output[boxCount + box];
        const float boxWidth = output[2 * boxCount + box];
        const float boxHeight = output[3 * boxCount + box];

        int left = static_cast<int>(
            (centerX - boxWidth * 0.5F) * m_params.imageWidth);
        int top = static_cast<int>(
            (centerY - boxHeight * 0.5F) * m_params.imageHeight);
        int right = static_cast<int>(
            (centerX + boxWidth * 0.5F) * m_params.imageWidth);
        int bottom = static_cast<int>(
            (centerY + boxHeight * 0.5F) * m_params.imageHeight);

        left = std::clamp(left, 0, static_cast<int>(m_params.imageWidth) - 1);
        top = std::clamp(top, 0, static_cast<int>(m_params.imageHeight) - 1);
        right = std::clamp(right, 0, static_cast<int>(m_params.imageWidth));
        bottom = std::clamp(bottom, 0, static_cast<int>(m_params.imageHeight));

        if (right <= left || bottom <= top) {
            continue;
        }

        candidates.push_back({
            bestScore,
            bestClass,
            left,
            top,
            right - left,
            bottom - top
        });
    }

    /* Class-aware NMS: different classes do not suppress each other. */
    ApplyClassAwareNms(candidates, m_results, m_params);

    return true;
}

YoloV8NewPostProcess::YoloV8NewPostProcess(
    const std::vector<std::shared_ptr<fwk::iface::TensorIface>>& outputTensors,
    std::vector<yolov8_detection::DetectionResult>& results,
    const YoloV8PostProcessParams& params) :
    m_outputTensors{outputTensors},
    m_results{results},
    m_params{params}
{}

bool YoloV8NewPostProcess::DoPostProcess()
{
    struct FeatureMap {
        std::shared_ptr<fwk::iface::TensorIface> tensor;
        size_t height{0};
        size_t width{0};
        size_t channels{0};
        size_t stride{0};
        size_t objectnessOffset{0};
    };

    m_results.clear();

    if (m_outputTensors.size() != 4) {
        printf_err("New YOLOv8 model must have four output tensors\n");
        return false;
    }

    std::shared_ptr<fwk::iface::TensorIface> objectnessTensor;
    std::vector<FeatureMap> featureMaps;

    for (const auto& tensor : m_outputTensors) {
        if (tensor == nullptr || tensor->Type() != fwk::iface::TensorType::INT8) {
            printf_err("New YOLOv8 outputs must be int8 tensors\n");
            return false;
        }

        const auto shape = tensor->Shape();
        if (shape.size() == 3 && shape[0] == 1 && shape[1] == 1) {
            if (objectnessTensor != nullptr) {
                printf_err("New YOLOv8 model has multiple objectness outputs\n");
                return false;
            }
            objectnessTensor = tensor;
            continue;
        }

        if (shape.size() != 4 || shape[0] != 1 || shape[1] == 0 || shape[2] == 0) {
            printf_err("Invalid new YOLOv8 feature map shape\n");
            return false;
        }

        featureMaps.push_back({tensor, shape[1], shape[2], shape[3]});
    }

    if (objectnessTensor == nullptr || featureMaps.size() != 3) {
        printf_err("New YOLOv8 model must have three feature maps and one objectness output\n");
        return false;
    }

    std::sort(
        featureMaps.begin(),
        featureMaps.end(),
        [](const FeatureMap& first, const FeatureMap& second) {
            return first.width > second.width;
        });

    const size_t objectnessElements = objectnessTensor->GetNumElements();
    size_t objectnessOffset = 0;
    size_t numClasses = 0;

    for (auto& featureMap : featureMaps) {
        if (m_params.imageWidth % featureMap.width != 0 ||
            m_params.imageHeight % featureMap.height != 0 ||
            featureMap.channels < ms_dflValues) {
            printf_err("Invalid new YOLOv8 feature map dimensions\n");
            return false;
        }

        featureMap.stride = m_params.imageWidth / featureMap.width;
        if (featureMap.stride == 0 ||
            m_params.imageHeight / featureMap.height != featureMap.stride) {
            printf_err("New YOLOv8 feature map stride is invalid\n");
            return false;
        }

        const size_t featureMapClasses = featureMap.channels - ms_dflValues;
        if (numClasses == 0) {
            numClasses = featureMapClasses;
        } else if (numClasses != featureMapClasses) {
            printf_err("New YOLOv8 feature maps have different class counts\n");
            return false;
        }

        featureMap.objectnessOffset = objectnessOffset;
        objectnessOffset += featureMap.height * featureMap.width;
    }

    if (m_params.numClasses != 0 && m_params.numClasses != numClasses) {
        printf_err("New YOLOv8 output class count does not match configuration\n");
        return false;
    }

    if (objectnessOffset != objectnessElements) {
        printf_err("New YOLOv8 objectness output has an unexpected size\n");
        return false;
    }

    const auto objectnessQuantParams = objectnessTensor->GetQuantParams();
    if (objectnessQuantParams.scale <= 0.0F) {
        printf_err("New YOLOv8 objectness output has invalid quantization parameters\n");
        return false;
    }

    const auto* objectness = objectnessTensor->GetData<int8_t>();
    std::vector<yolov8_detection::DetectionResult> candidates;
    candidates.reserve(objectnessElements);

    for (const auto& featureMap : featureMaps) {
        const auto quantParams = featureMap.tensor->GetQuantParams();
        if (quantParams.scale <= 0.0F) {
            printf_err("New YOLOv8 output has invalid quantization parameters\n");
            return false;
        }

        const auto* output = featureMap.tensor->GetData<int8_t>();

        for (size_t y = 0; y < featureMap.height; ++y) {
            for (size_t x = 0; x < featureMap.width; ++x) {
                const size_t cell = y * featureMap.width + x;
                const float objectnessScore = Sigmoid(Dequantize(
                    objectness[featureMap.objectnessOffset + cell], objectnessQuantParams));

                std::array<float, ms_dflBins> dflValues{};
                std::array<float, 4> distances{};

                for (size_t side = 0; side < 4; ++side) {
                    float maximum = -std::numeric_limits<float>::infinity();
                    for (size_t bin = 0; bin < ms_dflBins; ++bin) {
                        const size_t index = cell * featureMap.channels + side * ms_dflBins + bin;
                        dflValues[bin] = Dequantize(output[index], quantParams);
                        maximum = std::max(maximum, dflValues[bin]);
                    }

                    float sum = 0.0F;
                    float weightedSum = 0.0F;
                    for (size_t bin = 0; bin < ms_dflBins; ++bin) {
                        const float probability = std::exp(dflValues[bin] - maximum);
                        sum += probability;
                        weightedSum += static_cast<float>(bin) * probability;
                    }
                    distances[side] = sum > 0.0F ? weightedSum / sum : 0.0F;
                }

                float bestScore = 0.0F;
                int bestClass = -1;
                for (size_t classIndex = 0; classIndex < numClasses; ++classIndex) {
                    const size_t index = cell * featureMap.channels + ms_dflValues + classIndex;
                    const float classScore = Sigmoid(Dequantize(output[index], quantParams));
                    const float score = objectnessScore * classScore;
                    if (score > bestScore) {
                        bestScore = score;
                        bestClass = static_cast<int>(classIndex);
                    }
                }

                if (bestClass < 0 || bestScore < m_params.scoreThreshold) {
                    continue;
                }

                const float centerX = (static_cast<float>(x) + 0.5F) * featureMap.stride;
                const float centerY = (static_cast<float>(y) + 0.5F) * featureMap.stride;
                const float left = centerX - distances[0] * featureMap.stride;
                const float top = centerY - distances[1] * featureMap.stride;
                const float right = centerX + distances[2] * featureMap.stride;
                const float bottom = centerY + distances[3] * featureMap.stride;

                const int clippedLeft = std::clamp(
                    static_cast<int>(left), 0, static_cast<int>(m_params.imageWidth) - 1);
                const int clippedTop = std::clamp(
                    static_cast<int>(top), 0, static_cast<int>(m_params.imageHeight) - 1);
                const int clippedRight = std::clamp(
                    static_cast<int>(right), 0, static_cast<int>(m_params.imageWidth));
                const int clippedBottom = std::clamp(
                    static_cast<int>(bottom), 0, static_cast<int>(m_params.imageHeight));

                if (clippedRight <= clippedLeft || clippedBottom <= clippedTop) {
                    continue;
                }

                candidates.push_back({
                    bestScore,
                    bestClass,
                    clippedLeft,
                    clippedTop,
                    clippedRight - clippedLeft,
                    clippedBottom - clippedTop
                });
            }
        }
    }

    ApplyClassAwareNms(candidates, m_results, m_params);
    return true;
}

} /* namespace arm::app */
