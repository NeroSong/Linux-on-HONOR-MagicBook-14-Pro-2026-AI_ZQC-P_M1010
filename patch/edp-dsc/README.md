# The panel is driven at 6 bits per colour

> Local Omarchy note (2026-09-16): install.sh now routes Omarchy to an
> exact-source DSC-only builder. A source/configuration mismatch or a native
> baseline code mismatch refuses installation; there is no vanilla fallback.
> The tested 7.2.5-3 build enables DSC and 8 bpc without dithering. External
> display reconnection after sleep still fails; its cause is not established.
> The local patch restores the complete DSC state and FEC flag on fallback.

| | |
|---|---|
| Symptom | banding and dither noise on flat areas and gradients; the pipe reports `bpp=18, dither=yes` on a 10-bit OLED |
| Cause | the link cannot carry 8 bpc at this mode, and the driver is allowed to drop colour depth to make a mode fit before it will consider compression |
| Fix | a kernel patch: on eDP, prefer DSC over going below 8 bpc, and fall back to the old behaviour if DSC does not compute |
| Needs | an `xe.ko` rebuild and a reboot |

## What the driver is doing

With `drm.debug=0x04` set across a modeset:

```
[CONNECTOR:512:eDP-1] Limiting target display pipe bpp to 30
    (EDID bpp 30, max requested bpp 36, max platform bpp 36)
[ENCODER:511:DDI A/PHY A][CRTC:151:pipe A] DP link limits: pixel clock 900864 kHz
    DSC off max lanes 4 max rate 540000 max pipe_bpp 30
    min link_bpp 18.0000 max link_bpp 30.0000
DP lane count 4 clock 540000 bpp input 18 compressed 0.0000 HDR no
    link rate required 2026944 available 2160000
[CRTC:151:pipe A] hw max bpp: 30, pipe bpp: 18, dithering: 1
```

The ceiling is not the panel. It declares 10 bits per colour in its EDID and
the platform would go to 12. It is the link: four lanes of HBR2 leave 2160000,
18 bpp costs 2026944 and 24 bpp would cost 2702592. So the search settles on
18 bpp, which is 6 bits per colour, and turns dithering on to hide it.

There is no `Try DSC` line anywhere in that log, because compression is only
reached when the uncompressed search *fails*:

```c
	dsc_needed = joiner_needs_dsc || intel_dp->force_dsc_en ||
		     !intel_dp_compute_config_limits(...);

	if (!dsc_needed) {
		ret = intel_dp_compute_link_config_wide(...);
		...
		if (ret || !intel_dp_dotclk_valid(...))
			dsc_needed = true;
	}
```

and it does not fail, because `intel_dp_min_bpp()` lets it go to 6 bpc for RGB:

```c
static int intel_dp_min_bpp(enum intel_output_format output_format)
{
	if (output_format == INTEL_OUTPUT_FORMAT_RGB)
		return 6 * 3;
	else
		return 8 * 3;
}
```

