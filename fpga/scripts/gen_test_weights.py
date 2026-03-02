"""
生成确定性测试权重和测试图片，用于 cim_fpga_model.sv 的 RTL 验证。
不需要 PyTorch，纯 Python 标准库。

输出:
  weight_pos.hex — 正列权重 [64 rows × 10 cols], 4-bit (0-F)
  weight_neg.hex — 负列权重 [64 rows × 10 cols], 4-bit (0-F)
  test_image.hex — 测试图片 bit-plane 数据 (T=3, 24 lines)
  test_golden.txt — 预期的 BL 累加结果 (用于 TB 对照)

权重设计策略:
  - digit 0 对应 col 0，digit 1 对应 col 1，以此类推
  - 让 row[0:6] 对 col 0 有强正权重，row[7:13] 对 col 1 有强正权重...
  - 负列权重设为 0（简化测试，保证 diff > 0）
  这样给定全 1 输入时，所有列都有累加值，但可预测。
"""

import os
import random

# Match RTL parameters
NUM_INPUTS = 64
NUM_OUTPUTS = 10
WEIGHT_BITS = 4
MAX_WEIGHT = (1 << WEIGHT_BITS) - 1  # 15
PIXEL_BITS = 8
TIMESTEPS = 3

OUT_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "cim_model")


def gen_structured_weights():
    """
    Generate weights where each output class has a "receptive field":
    - Output j has strong weights (15) for rows j*6 .. j*6+5
    - All other entries have weak weights (1-3)
    - Negative weights are all 0 (simplified for testing)
    This creates predictable, distinguishable per-class responses.
    """
    random.seed(42)
    weight_pos = [[0] * NUM_OUTPUTS for _ in range(NUM_INPUTS)]
    weight_neg = [[0] * NUM_OUTPUTS for _ in range(NUM_INPUTS)]

    for j in range(NUM_OUTPUTS):
        # Strong weights for this class's receptive field
        start_row = j * 6
        for i in range(NUM_INPUTS):
            if start_row <= i < start_row + 6 and i < NUM_INPUTS:
                weight_pos[i][j] = MAX_WEIGHT  # 15 (strong)
            else:
                weight_pos[i][j] = random.randint(0, 3)  # weak background

    return weight_pos, weight_neg


def write_hex(filepath, weights):
    """Write 2D weight array [NUM_INPUTS][NUM_OUTPUTS] to hex file."""
    with open(filepath, "w") as f:
        for i in range(NUM_INPUTS):
            for j in range(NUM_OUTPUTS):
                f.write(f"{weights[i][j]:X}\n")
    total = NUM_INPUTS * NUM_OUTPUTS
    print(f"  Written: {filepath} ({total} entries)")


def gen_test_image():
    """
    Generate a simple test image (64 pixels, 8-bit each).
    Pattern: pixels 0-5 = 255 (strong activation for class 0),
             pixels 6-11 = 128, rest = 64.
    """
    pixels = [64] * NUM_INPUTS  # background
    for i in range(6):          # class 0 receptive field: strong
        pixels[i] = 255
    for i in range(6, 12):      # class 1 receptive field: medium
        pixels[i] = 128
    return pixels


def encode_bitplanes(pixels, timesteps=TIMESTEPS):
    """
    Encode pixels into bit-plane format.
    Each bit-plane is a 64-bit vector (one bit per pixel).
    Total: timesteps × PIXEL_BITS lines.
    """
    bitplanes = []
    for _t in range(timesteps):
        for b in range(PIXEL_BITS - 1, -1, -1):  # MSB first: 7,6,...,0
            bitmap = 0
            for i in range(NUM_INPUTS):
                if (pixels[i] >> b) & 1:
                    bitmap |= (1 << i)
            bitplanes.append(bitmap)
    return bitplanes


