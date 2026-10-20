# Copyright 2026 MOSAIC-SoC contributors
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

from ..abstractions import BasePeripheral


class Efpga(BasePeripheral):
    """
    The registers of the eFPGA wrapper, hw/efpga/mosaic_efpga.sv (soc.efpga).
    """

    _name = "efpga"
