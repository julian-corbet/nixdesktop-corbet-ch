# Evaluates modules/nixos-backend.nix + profiles/desktop.nix as a REAL NixOS system and proves the
# one thing about the `input` role that a package list can never prove: that filling it actually
# turns the remapping daemon ON, and that leaving it unfilled turns nothing on.
#
# WHY THIS CHECK EXISTS, and why it is the same argument checks/file-manager.nix makes one role
# over. On Arch, "the package is installed" and "the mechanism exists" are close to the same
# statement — the package drops the binary, its systemd unit and its udev rules into the one shared
# prefix — so nixarch's table of pacman names is nearly a complete answer. On NixOS they come apart
# almost entirely: `pkgs.keyd` in `environment.systemPackages` gives you `keyd monitor` and
# `keyd reload` and NOTHING else. There is no unit, no `keyd` group, no `/etc/keyd`; nixpkgs'
# `services.keyd` module owns all three, and it does not add the package to the system profile
# itself. So the two halves are complementary, and the failure of forgetting the option half is
# the silent kind this directory exists to catch: a daemon that is installed, looks configured,
# and never runs.
#
# BOTH DIRECTIONS ARE ASSERTED. `input` defaults to null, which is what every existing consumer
# already evaluates — a regression that fired the option unconditionally would enable a daemon on
# every desktop in the family without anyone asking for one, and nothing downstream would complain.
#
# A REAL `nixpkgs.lib.nixosSystem`, not `lib.evalModules` + a stub, for checks/file-manager.nix's
# reason exactly: what is under test is what nixpkgs' OWN module does downstream of the boolean
# this backend sets, and a stub declaring `services.keyd` as `attrsOf anything` would accept the
# write and prove nothing about its effect.
{ pkgs, nixpkgs, system, lib ? pkgs.lib }:
let
  support = import ./support.nix { inherit pkgs lib; };
  inherit (support) report;

  configFor = settings: (nixpkgs.lib.nixosSystem {
    inherit system;
    modules = [
      ../profiles/desktop.nix
      ../modules/nixos-backend.nix
      {
        nixdesktop.nixosBackend.enable = true;
        system.stateVersion = "24.11";
        boot.isContainer = true;
      }
      settings
    ];
  }).config;

  # `compositor` has no default (see profiles/desktop.nix) and is mandatory the moment the profile
  # is enabled, so every enabled fixture carries it. Which compositor is irrelevant here.
  desktop = extra: { nixdesktop.desktop = { enable = true; compositor = "niri"; } // extra; };

  keyd = configFor (desktop { input = "keyd"; });
  unfilled = configFor (desktop { });
  disabled = configFor { nixdesktop.desktop = { enable = false; compositor = "niri"; }; };

  packageNames = cfg: map (p: p.name or "") cfg.environment.systemPackages;
  hasNamed = prefix: cfg: lib.any (n: lib.hasPrefix prefix n) (packageNames cfg);

  results = {
    # ── THE REAL OPTION, NOT A PACKAGE LIST ───────────────────────────────────────────────────
    "input = keyd sets services.keyd.enable, the only thing that defines the daemon at all" =
      keyd.services.keyd.enable;

    "...which is what actually renders the systemd unit" =
      keyd.systemd.services ? keyd;

    # The package half is not redundant with the option half: `services.keyd` deliberately does
    # not put keyd in the system profile, so without the table entry the client binaries
    # (`keyd monitor`, `keyd reload`) would be unreachable on a host that asked for keyd.
    "...and the client binaries still reach PATH, which services.keyd does not do on its own" =
      hasNamed "keyd-" keyd;

    # ── THE UNFILLED ROLE ENABLES NOTHING ─────────────────────────────────────────────────────
    #
    # `input` defaults to null, so this is the state every existing consumer evaluates today. A
    # regression here would silently start a keyboard-remapping daemon on every desktop.
    "an unfilled input role leaves services.keyd.enable off" =
      !unfilled.services.keyd.enable;

    "...and installs no remapper package either" =
      !(hasNamed "keyd-" unfilled);

    # ── THE PROFILE OFF ENTIRELY ──────────────────────────────────────────────────────────────
    #
    # `nixdesktop.want` is `{}` here, and the backend must emit nothing — the same contract
    # checks/file-manager.nix pins for the four options it already writes.
    "a disabled profile writes no services.keyd.enable" =
      !disabled.services.keyd.enable;
  };
in
report "input-substrate" results