Dithering down to 6 bpc is deliberate and it is old. It arrived as
[Dither down to 6bpc if it makes the mode fit](https://patchwork.kernel.org/project/intel-gfx/patch/1311174531-23070-1-git-send-email-ajax@redhat.com/)
in 2011, when the alternative was no picture at all. On a panel that can also
decompress, the alternative is no longer that.

## No faster link exists

Asked of the panel directly, over the eDP AUX channel at `/dev/drm_dp_aux0`:

```
DPCD 0x000 DPCD_REV       0x14  ->  DP 1.4
DPCD 0x001 MAX_LINK_RATE  0x14  ->  5.4 Gbps
DPCD 0x002 MAX_LANE_COUNT 0x84  ->  4 lanes, enhanced framing, no TPS3
DPCD 0x010 eDP SUPPORTED_LINK_RATES, 16-bit LE, 200 kHz units:
           13500 -> 2.70 Gbps      27000 -> 5.40 Gbps      (the rest zero)
```

Two rates and the faster is HBR2. There is no HBR3 here, so 17.28 Gbit/s of
payload is the hard ceiling and nothing reaches 8 bpc uncompressed at this
pixel clock.

The 60 Hz mode looks like it should help and does not. It is the same pixel
clock with the vertical blanking doubled, `vtotal` 2208 becomes 4416 while
`clock` stays 900864, so the link carries the same load and the pipe stays at
18 bpp. Measured, not assumed.

## DSC works here

Forced on through `i915_dsc_fec_support` and committed with a real modeset, at
the 120 Hz mode actually in use:

| | stock | DSC |
|---|---|---|
| pipe bpp | 18, six per colour | **30, ten per colour** |
| dithering | yes | **no** |
| link rate required | 2026944 of 2160000 | **900864 of 2160000** |

```
DP DSC computed with Input Bpp = 30 Compressed Bpp = 8.0000 Slice Count = 4
```

4 slices of 780x130, block prediction on, line buffer 11 bits, RGB. Read back
from the panel while compression was live:

```
DPCD 0x202/0x203  LANE0..3  CR=1 EQ=1 SYM_LOCK=1 on all four lanes
DPCD 0x204                  INTERLANE_ALIGN_DONE=1
DPCD 0x210..0x216           SYMBOL_ERROR_COUNT = 0 on all four lanes
```

and checked by eye: no artefacts, no flicker, correct colours.

The firmware permits it. `edp_dsc_disable` in VBT block 27 (`BDB_EDP`) reads
`0x0000`; in fact every byte of the block from offset 740 onward is zero, so
whichever offset that field really sits at, it is not set. Panel type is 2,
read from block 40, which agrees with what
[`patch/oled-backlight/`](../oled-backlight/) measured independently.

## The patch

[`0001-drm-i915-dp-prefer-DSC-over-driving-eDP-below-8-bpc.patch`](0001-drm-i915-dp-prefer-DSC-over-driving-eDP-below-8-bpc.patch),
against `intel_dp_compute_link_for_joined_pipes()`.

After the uncompressed pass succeeds, it notes the case where the result is
below 8 bpc while the panel would take more:

```c
		else if (intel_dp_is_edp(intel_dp) &&
			 pipe_config->pipe_bpp < 8 * 3 &&
			 pipe_config->pipe_bpp < limits.pipe.max_bpp &&
			 intel_dp_supports_dsc(intel_dp, connector, pipe_config)) {
```

and then runs the DSC path for that case as well. Three properties are
deliberate:

* **It cannot turn a working mode into a rejected one.** DSC here is a
  preference, not a requirement. The uncompressed `pipe_bpp`, `port_clock` and
  `lane_count` are kept, and if anything in the DSC pass fails they are put
  back and the modeset proceeds exactly as before. The `return`s in that block
  became a single failure path that distinguishes the two cases.
* **It does not fire when there is nothing to gain.** The
  `pipe_bpp < limits.pipe.max_bpp` term means a genuine 6 bpc panel, where the
  driver picked 18 bpp because that is all the panel has, is left alone.
* **eDP only.** On an external DP link, a link that cannot carry 8 bpc is far
  more often a bad cable than a design, and quietly compressing to hide it
  would be the wrong answer.
* **The DSC pass gets the original depth back, not the reduced one.** This one
  is easy to miss and it cost a reboot to find. `intel_dp_compute_config_limits()`
  derives the DSC input depth from whatever is in the crtc state:

  ```c
	limits->pipe.max_bpp = clamp(crtc_state->pipe_bpp,
				     limits->pipe.min_bpp, limits->pipe.max_bpp);
  ```

  When compression is *required* that is still the depth the modeset arrived
  with. When it is only *preferred*, the uncompressed search has already
  written 18 there, and the DSC minimum is 24, so the clamp yields 24 and the
  panel ends up at 8 bits per colour rather than the 10 it is capable of.
  Measured exactly that way on the first attempt here. The patch saves the
  entry value and restores it before computing the DSC limits.

## Installing

```sh
sudo bash patch/edp-dsc/install.sh
sudo reboot
```

or through `apply_patch.sh`, which runs it where the profile lists it.
`SKIP_DSC=1` leaves it out, for the same reason `SKIP_CDCLK=1` exists: the
build downloads the distribution's kernel source, about 260 MB, and compiles
for a few minutes.

Both patches live inside the same `xe.ko`, so the build itself is in
[`lib/xe-build.sh`](../../lib/xe-build.sh) and always carries every patch that
applies to the machine. Running one installer does not silently drop the
other's change, and running the second one finds the work already done. What
went into the module is recorded in `/var/lib/honor/xe-module.stamp`.

## Verifying after reboot

```sh
sudo grep -E 'pipe src=' /sys/kernel/debug/dri/*/i915_display_info
    expect: dither=no, bpp=24 or 30, depending on the requested depth.
    The local Omarchy desktop uses XRGB8888 and has been measured at 24 bpp.
    24 bpp alone is not evidence that the original-baseline restoration failed.

sudo grep DSC_Enabled /sys/kernel/debug/dri/*/eDP-1/i915_dsc_fec_support
    expect: yes

cat /var/lib/honor/xe-module.stamp
```

With `drm.debug=0x04` the decision is visible directly:

```
Try DSC (fallback=no, joiner=no, force=no, preferred=yes)
DP DSC computed with Input Bpp = 30 Compressed Bpp = 8.0000 Slice Count = 4
```

`preferred=yes` is this patch. `fallback=yes` would mean the mode did not fit
at all and compression was required, which is the behaviour that was already
there.

## If it goes wrong

The module overlay is per kernel version, under
`/usr/lib/modules/$(uname -r)/updates/`. A second installed kernel is
untouched, so booting the other entry in the bootloader gives a working
display. `uninstall_patch.sh` removes the overlay; so does deleting that one
file and running `depmod`.

## What is not known

**Suspend and resume with compression live has not been tested.** Nor has
external-display hotplug while the internal panel is compressed.

**Power.** DSC halves the link load, which should help, and it runs the VDSC
engine, which costs. Neither has been measured here, so no claim is made.

**Interaction with PSR2.** Under DSC the selective update region has to align
to the DSC slice height rather than the panel's own granularity, 130 lines
instead of a handful, which would make
[the band](../psr-band/) taller rather than smaller. That is moot while PSR is
held at PSR1 by [`patch/psr-band/`](../psr-band/), which this machine needs
anyway.

## Sending it upstream

The patch is written to be sendable: it is against current `intel_dp.c`, it
carries its reasoning, and it is not conditioned on any DMI match. It has not
been sent. Doing so properly means testing it on a machine whose link *can*
carry 8 bpc, to show the preference does not fire there, and on one where DSC
fails, to show the fallback works. Neither of those machines is here.
