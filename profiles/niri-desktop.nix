# profiles/niri-desktop.nix — the POLICY layer of a niri desktop: which roles the session wants
# filled, and by which implementation. This module installs nothing and names no package.
#
# WHY NO PACKAGES HERE. Package names are platform-specific (`thunar` on Arch, `xfce.thunar` in
# nixpkgs) and so are binary paths (mate-polkit's agent lives somewhere different on every
# distro). A profile that emits package names is a profile that only works on one distro. So this
# module emits ROLES — a read-only `nixdesktop.want` attrset — and a platform backend resolves
# them. nixarch ships the Arch/CachyOS backend; a NixOS backend is additive and needs no change
# here.
#
# THE DEFAULTS ARE NOT TASTE. Every default below is the CPU-rendered option in its category,
# because that is this project's one hard constraint (see studies/rendering-cost.md): a Wayland
# desktop component that opens a DRM fd and drives a GPU scene graph (GTK4/GSK, Qt Quick/QML)
# costs real, permanent VRAM for work a CPU-side toolkit does for free. Measured, not assumed —
# an effects-capable compositor plus a QML shell cost ~860-930MB VRAM mastering a display, versus
# ~83-131MB for niri plus a GTK3 bar doing the identical job. On a machine whose GPU memory is
# shared with real work (an iGPU carving out of system RAM, or a discrete card also serving
# compute), that difference is the whole budget.
#
# Consequences worth naming, since they cut against the obvious pick in two cases:
#   - fileManager defaults to thunar, not nautilus. Nautilus is GTK4; Thunar is GTK3+Cairo.
#   - polkitAgent defaults to mate-polkit, not polkit-kde-agent. niri's own wiki suggests the
#     latter, but it is Qt6+QML and drags a KDE Frameworks stack onto an otherwise-GTK box.
#     mate-polkit is GTK3 and confirmed to work standalone outside its parent DE.
# Both are plain options. A consumer who wants the heavier component sets it and moves on.
{ lib, config, ... }:
let
  cfg = config.nixdesktop.niriDesktop;
