# nixdesktop

A declarative Wayland desktop — niri, a bar, a notifier, a locker — as home-manager modules plus
a platform-neutral policy profile. Distro-agnostic: it generates config and declares roles, and
installs nothing.

## The split

Two halves, deliberately separated, because they have different portability:

**Policy** (`profiles/niri-desktop.nix`) — which roles a session wants filled, and by which
implementation. Emits a read-only `nixdesktop.want` attrset. Names no package and no binary path.

**Config generation** (`home/*.nix`) — home-manager modules writing real dotfiles
(`~/.config/niri/config.kdl` and friends) from structured options instead of hand-edited KDL.

Neither installs software. That is a **platform backend's** job: it reads `nixdesktop.want` and
resolves roles into real packages for its platform. [nixarch][nixarch] ships the Arch/CachyOS
backend; a NixOS backend is purely additive and needs no change here.

The reason for the indirection is that package names are not portable (`thunar` on Arch,
`xfce.thunar` in nixpkgs) and binary paths are worse — mate-polkit's agent lives somewhere
different on nearly every distribution. A profile that emits package names is a profile that
works on exactly one distro.

```nix
# consumer, on Arch, via nixarch's backend
nixdesktop.niriDesktop = {
  enable = true;
  fileManager = "thunar";
  polkitAgent = "mate-polkit";
};
```

## Modules

| Module | Class | Owns |
|---|---|---|
| `niri-desktop` | system-manager / NixOS | the role policy; publishes `nixdesktop.want` |
| `homeManagerModules.niri` | home-manager | `~/.config/niri/config.kdl` — layout, binds, workspaces, idle/lock, startup |
| `homeManagerModules.waybar` | home-manager | bar config + style |
| `homeManagerModules.mako` | home-manager | notification daemon config |
| `homeManagerModules.swaylock` | home-manager | lock screen appearance |
| `homeManagerModules.nwgBar` | home-manager | power menu |
| `homeManagerModules.eww` | home-manager | widget toolkit scaffolding |
| `homeManagerModules.noctalia` | home-manager | supplement to noctalia's own upstream module (see below) |

## Defaults are evidence, not taste

Every default is the CPU-rendered option in its category. GPU scene-graph toolkits (GTK4/GSK,
Qt Quick/QML) and compositor effects layers cost real, permanent VRAM for work CPU-side toolkits
do for free — measured at ~860–930 MB versus ~83–131 MB for an equivalent stack doing the
identical job. That matters on any machine whose GPU memory is shared with real work.

Two defaults cut against the obvious pick as a result:

- **`fileManager = "thunar"`**, not nautilus — Thunar is GTK3, Nautilus is GTK4.
- **`polkitAgent = "mate-polkit"`**, not polkit-kde-agent — niri's own wiki suggests the latter,
  but it is Qt6/QML and drags a KDE Frameworks stack onto an otherwise-GTK box.

Full method, numbers and the measurement trap that invalidated the first run:
[`studies/rendering-cost.md`](studies/rendering-cost.md).

This is emphatically not a claim that GPU rendering is disqualifying — only that the cost is real
and worth knowing. Every one of these is a plain option so the trade stays yours.

## Sharp edges worth knowing before you hit them

- **A missing polkit agent fails silently.** niri does not process XDG autostart, so an agent
  needs an explicit spawn. Without one, every privileged GUI prompt simply never appears —
  nothing is logged. `polkitAgentCommand` exists as a first-class option for this reason.
- **Polkit refuses to register an agent from a seatless session.** A niri started as a bare
  systemd `--user` unit has no logind seat, and *every* agent then fails identically. Fix the
  session's seat, not the agent.
- **Two secret-service providers will race.** Only ever run one; the symptom is applications
  intermittently losing stored secrets.
- **A notification daemon left installed can still win the D-Bus name** via its own
  service-activation file, even if never spawned. To hand notifications to a full shell, set
  `notifications = null` — do not merely stop spawning it.

## noctalia

`homeManagerModules.noctalia` is a **supplement**, not a replacement for noctalia's own module — it adds
the EGL-vendor-ICD fix a nix-built GPU client needs on a non-NixOS host, plus startup wiring.
noctalia is deliberately *not* a flake input here: inputs are fetched on every evaluation, so
declaring it would put a QML shell in the closure of every consumer, including the majority
running waybar. Add it as your own input and import both:

```nix
imports = [ inputs.noctalia.homeModules.default inputs.nixdesktop.homeManagerModules.noctalia ];
```

## Status

Early. Extracted from [nixarch][nixarch], where these modules originally grew — nixarch's remit
is making an Arch box Nix-manageable, and a Wayland desktop is a different domain that happens to
have started life there. The option surface will move as the desktop does; there are no
compatibility shims at this stage.

[nixarch]: https://github.com/julian-corbet/nixarch-corbet-ch

## License

MIT
