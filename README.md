# nixdesktop

The desktop **policy** and **shared-component** layer for a declarative Wayland desktop — which
roles a session wants filled (a bar, a file manager, a polkit agent, a notification daemon, ...),
plus the home-manager modules for the pieces that are the same regardless of which compositor is
running (a bar, a notifier, a lock screen, a systemd session-service layer). It does not ship a
compositor itself: the compositor's own config comes from a sibling repo — [nixniri][nixniri] for
niri, nixscroll for scroll, or any future compositor-module repo that speaks the same contract.
Distro-agnostic and compositor-agnostic: it generates config and declares roles, and installs
nothing.

## The split

Three layers, deliberately separated, because they have different portability:

**Compositor** (a sibling repo, not this one — [nixniri][nixniri] for niri, nixscroll for scroll,
...) — the compositor's own config: layout, binds, workspaces, and its own native startup
mechanism. This repo used to ship niri's config module (`home/niri.nix`); it has moved out to
nixniri so nixdesktop itself never has to know which compositor a consumer picked.

**Policy** (`profiles/desktop.nix`) — which roles a session wants filled, and by which
implementation — compositor-neutral itself: `compositor` is a free-form string option, not a
closed enum, so pairing this repo with a new compositor repo never requires editing this one.
Emits a read-only `nixdesktop.want` attrset. Names no package and no binary path.

