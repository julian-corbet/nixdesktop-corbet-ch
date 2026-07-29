# The rendering-cost constraint

Every default in `profiles/desktop.nix` follows from one measured finding: **a Wayland
desktop component that drives a GPU scene graph costs real, permanent VRAM for work a CPU-side
toolkit does for free.**

This is not a micro-optimisation. It decides which components are viable on any machine whose
GPU memory is contended — an integrated GPU carving out of system RAM, or a discrete card that
also serves compute (ML inference, transcoding, game streaming). On such a machine the desktop
is competing with the actual workload for the same pool.

## The axis

| Side | Toolkits | Behaviour |
|---|---|---|
| CPU-rendered | GTK3 + Cairo/Pango, pixman, software renderers | Never opens a DRM fd. VRAM cost not measurable. |
| GPU-rendered | GTK4/GSK, Qt Quick/QML, wlroots effects layers (blur/shadow/corner-radius) | Opens a DRM fd, holds buffers, grows under load. |

The trap is that this is invisible from the outside. A GTK4 application and a GTK3 application
look identical in a README, describe themselves the same way, and often *are* the same program a
major version apart — while having structurally different rendering pipelines underneath.
"Lightweight" in a project's own marketing predicts nothing. The only reliable signals are build
dependencies (`meson.build`/`Cargo.toml`) and actual linkage (`ldd` showing `libvulkan`/`libEGL`/
`libgbm`).

## Method

- System total via `mem_info_vram_used`, per-process attribution via `fdinfo`'s
  `drm-memory-vram`.
- Idle and loaded (a browser plus a file manager open) for each candidate.
- Restart the compositor between candidates.

That last step is not hygiene, it is correctness. The first measurement run produced a ~518 MB
"bar baseline" that was almost entirely **stale compositor swapchain state** left over from an
earlier browser session — not the bar at all. Compositor swapchain growth persists across
application lifetimes and will silently contaminate any measurement taken after real use. Restart
the compositor, take the baseline, then swap one component.

## Results

Compositor plus shell, mastering a real display, doing the identical job:

| Stack | VRAM |
|---|---|
| Effects-capable compositor + QML shell | ~860–930 MB |
| niri + GTK3 bar | ~83–131 MB |

Reproduced 5+ times, restart-immune, and shell-independent: isolating the shell out of the
expensive combination made no difference to the compositor's own cost. Both halves of that stack
pay separately.

Individual components, measured as a delta against a clean baseline:

| Component | Rendering | Cost |
|---|---|---|
| GTK3 bar (waybar class) | CPU | not measurable — never opens a DRM fd |
| QML shell (noctalia class) | GPU | ~190 MB over the GTK3 bar, with or without apps open |
| GPU-accelerated terminal (kitty class) | GPU | ~110 MB |
| Software terminal (foot class) | CPU | ~19 MB |
| GTK4 launcher (walker class) | GPU | ~165 MB |
| Cairo/pixman launcher (rofi class) | CPU | ~41 MB |
| Minimal launcher (fuzzel class) | CPU | baseline |

## What this does and does not justify

It justifies the defaults: `foot`, `fuzzel`, `waybar`, `mako`, `thunar` (GTK3) over `nautilus`
(GTK4), `mate-polkit` (GTK3) over `polkit-kde-agent` (Qt6/QML).

It does **not** justify treating GPU rendering as disqualifying. The right reading is that the
cost is real, structural, and worth *knowing* — not that it is always unaffordable. On a machine
with a dedicated GPU and no compute contention, 190 MB for a materially nicer shell is a fine
trade. Every one of these is a plain option precisely so that trade stays the consumer's to make.

The two components where the measurement genuinely overturned the obvious choice are the ones
called out in the profile header: the GTK4 file manager most distributions ship by default, and
the polkit agent niri's own wiki recommends.
