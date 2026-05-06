#!/usr/bin/env python3
"""capture_uart.py — V2.B 板验通用 UART 抓取工具.

用法（最常见）：
  python scripts/capture_uart.py --pass ARM_FPGA_DEMO_LENET5_PASS \
                                  --fail ARM_FPGA_DEMO_LENET5_FAIL

或 e203 板验：
  python scripts/capture_uart.py --pass FPGA_V2_E203_LENET5_PASS \
                                  --fail FPGA_V2_E203_LENET5_FAIL

完整选项：
  --pass MARKER   抓到这个字符串立即退出，return 0
  --fail MARKER   抓到这个字符串立即退出，return 1
  --timeout N     秒，默认 90；超时退出 return 3
  --baud N        默认 115200
  --port COM      跳过自动扫描，直接用这个 COM
  --tee FILE      所有 UART 输出 mirror 到这个文件
  --quiet-probe   不在 stderr 打印 candidate 探测过程

行为：
  1. 优先按 description 匹配 CP2108 / Silicon Labs / Interface 0
  2. 兜底扫 COM3..COM6
  3. 每个候选打开后读 2 秒，看到任何字节就锁定
  4. 锁定后开始转发 stdout，监视 PASS/FAIL marker

退出码：
  0  抓到 --pass marker
  1  抓到 --fail marker
  2  没找到任何能响应的 COM（FPGA 没烧 / 板没上电 / COM 被占用）
  3  超时（--timeout 内既没 PASS 也没 FAIL）
  4  CLI 参数错误
"""
import argparse
import sys
import time

try:
    import serial
    from serial.tools import list_ports
except ImportError:
    sys.stderr.write(
        "[uart] FATAL: pyserial 没装。跑：pip install pyserial\n"
    )
    sys.exit(4)


def discover_candidates(explicit_port, quiet):
    """返回候选 COM 列表（优先 CP2108，兜底 COM3..COM6）."""
    if explicit_port:
        return [explicit_port]

    preferred = []
    fallback = []
    for p in list_ports.comports():
        desc = (p.description or "") + " " + (p.hwid or "")
        if any(k in desc for k in ("CP210", "Silicon Labs")):
            if "Interface 2" in desc:
                preferred.append(p.device)
            else:
                fallback.append(p.device)

    candidates = list(preferred)
    for port in fallback:
        if port not in candidates:
            candidates.append(port)
    for c in ("COM3", "COM4", "COM5", "COM6"):
        if c not in candidates:
            candidates.append(c)

    if not quiet:
        sys.stderr.write(f"[uart] candidates: {candidates}\n")
    return candidates


def open_responsive(candidates, baud, quiet, eager_lock=False):
    """逐个打开候选，2 秒内有字节就锁定该 COM."""
    for port in candidates:
        try:
            s = serial.Serial(port, baud, timeout=1)
            try:
                s.reset_input_buffer()
            except Exception:
                pass
        except Exception as e:
            if not quiet:
                sys.stderr.write(f"[uart] {port}: {e}\n")
            continue

        if eager_lock:
            if not quiet:
                sys.stderr.write(f"[uart] locked on {port} (explicit)\n")
            return s, b""

        deadline = time.time() + 2
        buf = b""
        while time.time() < deadline:
            chunk = s.read(64)
            buf += chunk
            if chunk:
                break

        if buf:
            if not quiet:
                sys.stderr.write(f"[uart] locked on {port}\n")
            return s, buf

        s.close()

    return None, b""


def main():
    ap = argparse.ArgumentParser(description="V2.B 板验 UART 抓取")
    ap.add_argument("--pass", dest="pass_marker", default="ARM_FPGA_DEMO_LENET5_PASS",
                    help="PASS marker（抓到立即 return 0）")
    ap.add_argument("--fail", dest="fail_marker", default="ARM_FPGA_DEMO_LENET5_FAIL",
                    help="FAIL marker（抓到立即 return 1）")
    ap.add_argument("--timeout", type=int, default=90, help="抓取秒数上限（默认 90）")
    ap.add_argument("--baud", type=int, default=115200, help="波特率（默认 115200）")
    ap.add_argument("--port", default=None, help="指定 COM（跳过自动扫描）")
    ap.add_argument("--tee", default=None, help="把所有 UART 输出 mirror 到该文件")
    ap.add_argument("--quiet-probe", action="store_true", help="不在 stderr 打印探测过程")
    args = ap.parse_args()

    cands = discover_candidates(args.port, args.quiet_probe)
    s, prefetch = open_responsive(
        cands, args.baud, args.quiet_probe, eager_lock=bool(args.port)
    )

    if s is None:
        sys.stderr.write(
            "[uart] FATAL: 没找到能响应的 COM。\n"
            "       检查：板有没有上电？JTAG bit 烧没烧上？另一个终端有没有占着串口？\n"
        )
        sys.exit(2)

    tee_fp = open(args.tee, "w", encoding="utf-8") if args.tee else None

    def emit(text):
        sys.stdout.write(text)
        sys.stdout.flush()
        if tee_fp:
            tee_fp.write(text)
            tee_fp.flush()

    # 把锁定时已经读到的 prefetch 字节先吐出来
    if prefetch:
        emit(prefetch.decode("utf-8", errors="replace"))

    deadline = time.time() + args.timeout
    rc = 3  # 默认 timeout
    marker_window = ""
    max_window = max(
        len(args.pass_marker or ""),
        len(args.fail_marker or ""),
        256,
    ) * 2
    try:
        while time.time() < deadline:
            chunk = s.read(256)
            if chunk:
                text = chunk.decode("utf-8", errors="replace")
                emit(text)
                marker_window = (marker_window + text)[-max_window:]
                if args.pass_marker and args.pass_marker in marker_window:
                    rc = 0
                    break
                if args.fail_marker and args.fail_marker in marker_window:
                    rc = 1
                    break
    finally:
        try:
            s.close()
        except Exception:
            pass
        if tee_fp:
            tee_fp.close()

    if rc == 3:
        sys.stderr.write(
            f"[uart] TIMEOUT after {args.timeout}s "
            f"（没看到 {args.pass_marker} 也没看到 {args.fail_marker}）\n"
        )

    sys.exit(rc)


if __name__ == "__main__":
    main()