in
{
  options.nixdesktop.niriDesktop = {
    enable = lib.mkEnableOption
      "niri desktop policy (declare the roles a niri session needs; a platform backend installs them)";

    bar = lib.mkOption {
      type = lib.types.nullOr (lib.types.enum [ "waybar" "eww" "noctalia" ]);
      default = "waybar";
      description = ''
        Status bar, or null for none. `waybar` is GTK3/Cairo (CPU-only, has a real SNI tray).
        `eww` is GTK3 too but ships no bar — you build one from primitives. `noctalia` is a full
        QML shell: far more capable, and measurably more expensive in VRAM.
      '';
    };

    notifications = lib.mkOption {
      type = lib.types.nullOr (lib.types.enum [ "mako" ]);
      default = "mako";
      description = ''
        Notification daemon, or null when something else owns
        `org.freedesktop.Notifications` (a full shell like noctalia does). Deliberately
        independent of `bar`: the two are unrelated jobs, and a daemon left installed can still
        win the D-Bus race via its own service-activation file even if it is never spawned — so
        to hand notifications to another component this must actually be null, not merely
        unspawned.
      '';
    };

    fileManager = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = "thunar";
      description = ''
        File manager role, or null for none. Free-form rather than an enum: the backend maps the
        name, and there is no reason to gatekeep which one a consumer wants. See the header for
        why the default is Thunar (GTK3) rather than Nautilus (GTK4).
      '';
    };

    polkitAgent = lib.mkOption {
      type = lib.types.nullOr (lib.types.enum [ "mate-polkit" "polkit-kde-agent" "lxqt-policykit" ]);
      default = "mate-polkit";
      description = ''
        Polkit authentication agent, or null for none. Without one, any privileged GUI prompt
        (udisks, NetworkManager, a GUI sudo) fails **silently** — there is no error, the dialog
        simply never appears, which is a genuinely hard failure to diagnose. niri does not
        process XDG autostart, so the agent needs an explicit spawn; `home/niri.nix`'s
        `polkitAgentCommand` does that, and the backend supplies the platform's binary path.

        Known trap, not a bug in any agent: polkit refuses to register an agent from a session
        with no logind seat. A niri started as a bare systemd `--user` unit has none, and every
        agent then fails identically ("Failed to register client" / "Cannot determine user of
        subject"). Fix the session's seat, not the agent.
      '';
    };

    keyring = lib.mkOption {
      type = lib.types.nullOr (lib.types.enum [ "gnome-keyring" "kwallet" ]);
      default = "gnome-keyring";
      description = ''
        Secret-service provider (`org.freedesktop.secrets`), or null for none. Only one may run:
        two providers racing for the same D-Bus name is a real and confusing failure mode.
        `kwallet` works without a Plasma session but needs its own explicit spawn wiring.
      '';
    };

    launcher = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = "fuzzel";
      description = "Application launcher role, or null for none. fuzzel is pixman/cairo (CPU-only).";
    };

    terminal = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = "foot";
      description = ''
        Terminal role, or null for none. Must be set to something the backend can install:
        `home/niri.nix` binds a terminal by name regardless, so leaving this null while the
        keybind stays produces a bind that spawns a binary that isn't there.
      '';
    };

    osd = lib.mkOption {
      type = lib.types.nullOr (lib.types.enum [ "swayosd" ]);
      default = null;
      description = ''
        On-screen display for volume/brightness/caps-lock, or null. Null is not a broken desktop:
        the media and brightness keys still act via the compositor's own binds, they just do so
        without visual feedback.
      '';
    };

    screenshots = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Install a region-capture toolchain (grim/slurp class). niri has a built-in screenshot bind that does not strictly need these, but most region workflows do.";
    };

    xwayland = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        X11 application support (xwayland-satellite class). niri probes for it at startup and
        silently disables X11 integration if absent — it warns rather than failing, so a missing
        binary shows up much later as "X11 apps don't start" with no obvious cause.
      '';
    };

    clipboardHistory = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Clipboard history tooling (cliphist/wl-clipboard class), paired with home/niri.nix's clipboard binds.";
    };

    idleAndLock = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Idle daemon + screen locker (swayidle/swaylock class), paired with home/niri.nix's idle timeouts and lockCommand.";
    };

    portals = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Install desktop portal backends. niri itself declares a hard dependency on *some* portal
        implementation, so this is close to mandatory: screen sharing, file choosers and
        "open with" all route through it.
      '';
    };

    extraComponents = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = ''
        Escape hatch: additional role names passed through to the backend verbatim. Use for
        things this profile has no opinion about (a bluetooth applet, an audio mixer). Names are
        resolved by the backend, so portability is the consumer's problem for these.
      '';
    };
  };

  # NO `default` here, and the definition below is unconditional. `readOnly` permits exactly one
  # definition, and a default combined with a `mkIf`-guarded definition counts as two — the
  # profile fails to evaluate the moment it is enabled. So the empty-when-disabled case is
  # expressed in the value, not by withholding the definition.
  options.nixdesktop.want = lib.mkOption {
    type = lib.types.attrs;
    readOnly = true;
    description = ''
      READ-ONLY, computed. The resolved role set a platform backend consumes to produce real
      packages. This is the entire contract between nixdesktop and a backend — a backend that
      reads only this attrset needs no other knowledge of this profile, and this profile needs
      none of the backend's package naming.
    '';
  };

  config.nixdesktop.want = lib.optionalAttrs cfg.enable {
    compositor = "niri";
    inherit (cfg)
      bar
      notifications
      fileManager
      polkitAgent
      keyring
      launcher
      terminal
      osd
      screenshots
      xwayland
      clipboardHistory
      idleAndLock
      portals
      extraComponents
      ;
  };
}
