/*
 * SPDX-FileCopyrightText: Copyright 2026 Arm Limited and/or its affiliates
 * <open-source-office@arm.com>
 * SPDX-License-Identifier: Apache-2.0
 */
#include "mlek/use_case/yolov8_detection/YoloV8PostProcessing.hpp"

#include "mlek/log/log_macros.h"

#include <algorithm>
#include <cmath>

namespace arm::app {

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

    std::sort(
        candidates.begin(),
        candidates.end(),
        [](const auto& first, const auto& second) {
            return first.score > second.score;
        });

    /*
     * Class-aware NMS: different classes do not suppress each other.
     */
    for (const auto& candidate : candidates) {
        bool suppressed = false;

        for (const auto& selected : m_results) {
            if (candidate.classId != selected.classId) {
                continue;
            }

            if (CalculateIoU(candidate, selected) > m_params.nmsThreshold) {
                suppressed = true;
                break;
            }
        }

        if (!suppressed) {
            m_results.push_back(candidate);

            if (m_results.size() >= m_params.maxDetections) {
                break;
            }
        }
    }

    return true;
}

} /* namespace arm::app */
