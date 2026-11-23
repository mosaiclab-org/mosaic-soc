#!/usr/bin/env python3
"""Pack MOSAIC AMP images into a bootable SPI-flash deployment image.

The x-heep boot ROM enables the memory-mapped flash window and jumps to byte
offset 0x180.  A compact table below that entry point describes worker images;
the TITAN cold-boot loader copies and CRC-checks them before TDU wake-up.
With --efpga, the last entries hold the stream of an eFPGA design (a
<design>.hex of util/mosaic_gen/efpga_gen.py) and, with --efpga-unload, its
unload stream: the loader writes the unload to the BITSTREAM register of the
design's eFPGA (soc.efpga) if a reset kept a design in the fabric, then the
stream, before it wakes the workers. With --efpga-div N, an entry between them
sets the fabric's clock to one cycle in N (the CLKDIV register, N - 1): the N
the design was timed at, which a reset puts back to 4.
"""

from __future__ import annotations

import argparse
import binascii
import hashlib
import json
from pathlib import Path
import struct
from typing import Sequence


MAGIC = 0x4D4F5341
VERSION = 2  # 2: each entry starts with its kind
TITAN_OFFSET = 0x180
FLASH_SIZE = 0x0100_0000
HEADER = struct.Struct("<8I")
ENTRY = struct.Struct("<5I")  # kind, destination, size, flash_offset, crc32
KIND_COPY = 0  # copy to SRAM at destination and check its CRC32
KIND_EFPGA = 1  # write the words to the BITSTREAM register at destination
KIND_EFPGA_UNLOAD = 2  # the same, first, only if the fabric holds a design
KIND_EFPGA_CLKDIV = 3  # one word for the CLKDIV register at destination, before the stream
CLKDIV = 0x18  # of the eFPGA's registers (hw/efpga/mosaic_efpga.sv)
MAX_ENTRIES = 15  # MOSAIC_DEPLOY_MAX_ENTRIES of sw/firmware/common/cold_boot.c


class PackError(RuntimeError):
    pass


def _align(value: int, alignment: int) -> int:
    return (value + alignment - 1) & -alignment


def _verilog_hex(data: bytes) -> str:
    lines = ["@00000000"]
    for offset in range(0, len(data), 16):
        lines.append(" ".join(f"{byte:02X}" for byte in data[offset : offset + 16]))
    return "\n".join(lines) + "\n"


