import ctypes
import random
import struct
from pathlib import Path

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer
from cocotb_tools.runner import get_runner

# Keep this as "sources" for the real hidden-test branch.
# Temporarily change it to "golden" only for the sanity check.
RTL_VARIANT = "sources"


def bits_to_float32(bits: int) -> float:
    return struct.unpack("!f", struct.pack("!I", bits & 0xFFFFFFFF))[0]


def float32_to_bits(value: float) -> int:
    value32 = ctypes.c_float(value).value
    return struct.unpack("!I", struct.pack("!f", value32))[0]


def mul_fp32_bits(a_bits: int, b_bits: int) -> int:
    a_val = bits_to_float32(a_bits)
    b_val = bits_to_float32(b_bits)
    prod = a_val * b_val
    return float32_to_bits(prod)


def is_normal_fp32(bits: int) -> bool:
    exp = (bits >> 23) & 0xFF
    return 1 <= exp <= 254


def make_normal_operand(rng: random.Random) -> int:
    sign = rng.randint(0, 1)
    exp = rng.randint(16, 238)
    frac = rng.getrandbits(23)
    return (sign << 31) | (exp << 23) | frac


def make_normal_case_with_normal_result(rng: random.Random) -> tuple[int, int, int]:
    while True:
        a_bits = make_normal_operand(rng)
        b_bits = make_normal_operand(rng)
        z_bits = mul_fp32_bits(a_bits, b_bits)
        if is_normal_fp32(z_bits):
            return a_bits, b_bits, z_bits


async def tick_and_settle(dut):
    await RisingEdge(dut.clk)
    await Timer(1, unit="ps")


async def reset_dut(dut):
    dut.valid.value = 0
    dut.a.value = 0
    dut.b.value = 0

    dut.rst.value = 1
    await tick_and_settle(dut)
    await tick_and_settle(dut)
    dut.rst.value = 0
    await tick_and_settle(dut)


async def start_op(dut, a_bits: int, b_bits: int):
    dut.a.value = a_bits
    dut.b.value = b_bits
    dut.valid.value = 1
    await tick_and_settle(dut)   # accepted here if idle
    dut.valid.value = 0


async def wait_for_result(dut, max_cycles: int = 20) -> tuple[int, int]:
    for cycle_count in range(1, max_cycles + 1):
        await tick_and_settle(dut)
        if int(dut.out_valid.value):
            return int(dut.z.value), cycle_count
    raise AssertionError("Timed out waiting for out_valid")


@cocotb.test()
async def basic_function_and_latency(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await reset_dut(dut)

    test_vectors = [
        (0x3F800000, 0x3F800000),  # 1.0 * 1.0
        (0x40000000, 0x40400000),  # 2.0 * 3.0
        (0xBFC00000, 0x40200000),  # -1.5 * 2.5
        (0x00800000, 0x40000000),  # smallest normal * 2.0
        (0x3F7FFFFF, 0x3F800001),  # close-to-1 rounding-sensitive pair
    ]

    for a_bits, b_bits in test_vectors:
        expected = mul_fp32_bits(a_bits, b_bits)

        await start_op(dut, a_bits, b_bits)
        got, latency = await wait_for_result(dut)

        assert latency == 7, f"Expected latency 7, got {latency}"
        assert got == expected, (
            f"Mismatch for a=0x{a_bits:08X}, b=0x{b_bits:08X}, "
            f"expected=0x{expected:08X}, got=0x{got:08X}"
        )


@cocotb.test()
async def ignore_valid_while_busy(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await reset_dut(dut)

    first_a = 0x40000000   # 2.0
    first_b = 0x40400000   # 3.0
    first_expected = mul_fp32_bits(first_a, first_b)

    second_a = 0x3FC00000  # 1.5
    second_b = 0x40800000  # 4.0
    second_expected = mul_fp32_bits(second_a, second_b)

    # Start first operation
    await start_op(dut, first_a, first_b)

    # Attempt a second request while the DUT is busy; spec says it must be ignored.
    dut.a.value = second_a
    dut.b.value = second_b
    dut.valid.value = 1
    await tick_and_settle(dut)
    dut.valid.value = 0

    # One cycle was already consumed by the ignored pulse above,
    # so the remaining time to the first result is 6 cycles.
    got1, latency1 = await wait_for_result(dut)
    assert latency1 == 6, f"Expected first result latency 6 after one extra busy cycle, got {latency1}"
    assert got1 == first_expected, (
        f"Busy-handshake failure: expected first result 0x{first_expected:08X}, got 0x{got1:08X}"
    )

    # No extra result should appear on its own.
    for _ in range(3):
        await tick_and_settle(dut)
        assert int(dut.out_valid.value) == 0, "Second request was not ignored while busy"

    # Re-issue the second request now that the DUT is idle.
    await start_op(dut, second_a, second_b)
    got2, latency2 = await wait_for_result(dut)
    assert latency2 == 7, f"Expected second result latency 7, got {latency2}"
    assert got2 == second_expected, (
        f"Expected second result 0x{second_expected:08X}, got 0x{got2:08X}"
    )


@cocotb.test()
async def randomized_normal_cases(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await reset_dut(dut)

    rng = random.Random(7)

    for _ in range(20):
        a_bits, b_bits, expected = make_normal_case_with_normal_result(rng)

        await start_op(dut, a_bits, b_bits)
        got, latency = await wait_for_result(dut)

        assert latency == 7, f"Expected latency 7, got {latency}"
        assert got == expected, (
            f"Random case mismatch for a=0x{a_bits:08X}, b=0x{b_bits:08X}, "
            f"expected=0x{expected:08X}, got=0x{got:08X}"
        )


def test_multiply_fp32_hidden():
    repo_root = Path(__file__).resolve().parents[1]
    rtl_path = repo_root / RTL_VARIANT / "multiply_fp32.sv"

    assert rtl_path.exists(), f"RTL file not found: {rtl_path}"

    runner = get_runner("icarus")
    runner.build(
        sources=[str(rtl_path)],
        hdl_toplevel="multiply_fp32",
        build_dir=str(repo_root / "tests" / "sim_build"),
        always=True,
    )
    runner.test(
        hdl_toplevel="multiply_fp32",
        test_module=Path(__file__).stem,
    )