/*
 * SPDX-FileCopyrightText: Copyright 2026 Arm Limited and/or its affiliates
 * <open-source-office@arm.com>
 * SPDX-License-Identifier: Apache-2.0
 */
#include "BufAttributes.hpp"
#include "Labels.hpp"
#include "UseCaseCommonUtils.hpp"
#include "mlek/log/log_macros.h"
#include "UseCaseHandler.hpp"

#if defined(MLEK_FWK_TFLM)
#include "mlek/fwk/tflm/YoloV8Model.hpp"
using YoloV8Model = arm::app::fwk::tflm::YoloV8Model;
#elif defined(MLEK_FWK_EXECUTORCH)
#include "mlek/fwk/executorch/EtModel.hpp"
using YoloV8Model = arm::app::fwk::et::EtModel;
#else
#error "No supported ML framework selected for YOLOv8 detection"
#endif

namespace arm::app {

static uint8_t activationBuffer[ACTIVATION_BUF_SZ]
    ACTIVATION_BUF_ATTRIBUTE;

namespace yolov8_detection {
extern uint8_t* GetModelPointer();
extern size_t GetModelLen();
} /* namespace yolov8_detection */

} /* namespace arm::app */

void MainLoop()
{
    YoloV8Model model;

    arm::app::fwk::iface::MemoryRegion modelMemory{
        arm::app::yolov8_detection::GetModelPointer(),
        arm::app::yolov8_detection::GetModelLen()
    };

    arm::app::fwk::iface::MemoryRegion computeMemory{
        arm::app::activationBuffer,
        sizeof(arm::app::activationBuffer)
    };

    if (!model.Init(computeMemory, modelMemory)) {
        printf_err("Failed to initialise YOLOv8 model\n");
        return;
    }

    model.LogInterpreterInfo();

    arm::app::ApplicationContext context;
    arm::app::Profiler profiler{"yolov8_detection"};

    context.Set<arm::app::Profiler&>("profiler", profiler);
    context.Set<arm::app::fwk::iface::Model&>("model", model);

    std::vector<std::string> labels;
    GetLabelsVector(labels);
    context.Set<const std::vector<std::string>&>("labels", labels);

    const bool successful =
        arm::app::YoloV8DetectionHandler(context);

    info("YOLOv8 use case terminated %s\n",
         successful ? "successfully" : "with failure");
}