def pack(
    manifest_path: Path,
    image_paths: dict[int, Path],
    output: Path,
    efpga_stream: Path | None = None,
    efpga_unload: Path | None = None,
    efpga_div: int | None = None,
) -> dict:
    manifest = json.loads(manifest_path.read_text())
    images = manifest.get("images")
    if not isinstance(images, list) or not images:
        raise PackError("boot manifest has no images")
    titan = next((item for item in images if 0 in item.get("harts", [])), None)
    if titan is None:
        raise PackError("boot manifest has no hart-zero TITAN image")
    titan_id = int(titan["image_id"])
    missing = sorted(int(item["image_id"]) for item in images if int(item["image_id"]) not in image_paths)
    if missing:
        raise PackError(f"missing binary paths for image IDs {missing}")

    binaries = {image_id: path.read_bytes() for image_id, path in image_paths.items()}
    if not binaries[titan_id]:
        raise PackError("TITAN binary is empty")
    cursor = _align(TITAN_OFFSET + len(binaries[titan_id]), 0x1000)
    entries: list[tuple[int, int, int, int]] = []
    deployments: list[dict] = []
    placements = {titan_id: TITAN_OFFSET}
    for item in images:
        image_id = int(item["image_id"])
        blob = binaries[image_id]
        max_size = int(item["max_size"])
        if len(blob) > max_size and image_id != titan_id:
            raise PackError(
                f"image {image_id} is {len(blob)} bytes, exceeds SRAM slot {max_size}"
            )
        if image_id != titan_id:
            placements[image_id] = cursor
            crc = binascii.crc32(blob) & 0xFFFF_FFFF
            entries.append((KIND_COPY, int(item["load_address"], 0), len(blob), cursor, crc))
            cursor = _align(cursor + len(blob), 0x1000)
        deployments.append(
            {
                "image_id": image_id,
                "harts": item["harts"],
                "execution_address": (
                    f"0x{0x4000_0000 + TITAN_OFFSET:08X}"
                    if image_id == titan_id
                    else item["load_address"]
                ),
                "sram_destination": (
                    None if image_id == titan_id else item["load_address"]
                ),
                "flash_offset": f"0x{placements[image_id]:08X}",
                "size": len(blob),
                "crc32": f"0x{binascii.crc32(blob) & 0xFFFF_FFFF:08X}",
                "sha256": hashlib.sha256(blob).hexdigest(),
                "source": image_paths[image_id].name,
            }
        )

    streams = {}  # kind -> (bytes, its deployment record)
    if efpga_div is not None and efpga_stream is None:
        raise PackError("--efpga-div sets the clock of the design of --efpga")
    if efpga_stream is not None or efpga_unload is not None:
        if "efpga" not in manifest:
            raise PackError("the design has no eFPGA (soc.efpga) to load a bitstream into")
        if efpga_stream is None or efpga_unload is None:
            raise PackError("--efpga and --efpga-unload go together: a reset keeps the "
                            "design in the fabric, which only its unload removes")
        destination = manifest["efpga"]["registers"]
        parts = [(KIND_EFPGA_UNLOAD, efpga_unload), (KIND_EFPGA, efpga_stream)]
        if efpga_div is not None:
            if not 1 <= efpga_div <= 16:
                raise PackError(f"--efpga-div {efpga_div}: the fabric's clock is one cycle in 1 to 16")
            parts.insert(1, (KIND_EFPGA_CLKDIV, efpga_div))
        for kind, path in parts:
            if kind == KIND_EFPGA_CLKDIV:
                words, at, source = [path - 1], f"0x{int(destination, 0) + CLKDIV:08X}", f"one cycle in {path}"
            else:
                words, at, source = [int(word, 16) for word in path.read_text().split()], destination, path.name
                if not words or any(not 0 <= word < 1 << 32 for word in words):
                    raise PackError(f"{path}: not a stream of 32-bit words, one per line")
            stream = struct.pack(f"<{len(words)}I", *words)
            crc = binascii.crc32(stream) & 0xFFFF_FFFF
            entries.append((kind, int(at, 0), len(stream), cursor, crc))
            streams[kind] = stream, {
                "destination": at,
                "flash_offset": f"0x{cursor:08X}",
                "size": len(stream),
                "crc32": f"0x{crc:08X}",
                "sha256": hashlib.sha256(stream).hexdigest(),
                "source": source,
            }
            cursor = _align(cursor + len(stream), 0x1000)
    if len(entries) > MAX_ENTRIES:
        raise PackError(f"{len(entries)} table entries; the cold-boot loader takes {MAX_ENTRIES}")

    entry_bytes = b"".join(ENTRY.pack(*entry) for entry in entries)
    header_size = HEADER.size + len(entry_bytes)
    if header_size > TITAN_OFFSET:
        raise PackError(f"deployment table ({header_size} bytes) overlaps TITAN entry")
    table_crc = binascii.crc32(entry_bytes) & 0xFFFF_FFFF
    topo_crc = binascii.crc32(manifest["topology_sha256"].encode("ascii")) & 0xFFFF_FFFF
    header = HEADER.pack(
        MAGIC, VERSION, header_size, len(entries), 1, topo_crc, table_crc, TITAN_OFFSET
    )
    if cursor > FLASH_SIZE:
        raise PackError(f"flash bundle is {cursor} bytes, exceeds {FLASH_SIZE}")
    flash = bytearray(b"\xFF" * cursor)
    flash[: len(header)] = header
    flash[len(header) : len(header) + len(entry_bytes)] = entry_bytes
    for image_id, offset in placements.items():
        blob = binaries[image_id]
        flash[offset : offset + len(blob)] = blob
    for stream, record in streams.values():
        offset = int(record["flash_offset"], 0)
        flash[offset : offset + len(stream)] = stream

    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_bytes(flash)
    output.with_suffix(".hex").write_text(_verilog_hex(flash))
    deployment = {
        "schema_version": 1,
        "boot_mode": "spi-memio-xip-titan-load-workers",
        "boot_straps": {"boot_select": 1, "execute_from_flash": 1},
        "flash_binary": output.name,
        "flash_verilog_hex": output.with_suffix(".hex").name,
        "flash_size": len(flash),
        "topology_sha256": manifest["topology_sha256"],
        "table": {
            "offset": "0x00000000",
            "size": header_size,
            "entry_count": len(entries),
            "crc32": f"0x{table_crc:08X}",
        },
        "images": deployments,
        "efpga_bitstream": streams.get(KIND_EFPGA, (None, None))[1],
        "efpga_unload": streams.get(KIND_EFPGA_UNLOAD, (None, None))[1],
        "efpga_clkdiv": streams.get(KIND_EFPGA_CLKDIV, (None, None))[1],
    }
    output.with_suffix(".json").write_text(json.dumps(deployment, indent=2, sort_keys=True) + "\n")
    return deployment


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", required=True, type=Path)
    parser.add_argument("--image", action="append", default=[], metavar="ID=BIN")
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--efpga", type=Path, metavar="STREAM.hex",
                        help="the stream of an eFPGA design, loaded before the workers wake")
    parser.add_argument("--efpga-unload", type=Path, metavar="STREAM.unload.hex",
                        help="its unload stream, for a design a reset kept in the fabric")
    parser.add_argument("--efpga-div", type=int, metavar="N",
                        help="the fabric's clock for that design: one cycle in N (1 to 16)")
    args = parser.parse_args(argv)
    paths: dict[int, Path] = {}
    for value in args.image:
        try:
            raw_id, raw_path = value.split("=", 1)
            image_id = int(raw_id, 0)
        except ValueError as exc:
            parser.error(f"invalid --image {value!r}; expected ID=BIN")
        if image_id in paths:
            parser.error(f"duplicate image ID {image_id}")
        paths[image_id] = Path(raw_path)
    try:
        pack(args.manifest, paths, args.output, args.efpga, args.efpga_unload, args.efpga_div)
    except (OSError, KeyError, TypeError, ValueError, PackError) as exc:
        parser.error(str(exc))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
