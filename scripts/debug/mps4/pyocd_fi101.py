# SPDX-FileCopyrightText: Copyright 2026 Arm Limited and/or its affiliates <open-source-office@arm.com>
# SPDX-License-Identifier: Apache-2.0
"""Correct the observed FI101 DPv3 BASEPTR decoding in pyOCD 0.45.1."""
import logging
from pyocd.core.soc_target import SoCTarget
from pyocd.utility.sequencer import CallSequence
from pyocd.coresight.dap import DP_BASEPTR0
from pyocd.coresight.ap import AccessPort, APv2Address, MEM_AP


def will_init_target(target: SoCTarget, init_sequence: CallSequence):
    """Insert a guarded correction before component discovery.

    :param target:          Target being initialized.
    :param init_sequence:   Mutable initialization sequence.
    """
    def correct_baseptr():
        """Re-read and correct the observed 32-bit FI101 root address."""
        if target.dp.dpidr.idr != 0x5C013477:
            raise RuntimeError("This workaround is restricted to the observed FI101 DP ID")
        raw = target.dp.read_reg(DP_BASEPTR0)
        corrected = raw & 0xFFFFF000
        if not raw & 1 or corrected != 0x14000:
            raise RuntimeError(f"Unexpected FI101 BASEPTR0: {raw:#010x}")
        old = target.dp.base_address
        if old not in (corrected, corrected >> 12):
            raise RuntimeError(f"Unexpected decoded BASEPTR: {old:#010x}")
        target.dp._base_addr = corrected
        logging.getLogger("mps4.baseptr").warning(
            "BASEPTR0 raw=%#010x: root address %#010x -> %#010x", raw, old, corrected
        )
    init_sequence.insert_before("discovery", ("correct_fi101_baseptr", correct_baseptr))


    def discover_cpu_ap():
        """Probe the CPU APv2 address explicitly specified by the FI101 BSP."""
        address = APv2Address(0x4000)
        if address in target.dp.aps:
            return
        logging.getLogger("mps4.cpu_ap").warning(
            "Probing BSP-defined CPU APv2 at 0x4000; ROM entries are unchanged"
        )
        ap = AccessPort.create(target.dp, address)
        if not isinstance(ap, MEM_AP):
            raise RuntimeError(f"Expected CPU MEM-AP, got {ap.description}")
        target.dp.aps[address] = ap
        logging.getLogger("mps4.cpu_ap").warning(
            "CPU AP IDR=%#010x, type=%s, has_rom_table=%s",
            ap.idr, ap.description, ap.has_rom_table
        )

    def extend_discovery(sequence: CallSequence) -> CallSequence:
        """Add explicit CPU AP discovery before scanning AP components.

        :param sequence:    Existing discovery sequence.
        :returns:           Extended discovery sequence.
        """
        sequence.insert_before("find_components", ("probe_fi101_cpu_ap", discover_cpu_ap))
        return sequence

    init_sequence.wrap_task("discovery", extend_discovery)
