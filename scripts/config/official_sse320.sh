#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright 2026 Arm Limited and/or its affiliates
# <open-source-office@arm.com>
# SPDX-License-Identifier: Apache-2.0

# Shared benchmark profile. Keep this file identical on the FVP and board branches.
# REPO_ROOT is supplied by the caller. Model compilation and firmware use this profile.
OFFICIAL_USE_CASES=(ad asr img_class inference_runner kws kws_asr noise_reduction
    object_detection vww)
NPU_MACS=1024
NPU_MEMORY_MODE="${OFFICIAL_MEMORY_MODE:-Dedicated_Sram}"
case "${NPU_MEMORY_MODE}" in
    Dedicated_Sram)
        NPU_CACHE_SIZE=393216
        DEFAULT_OFFICIAL_BUILD_DIR="${REPO_ROOT}/build-official-sse320"
        ;;
    Shared_Sram)
        NPU_CACHE_SIZE=0
        DEFAULT_OFFICIAL_BUILD_DIR="${REPO_ROOT}/build-official-sse320-shared"
        ;;
    *)
        printf 'Unsupported OFFICIAL_MEMORY_MODE: %s (Dedicated_Sram or Shared_Sram)\n' \
            "${NPU_MEMORY_MODE}" >&2
        exit 1
        ;;
esac
VELA_SYSTEM_CONFIG=Ethos_U85_SYS_DRAM_Mid_1024
VELA_CONFIG="${REPO_ROOT}/scripts/vela/default_vela.ini"
ACTIVATION_BUF_SIZE=0x00200000
# Vela's arena-cache-size also bounds the shared arena during scheduling.
# Leave 128 KiB of the common 2 MiB arena for TFLM metadata and CPU allocations.
if [[ "${NPU_MEMORY_MODE}" == Shared_Sram ]]; then
    VELA_ARENA_CACHE_SIZE=$((ACTIVATION_BUF_SIZE - 0x00020000))
else
    VELA_ARENA_CACHE_SIZE="${NPU_CACHE_SIZE}"
fi

# Isolated from all legacy/custom-model build and resource directories.
OFFICIAL_BUILD_DIR="${OFFICIAL_BUILD_DIR:-${DEFAULT_OFFICIAL_BUILD_DIR}}"
OFFICIAL_MODEL_DIR="${OFFICIAL_BUILD_DIR}/models"
OFFICIAL_CMAKE_OPTIONS=(
    -DCMAKE_BUILD_TYPE=Release
    -DTARGET_PLATFORM=mps4
    -DTARGET_SUBSYSTEM=sse-320
    -DML_FRAMEWORK=TensorFlowLiteMicro
    -DUSE_SINGLE_INPUT=ON
    -DINTERACTIVE_MODE=OFF
    -DFVP_VSI_ENABLED=OFF
    -DSEMIHOSTING_ENABLED=OFF
    -DBUILD_FVP_TESTS=OFF
    -DCPU_PROFILE_ENABLED=ON
    -DETHOS_U_NPU_ENABLED=ON
    -DETHOS_U_NPU_ID=U85
    "-DETHOS_U_NPU_CONFIG_ID=Z${NPU_MACS}"
    "-DETHOSU_TARGET_NPU_CONFIG=ethos-u85-${NPU_MACS}"
    "-DETHOS_U_NPU_MEMORY_MODE=${NPU_MEMORY_MODE}"
    "-DETHOS_U_NPU_CACHE_SIZE=${NPU_CACHE_SIZE}"
    -DETHOS_U_NPU_TIMING_ADAPTER_ENABLED=OFF
    "-DRESOURCES_PATH=${REPO_ROOT}/resources_downloaded"
)

# Match the upstream default model names; kws_asr uses both KWS and ASR models.
OFFICIAL_MODELS=(
    ad/ad_medium_int8
    asr/wav2letter_pruned_int8
    img_class/mobilenet_v2_1.0_224_INT8
    inference_runner/dnn_s_quantized
    kws/kws_micronet_m
    kws_asr/kws_micronet_m
    kws_asr/wav2letter_pruned_int8
    noise_reduction/rnnoise_INT8
    object_detection/yolo-fastest_192_face_v4
    vww/vww4_128_128_INT8
)
