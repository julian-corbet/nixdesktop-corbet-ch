# Evaluates modules/layouts.nix for real and proves the arithmetic nobody can check by eye: the
# logical rectangle an output occupies once its scale and its transform have been applied, and the
# overlap test built on top of it.
#
# WHY THIS ONE MATTERS MOST. niri does not reject an overlapping output position. It SILENTLY
# DISCARDS the configured position, auto-places the output instead, and logs one warn line — so a
# wrong overlap computation here does not produce a wrong error, it produces no error at all while
# the screen quietly stops matching the config. Every fixture below is therefore paired: one that
# must fire and one one logical pixel away that must not, because an off-by-one in either
# direction is invisible at runtime.
{ pkgs, lib ? pkgs.lib }:
let
  support = import ./support.nix { inherit pkgs lib; };
  inherit (support) evalWith firedMessages matching countMatching report;

  layoutsOnly = defs: evalWith [ ../modules/layouts.nix { nixdesktop.layouts = defs; } ];

  withRegistry = mon: lay: evalWith [
    ../modules/monitors.nix
    ../modules/layouts.nix
    { nixdesktop.monitors = mon; nixdesktop.layouts = lay; }
  ];

  # One layout named `desk`, so every message infix below is stable.
  desk = outputs: layoutsOnly { desk = { description = "fixture"; inherit outputs; }; };

  at = x: y: { inherit x y; };
  hd = { mode = "1920x1080@60"; };

  # Two side-by-side 1080p panels, the single most common correct layout there is. The pair proves
  # the comparison is strict on both sides: touching edges are adjacent, one pixel of overlap is
  # not.
  adjacent = desk [
    ({ connector = "DP-1"; match = "connector"; position = at 0 0; } // hd)
    ({ connector = "DP-2"; match = "connector"; position = at 1920 0; } // hd)
  ];
  overlapping = desk [
    ({ connector = "DP-1"; match = "connector"; position = at 0 0; } // hd)
    ({ connector = "DP-2"; match = "connector"; position = at 1919 0; } // hd)
  ];

  # SCALE: a 3840x2160 panel at scale 2 occupies 1920x1080 LOGICAL pixels, which is the space
  # `position` is expressed in. Ignoring the divisor would make the neighbour at x=1920 overlap.
  scaled = boundary: desk [
    { connector = "DP-1"; match = "connector"; mode = "3840x2160@60"; scale = 2; position = at 0 0; }
    ({ connector = "DP-2"; match = "connector"; position = at boundary 0; } // hd)
  ];

  # TRANSFORM + SCALE together: 3840x2160 at scale 2 is 1920x1080 logical, and a 270 turn exchanges
  # the axes to 1080x1920. A neighbour at x=1500 clears the turned panel and would NOT clear the
  # unturned one — so this pair proves the swap is applied rather than merely present.
  turned = boundary: desk [
    {
      connector = "DP-1";
      match = "connector";
      mode = "3840x2160@60";
      scale = 2;
      transform = "270";
      position = at 0 0;
    }
    ({ connector = "DP-2"; match = "connector"; position = at boundary 0; } // hd)
  ];

  # A 1080p60 modeline carrying POSITIVE h/v sync — the ast2500 case that is the whole reason the
  # option exists. Geometry comes from fields 2 and 6; the polarity is passed through untouched.
  modelined = boundary: desk [
    {
      connector = "VGA-1";
      match = "connector";
      modeline = "148.50 1920 2008 2052 2200 1080 1084 1089 1125 +hsync +vsync";
      position = at 0 0;
    }
    ({ connector = "DP-2"; match = "connector"; position = at boundary 0; } // hd)
  ];

  # No mode, no modeline: the size must come from the registry's `nativeMode`, or the overlap
  # check silently covers less than the config implies.
  fromRegistry = boundary: withRegistry
    { big = { make = "Dell Inc."; model = "DELL U4323QE"; serial = "9BQR2P3"; nativeMode = "3840x2160@60"; }; }
    {
      desk = {
        description = "fixture";
        outputs = [
          { monitor = "big"; position = at 0 0; }
          ({ connector = "DP-2"; match = "connector"; position = at boundary 0; } // hd)
        ];
      };
    };

  unsizable = desk [
    { connector = "DP-1"; match = "connector"; position = at 0 0; }
    ({ connector = "DP-2"; match = "connector"; position = at 0 0; } // hd)
  ];

  bothSelectors = desk [{ monitor = "x"; connector = "DP-1"; }];
  neitherSelector = desk [{ mode = "1920x1080@60"; }];
  identityWithoutMonitor = desk [{ connector = "DP-1"; }];
  connectorWithoutConnector = desk [{ monitor = "x"; match = "connector"; }];
  unknownSlug = withRegistry
    { known = { make = "A"; model = "B"; serial = "C"; }; }
    { desk = { description = "fixture"; outputs = [{ monitor = "typo"; }]; }; };

  partial = desk [
    ({ connector = "DP-1"; match = "connector"; position = at 0 0; } // hd)
    ({ connector = "DP-2"; match = "connector"; } // hd)
  ];
  partialButDisabled = desk [
    ({ connector = "DP-1"; match = "connector"; position = at 0 0; } // hd)
    ({ connector = "eDP-1"; match = "connector"; enable = false; } // hd)
  ];
  # A DISABLED output occupies no space, so it cannot overlap anything — the docked layout that
  # turns the laptop panel off while a monitor sits at the same origin is correct, not a clash.
  disabledAtSameOrigin = desk [
    ({ connector = "DP-1"; match = "connector"; position = at 0 0; } // hd)
    ({ connector = "eDP-1"; match = "connector"; enable = false; position = at 0 0; } // hd)
  ];

  overlapCount = cfg: countMatching "two enabled outputs overlap" (firedMessages cfg);

  results = {
    # ── SELECTOR AND MATCHER AGREEMENT ────────────────────────────────────────────────────────
    "setting both monitor and connector is rejected" =
      countMatching "BOTH `monitor` and `connector`" (firedMessages bothSelectors) == 1;

    "setting neither is rejected" =
      countMatching "NEITHER `monitor` nor `connector`" (firedMessages neitherSelector) == 1;

    # The default is `identity`, so a connector-addressed entry must say `match = "connector"`
    # explicitly. Inferring it would quietly swap two matchers with genuinely different stability
    # properties — an identity roams with the panel, a connector stays with the socket.
    "match=identity without a monitor is rejected" =
      countMatching ''sets `match = "identity"` but no `monitor`'' (firedMessages identityWithoutMonitor) == 1;

    # The companion rule. Together with the one above and the exactly-one-selector rule, it makes
    # an unidentifiable registry entry UNREFERENCEABLE — which is the other half of
    # modules/monitors.nix's own assertion.
    "match=connector without a connector is rejected" =
      countMatching ''sets `match = "connector"` but no `connector`'' (firedMessages connectorWithoutConnector) == 1;

    # Rename/typo detection, and only reachable when the registry is composed at all: a host that
    # addresses only connectors imports no registry, and an error about an empty one would be an
    # error about nothing.
    "a monitor slug the registry does not declare is rejected" =
      countMatching "names the monitor slug" (firedMessages unknownSlug) == 1
      && lib.hasInfix "known"
        (lib.head (matching "names the monitor slug" (firedMessages unknownSlug)));

    # ── ALL-OR-NOTHING POSITIONING ────────────────────────────────────────────────────────────
    "a positioned layout with one unpositioned enabled output is rejected" =
      countMatching "has no `position`" (firedMessages partial) == 1;

    "a disabled output needs no position" =
      countMatching "has no `position`" (firedMessages partialButDisabled) == 0;

    # ── OVERLAP ───────────────────────────────────────────────────────────────────────────────
    "touching edges are adjacent, not overlapping" = overlapCount adjacent == 0;
    "one logical pixel of overlap is caught" = overlapCount overlapping == 1;

    "the overlap message names both outputs and both rectangles" =
      let m = lib.head (matching "two enabled outputs overlap" (firedMessages overlapping)); in
      lib.hasInfix ''connector "DP-1"'' m
      && lib.hasInfix ''connector "DP-2"'' m
      && lib.hasInfix "1920x1080 logical at (0, 0)" m
      && lib.hasInfix "1920x1080 logical at (1919, 0)" m;

    # scale divides: 3840/2 = 1920, so x=1920 clears and x=1919 does not. Were the divisor
    # ignored, the panel would span 3840 columns and BOTH would collide.
    "scale divides the logical width" = overlapCount (scaled 1920) == 0;
    "scale does not hide a real overlap" = overlapCount (scaled 1919) == 1;

    # 270 exchanges the axes: 1920x1080 logical becomes 1080x1920, so x=1080 clears. Without the
    # swap the panel would span 1920 columns and x=1500 would collide — which is why the clearing
    # case is the one that proves it.
    "a 270 transform exchanges width and height" = overlapCount (turned 1500) == 0;
    "the transformed rectangle still catches a real overlap" = overlapCount (turned 1079) == 1;

    "the turned rectangle is reported with its axes exchanged" =
      let m = lib.head (matching "two enabled outputs overlap" (firedMessages (turned 1079))); in
      lib.hasInfix "1080x1920 logical at (0, 0)" m;

    # ── GEOMETRY SOURCES ──────────────────────────────────────────────────────────────────────
    "a modeline supplies hdisp/vdisp for the rectangle" =
      overlapCount (modelined 1920) == 0 && overlapCount (modelined 1919) == 1;

    "a mode-less output takes its size from the registry's nativeMode" =
      overlapCount (fromRegistry 3840) == 0 && overlapCount (fromRegistry 3839) == 1;

    # An output whose size is genuinely unknowable must not be silently skipped: checking less
    # than the config says, without saying so, is the failure class this module removes.
    "an unsizable positioned output warns rather than being silently skipped" =
      lib.length (lib.filter (w: lib.hasInfix "cannot be computed" w) unsizable.warnings) == 1
      && overlapCount unsizable == 0;

    "a disabled output at the same origin does not overlap" =
      overlapCount disabledAtSameOrigin == 0;

    # ── TYPE-LEVEL GUARDS ─────────────────────────────────────────────────────────────────────
    # A zero or negative scale is not a scale; it would make every logical size infinite or
    # negative and the overlap arithmetic meaningless rather than merely wrong. Rejected by the
    # type, so it throws out of the module system and never reaches `assertions`.
    "a zero scale is rejected by the type" =
      support.evalThrows [
        ../modules/layouts.nix
        {
          nixdesktop.layouts.desk = {
            description = "fixture";
            outputs = [{ connector = "DP-1"; match = "connector"; scale = 0; }];
          };
        }
      ];

    # Integers and floats are both ordinary scales; demanding `2.0` would be a papercut with no
    # upside, and integer division must not silently truncate the fractional case.
    "an integer scale is accepted, and a fractional one divides properly" =
      overlapCount (scaled 1920) == 0
      && overlapCount
        (desk [
          { connector = "DP-1"; match = "connector"; mode = "2560x1440@60"; scale = 1.5; position = at 0 0; }
          ({ connector = "DP-2"; match = "connector"; position = at 1707 0; } // hd)
        ]) == 0
      && overlapCount
        (desk [
          { connector = "DP-1"; match = "connector"; mode = "2560x1440@60"; scale = 1.5; position = at 0 0; }
          ({ connector = "DP-2"; match = "connector"; position = at 1706 0; } // hd)
        ]) == 1;

    "an unknown transform is rejected by the type" =
      support.evalThrows [
        ../modules/layouts.nix
        {
          nixdesktop.layouts.desk = {
            description = "fixture";
            outputs = [{ connector = "DP-1"; match = "connector"; transform = "rotate-90"; }];
          };
        }
      ];
  };
in
report "layout geometry" results
