# multiply_fp32 — FP32 Multiplier Specification

## Overview
Implement a synthesizable SystemVerilog module `multiply_fp32` that multiplies two IEEE-754 single-precision floating-point values and returns the result using a `valid` / `out_valid` handshake.

The design should behave as:

- `z = a * b`

where `a`, `b`, and `z` are 32-bit IEEE-754 single-precision values.

---

## Interface

### Ports
| Port | Dir | Width | Description |
|------|-----|-------|-------------|
| `clk`       | in  | 1  | Clock |
| `rst`       | in  | 1  | Asynchronous reset (posedge) |
| `valid`     | in  | 1  | 1-cycle start pulse |
| `a`         | in  | 32 | Operand A (FP32 bits) |
| `b`         | in  | 32 | Operand B (FP32 bits) |
| `z`         | out | 32 | Result (FP32 bits) |
| `out_valid` | out | 1  | 1-cycle pulse when `z` is valid |

---

## Handshake Behavior

- A new operation is accepted only when the unit is idle.
- If `valid` is high on a rising clock edge while the unit is idle, the operation starts on that edge.
- While an operation is in progress, any new `valid` pulse must be ignored.
- Only one multiplication may be in flight at a time.
- `out_valid` must pulse high for exactly one cycle when the result is ready.

---

## Timing Requirements

- The design is **not pipelined**.
- The result must appear with a **fixed latency of 7 clock cycles** from the cycle where the request is accepted.
- `out_valid` must assert on the cycle when the packed result is available.

---

## Arithmetic Requirements

- Inputs `a` and `b` are IEEE-754 binary32 values.
- For this task, you may assume the evaluated inputs are **finite normal numbers**.
- The output must be the IEEE-754 single-precision product of `a` and `b` for the evaluated cases.
- Use standard floating-point multiplication behavior, including:
  - sign computation
  - exponent handling
  - significand multiplication
  - normalization
  - **round-to-nearest-even**

---

## Constraints

- Keep the module name exactly as `multiply_fp32`.
- The implementation must be placed in `sources/multiply_fp32.sv`.
- Do not change any module ports.
- The RTL must be synthesizable.
- The test environment uses **Icarus Verilog**, so avoid SystemVerilog Assertion (SVA) property/sequence syntax.

---

## Verification Notes

A correct implementation should support the following observable behavior:

- synchronous request acceptance using `valid`
- fixed 7-cycle response timing
- correct handling of the busy / ignore-new-valid behavior
- correct IEEE-754 multiplication result for the evaluated normal input cases