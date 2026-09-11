# SPDX-FileCopyrightText: Copyright 2026 Arm Limited and/or its affiliates
# <open-source-office@arm.com>
# SPDX-License-Identifier: Apache-2.0

# Specify supported frameworks.
set(${use_case}_ML_FRAMEWORK "TensorFlowLiteMicro;ExecuTorch")

if (NOT ${ML_FRAMEWORK} IN_LIST ${use_case}_ML_FRAMEWORK)
    set(${use_case}_supports_${ML_FRAMEWORK} OFF)
    return()
endif()

set(${use_case}_supports_${ML_FRAMEWORK} ON)

# Link the platform-independent YOLOv8 API.
list(APPEND ${use_case}_API_LIST "yolov8_detection")

USER_OPTION(
    ${use_case}_MODEL_IN_EXT_FLASH
    "Run model from external flash."
    OFF
    BOOL)

USER_OPTION(
    ${use_case}_MAX_DETECTIONS
    "Maximum number of detections after NMS."
    20
    STRING)

USER_OPTION(
    ${use_case}_SCORE_THRESHOLD
    "Detection score threshold."
    0.25
    STRING)

USER_OPTION(
    ${use_case}_NMS_THRESHOLD
    "NMS IoU threshold."
    0.45
    STRING)

USER_OPTION(
    ${use_case}_DISPLAY_DOWNSCALE
    "LCD image downscale factor."
    2
    STRING)

if (${ML_FRAMEWORK} STREQUAL "TensorFlowLiteMicro")
    set(DEFAULT_MODEL_PATH
        ${CMAKE_SOURCE_DIR}/vela_output/best_int8_z256/best_int8_vela.tflite)
    set(DEFAULT_LABELS_PATH
        ${CMAKE_SOURCE_DIR}/resources/object_detection/samples/coco128.yaml)
    set(DEFAULT_IMAGE_SIZE 256)
    set(DEFAULT_NUM_CLASSES 80)
    set(DEFAULT_ACTIVATION_BUF_SZ 0x00200000)
elseif (${ML_FRAMEWORK} STREQUAL "ExecuTorch")
    set(DEFAULT_MODEL_PATH
        ${CMAKE_SOURCE_DIR}/resources_downloaded/gesture_detection/best_mlek_ethos-u85-512.pte)
    set(DEFAULT_LABELS_PATH
        ${CMAKE_SOURCE_DIR}/resources/gesture_detection/labels.txt)
    set(DEFAULT_IMAGE_SIZE 320)
    set(DEFAULT_NUM_CLASSES 10)
    # Keep the method allocator within the MPS4 SSE-320 4 MiB SRAM region.
    # Its usage is separate from the temporary pool that holds NPU scratch.
    set(DEFAULT_ACTIVATION_BUF_SZ 0x00300000)
endif()

USER_OPTION(
    ${use_case}_IMAGE_SIZE
    "YOLOv8 input image width and height."
    ${DEFAULT_IMAGE_SIZE}
    STRING)

USER_OPTION(
    ${use_case}_NUM_CLASSES
    "Number of YOLOv8 classes."
    ${DEFAULT_NUM_CLASSES}
    STRING)

USER_OPTION(
    ${use_case}_ACTIVATION_BUF_SZ
    "Tensor arena size."
    ${DEFAULT_ACTIVATION_BUF_SZ}
    STRING)

USER_OPTION(
    ${use_case}_MODEL_PATH
    "YOLOv8 TFLite or ExecuTorch PTE model."
    ${DEFAULT_MODEL_PATH}
    FILEPATH)

USER_OPTION(
    ${use_case}_FILE_PATH
    "Directory containing input images, or a path to one input image."
    ${CMAKE_SOURCE_DIR}/20260827_Model
    PATH_OR_FILE)

USER_OPTION(
    ${use_case}_LABELS_YAML_FILE
    "Ultralytics dataset YAML or one-label-per-line text file."
    ${DEFAULT_LABELS_PATH}
    FILEPATH)

if (COMMAND generate_pte_ops_lib AND "${ML_FRAMEWORK}" STREQUAL "ExecuTorch")
    generate_pte_ops_lib(
        MODEL_PATH      "${${use_case}_MODEL_PATH}"     # Path to the model PTE
        LIB_NAME        "${use_case}_portable_ops_lib"  # Library target name
        SELECT_OPS_LIST "")                             # Always included ops list

    # If the target is generated, request it to be linked for this use case.
    if (TARGET ${use_case}_portable_ops_lib)
        set(${use_case}_LINK_LIBS ${use_case}_portable_ops_lib)
    endif()
endif()

if (NOT EXISTS "${${use_case}_LABELS_YAML_FILE}")
    message(FATAL_ERROR
        "YOLOv8 labels file not found: ${${use_case}_LABELS_YAML_FILE}")
endif()

