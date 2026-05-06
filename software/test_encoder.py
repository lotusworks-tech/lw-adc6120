#!/usr/bin/env python3
"""
test_encoder.py — Test rotary encoder gain control for XLR1 or XLR2.

Encoder behavior (from logic analyzer):
  - Each click produces exactly one edge on each phase (sticky state).
  - CW:  B leads A  → +1 dB
  - CCW: A leads B  → -1 dB

Usage:
  sudo python3 test_encoder.py        # defaults to CH1
  sudo python3 test_encoder.py --ch 2
Ctrl-C to exit.
"""

import argparse
import re
import subprocess

import gpiod
from gpiod.line import Bias, Direction, Edge, Value

GPIO_CHIP = "/dev/gpiochip0"
ALSA_CARD = "LotusWorksADC61"
GAIN_MIN  = 0
GAIN_MAX  = 42

CHANNELS = {
    1: {"gpio_a": 17, "gpio_b": 27, "control": "Analog CH1 Mic Gain Volume", "label": "XLR1"},
    2: {"gpio_a": 22, "gpio_b": 23, "control": "Analog CH2 Mic Gain Volume", "label": "XLR2"},
}

parser = argparse.ArgumentParser()
parser.add_argument("--ch", type=int, choices=[1, 2], default=1)
args = parser.parse_args()

ch = CHANNELS[args.ch]
GPIO_A   = ch["gpio_a"]
GPIO_B   = ch["gpio_b"]
CTRL     = ch["control"]
LABEL    = ch["label"]

def amixer(*a) -> str:
    try:
        r = subprocess.run(["amixer", "-c", ALSA_CARD] + list(a),
                           capture_output=True, text=True, timeout=5)
        return r.stdout
    except Exception as e:
        print(f"amixer error: {e}")
        return ""

def set_gain(db: int) -> int:
    db = max(GAIN_MIN, min(GAIN_MAX, db))
    amixer("cset", f'name="{CTRL}"', str(db))
    return db

current_gain = set_gain(20)
print(f"{LABEL} encoder test (GPIO{GPIO_A}/GPIO{GPIO_B}) — initial gain: {current_gain} dB")
print("CW to increase, CCW to decrease. Ctrl-C to quit.\n")

request = gpiod.request_lines(
    GPIO_CHIP,
    consumer=f"test-enc{args.ch}",
    config={
        (GPIO_A, GPIO_B): gpiod.LineSettings(
            direction=Direction.INPUT,
            bias=Bias.PULL_UP,
            edge_detection=Edge.BOTH,
        ),
    },
)

first_pin = None

try:
    while True:
        if not request.wait_edge_events(timeout=0.1):
            continue
        for ev in request.read_edge_events(max_events=16):
            pin = 'A' if ev.line_offset == GPIO_A else 'B'
            if first_pin is None:
                first_pin = pin
            elif first_pin != pin:
                direction = +1 if first_pin == 'B' else -1
                current_gain = set_gain(current_gain + direction)
                print(f"  {'▲' if direction > 0 else '▼'}  {LABEL} gain: {current_gain} dB")
                first_pin = None
except KeyboardInterrupt:
    print(f"\nDone. Final {LABEL} gain: {current_gain} dB")
finally:
    request.release()
