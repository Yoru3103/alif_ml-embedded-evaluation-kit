/*
 * SPDX-FileCopyrightText: Copyright 2026 Arm Limited and/or its affiliates
 * <open-source-office@arm.com>
 * SPDX-License-Identifier: Apache-2.0
 */
#include "UseCaseHandler.hpp"

#include "sample_files.h"
#include "UseCaseCommonUtils.hpp"
#include "hal.h"
#include "mlek/common/ImageUtils.hpp"
#include "mlek/fwk/tflm/YoloV8Model.hpp"
#include "mlek/log/log_macros.h"
#include "mlek/use_case/yolov8_detection/YoloV8PreProcessing.hpp"
#include "mlek/use_case/yolov8_detection/YoloV8PostProcessing.hpp"

#include <algorithm>
#include <cinttypes>
#include <cstdio>
#include <string>
#include <vector>

namespace arm::app {

namespace {

const char* GetLabel(const std::vector<std::string>& labels, int classId)
{
    if (classId < 0 || static_cast<size_t>(classId) >= labels.size()) {
        return "unknown";
    }

    return labels[static_cast<size_t>(classId)].c_str();
}

void DrawDetectionBoxes(
    const std::vector<yolov8_detection::DetectionResult>& results,
    uint32_t startX,
    uint32_t startY,
    uint32_t downscale)
{
    constexpr uint32_t thickness = 1;

    for (const auto& result : results) {
        const uint32_t x = startX + result.x / downscale;
        const uint32_t y = startY + result.y / downscale;
        const uint32_t width = result.width / downscale;
        const uint32_t height = result.height / downscale;

        if (width <= thickness || height <= thickness) {
            continue;
        }

        hal_display_show_box(x, y, width, thickness, COLOR_GREEN);
        hal_display_show_box(x, y + height - thickness, width, thickness, COLOR_GREEN);
        hal_display_show_box(x, y, thickness, height, COLOR_GREEN);
        hal_display_show_box(x + width - thickness, y, thickness, height, COLOR_GREEN);
    }
}

void PrintResults(const std::vector<yolov8_detection::DetectionResult>& results,
                  const std::vector<std::string>& labels)
{
    info("Detections: %zu\n", results.size());

    for (size_t index = 0; index < results.size(); index++) {
        const auto& result = results[index];

        info("%zu: class=%d label=%s score=%f x=%d y=%d w=%d h=%d\n",
             index,
             result.classId,
             GetLabel(labels, result.classId),
             result.score,
             result.x,
             result.y,
             result.width,
             result.height);
    }
}

void PresentResults(const std::vector<yolov8_detection::DetectionResult>& results,
                    const std::vector<std::string>& labels,
                    uint32_t startX,
                    uint32_t startY)
{
    constexpr uint32_t lineHeight = 16;
    constexpr size_t maxDisplayedResults = 9;
    char line[32]{};

    hal_display_set_text_color(COLOR_GREEN);
    const int countLength = std::snprintf(line, sizeof(line), "Detections: %zu", results.size());
    if (countLength > 0) {
        hal_display_show_text(line,
                              std::min(static_cast<size_t>(countLength), sizeof(line) - 1),
                              startX,
                              startY,
                              false);
    }

    const size_t displayedResults = std::min(results.size(), maxDisplayedResults);
    for (size_t index = 0; index < displayedResults; ++index) {
        const auto& result = results[index];
        const int lineLength = std::snprintf(line,
                                             sizeof(line),
                                             "%zu:%s %.2f",
                                             index,
                                             GetLabel(labels, result.classId),
                                             static_cast<double>(result.score));
        if (lineLength > 0) {
            hal_display_show_text(line,
                                  std::min(static_cast<size_t>(lineLength), sizeof(line) - 1),
                                  startX,
                                  startY + static_cast<uint32_t>(index + 1) * lineHeight,
                                  false);
        }
    }
}

} /* anonymous namespace */

bool YoloV8DetectionHandler(ApplicationContext& ctx)
{
    auto& model = ctx.Get<fwk::iface::Model&>("model");
    auto& profiler = ctx.Get<Profiler&>("profiler");
    const auto& labels =
        ctx.Get<const std::vector<std::string>&>("labels");

    if (!model.IsInited()) {
        printf_err("Model is not initialised\n");
        return false;
    }

    if (model.GetNumInputs() != 1 || model.GetNumOutputs() != 1) {
        printf_err("YOLOv8 model must have one input and one output\n");
        return false;
    }

    if (labels.size() != YOLOV8_NUM_CLASSES) {
        printf_err("YOLOv8 label count does not match the configured class count\n");
        return false;
    }

    auto inputTensor = model.GetInputTensor(0);
    auto outputTensor = model.GetOutputTensor(0);
    const auto inputShape = inputTensor->Shape();

    if (inputShape.size() != 4 || inputShape[fwk::tflm::YoloV8Model::ms_inputChannelsIdx] != 3) {
        printf_err("Expected input shape [1, 3, H, W]\n");
        return false;
    }

    const uint32_t imageHeight = inputShape[fwk::tflm::YoloV8Model::ms_inputRowsIdx];
    const uint32_t imageWidth = inputShape[fwk::tflm::YoloV8Model::ms_inputColsIdx];

    if (get_sample_img_width() != imageWidth ||
        get_sample_img_height() != imageHeight) {
        printf_err("Generated image dimensions do not match model input\n");
        return false;
    }

    YoloV8PreProcess preProcess{inputTensor};

    std::vector<yolov8_detection::DetectionResult> results;
    YoloV8PostProcessParams params{
        imageWidth,
        imageHeight,
        YOLOV8_NUM_CLASSES,
        YOLOV8_MAX_DETECTIONS,
        YOLOV8_SCORE_THRESHOLD,
        YOLOV8_NMS_THRESHOLD
    };
    YoloV8PostProcess postProcess{outputTensor, results, params};

    constexpr uint32_t imageStartX = 10;
    constexpr uint32_t imageStartY = 35;
    constexpr uint32_t textStartY = 40;
    constexpr uint32_t displayWidth = 320;
    constexpr uint32_t displayHeight = 240;
    constexpr uint32_t downscale = YOLOV8_DISPLAY_DOWNSCALE;
    static_assert(downscale > 0, "Display downscale factor must be greater than zero");

    const uint32_t displayedImageWidth = imageWidth / downscale;
    const uint32_t displayedImageHeight = imageHeight / downscale;
    const uint32_t textStartX = imageStartX + displayedImageWidth + 10;
    if (textStartX >= displayWidth ||
        imageStartY + displayedImageHeight > displayHeight) {
        printf_err("Displayed image does not fit the Corstone-320 HDLCD\n");
        return false;
    }
    const uint32_t textPanelWidth = displayWidth - textStartX;

    for (uint32_t index = 0; index < get_sample_n_elements(); ++index) {
#ifdef INTERACTIVE_MODE
        AwaitUserInput();
#endif

        const uint8_t* image = get_sample_data_ptr(index);
        if (image == nullptr) {
            printf_err("Failed to get input image\n");
            return false;
        }

        info("Running image %" PRIu32 ": %s\n",
             index,
             get_sample_data_filename(index));

        hal_display_clear(COLOR_BLACK);
        const std::string inferenceMessage{"Running inference"};
        hal_display_show_text(inferenceMessage.c_str(),
                              inferenceMessage.size(),
                              textStartX,
                              textStartY,
                              false);
        hal_display_show_image(
            image,
            imageWidth,
            imageHeight,
            3,
            imageStartX,
            imageStartY,
            downscale);

        if (!preProcess.DoPreProcess(
                image,
                get_sample_img_total_bytes())) {
            printf_err("Pre-processing failed\n");
            return false;
        }

        if (!RunInference(model, profiler)) {
            printf_err("Inference failed\n");
            return false;
        }

        if (!postProcess.DoPostProcess()) {
            printf_err("Post-processing failed\n");
            return false;
        }

        PrintResults(results, labels);
        hal_display_show_box(textStartX, textStartY, textPanelWidth, 16, COLOR_BLACK);
        PresentResults(results, labels, textStartX, textStartY);
        DrawDetectionBoxes(
            results,
            imageStartX,
            imageStartY,
            downscale);

#if VERIFY_TEST_OUTPUT
        DumpTensor(outputTensor);
#endif

        profiler.PrintProfilingResult();
    }

    return true;
}

} /* namespace arm::app */