set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS
    "${${use_case}_LABELS_YAML_FILE}")

set(YOLOV8_LABELS_TXT_FILE "${SRC_GEN_DIR}/yolov8_labels.txt")
file(WRITE "${YOLOV8_LABELS_TXT_FILE}" "")

get_filename_component(YOLOV8_LABELS_EXTENSION
    "${${use_case}_LABELS_YAML_FILE}" EXT)
string(TOLOWER "${YOLOV8_LABELS_EXTENSION}" YOLOV8_LABELS_EXTENSION)

if (YOLOV8_LABELS_EXTENSION STREQUAL ".txt")
    file(STRINGS "${${use_case}_LABELS_YAML_FILE}" YOLOV8_LABEL_NAMES)
    list(LENGTH YOLOV8_LABEL_NAMES YOLOV8_LABEL_COUNT)

    if (NOT YOLOV8_LABEL_COUNT EQUAL ${${use_case}_NUM_CLASSES})
        message(FATAL_ERROR
            "Expected ${${use_case}_NUM_CLASSES} labels in "
            "${${use_case}_LABELS_YAML_FILE}, found ${YOLOV8_LABEL_COUNT}")
    endif()

    foreach(YOLOV8_LABEL_NAME IN LISTS YOLOV8_LABEL_NAMES)
        string(STRIP "${YOLOV8_LABEL_NAME}" YOLOV8_LABEL_NAME)
        file(APPEND "${YOLOV8_LABELS_TXT_FILE}" "${YOLOV8_LABEL_NAME}\n")
    endforeach()
else()
    file(STRINGS "${${use_case}_LABELS_YAML_FILE}" YOLOV8_LABEL_LINES
        REGEX "^[ \t]*[0-9]+:[ \t]+.+$")

    list(LENGTH YOLOV8_LABEL_LINES YOLOV8_LABEL_COUNT)
    if (NOT YOLOV8_LABEL_COUNT EQUAL ${${use_case}_NUM_CLASSES})
        message(FATAL_ERROR
            "Expected ${${use_case}_NUM_CLASSES} labels in "
            "${${use_case}_LABELS_YAML_FILE}, found ${YOLOV8_LABEL_COUNT}")
    endif()

    set(YOLOV8_EXPECTED_CLASS_ID 0)
    foreach(YOLOV8_LABEL_LINE IN LISTS YOLOV8_LABEL_LINES)
        string(REGEX MATCH
            "^[ \t]*([0-9]+):[ \t]*(.+)$"
            YOLOV8_LABEL_MATCH
            "${YOLOV8_LABEL_LINE}")
        set(YOLOV8_CLASS_ID "${CMAKE_MATCH_1}")
        set(YOLOV8_CLASS_NAME "${CMAKE_MATCH_2}")
        string(STRIP "${YOLOV8_CLASS_NAME}" YOLOV8_CLASS_NAME)

        if (NOT YOLOV8_CLASS_ID EQUAL YOLOV8_EXPECTED_CLASS_ID)
            message(FATAL_ERROR
                "YOLOv8 label IDs must be contiguous from zero; expected "
                "${YOLOV8_EXPECTED_CLASS_ID}, found ${YOLOV8_CLASS_ID}")
        endif()

        file(APPEND "${YOLOV8_LABELS_TXT_FILE}" "${YOLOV8_CLASS_NAME}\n")
        math(EXPR YOLOV8_EXPECTED_CLASS_ID "${YOLOV8_EXPECTED_CLASS_ID} + 1")
    endforeach()
endif()

generate_images_code(
    "${${use_case}_FILE_PATH}"
    ${SAMPLES_GEN_DIR}
    "${${use_case}_IMAGE_SIZE}")

set(${use_case}_LABELS_CPP_FILE Labels)
generate_labels_code(
    INPUT "${YOLOV8_LABELS_TXT_FILE}"
    DESTINATION_SRC ${SRC_GEN_DIR}
    DESTINATION_HDR ${INC_GEN_DIR}
    OUTPUT_FILENAME "${${use_case}_LABELS_CPP_FILE}")

generate_model_code(
    MODEL_PATH ${${use_case}_MODEL_PATH}
    DESTINATION ${SRC_GEN_DIR}
    NAMESPACE "arm" "app" "yolov8_detection")

set(${use_case}_COMPILE_DEFS
    "YOLOV8_NUM_CLASSES=${${use_case}_NUM_CLASSES}"
    "YOLOV8_MAX_DETECTIONS=${${use_case}_MAX_DETECTIONS}"
    "YOLOV8_SCORE_THRESHOLD=${${use_case}_SCORE_THRESHOLD}F"
    "YOLOV8_NMS_THRESHOLD=${${use_case}_NMS_THRESHOLD}F"
    "YOLOV8_DISPLAY_DOWNSCALE=${${use_case}_DISPLAY_DOWNSCALE}")
