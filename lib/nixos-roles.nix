# lib/nixos-roles.nix — the NixOS resolution tables for nixdesktop's roles. Pure data (a function
# of `pkgs`, plus an optional consumer-supplied compositor table — see `compositors` below), no
# module system: imported by modules/nixos-backend.nix (the only consumer today) and
# available to a future paired home-manager module the same way nixarch's home/desktop.nix reads
# lib/desktop-roles.nix — for the same reason: the polkit agent's package and the polkit agent's
# spawn command are the same fact, and keeping them in one attrset means a system-layer module and
# a user-layer module can never disagree about it even though they are separate evaluations.
#
# THIS FILE IS THE ONLY PLACE IN THE PROJECT THAT KNOWS NIXPKGS ATTRIBUTE PATHS for the desktop.
# nixdesktop declares roles ("thunar", "mate-polkit") and never names a package; that split is the
# whole point, and this file is the NixOS half of it (nixarch/lib/desktop-roles.nix is the Arch
# half, same shape, pacman names instead of nixpkgs attrs).
#
# WHY THIS BACKEND LIVES IN nixdesktop ITSELF, UNLIKE THE ARCH ONE. nixarch's backend could not
# live here because naming pacman packages requires knowing Arch's package repos — foreign
# knowledge nixdesktop has no other reason to carry. Resolving roles to nixpkgs attributes needs no
# such foreign knowledge: nixpkgs is already nixdesktop's only flake input (see flake.nix), so this
# file adds a data table, not a dependency. The asymmetry is deliberate, not an inconsistency.
#
# NIXPKGS ATTR PATHS ARE NOT PACMAN NAMES. This is the entire reason the role indirection exists,
# and it bites immediately: `thunar` is `pkgs.thunar` (top-level in current nixpkgs; older releases
# nested it under `pkgs.xfce`), but `mate-polkit` is `pkgs.mate-polkit` while
# `polkit-kde-agent` is `pkgs.kdePackages.polkit-kde-agent-1` — no top-level alias, and the trailing
# `-1` is part of the real attribute name, not a version pin. Verified against a live nixpkgs
# evaluation while writing this file (`nix eval`/`nix build` against nixos-unstable), not guessed.
#
# POLKIT AGENT BINARY PATHS ARE STORE PATHS, NOT `/usr/lib/...`. nixarch's table hardcodes
# absolute paths like `/usr/lib/mate-polkit/polkit-mate-authentication-agent-1` because that is
# where Arch's packaging puts it, always, for every user. Nix has no equivalent fixed location —
# the agent binary lives under the package's own store path, which is only known once the package
# is. So every `command` below is built as a string interpolation of the package itself
# (`"${pkg}/libexec/..."`), never a literal path. The subpath itself was confirmed by building each
# package and listing its output (`nix build` + `find $out`) rather than assumed from the Arch
# layout — mate-polkit in particular installs straight to `$out/libexec/`, with none of the
# `mate-polkit/`-named subdirectory Arch's own packaging adds, so copying the Arch path across
# platforms would have silently pointed at a directory that doesn't exist.
{ lib, pkgs, extraCompositors ? { } }:
rec {
  # ── Roles whose implementation is a named choice ────────────────────────────────────────────

  # Same floor as nixarch's table, same reasoning: a file manager alone is not a working file
  # manager without a thumbnailer and gvfs (removable media, network shares, MTP phones). Taste-
  # level plugins stay the consumer's business via `extraComponents`.
  fileManagers = {
    thunar = [ pkgs.thunar pkgs.tumbler pkgs.gvfs pkgs.thunar-volman ];
    nautilus = [ pkgs.nautilus pkgs.gvfs ];
    dolphin = [ pkgs.kdePackages.dolphin pkgs.kdePackages.kio-extras ];
    nemo = [ pkgs.nemo pkgs.gvfs ];
    pcmanfm = [ pkgs.pcmanfm pkgs.gvfs ];
  };

  polkitAgents = {
    mate-polkit = {
      packages = [ pkgs.mate-polkit ];
      command = "${pkgs.mate-polkit}/libexec/polkit-mate-authentication-agent-1";
    };
    polkit-kde-agent = {
      # qt6ct rides along for the same reason nixarch's table carries it: this agent is the only
      # Qt component on an otherwise-GTK desktop, and without a Qt platform theme it renders
      # unstyled against everything else.
      packages = [ pkgs.kdePackages.polkit-kde-agent-1 pkgs.qt6Packages.qt6ct ];
      command = "${pkgs.kdePackages.polkit-kde-agent-1}/libexec/polkit-kde-authentication-agent-1";
    };
    lxqt-policykit = {
      packages = [ pkgs.lxqt.lxqt-policykit ];
      command = "${pkgs.lxqt.lxqt-policykit}/bin/lxqt-policykit-agent";
    };
  };

  # Both daemons here install their binary straight to $out/bin (confirmed by build + `find`, same
  # as every other role), so — unlike the polkit agents above — a bare command resolved via PATH is
  # correct and there is no store path to interpolate. Kept as `command` strings anyway, mirroring
  # the Arch table's shape and for the same reason a future home-layer module would want it: the
  # package and the spawn command are one fact.
  keyrings = {
    gnome-keyring = {
      packages = [ pkgs.gnome-keyring ];
      # --components=secrets only: this is the secret-service role, not the ssh-agent or pkcs11
      # ones. A consumer wanting those should say so rather than get them by accident.
      command = "gnome-keyring-daemon --start --components=secrets";
    };
    kwallet = {
      packages = [ pkgs.kdePackages.kwallet ];
      command = "kwalletd6";
    };
  };

  bars = {
    waybar = [ pkgs.waybar ];
    eww = [ pkgs.eww ];
    # noctalia is installed from its own flake through home-manager, not from nixpkgs — nixpkgs
    # carries no package for it at all. Empty on purpose, not an oversight; see flake.nix's own
    # comment on why noctalia is deliberately not a flake input here.
    noctalia = [ ];
  };

  notificationDaemons.mako = [ pkgs.mako ];

  osds.swayosd = [ pkgs.swayosd ];

  # ── Capability roles: booleans in `want`, package sets here ─────────────────────────────────
  #
  # `portals` is deliberately NOT a key here, unlike nixarch's table. On Arch, "install the portal
  # backend" and "the portal works" are the same action — pacman drops the package and the
  # `.portal`/desktop files it ships are all xdg-desktop-portal reads. On NixOS the package alone
  # is not enough: `xdg-desktop-portal` itself needs `xdg.portal.enable` (its systemd user service,
  # its D-Bus activation) and a backend needs to be listed in `xdg.portal.extraPortals` so it is
  # registered in `portals.conf` at all — dropping the package into `environment.systemPackages`
  # with nothing else produces an installed-but-unregistered binary that is invisible to portal
  # requests, which is a worse failure than doing nothing (it looks configured and isn't). Rather
  # than pretend that gap away by wiring it through `packagesFor` like everything else,
  # `portalPackages` below is exported separately and modules/nixos-backend.nix wires it through
  # the real option.
  capabilities = {
    # niri probes for xwayland-satellite by name at startup and, if absent, WARNS and continues
    # with X11 integration silently disabled — which surfaces much later as "X11 apps don't
    # start" with nothing obvious to blame.
    xwayland = [ pkgs.xwayland-satellite ];
    screenshots = [ pkgs.grim pkgs.slurp ];
    clipboardHistory = [ pkgs.cliphist pkgs.wl-clipboard ];
    idleAndLock = [ pkgs.swayidle pkgs.swaylock ];
  };

  # Not a capability (no `want.portals`-shaped boolean loop reaches this) — see the comment on
  # `capabilities` above for why. Same package choice as nixarch's table: niri hard-requires SOME
  # portal backend, gtk is the general-purpose fallback, gnome supplies the screencast portal gtk's
  # does not (what screen sharing actually needs on wlroots-adjacent stacks).
  portalPackages = [ pkgs.xdg-desktop-portal-gnome pkgs.xdg-desktop-portal-gtk ];

  # The compositor plus what its own default keybinds shell out to. niri's stock media and
  # brightness binds call these by name, so a compositor installed without them has keys that
  # silently do nothing.
  #
  # EXTENSIBLE, NOT CLOSED. niri is the only compositor with a nixpkgs package today; scroll (a
  # niri fork) has none, and future compositor-module repos won't necessarily either. Hardcoding
  # scroll's derivation here would mean this file — and a new release of this repo — has to be
  # edited every time a sibling compositor-module repo shows up, exactly the coupling the rest of
  # this project avoids for every other role. `extraCompositors` (this file's own function
  # argument, threaded in from `modules/nixos-backend.nix`'s identically-named option) is merged
  # in on top instead, so a consumer pairs this backend with, say, nixscroll by supplying
  # `{ scroll = [ nixscroll-flake.packages.${system}.scroll ]; }` — no edit to this file, no new
  # release of this repo needed. niri needs no such entry; it already resolves out of the box.
  compositors = { niri = [ pkgs.niri pkgs.brightnessctl pkgs.playerctl ]; } // extraCompositors;

  # ── Resolution ──────────────────────────────────────────────────────────────────────────────

  # Look a role value up in a table; fall through to `pkgs.${value}` as a top-level nixpkgs
  # attribute. The fallthrough exists for the same reason as nixarch's: nixdesktop's `fileManager`,
  # `launcher` and `terminal` are free-form strings precisely so a consumer is not gated on this
  # table being exhaustive (`launcher = "fuzzel"` and `terminal = "foot"`, this profile's own
  # defaults, both resolve this way — neither has a dedicated table above). Unlike the Arch
  # version, the fallthrough cannot just return the string: `environment.systemPackages` needs real
  # derivations, not names, so an unresolvable value is a hard eval error (`pkgs.${value}` throws
  # "attribute missing") rather than a silent no-op — a consumer who reaches for a role name that
  # isn't also a top-level nixpkgs attribute finds out at evaluation time, not at runtime with a
  # missing binary.
  resolve = table: value:
    if value == null then [ ]
    else if table ? ${value} then
      (if lib.isList table.${value} then table.${value} else table.${value}.packages)
    else [ pkgs.${value} ];

  # Packages for a resolved `nixdesktop.want`. An empty want (profile disabled) yields nothing.
  packagesFor = want:
    if want == { } then [ ] else
    lib.unique (
      resolve compositors (want.compositor or null)
      ++ resolve bars (want.bar or null)
      ++ resolve notificationDaemons (want.notifications or null)
      ++ resolve fileManagers (want.fileManager or null)
      ++ resolve polkitAgents (want.polkitAgent or null)
      ++ resolve keyrings (want.keyring or null)
      ++ resolve osds (want.osd or null)
      ++ lib.optionals (want.launcher or null != null) [ pkgs.${want.launcher} ]
      ++ lib.optionals (want.terminal or null != null) [ pkgs.${want.terminal} ]
      ++ lib.concatLists (lib.mapAttrsToList
        (name: pkgs': lib.optionals (want.${name} or false) pkgs')
        capabilities)
      ++ map (name: pkgs.${name}) (want.extraComponents or [ ])
    );
}
