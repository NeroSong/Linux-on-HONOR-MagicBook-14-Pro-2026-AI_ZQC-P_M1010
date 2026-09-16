#!/usr/bin/env bash
# install.sh — rebuild xe.ko so the driver reaches for DSC instead of driving
# the internal panel below 8 bits per colour.
#
# intel_dp_compute_link_config_wide() is allowed to give up colour depth to
# make a mode fit, down to 6 bpc for RGB, and compression is only considered
# after that search fails. On this machine the search does not fail: the panel
# is 3120x2080 at 120 Hz, its DPCD offers no link rate above HBR2, and 6 bpc
# with dithering is the best that fits uncompressed. The panel supports DSC,
# the firmware does not forbid it, and nothing ever asks. See README.md.
#
# The module is shared with the other xe fixes in this repository, so the
# actual build lives in lib/xe-build.sh and always carries the full set.
#
# Env knobs are the builder's: KVER, JOBS, WORKDIR, KEEP_SRC, REGEN, FORCE.

set -euo pipefail

if (( EUID != 0 )); then
    echo "Must be run as root. Use: sudo bash $0" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m==>\033[0m %s\n' "$*" >&2; }

# Tier A: nothing here comes out of the profile. The patch either applies to
# the kernel source or it does not, and whether it changes anything at run time
# is decided by the driver from the link and the panel, on every modeset.
source "${SCRIPT_DIR}/../../lib/gate.sh"
honor_gate edp-dsc

# Every fix is looked up the same way, including the ones that carry no
# numbers of their own: patch/edp-dsc/<model>/<board>/ records that this
# machine was considered and on what evidence. See lib/variant.sh.
variant_find "$SCRIPT_DIR" || die \
    "this fix has nothing for $(profile_get model) board ${PROFILE_BOARD:-?}.
    Covered: $(variant_known "$SCRIPT_DIR")"
log "machine: $(variant_note)"

# --- what is the panel doing right now? ---------------------------------------
# Informational rather than a gate. The patch is conditional in the driver: on
# a machine whose link already carries 8 bpc it simply never fires, so there is
# no case where installing it is wrong but building it would be skipped.
found=0
for f in /sys/kernel/debug/dri/*/i915_display_info; do
    [[ -r "$f" ]] || continue
    line=$(grep -m1 -E 'pipe src=.*bpp=' "$f" || true)
    [[ -n "$line" ]] || continue
    found=1
    bpp=$(sed -n 's/.*bpp=\([0-9]*\).*/\1/p' <<<"$line")
    if [[ -n "$bpp" ]] && (( bpp < 24 )); then
        log "the pipe is at ${bpp} bpp, $((bpp / 3)) bits per colour:"
        echo "    ${line#"${line%%pipe*}"}"
    else
        log "the pipe is at ${bpp:-?} bpp, which is already 8 bits per colour or better."
        echo "    Installing anyway: the change only fires when the link forces"
        echo "    the pipe below 8 bpc, so it costs nothing here."
    fi
    break
done
(( found )) || warn "cannot read i915_display_info, so the current colour depth is
    unknown. Continuing: the change is conditional inside the driver."

# --- build --------------------------------------------------------------------
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../../lib/xe-build.sh"
xe_build_install edp-dsc

cat <<EOT

Reboot, then check:

    sudo grep -E 'pipe src=' /sys/kernel/debug/dri/*/i915_display_info
        expect: DSC enabled, dither=no, bpp=24 or 30 depending on the requested depth

    sudo grep DSC_Enabled /sys/kernel/debug/dri/*/eDP-1/i915_dsc_fec_support
        expect: yes

If the panel comes up wrong, boot the other kernel entry in your bootloader:
the module overlay is per kernel version, so a second installed kernel is
unaffected by this. uninstall_patch.sh removes the overlay.
EOT
