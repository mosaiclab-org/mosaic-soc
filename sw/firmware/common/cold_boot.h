// Copyright 2026 MOSAIC-SoC Contributors
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

#ifndef MOSAIC_COLD_BOOT_H_
#define MOSAIC_COLD_BOOT_H_

#include <stdint.h>

// Copies and checks every worker image of the deployment table, and loads the
// eFPGA bitstream of the table, if it has one, into the fabric and connects
// it; a design a reset kept in the fabric is first removed by the table's
// unload stream. Returns 0, or the code of the first table or image error. A bitstream
// the eFPGA refused does not stop the boot: *efpga_failure is then its STATUS
// with bit 31 set, and 0 otherwise. The table may set the fabric's clock
// first (CLKDIV): if the eFPGA does not keep it, *efpga_failure is
// 0x80000000 | MOSAIC_EFPGA_CLKDIV_REFUSED | what it kept, and the
// bitstream is not loaded.
uint32_t mosaic_cold_boot_load_workers(uint32_t *efpga_failure);

#endif  // MOSAIC_COLD_BOOT_H_
