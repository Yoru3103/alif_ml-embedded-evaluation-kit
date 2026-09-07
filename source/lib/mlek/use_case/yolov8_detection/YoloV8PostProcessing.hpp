/*
 * SPDX-FileCopyrightText: Copyright 2026 Arm Limited and/or its affiliates
 * <open-source-office@arm.com>
 * SPDX-License-Identifier: Apache-2.0
 */
#ifndef YOLOV8_POST_PROCESSING_HPP
#define YOLOV8_POST_PROCESSING_HPP

#include "mlek/common/BaseProcessing.hpp"
#include "mlek/fwk/iface/Tensor.hpp"
#include "mlek/use_case/yolov8_detection/DetectionResult.hpp"

#include <memory>
#include <vector>

namespace arm::app {

struct YoloV8PostProcessParams {
    uint32_t imageWidth{0};
    uint32_t imageHeight{0};
    uint32_t numClasses{80};
    uint32_t maxDetections{20};
    float scoreThreshold{0.25F};
    float nmsThreshold{0.45F};
};

class YoloV8PostProcess : public BasePostProcess {
public:
    YoloV8PostProcess(
        const std::shared_ptr<fwk::iface::TensorIface>& outputTensor,
        std::vector<yolov8_detection::DetectionResult>& results,
        const YoloV8PostProcessParams& params);

    bool DoPostProcess() override;

private:
    static float CalculateIoU(
        const yolov8_detection::DetectionResult& first,
        const yolov8_detection::DetectionResult& second);

    std::shared_ptr<fwk::iface::TensorIface> m_outputTensor;
    std::vector<yolov8_detection::DetectionResult>& m_results;
    YoloV8PostProcessParams m_params;
};

/**
 * @brief Post-processes the four-output INT8 NHWC YOLOv8 model.
 *
 * The model has three feature maps containing 64 DFL box values followed by
 * the class logits, plus one concatenated objectness output.
 */
class YoloV8NewPostProcess : public BasePostProcess {
public:
    YoloV8NewPostProcess(
        const std::vector<std::shared_ptr<fwk::iface::TensorIface>>& outputTensors,
        std::vector<yolov8_detection::DetectionResult>& results,
        const YoloV8PostProcessParams& params);

    bool DoPostProcess() override;

private:
    static constexpr size_t ms_dflBins = 16;
    static constexpr size_t ms_dflValues = 4 * ms_dflBins;

    std::vector<std::shared_ptr<fwk::iface::TensorIface>> m_outputTensors;
    std::vector<yolov8_detection::DetectionResult>& m_results;
    YoloV8PostProcessParams m_params;
};

} /* namespace arm::app */

#endif // !YOLOV8_POST_PROCESSING_HPP
