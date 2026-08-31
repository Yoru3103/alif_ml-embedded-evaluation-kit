# SPDX-FileCopyrightText: Copyright 2026 Arm Limited and/or its affiliates
# <open-source-office@arm.com>
# SPDX-License-Identifier: Apache-2.0

cmake_minimum_required(VERSION 3.21.0)

set(YOLOV8_DETECTION_API_TARGET yolov8_detection_api)

project(
    ${YOLOV8_DETECTION_API_TARGET}
    DESCRIPTION "YOLOv8 detection use case API"
    LANGUAGES C CXX)

add_library(
    ${YOLOV8_DETECTION_API_TARGET}
    STATIC
    YoloV8PreProcessing.cc
    YoloV8PostProcessing.cc)

target_link_libraries(
    ${YOLOV8_DETECTION_API_TARGET}
    PUBLIC
    common_api)

add_library(
    mlek::${YOLOV8_DETECTION_API_TARGET}
    ALIAS
    ${YOLOV8_DETECTION_API_TARGET})
    
