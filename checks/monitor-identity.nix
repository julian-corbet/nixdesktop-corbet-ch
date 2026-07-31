# Evaluates modules/monitors.nix for real and proves the two things it exists to get right: the
# derived output identity, and the assertion that no two declarations can ever produce the same
# one.
#
# WHY THIS IS NOT A FORMALITY. The identity string is what both niri and scroll/sway match an
# output on AND what they key remembered workspace assignment to. A wrong separator or a wrong
# Unknown-substitution produces a matcher that matches nothing — silently, on both compositors,
# leaving the output at its defaults with no error anywhere. A DUPLICATE identity is worse: it is
# niri #734, where workspace assignment attaches to whichever panel resolved first. Neither shows
# up as anything but "my config was ignored", so both are proven here.
{ pkgs, lib ? pkgs.lib }:
let
  support = import ./support.nix { inherit pkgs lib; };
  inherit (support) evalWith firedMessages matching countMatching report;

  monitorsOnly = defs: evalWith [ ../modules/monitors.nix { nixdesktop.monitors = defs; } ];

  # Both tables composed together — the only way to exercise the cross-check, and a fixture worth
  # having in its own right: the two modules read each other defensively and must not deadlock.
  bothTables = mon: lay: evalWith [
    ../modules/monitors.nix
    ../modules/layouts.nix
    { nixdesktop.monitors = mon; nixdesktop.layouts = lay; }
  ];

  mon = slug: cfg: (monitorsOnly { ${slug} = cfg; }).nixdesktop.monitors.${slug};

  dell = { make = "Dell Inc."; model = "DELL U4323QE"; serial = "9BQR2P3"; };

  # The estate's real trap, declared exactly as it presents. See modules/monitors.nix's header:
  # every HP LA2306 ever made shows this same numeric-serial fallback when read from a unit whose
  # 0xFF descriptor is missing.
  la2306Fallback = { make = "HP Inc."; model = "HP LA2306"; serial = "0x01010101"; };

  collidingPair = monitorsOnly { a = dell; b = dell; };
  aliasCollision = monitorsOnly {
    a = dell;
    b = { make = "Dell Inc."; model = "DELL U2724DE"; serial = "1AA2B3C"; aliases = [ dell ]; };
  };
  threeWay = monitorsOnly { a = dell; b = dell; c = dell // { aliases = [ dell ]; }; };
  distinct = monitorsOnly {
    a = dell;
    b = { make = "Dell Inc."; model = "DELL U4323QE"; serial = "9BQR2P4"; };
  };

  unidentifiableByIdentity = bothTables
    { la2306 = la2306Fallback; }
    { desk = { description = "one panel"; outputs = [{ monitor = "la2306"; }]; }; };

  identifiableByIdentity = bothTables
    { u4323qe = dell; }
    { desk = { description = "one panel"; outputs = [{ monitor = "u4323qe"; }]; }; };

  noSerialByIdentity = bothTables
    { panel = { make = "LG Display"; model = "0x0576"; }; }
    { desk = { description = "one panel"; outputs = [{ monitor = "panel"; }]; }; };

  results = {
    # ── THE DERIVATION ────────────────────────────────────────────────────────────────────────
    "identifier is make, model and serial joined by single spaces" =
      (mon "a" dell).identifier == "Dell Inc. DELL U4323QE 9BQR2P3";

    # `Unknown` is the literal both compositors substitute. Anything else here is a matcher that
    # matches nothing, and neither compositor calls that an error.
    "a null serial renders as the literal Unknown" =
      (mon "a" { make = "LG Display"; model = "0x0576"; }).identifier == "LG Display 0x0576 Unknown";

    "an empty field renders as Unknown too, not as a double space" =
      (mon "a" { make = ""; model = "SyncMaster"; serial = null; }).identifier
      == "Unknown SyncMaster Unknown";

    "an alias derives its own identifier by the same rule" =
      (mon "a" (dell // {
        aliases = [{ make = "Dell Inc."; model = "DELL U4323QE (USB-C)"; serial = "9BQR2P3"; }];
      })).aliases == [
        {
          make = "Dell Inc.";
          model = "DELL U4323QE (USB-C)";
          serial = "9BQR2P3";
          identifier = "Dell Inc. DELL U4323QE (USB-C) 9BQR2P3";
        }
      ];

    # ── identifiable ──────────────────────────────────────────────────────────────────────────
    "a real 0xFF serial descriptor is identifiable" = (mon "a" dell).identifiable;

    "a null serial is not identifiable" =
      !(mon "a" { make = "LG Display"; model = "0x0576"; }).identifiable;

    # THE ESTATE'S OWN TRAP: libdisplay-info renders EDID's numeric serial FIELD as 0x%08X when the
    # 0xFF descriptor is absent, and the LA2306's numeric field is the dummy constant 0x01010101 —
    # shared by every unit ever made.
    "libdisplay-info's 0x-fallback serial is not identifiable" =
      !(mon "a" la2306Fallback).identifiable;

    "the 0x-fallback is detected in either hex case" =
      !(mon "a" (dell // { serial = "0xDEADbeef"; })).identifiable;

    # The pattern must be exactly eight digits: a genuine serial that merely starts with 0x is a
    # serial, and treating it as no-identity would push a perfectly addressable panel onto
    # connector matching for nothing.
    "a 0x string of the wrong length is a real serial" =
      (mon "a" (dell // { serial = "0x0101010"; })).identifiable
      && (mon "a" (dell // { serial = "0x0101010101"; })).identifiable;

    # ── THE UNIQUENESS ASSERTION ──────────────────────────────────────────────────────────────
    "two monitors with one identity collide" =
      countMatching "resolve to the SAME" (firedMessages collidingPair) == 1;

    "the collision message names the identity and both declarations" =
      let m = lib.head (firedMessages collidingPair); in
      lib.hasInfix ''"Dell Inc. DELL U4323QE 9BQR2P3"'' m
      && lib.hasInfix "nixdesktop.monitors.a" m
      && lib.hasInfix "nixdesktop.monitors.b" m;

    # An alias is indistinguishable from a monitor on the wire — both are just strings a
    # compositor matches — so it has to participate in uniqueness or the guard has a hole exactly
    # where multi-input panels live.
    "a monitor colliding with another monitor's ALIAS is caught" =
      countMatching "resolve to the SAME" (firedMessages aliasCollision) == 1
      && lib.hasInfix "aliases[0]" (lib.head (firedMessages aliasCollision));

    "a three-way collision is reported once, naming all four declarations" =
      let msgs = matching "resolve to the SAME" (firedMessages threeWay); in
      lib.length msgs == 1
      && lib.hasInfix "4 declarations" (lib.head msgs)
      && lib.hasInfix "nixdesktop.monitors.c.aliases[0]" (lib.head msgs);

    "distinct serials do not collide" =
      countMatching "resolve to the SAME" (firedMessages distinct) == 0;

    # ── THE LAYOUT CROSS-CHECK ────────────────────────────────────────────────────────────────
    "an unidentifiable monitor addressed by identity is rejected" =
      countMatching "addresses the monitor" (firedMessages unidentifiableByIdentity) == 1;

    "that message names the layout entry and the shared identity" =
      let m = lib.head (matching "addresses the monitor" (firedMessages unidentifiableByIdentity)); in
      lib.hasInfix "nixdesktop.layouts.desk.outputs[0]" m
      && lib.hasInfix ''"HP Inc. HP LA2306 0x01010101"'' m;

    "a serial-less monitor addressed by identity is rejected too" =
      countMatching "addresses the monitor" (firedMessages noSerialByIdentity) == 1;

    "an identifiable monitor addressed by identity is fine" =
      countMatching "addresses the monitor" (firedMessages identifiableByIdentity) == 0;

    # Composing both tables must not deadlock: each module reads the other's values defensively,
    # and a cycle would show up as an infinite recursion rather than a failed assertion.
    "both tables compose without an evaluation cycle" =
      lib.isList (firedMessages identifiableByIdentity);
  };

in
report "monitor identity" results
