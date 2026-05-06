#!/usr/bin/env python3
"""
lw_hat_ctrl.py — LotusWorks ADC6120 HAT Control Daemon

Reads two rotary encoders to adjust TLV320ADC6120 analog input gain
(channels 1 and 2) and drives clipping indicator LEDs.

Hardware connections (RPi5 expansion header):
  Encoder 1 (CH1): Pin 15 (GPIO22) + Pin 16 (GPIO23)
  Encoder 2 (CH2): Pin 11 (GPIO17) + Pin 13 (GPIO27)
  LED 1 (CH1 clip): Pin 29 (GPIO5)  — active low
  LED 2 (CH2 clip): Pin 37 (GPIO26) — active low
"""

import argparse
import logging
import os
import re
import select
import signal
import struct
import subprocess
import sys
import threading
import time

import gpiod
from gpiod.line import Bias, Direction, Edge, Value

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

GPIO_CHIP = "/dev/gpiochip0"          # RP1 on Pi 5

# Encoder GPIOs (BCM numbering)
ENC1_A, ENC1_B = 22, 23              # Encoder 1 — CH1 gain
ENC2_A, ENC2_B = 17, 27              # Encoder 2 — CH2 gain

# LED GPIOs (active-low: drive low = LED on)
LED1_GPIO = 5                         # CH1 clip indicator
LED2_GPIO = 26                        # CH2 clip indicator

# Gain range (TLV320ADC6120 analog PGA)
# Positive: 0 dB to +42 dB in 1 dB steps
# Negative: -1 dB to -11 dB in 1 dB steps (GAIN_SIGN bit set)
GAIN_MIN_DB = -11
GAIN_MAX_DB = 42
GAIN_STEP_DB = 1                      # dB change per encoder detent

# ALSA control names (from the tlv320adcx140 driver)
ALSA_CARD = "LotusWorksADC61"
ALSA_CH1_GAIN      = "Analog CH1 Mic Gain Volume"
ALSA_CH2_GAIN      = "Analog CH2 Mic Gain Volume"
ALSA_CH1_GAIN_SIGN = "Analog CH1 Gain Sign"
ALSA_CH2_GAIN_SIGN = "Analog CH2 Gain Sign"

# Clipping detection
# NOTE: clip detection holds the ALSA hw device open exclusively, preventing
# concurrent arecord use. Disabled by default; enable only if the audio
# device will not be used for recording while the daemon is running.
CLIP_DETECTION_ENABLED = False
CLIP_THRESHOLD = 0.98                 # fraction of full-scale (16-bit)
CLIP_HOLD_SEC = 0.5                   # how long LED stays on after clip
CLIP_POLL_FRAMES = 256                # frames per arecord read
CLIP_SAMPLE_RATE = 48000

LOG = logging.getLogger("lw-hat-ctrl")

# ---------------------------------------------------------------------------
# Encoder reader using gpiod v2 edge events
# ---------------------------------------------------------------------------

class EncoderReader:
    """Encoder decoder using gpiod v2 edge detection.

    Each detent click produces exactly one edge on each phase (sticky state).
    Direction is determined by which phase leads:
      B leads A → CW  (+1)
      A leads B → CCW (-1)
    """

    def __init__(self, chip_path: str, gpio_a: int, gpio_b: int,
                 callback, label: str = "encoder"):
        self._gpio_a = gpio_a
        self._gpio_b = gpio_b
        self._callback = callback
        self._label = label
        self._first_pin = None   # 'A' or 'B' — leading edge of current click
        self._running = False
        self._thread = None

        self._request = gpiod.request_lines(
            chip_path,
            consumer=f"lw-hat-{label}",
            config={
                (gpio_a, gpio_b): gpiod.LineSettings(
                    direction=Direction.INPUT,
                    bias=Bias.PULL_UP,
                    edge_detection=Edge.BOTH,
                ),
            },
        )

    def start(self):
        """Start background thread to process encoder events."""
        self._running = True
        self._thread = threading.Thread(target=self._poll_loop,
                                        daemon=True, name=self._label)
        self._thread.start()

    def stop(self):
        self._running = False
        if self._thread:
            self._thread.join(timeout=2)
        self._request.release()

    def _poll_loop(self):
        """Wait for edge events and decode direction from leading phase."""
        while self._running:
            if not self._request.wait_edge_events(timeout=0.1):
                continue
            for ev in self._request.read_edge_events(max_events=16):
                pin = 'A' if ev.line_offset == self._gpio_a else 'B'
                if self._first_pin is None:
                    self._first_pin = pin
                elif self._first_pin != pin:
                    # B led → CW (+1), A led → CCW (-1)
                    self._callback(+1 if self._first_pin == 'B' else -1)
                    self._first_pin = None


# ---------------------------------------------------------------------------
# Gain controller (wraps amixer)
# ---------------------------------------------------------------------------