def compute_golden(weight_pos, weight_neg, pixels, timesteps=TIMESTEPS):
    """
    Compute expected BL data for each column after full inference.
    For each bit-plane b (MSB=7..LSB=0):
      spike[i] = (pixels[i] >> b) & 1
      acc_pos[j] += Σ (spike[i] * weight_pos[i][j])
      acc_neg[j] += Σ (spike[i] * weight_neg[i][j])
    Then adc_ctrl does: diff[j] = pos[j] - neg[j]
    Then LIF accumulates: membrane[j] += diff[j] << b

    We compute the final membrane potential after all timesteps×bitplanes.
    """
    membrane = [0] * NUM_OUTPUTS

    for _t in range(timesteps):
        for b in range(PIXEL_BITS - 1, -1, -1):
            # Compute spike bitmap for this bit-plane
            spikes = [(pixels[i] >> b) & 1 for i in range(NUM_INPUTS)]

            # Compute BL accumulation per column
            bl_pos = [0] * NUM_OUTPUTS
            bl_neg = [0] * NUM_OUTPUTS
            for j in range(NUM_OUTPUTS):
                for i in range(NUM_INPUTS):
                    if spikes[i]:
                        bl_pos[j] += weight_pos[i][j]
                        bl_neg[j] += weight_neg[i][j]

                # Clamp to 8-bit
                bl_pos[j] = min(bl_pos[j], 255)
                bl_neg[j] = min(bl_neg[j], 255)

            # Scheme B diff + LIF shift-accumulate
            for j in range(NUM_OUTPUTS):
                diff = bl_pos[j] - bl_neg[j]  # signed 9-bit
                membrane[j] += diff * (1 << b)  # arithmetic shift accumulate

    return membrane


def main():
    os.makedirs(OUT_DIR, exist_ok=True)
    print("=== Generating Test Weights & Data ===")

    # Generate weights
    weight_pos, weight_neg = gen_structured_weights()
    write_hex(os.path.join(OUT_DIR, "weight_pos.hex"), weight_pos)
    write_hex(os.path.join(OUT_DIR, "weight_neg.hex"), weight_neg)

    # Generate test image
    pixels = gen_test_image()
    bitplanes = encode_bitplanes(pixels)

    # Write test image hex
    img_path = os.path.join(OUT_DIR, "test_image.hex")
    with open(img_path, "w") as f:
        for bp in bitplanes:
            f.write(f"{bp:016X}\n")
    print(f"  Written: {img_path} ({len(bitplanes)} bit-planes)")

    # Compute and write golden reference
    membrane = compute_golden(weight_pos, weight_neg, pixels)
    golden_path = os.path.join(OUT_DIR, "test_golden.txt")
    with open(golden_path, "w") as f:
        f.write("# Golden membrane potentials after full inference\n")
        f.write(f"# Pixels: class0_field=255, class1_field=128, background=64\n")
        f.write(f"# Timesteps={TIMESTEPS}, PixelBits={PIXEL_BITS}\n")
        f.write(f"# Threshold default = 3060\n")
        threshold = 3060
        for j in range(NUM_OUTPUTS):
            spike = "SPIKE" if membrane[j] >= threshold else "no_spike"
            f.write(f"neuron[{j}]: membrane={membrane[j]:8d}  {spike}\n")
    print(f"  Written: {golden_path}")

    # Print summary
    print("\n=== Golden Reference ===")
    print(f"Threshold = 3060")
    spike_count = 0
    for j in range(NUM_OUTPUTS):
        spike = membrane[j] >= 3060
        if spike:
            spike_count += 1
        marker = " ** SPIKE **" if spike else ""
        print(f"  neuron[{j}]: membrane = {membrane[j]:8d}{marker}")
    print(f"\nExpected spike count: {spike_count}")

    # Also compute per-bitplane BL values for first timestep (debug)
    print("\n=== BL Data (first bitplane, b=7) ===")
    spikes_msb = [(pixels[i] >> 7) & 1 for i in range(NUM_INPUTS)]
    active = sum(spikes_msb)
    print(f"  Active WL count (bit7): {active}/{NUM_INPUTS}")
    for j in range(NUM_OUTPUTS):
        acc = sum(weight_pos[i][j] for i in range(NUM_INPUTS) if spikes_msb[i])
        clamped = min(acc, 255)
        print(f"  bl_pos[{j}] = {acc} → clamped = {clamped}")


if __name__ == "__main__":
    main()