**Shared config generation** (`home/*.nix`) — home-manager modules for the pieces every
compositor session needs alike: bar config, notification daemon config, lock-screen appearance,
and the systemd-service layer that turns all of it (plus whatever the compositor module starts)
into ordered, restartable services instead of fragile spawn-at-startup lines. `home/startup.nix`
is the one deliberate seam between this layer and the compositor layer — see
["The startup contract"](#the-startup-contract) below.

Neither the policy layer nor the shared-component layer installs software. That is a **platform
backend's** job: it reads `nixdesktop.want` (including the `compositor` role) and resolves it
into real packages for its platform. [nixarch][nixarch] ships the Arch/CachyOS backend; this
repo's own `nixosModules.backend` is the NixOS one.

**Layering, end to end:** a compositor repo (nixniri/nixscroll/...) and nixdesktop are siblings, both
consumed by a hub (a real host config), which also picks a platform backend to turn nixdesktop's
policy into installed packages:

```
compositor repo (nixniri / nixscroll / ...)  ─┐
                                                ├──▶ hub (a real host config)
nixdesktop (policy + shared components)       ─┘            │
                                                              ▼
                                              platform backend (this repo's `nixosModules.backend`,
                                              or nixarch's Arch/CachyOS backend)
```

The reason for the indirection is that package names are not portable (`thunar` on Arch,
`xfce.thunar` in nixpkgs) and binary paths are worse — mate-polkit's agent lives somewhere
different on nearly every distribution. A profile that emits package names is a profile that
works on exactly one distro — and one compositor's config module hardcoded into the policy layer
would be a profile that works with exactly one compositor.

```nix
# consumer (a hub), pairing nixdesktop with niri via nixniri, on NixOS
{
  imports = [
    inputs.nixniri.homeManagerModules.default        # or inputs.nixscroll's equivalent
    inputs.nixdesktop.homeManagerModules.session
    inputs.nixdesktop.homeManagerModules.waybar
    inputs.nixdesktop.nixosModules.desktop
    inputs.nixdesktop.nixosModules.backend
  ];

  nixdesktop.desktop = {
    enable = true;
    compositor = "niri";      # or "scroll" — must match whatever the compositor repo expects
    fileManager = "thunar";
    polkitAgent = "mate-polkit";
  };
  nixdesktop.nixosBackend.enable = true;
}
```

## Modules

| Module | Class | Owns |
|---|---|---|
| `desktop` | system-manager / NixOS | the role policy, including `compositor`; publishes `nixdesktop.want` |
| `backend` | NixOS | resolves `nixdesktop.want` into `environment.systemPackages` (this repo's NixOS backend; nixarch ships the Arch/CachyOS one) |
| `homeManagerModules.session` | home-manager | turns bar/notifier/osd/idle/polkit/keyring into systemd user services |
| `homeManagerModules.waybar` | home-manager | bar config + style |
| `homeManagerModules.mako` | home-manager | notification daemon config |
| `homeManagerModules.swaylock` | home-manager | lock screen appearance |
| `homeManagerModules.nwgBar` | home-manager | power menu |
| `homeManagerModules.eww` | home-manager | widget toolkit scaffolding |
| `homeManagerModules.noctalia` | home-manager | supplement to noctalia's own upstream module (see below) |
| `homeManagerModules.startup` | home-manager | the `nixdesktop.startup` contract — see below |

There is no `homeManagerModules.default`. Before the niri module moved out to nixniri, `default`
pointed at it, as "the module this project exists for." That framing no longer holds: every
module above is an independent, separately opt-in component, and none of them is the obvious
thing every consumer wants — picking one anyway would misrepresent it as this repo's primary
artifact. Import the ones you actually want by name.

## The startup contract

Nothing in this repo spawns anything at session start on its own — that would require knowing a
compositor's own startup syntax, which is exactly the coupling this repo avoids. Instead,
`nixdesktop.startup` (`home/startup.nix`, also exported standalone as `homeManagerModules.startup`
for a compositor module to depend on alone) is a plain list of raw shell-command strings that any
nixdesktop module can append to when it needs something running at session start —
`homeManagerModules.noctalia` is the one example today. A compositor module is expected to read
`config.nixdesktop.startup` and wrap each entry in its own native startup syntax (niri's
`spawn-sh-at-startup "<command>"` form, scroll's equivalent, ...). nixdesktop never assumes which
syntax that is; the list holds plain commands so the same list works unmodified no matter which
compositor module ends up consuming it.

## Defaults are evidence, not taste

Every default is the CPU-rendered option in its category. GPU scene-graph toolkits (GTK4/GSK,
Qt Quick/QML) and compositor effects layers cost real, permanent VRAM for work CPU-side toolkits
do for free — measured at ~860–930 MB versus ~83–131 MB for an equivalent stack doing the
identical job. That matters on any machine whose GPU memory is shared with real work, and it
holds regardless of which compositor fills the `compositor` role.

Two defaults cut against the obvious pick as a result:

- **`fileManager = "thunar"`**, not nautilus — Thunar is GTK3, Nautilus is GTK4.
- **`polkitAgent = "mate-polkit"`**, not polkit-kde-agent — niri's own wiki suggests the latter,
  but it is Qt6/QML and drags a KDE Frameworks stack onto an otherwise-GTK box.

Full method, numbers and the measurement trap that invalidated the first run:
[`studies/rendering-cost.md`](studies/rendering-cost.md).

This is emphatically not a claim that GPU rendering is disqualifying — only that the cost is real
and worth knowing. Every one of these is a plain option so the trade stays yours.

## Sharp edges worth knowing before you hit them

- **A missing polkit agent fails silently.** Many Wayland compositors (niri among them) do not
  process XDG autostart, so an agent needs an explicit spawn — that is the compositor module's
  job (nixniri's own polkit wiring, for instance), not nixdesktop's; nixdesktop only declares the
  `polkitAgent` role, and a platform backend resolves it to a real binary path
  (`modules/nixos-backend.nix` via `lib/nixos-roles.nix`'s `polkitAgents.<name>.command`).
- **Polkit refuses to register an agent from a seatless session.** A compositor started as a bare
  systemd `--user` unit has no logind seat, and *every* agent then fails identically. Fix the
  session's seat, not the agent.
- **Two secret-service providers will race.** Only ever run one; the symptom is applications
  intermittently losing stored secrets.
- **A notification daemon left installed can still win the D-Bus name** via its own
  service-activation file, even if never spawned. To hand notifications to a full shell, set
  `notifications = null` — do not merely stop spawning it.

## noctalia

`homeManagerModules.noctalia` is a **supplement**, not a replacement for noctalia's own module — it adds
the EGL-vendor-ICD fix a nix-built GPU client needs on a non-NixOS host, plus startup wiring (via
the startup contract above, not a compositor-specific option). noctalia is deliberately *not* a
flake input here: inputs are fetched on every evaluation, so declaring it would put a QML shell in
the closure of every consumer, including the majority running waybar. Add it as your own input and
import both:

```nix
imports = [ inputs.noctalia.homeModules.default inputs.nixdesktop.homeManagerModules.noctalia ];
```

## Status

Early. Originally extracted from [nixarch][nixarch], where these modules grew before this repo
split off — nixarch's remit is making an Arch box Nix-manageable, and a Wayland desktop is a
different domain that happens to have started life there. The niri-specific piece that lived here
(`home/niri.nix`) has itself since moved out again, to [nixniri][nixniri], so nixdesktop could
become genuinely compositor-neutral — usable by nixniri, nixscroll, or a compositor that doesn't
exist yet. The option surface will keep moving as the desktop does; there are no compatibility
shims at this stage.

[nixarch]: https://github.com/julian-corbet/nixarch-corbet-ch
[nixniri]: https://github.com/julian-corbet/nixniri-corbet-ch

## License

MIT