class GainController:
    """Reads/writes analog gain via the ALSA amixer command.

    Supports the full TLV320ADC6120 analog gain range:
      -11 dB to 0 dB  (GAIN_SIGN=1, magnitude 11..1)
       0 dB to +42 dB (GAIN_SIGN=0, magnitude 0..42)

    The sign bit is kept in sync with the magnitude through ALSA controls
    so the kernel regmap cache stays coherent.
    """

    def __init__(self, card: str, control_name: str, sign_control_name: str,
                 channel_label: str):
        self.card = card
        self.control = control_name
        self.sign_control = sign_control_name
        self.label = channel_label
        self._current_db = self._read_gain_signed()
        self._setup_channel()
        LOG.info("%s: initial gain = %+d dB", self.label, self._current_db)

    # ---- public API ---------------------------------------------------------

    @property
    def gain_db(self) -> int:
        return self._current_db

    def adjust(self, direction: int) -> int:
        """Increment (+1) or decrement (-1) gain by GAIN_STEP_DB.
        Returns the new signed gain value in dB."""
        cur = self._current_db

        if cur == 0 and direction == -1:
            # Cross into negative territory: skip -0 dB, land on -1 dB.
            new = -1
        elif cur < 0 and direction == 1 and cur + GAIN_STEP_DB >= 0:
            # Cross back to positive: snap to 0 dB positive (clear sign bit).
            new = 0
        else:
            new = cur + direction * GAIN_STEP_DB
            new = max(GAIN_MIN_DB, min(GAIN_MAX_DB, new))

        if new != cur:
            self._write_gain_signed(new)
            self._current_db = new
            LOG.info("%s: gain → %+d dB", self.label, new)
        return self._current_db

    # ---- private helpers ----------------------------------------------------

    def _amixer(self, *args) -> str:
        cmd = ["amixer", "-c", self.card] + list(args)
        try:
            result = subprocess.run(cmd, capture_output=True, text=True,
                                    timeout=5)
            return result.stdout
        except (subprocess.SubprocessError, FileNotFoundError) as exc:
            LOG.warning("amixer failed: %s", exc)
            return ""

    def _amixer_get_int(self, control: str) -> int | None:
        out = self._amixer("cget", f'name="{control}"')
        # Integer controls:  ": values=12"
        # Boolean controls:  ": values=on" / ": values=off"
        m = re.search(r"^\s*:\s*values=(\w+)", out, re.MULTILINE)
        if not m:
            return None
        val = m.group(1)
        if val == "on":
            return 1
        if val == "off":
            return 0
        return int(val) if val.isdigit() else None

    def _setup_channel(self):
        ch_idx = "1" if "CH1" in self.control else "2"
        self._amixer("cset", f"name=\"CH{ch_idx}_ASI_EN Switch\"", "on")

    def _read_gain_signed(self) -> int:
        """Read current gain as a signed dB value from hardware."""
        magnitude = self._amixer_get_int(self.control)
        sign_val  = self._amixer_get_int(self.sign_control)
        if magnitude is None or sign_val is None:
            LOG.warning("%s: could not parse gain, defaulting to 0 dB", self.label)
            return 0
        # sign_val=1 means negative; magnitude=0 with sign=1 would be -0 dB
        # (ambiguous), so treat it as 0 dB positive.
        if sign_val == 1 and magnitude > 0:
            return -magnitude
        return magnitude

    def _write_gain_signed(self, db: int):
        """Write a signed dB value: set magnitude control then sign control."""
        if db < 0:
            self._amixer("cset", f'name="{self.control}"', str(abs(db)))
            self._amixer("cset", f'name="{self.sign_control}"', "on")
        else:
            # Clear sign before setting magnitude to avoid a momentary
            # negative-magnitude state in hardware.
            self._amixer("cset", f'name="{self.sign_control}"', "off")
            self._amixer("cset", f'name="{self.control}"', str(db))


# ---------------------------------------------------------------------------
# Clip detector (monitors ALSA capture levels and drives LEDs)
# ---------------------------------------------------------------------------

