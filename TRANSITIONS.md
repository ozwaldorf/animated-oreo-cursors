# Animated Oreo proof of concept

Transition extension added 2026-10-08.

This fork adds 19 reversible, one-shot transitions to Oreo Spark Black
Bordered:

- Default to pointer, text, crosshair, grab, grabbing, progress, and wait.
- Default to horizontal, vertical, both diagonal, and column resize.
- Pointer to text; grab to grabbing.
- Grabbing to copy, not-allowed, and no-drop.
- Text to vertical-text; zoom-in to zoom-out.

Resize direction aliases and move/all-resize share transition files through
symlinks, covering 38 named pairs. Each file handles both directions; reverse
files are unnecessary.
`default` is the arrow/droplet; `pointer` is the link hand. The existing theme
and aliases remain intact. The generated theme is named
`animated_oreo_spark_black_bordered_cursors`.

## Build
Build tools are Ruby (REXML and Minitest), Inkscape, ImageMagick, and xcursorgen.

```sh
nix build
nix build .#niri --out-link result-niri
```

The theme is under `result/share/icons`; the standalone patched compositor is
`result-niri/bin/niri`. The theme build reuses the pinned upstream
Oreo package for ordinary cursors and generates transition files from the
matching SVG sources. It validates their sizes, frame counts, hotspots, and
frame delays. The generator currently targets the black, white-bordered variant.

To generate local assets and a preview, use a fresh output directory:

```sh
nix develop
ruby generator/transitions.rb \
  --base-theme /path/to/oreo_spark_black_bordered_cursors \
  --output build/animated_oreo_spark_black_bordered_cursors \
  --preview build/preview
ruby tests/test_transitions.rb
```

Each transition has 24 frames at 5 ms per frame (120 ms total), at nominal
sizes 24, 32, 40, 48, 56, and 64. The canvas is twice the nominal size to leave
room around a fixed hotspot. Frames use 256 evenly spaced outline points with
cyclic correspondence, eased point interpolation, and a smooth quadratic outline.
Disconnected outlines and holes grow or shrink continuously. Detail layers
such as resize arrows and drag badges fade and move with the interpolated body.
Shadows are reconstructed between the original endpoint images. The GIF previews
play slower than the cursors.

## Niri

Apply `patches/niri-cursor-transitions.patch` to Niri 26.04. There is no new configuration syntax, manifest, or Wayland protocol.
Install the theme using Home Manager's `home.pointerCursor.package` and set
`home.pointerCursor.name` to `animated_oreo_spark_black_bordered_cursors`.
Niri's `xcursor-theme` should use that same name.

For an isolated nested session, after building the theme and patched Niri:

```sh
XCURSOR_PATH="$PWD/result/share/icons" "$PWD/result-niri/bin/niri" \
  --config /path/to/test-config.kdl
```

The test configuration should contain:

```kdl
cursor {
    xcursor-theme "animated_oreo_spark_black_bordered_cursors"
    xcursor-size 24
}
```

Applications must request named cursors using Wayland's cursor-shape protocol.
Custom cursor surfaces, including those supplied by some toolkits or XWayland
clients, keep their ordinary behavior. This does not infer shapes from pixels.

## Naming and playback contract

Place an ordinary animated Xcursor file at `cursors/<from>-to-<to>` using
Wayland cursor-shape names. Both directions use the same file. If both names
exist, Niri prefers the spelling whose source name sorts first lexically.
No reverse symlink is needed. Each frame must have a positive delay; empty,
single-frame, zero-delay, or unreadable transition files are ignored.

A shape change plays the transition once and then displays the normal target
cursor, including its regular looping animation if it has one. A completed
transition starts that loop at its first frame. Busy transitions use the first
spinner frame as their endpoint; leaving an already spinning cursor can reset
its phase when the morph starts. Repeating a
request does not restart playback. Requesting the source shape reverses from
the current progress. Requesting a third shape cancels and switches immediately.
Hiding the pointer or supplying a cursor surface also cancels immediately.
Theme reload clears transitions and caches. Missing pairs switch immediately.

Mouse movement and clicks are never delayed. Hotspots remain anchored to the
actual pointer position. Use identical timing across sizes; Niri uses the
base-size animation duration and maps its progress to each output's frames.

Centered shapes use top-aligned hotspots: text, vertical-text, resize cursors,
grab, grabbing/move, wait, not-allowed, crosshair, and zoom cursors. Their
horizontal hotspot stays unchanged. The top is the first pixel row with at
least half opacity, excluding the faint shadow. All frames of a looping cursor
share the same hotspot. Normal cursor files, their aliases, and transition
endpoints use this same anchor, so finishing a morph does not reset its placement.
The click point for these shapes is now at their top rather than their center.
Arrow, pointing-hand, progress, copy, and no-drop cursors retain their usual hotspots.

## Tests

The Niri patch includes cursor unit tests. In a Niri build environment:

```sh
cargo test --lib cursor::tests
```

The patch changes Xcursor frame selection to group by nominal size rather than
pixel dimensions, allowing padded transition canvases and different frame
bounds without mixing size variants.

This is an experimental theme extension. Unpatched compositors ignore the
extra filenames and use the normal Oreo cursors.
