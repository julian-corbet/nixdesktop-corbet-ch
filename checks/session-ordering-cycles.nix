# checks/session-ordering-cycles.nix — proves home/session.nix's ordering-cycle guard, and the one
# component in this repo that used to trip it.
#
# WHAT THIS IS ABOUT. systemd gives every unit an implicit `Before=` on the target that pulls it
# in. A component that is `wantedBy` T and `after` T therefore sits on both sides of T, and the
# loop closes the moment a sibling T also pulls in is ordered after it:
#
#   T -> sibling (implicitly before T, waiting for the component) -> component (after T) -> T
#
# WHY IT IS WORTH A CHECK FILE OF ITS OWN. systemd does not fail this. It deletes one start job to
# break the cycle and logs a single line naming a THIRD unit:
#
#   Found ordering cycle: graphical-session.target/verify-active after bar.service/start
#     after scroll-ipc-compat.service/start - after graphical-session.target
#   Job bar.service/start deleted to break ordering cycle
#
# The victim is then `inactive (dead)`, nothing failed, `systemctl --failed` clean — a status bar
# that stops appearing after a reboot with no error anywhere pointing at it. That is the live
# failure this guard came from, and an absence is the one class of bug an eval check can catch
# that a running session cannot report.
#
# AND WHY THE GUARD IS NOT MERELY DEFENSIVE. `after` and `wantedBy` BOTH default to
# graphical-session.target in home/session.nix, so the dangerous half is what a consumer gets by
# writing nothing at all; only the `before` is ever typed on purpose, and it reads perfectly
# reasonable in isolation. This repo's own `keyring.oo7.credential.bootstrap` was built exactly
# that way and shipped the cycle in its DEFAULT configuration — the fixture below is that config,
# and it must come out clean.
{ pkgs, lib ? pkgs.lib }:
let
  support = import ./support.nix { inherit pkgs lib; };
  inherit (support) report;

  # Same stub as checks/keyring.nix's own, same reasoning — a stand-in for "a host" matching the
  # surface home-manager itself declares, not a simplification of it.
  stubs = { lib, ... }: {
    options = {
      xdg.configFile = lib.mkOption {
        type = lib.types.attrsOf (lib.types.attrsOf lib.types.anything);
        default = { };
      };
      home.packages = lib.mkOption { type = lib.types.listOf lib.types.anything; default = [ ]; };
      home.file = lib.mkOption { type = lib.types.attrsOf lib.types.anything; default = { }; };
      assertions = lib.mkOption { type = lib.types.listOf lib.types.anything; default = [ ]; };
      warnings = lib.mkOption { type = lib.types.listOf lib.types.str; default = [ ]; };
      systemd.user = lib.mkOption { type = lib.types.anything; default = { }; };
    };
  };

  evalWith = settings: (lib.evalModules {
    modules = [
      stubs
      ../home/session.nix
      { nixdesktop.session = { enable = true; } // settings; }
    ];
    specialArgs = { inherit pkgs; };
  }).config;

  fired = settings: support.firedMessages (evalWith settings);
  cycles = settings: support.matching "ordering cycle through" (fired settings);

  # ── fixtures ────────────────────────────────────────────────────────────────────────────────
  # The plain session: every component on the class defaults (`after` AND `wantedBy` both
  # graphical-session.target), nothing ordered before a sibling. This is the shape the whole file
  # is built on and it must stay silent — a guard that fires here would be unusable.
  plain = { bar.enable = true; notifications.enable = true; osd.enable = true; };

  # This repo's own bootstrap component, on nothing but its documented options. It is `before` the
  # daemon, `wantedBy` the daemon's target, and the daemon is `wantedBy` that target too — every
  # ingredient of the cycle except an `after` on the same target, which is exactly what was
  # removed. Green here is the regression test.
  keyringBootstrap = {
    keyring.enable = true;
    keyring.oo7.enable = true;
    keyring.oo7.command = "oo7-daemon";
    keyring.oo7.credential.enable = true;
    keyring.oo7.credential.path = "/var/lib/oo7.cred";
    keyring.oo7.credential.bootstrap.enable = true;
    keyring.oo7.credential.bootstrap.keyringPath = "/home/u/.local/share/keyrings/default.keyring";
  };

  bootstrapUnit = (evalWith keyringBootstrap).systemd.user.services.oo7-keyring-bootstrap;

  # The cycle, reintroduced the way a consumer would: reaching into `services.<name>` and putting
  # the target back into `after` — the natural edit, since it reads as "do not run before the
  # session exists" and nothing about it looks like a mistake.
  reintroducedViaAfter = keyringBootstrap // {
    services.oo7-keyring-bootstrap.after = [ "graphical-session.target" ];
  };

  # The SAME loop expressed from the other end: the component keeps the harmless class default,
  # and the sibling declares it waits for it. Both directions describe one edge, and a guard that
  # only understood `before` would miss half the ways to write it.
  reintroducedViaSiblingAfter = {
    bar.enable = true;
    services.helper = {
      command = "helper";
      description = "helper";
      # after/wantedBy left at the class defaults on purpose -- that is the point.
    };
    services.bar.after = [ "helper.service" ];
  };

  results = {
    # ── the guard stays quiet on everything legitimate ────────────────────────────────────────
    "an ordinary session of sibling-independent components trips nothing" =
      cycles plain == [ ];
    "no OTHER assertion fires on that session either -- the fixture is a clean config" =
      fired plain == [ ];
    "the keyring bootstrap's own default configuration is cycle-free" =
      cycles keyringBootstrap == [ ];

    # ── ...because of the one thing that was actually changed ─────────────────────────────────
    "the bootstrap is ordered before the daemon, which is its whole reason to exist" =
      bootstrapUnit.Unit.Before == [ "keyring.service" ];
    "and is NOT ordered after the target it is pulled in by -- the half that closed the loop" =
      (bootstrapUnit.Unit.After or [ ]) == [ ];
    "it is still pulled in and still stops with that target" =
      bootstrapUnit.Install.WantedBy == [ "graphical-session.target" ]
      && bootstrapUnit.Unit.PartOf == [ "graphical-session.target" ];

    # ── and it catches the loop however it is written ─────────────────────────────────────────
    "putting the target back into `after` is a build failure, not a silent deletion" =
      lib.length (cycles reintroducedViaAfter) == 1;
    "the message names the target, the victim, and the sibling that waits" =
      let m = lib.head (cycles reintroducedViaAfter); in
      lib.hasInfix "graphical-session.target" m
      && lib.hasInfix "oo7-keyring-bootstrap" m
      && lib.hasInfix "keyring" m;
    "the same loop declared from the sibling's `after` is caught too" =
      lib.length (cycles reintroducedViaSiblingAfter) == 1;
    "...and that one names the sibling as the waiter, not as the victim" =
      let m = lib.head (cycles reintroducedViaSiblingAfter); in
      lib.hasInfix "nixdesktop.session.services.helper:" m && lib.hasInfix "bar" m;
  };
in
report "session ordering cycles" results