class ClipDetector:
    """Reads raw audio from ALSA capture and toggles LEDs on clipping."""

    def __init__(self, chip_path: str, led_gpios: list[int],
                 card: str, channels: int = 2):
        self.card = card
        self.channels = channels
        self._led_gpios = led_gpios
        self._clip_until = [0.0] * channels   # monotonic time LED should stay on

        # Request LED lines as outputs (default HIGH = LED off for active-low)
        self._led_request = gpiod.request_lines(
            chip_path,
            consumer="lw-hat-leds",
            config={
                tuple(led_gpios): gpiod.LineSettings(
                    direction=Direction.OUTPUT,
                    output_value=Value.ACTIVE,   # HIGH = LED off (active-low)
                ),
            },
        )
        self._running = False
        self._thread = None

    def start(self):
        self._running = True
        self._thread = threading.Thread(target=self._monitor_loop,
                                         daemon=True, name="clip-detect")
        self._thread.start()

    def stop(self):
        self._running = False
        if self._thread:
            self._thread.join(timeout=2)
        # Turn off both LEDs
        for gpio in self._led_gpios:
            self._led_request.set_value(gpio, Value.ACTIVE)   # HIGH = off
        self._led_request.release()

    def _monitor_loop(self):
        """Continuously read audio samples from ALSA and check for clipping."""
        cmd = [
            "arecord",
            "-D", f"hw:{self.card}",
            "-f", "S32_LE",
            "-c", str(self.channels),
            "-r", str(CLIP_SAMPLE_RATE),
            "--buffer-size", str(CLIP_POLL_FRAMES * 4),
            "-t", "raw",
            "-q",
            "-"
        ]

        while self._running:
            try:
                proc = subprocess.Popen(cmd, stdout=subprocess.PIPE,
                                        stderr=subprocess.DEVNULL)
            except FileNotFoundError:
                LOG.error("arecord not found — clip detection disabled")
                return

            bytes_per_frame = 4 * self.channels   # S32_LE = 4 bytes/sample
            chunk_bytes = CLIP_POLL_FRAMES * bytes_per_frame

            try:
                while self._running:
                    data = proc.stdout.read(chunk_bytes)
                    if not data:
                        break

                    now = time.monotonic()
                    n_samples = len(data) // 4
                    samples = struct.unpack(f"<{n_samples}i", data[:n_samples * 4])

                    # Check per-channel peaks
                    for ch in range(self.channels):
                        ch_samples = samples[ch::self.channels]
                        if not ch_samples:
                            continue
                        peak = max(abs(s) for s in ch_samples) / 2147483647.0
                        if peak >= CLIP_THRESHOLD:
                            LOG.info("CH%d clip detected: peak=%.3f", ch + 1, peak)
                            self._clip_until[ch] = now + CLIP_HOLD_SEC

                    # Update LEDs
                    for ch in range(self.channels):
                        led_on = now < self._clip_until[ch]
                        # Active-low: INACTIVE (low) = LED on
                        val = Value.INACTIVE if led_on else Value.ACTIVE
                        self._led_request.set_value(self._led_gpios[ch], val)

            except Exception as exc:
                LOG.warning("clip monitor error: %s", exc)
            finally:
                proc.terminate()
                proc.wait()

            if self._running:
                time.sleep(1)   # brief pause before reconnecting


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    global GAIN_STEP_DB
    parser = argparse.ArgumentParser(
        description="LotusWorks ADC6120 HAT encoder/LED control daemon",
    )
    parser.add_argument("-v", "--verbose", action="store_true",
                        help="Enable debug logging")
    parser.add_argument("--card", default=ALSA_CARD,
                        help=f"ALSA card name (default: {ALSA_CARD})")
    parser.add_argument("--no-clip", action="store_true",
                        default=not CLIP_DETECTION_ENABLED,
                        help="Disable clip detection / LEDs")
    parser.add_argument("--gain-step", type=int, default=GAIN_STEP_DB,
                        help="dB change per encoder detent (default: 1)")
    args = parser.parse_args()

    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(asctime)s  %(name)s  %(levelname)s  %(message)s",
    )

    GAIN_STEP_DB = args.gain_step

    LOG.info("Starting LotusWorks ADC6120 HAT control daemon")
    LOG.info("  Encoder 1 (CH1): GPIO%d + GPIO%d", ENC1_A, ENC1_B)
    LOG.info("  Encoder 2 (CH2): GPIO%d + GPIO%d", ENC2_A, ENC2_B)
    LOG.info("  LED 1: GPIO%d, LED 2: GPIO%d", LED1_GPIO, LED2_GPIO)
    LOG.info("  ALSA card: %s", args.card)

    # --- Gain controllers ---------------------------------------------------
    gain_ch1 = GainController(args.card, ALSA_CH1_GAIN, ALSA_CH1_GAIN_SIGN, "CH1")
    gain_ch2 = GainController(args.card, ALSA_CH2_GAIN, ALSA_CH2_GAIN_SIGN, "CH2")

    # --- Encoders -----------------------------------------------------------
    enc1 = EncoderReader(GPIO_CHIP, ENC1_A, ENC1_B,
                          callback=lambda d: gain_ch1.adjust(d),
                          label="enc1-ch1")
    enc2 = EncoderReader(GPIO_CHIP, ENC2_A, ENC2_B,
                          callback=lambda d: gain_ch2.adjust(d),
                          label="enc2-ch2")

    # --- Clip detector / LEDs -----------------------------------------------
    clip = None
    if not args.no_clip:
        clip = ClipDetector(GPIO_CHIP, [LED1_GPIO, LED2_GPIO],
                            card=args.card)

    # --- Start everything ---------------------------------------------------
    enc1.start()
    enc2.start()
    if clip:
        clip.start()

    # --- Wait for shutdown signal -------------------------------------------
    shutdown = threading.Event()

    def on_signal(signum, frame):
        LOG.info("Received signal %d, shutting down…", signum)
        shutdown.set()

    signal.signal(signal.SIGINT, on_signal)
    signal.signal(signal.SIGTERM, on_signal)

    LOG.info("Daemon running — turn encoders to adjust gain")
    shutdown.wait()

    # --- Cleanup ------------------------------------------------------------
    LOG.info("Shutting down…")
    enc1.stop()
    enc2.stop()
    if clip:
        clip.stop()
    LOG.info("Done.")


if __name__ == "__main__":
    main()
