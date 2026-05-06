#!/bin/bash
# Sweeps sample rates AND bit depths on the LotusWorks ADC6120 HAT.
# Records 5s per (rate, depth) combo, then verifies each WAV matches the
# requested parameters and reports peak level.
#
# Supported rate ceiling is 192 kHz — the RP1 cannot cleanly synthesize the
# 24.576 MHz BCLK required for 384 kHz without an external oscillator.

DEVICE="hw:LotusWorksADC61"
DURATION=2
RATES=(8000 16000 32000 44100 48000 88200 96000 176400 192000)
# Fields: ALSA_FMT:label:soxi_prec
# Fields: ALSA_FMT:label:soxi_prec
# S24_LE is broken on the RP1 I2S: the controller zero-fills bits [31:24]
# instead of sign-extending, flipping negative samples to large positive values
# (half-wave rectification distortion). Use S32_LE for capture.
# Packed 3-byte formats (S20_3LE, S24_3LE) are rejected by the RP1 at hw_params.
DEPTHS=(
    "S16_LE:16:16"
    "S32_LE:32:32"
)

OUTDIR="./lw_rate_sweep"
rm -rf "$OUTDIR"
mkdir -p "$OUTDIR"

# Release the device from the HAT control daemon for the duration of the sweep
sudo systemctl stop lw-adc-hat-ctrl 2>/dev/null
trap 'sudo systemctl start lw-adc-hat-ctrl 2>/dev/null' EXIT

# Set baseline gain and ensure routing is correct for balanced XLR inputs.
# We force both to 'Differential' and ensure they are mapped to the I2S slots (ASI).
CARD_NAME="${DEVICE#hw:}"

# 1. Set Input Routing to Differential for XLR
amixer -c "$CARD_NAME" cset name="CH1_INP_SEL" "Differential" >/dev/null 2>&1
amixer -c "$CARD_NAME" cset name="CH2_INP_SEL" "Differential" >/dev/null 2>&1

# 2. Ensure both channels are enabled on the I2S bus
amixer -c "$CARD_NAME" cset name="CH1_ASI_EN" "On" >/dev/null 2>&1
amixer -c "$CARD_NAME" cset name="CH2_ASI_EN" "On" >/dev/null 2>&1

# 3. Set analog gain (32dB)
amixer -c "$CARD_NAME" cset name="Analog CH1 Mic Gain Volume" 32 >/dev/null 2>&1
amixer -c "$CARD_NAME" cset name="Analog CH2 Mic Gain Volume" 32 >/dev/null 2>&1

pass=()
fail=()
mismatch=()

echo "── Capture sweep ────────────────────────"
for depth_spec in "${DEPTHS[@]}"; do
    fmt="${depth_spec%%:*}"
    bits=$(echo "$depth_spec" | cut -d: -f2)
    for rate in "${RATES[@]}"; do
        outfile="${OUTDIR}/lw_${rate}_${bits}b.wav"
        printf "  %6d Hz  %2d-bit (%-8s) ... " "$rate" "$bits" "$fmt"

        if arecord -D "$DEVICE" -c 2 -f "$fmt" -r "$rate" -d "$DURATION" \
                "$outfile" >/dev/null 2>&1; then
            peak=$(sox "$outfile" -n stat 2>&1 \
                   | awk '/Maximum amplitude/ {printf "%.4f", $3}')
            echo "PASS  peak=${peak}"
            pass+=("${rate}@${bits}")
        else
            echo "FAIL"
            fail+=("${rate}@${bits}")
            rm -f "$outfile"
        fi
    done
done

echo ""
echo "── File parameter verification ──────────"
# Verify each PASS file has the expected rate / bit-depth / channel count
for depth_spec in "${DEPTHS[@]}"; do
    bits=$(echo "$depth_spec" | cut -d: -f2)
    soxi_prec=$(echo "$depth_spec" | cut -d: -f3)
    for rate in "${RATES[@]}"; do
        outfile="${OUTDIR}/lw_${rate}_${bits}b.wav"
        [ -f "$outfile" ] || continue

        info=$(soxi "$outfile" 2>/dev/null)
        actual_rate=$(echo "$info" | awk -F': *' '/Sample Rate/ {print $2}')
        actual_chan=$(echo "$info" | awk -F': *' '/Channels/    {print $2}')
        actual_prec=$(echo "$info" | awk -F': *' '/Precision/   {print $2}' \
                      | grep -oE '[0-9]+')

        ok=1
        [ "$actual_rate" = "$rate" ]       || ok=0
        [ "$actual_chan" = "2" ]           || ok=0
        [ "$actual_prec" = "$soxi_prec" ] || ok=0

        if [ "$ok" = "1" ]; then
            printf "  OK   %6d Hz  %2d-bit  2ch\n" "$rate" "$bits"
        else
            printf "  BAD  %6d Hz  %2d-bit  ->  rate=%s (exp %s)  prec=%s (exp %s)  ch=%s\n" \
                "$rate" "$bits" "$actual_rate" "$rate" "$actual_prec" "$soxi_prec" "$actual_chan"
            mismatch+=("${rate}@${bits}")
        fi
    done
done

echo ""
echo "── Results ──────────────────────────────"
echo "Captured OK : ${#pass[@]}    ${pass[*]:-none}"
echo "Capture FAIL: ${#fail[@]}    ${fail[*]:-none}"
echo "File MISMATCH: ${#mismatch[@]}    ${mismatch[*]:-none}"
echo ""
echo "Files in: ${OUTDIR}"
