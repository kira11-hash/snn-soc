#!/usr/bin/env python3
"""
Threshold recommendation helper for SNN SoC.

Usage examples:
  python doc/threshold_recommend.py --timesteps 5
  python doc/threshold_recommend.py --timesteps 5 --adc-peak 80
  python doc/threshold_recommend.py --timesteps 5 --use-fullscale

Notes:
- Default adc_peak=80 fits current behavioral model (popcount + j*3).
- If you have real ADC characterization, pass that peak value instead.
"""
import argparse

def main():
    p = argparse.ArgumentParser()
    p.add_argument("--adc-bits", type=int, default=12, help="ADC output bits")
    p.add_argument("--pixel-bits", type=int, default=8, help="bit-plane bits per pixel")
    p.add_argument("--timesteps", type=int, default=5, help="frames to accumulate")
    p.add_argument("--adc-peak", type=int, default=None, help="expected peak ADC code")
    p.add_argument("--use-fullscale", action="store_true", help="use full-scale ADC code")
    p.add_argument("--activity", type=float, default=0.6, help="activity ratio (0-1)")
    p.add_argument("--margin", type=float, default=1.0, help="extra safety margin")
    args = p.parse_args()

    if args.use_fullscale:
        adc_peak = (1 << args.adc_bits) - 1
    else:
        adc_peak = args.adc_peak if args.adc_peak is not None else 80

    max_per_frame = adc_peak * ((1 << args.pixel_bits) - 1)
    max_total = max_per_frame * args.timesteps
    recommended = int(max_total * args.activity * args.margin)

    print("=== Threshold Recommendation ===")
    print(f"adc_bits       : {args.adc_bits}")
    print(f"pixel_bits     : {args.pixel_bits}")
    print(f"timesteps      : {args.timesteps}")
    print(f"adc_peak       : {adc_peak}")
    print(f"activity ratio : {args.activity}")
    print(f"margin         : {args.margin}")
    print(f"max_per_frame  : {max_per_frame}")
    print(f"max_total      : {max_total}")
    print(f"recommended    : {recommended}")
    print("\nTip: If spikes are too frequent, increase threshold; if no spikes, decrease it.")

if __name__ == "__main__":
    main()
