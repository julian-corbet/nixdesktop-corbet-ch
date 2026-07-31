# modules/layouts.nix — a named arrangement of outputs: which panels a desktop expects, and where,
# at what size, turned which way.
#
# WHERE THIS SITS. modules/monitors.nix says what a panel IS (fleet-wide, roaming, identity-only).
# This module says what a SET of them looks like when they are all plugged into one machine at
# once — the desk, not the hardware. A host declares one layout per situation it actually has
# ("docked", "undocked", "the KVM position"), a session names one of them, and the compositor
# modules (nixniri, nixscroll) translate it into their own output syntax. Neither compositor
# repo re-derives geometry: everything that can be got wrong twice is got right once, here.
#
# THIS MODULE IS ARITHMETIC, NOT TASTE. Every assertion below encodes a way one of the two
# compositors fails SILENTLY on a layout that looks fine:
#
#   - sway/scroll auto-places any output that carries no explicit position, putting it directly to
#     the RIGHT of the rightmost already-placed output, in the order connectors happen to appear.
#     That order is not stable across boots, hotplugs or a dock re-enumeration, so a layout where
#     some outputs are positioned and some are not physically MOVES between reboots.
#   - niri, given a configured position that overlaps an already-placed output by even one pixel,
#     SILENTLY DISCARDS the configured position and falls back to automatic placement, logging a
#     single warn line into a journal nobody is reading at that moment. The config still says what
#     you wrote; the screen shows something else.
#
# Both failures are invisible from the config, so both become build failures here: the
# all-or-nothing positioning rule kills the first, and the overlap computation kills the second.
# That overlap check is the reason this module knows about modes, scales and transforms at all —
# it cannot compute a rectangle without them.
#
# TRANSFORM VOCABULARY IS COUNTER-CLOCKWISE, matching the wl_output protocol itself — see the
# `transform` option for the measured detail, and for why scroll's translator must invert while
# niri's must not.
{ lib, config, ... }:
let
  inherit (lib) types mkOption;

  cfg = config.nixdesktop.layouts;

  # ── Reading the monitor registry, if it is composed at all ──────────────────────────────────
  #
  # INTRA-repo read, so a plain `?` is right and `lib.probeFact` would be the wrong tool: probeFact
  # exists to tell "the sibling REPO was never composed" from "it is composed but the leaf was
  # renamed", and a rename inside this repo is caught by this repo's own checks in the same commit
  # that makes it. See modules/monitors.nix for the mirror-image read in the other direction.
  #
  # A layout is perfectly usable with no registry at all (a host that addresses only connectors —
  # a headless box, an evdi-only dock — has nothing to put in one), so the registry's absence is a
  # supported state, never an error.
  monitorsComposed = config.nixdesktop ? monitors;
  monitors = if monitorsComposed then config.nixdesktop.monitors else { };

  # ── Pixel geometry: three sources, in falling order of specificity ──────────────────────────

  # "3840x2160@60", "1920x1080@59.951", "2560x1440" -- the refresh suffix is optional and never
  # participates in geometry, so it is matched and discarded rather than parsed.
  parseMode = s:
    let m = builtins.match "([0-9]+)x([0-9]+)(@.*)?" s;
    in if m == null then null
    else { w = lib.toInt (builtins.elemAt m 0); h = lib.toInt (builtins.elemAt m 1); };

  # A raw modeline is nine whitespace-separated numbers followed by sync flags:
  #   <pixelclock> <hdisp> <hsyncstart> <hsyncend> <htotal> <vdisp> <vsyncstart> <vsyncend> <vtotal> [flags]
  # Only fields 2 and 6 (hdisp/vdisp) are geometry; everything else is timing and polarity, which
  # matter enormously at the wire (see the `modeline` option) and not at all to a rectangle.
  parseModeline = s:
    let
      toks = lib.filter (t: t != "")
        (lib.splitString " " (lib.replaceStrings [ "\t" "\n" ] [ " " " " ] s));
      hd = builtins.elemAt toks 1;
      vd = builtins.elemAt toks 5;
    in
    if lib.length toks < 9 then null
    else if builtins.match "[0-9]+" hd == null || builtins.match "[0-9]+" vd == null then null
    else { w = lib.toInt hd; h = lib.toInt vd; };

  # An output with no `mode` and no `modeline` runs at the panel's own preferred mode, which the
  # registry records as `nativeMode` -- so the registry is what makes the overlap check work for
  # the ordinary, mode-less layout entry instead of it giving up on every such output.
  registryMode = o:
    if o.monitor != null && monitors ? ${o.monitor}
    then monitors.${o.monitor}.nativeMode
    else null;

  pixelSize = o:
    if o.mode != null then parseMode o.mode
    else if o.modeline != null then parseModeline o.modeline
    else let nm = registryMode o; in if nm == null then null else parseMode nm;

  # A 90 or 270 turn (flipped or not) exchanges the axes: a 3840x2160 panel turned on its side
  # occupies 2160 logical columns and 3840 logical rows. Forgetting this is the classic way a
  # portrait monitor "overlaps nothing" in a config and overlaps everything on screen.
  swapsAxes = t: lib.elem t [ "90" "270" "flipped-90" "flipped-270" ];

  # POSITION AND SIZE ARE LOGICAL PIXELS, not physical ones -- that is the coordinate space both
  # compositors lay outputs out in, and it is what `position` means. Logical size is the mode's
  # pixel size divided by `scale`, THEN axis-swapped by the transform. `* 1.0` forces float
  # division: Nix's `/` on two integers truncates, and a 2560-wide panel at scale 1.5 is 1706.67
  # logical columns, not 1706 -- a rounding error of that size is exactly large enough to turn a
  # real one-pixel overlap into a clean-looking layout.
  logicalSize = o:
    let
      px = pixelSize o;
      s = if o.scale == null then 1.0 else o.scale;
      w = (if swapsAxes o.transform then px.h else px.w) * 1.0 / s;
      h = (if swapsAxes o.transform then px.w else px.h) * 1.0 / s;
    in
    if px == null then null else { inherit w h; };

  # ── Flattening every layout's outputs into addressable records ──────────────────────────────
  #
  # Every assertion below has to name the offending entry precisely, and `outputs` is a LIST, so
  # the index is the only address it has. Carrying it alongside the value from the start is what
  # lets each message say `nixdesktop.layouts.docked.outputs[2]` rather than "an output".
  entriesOf = lname: l: lib.imap0 (i: o: { layout = lname; index = i; output = o; }) l.outputs;
  allEntries = lib.concatLists (lib.mapAttrsToList entriesOf cfg);

  # How a message refers to an entry. Deliberately quotes the selector the consumer actually
  # wrote, so the error text can be grepped straight back into the config.
  selectorOf = o:
    if o.monitor != null then ''monitor "${o.monitor}"''
    else if o.connector != null then ''connector "${o.connector}"''
    else "an output naming neither a monitor nor a connector";

  addressOf = e: "nixdesktop.layouts.${e.layout}.outputs[${toString e.index}] (${selectorOf e.output})";

  # ── Per-layout geometry: only ENABLED outputs occupy space ──────────────────────────────────
  #
  # `enable = false` renders the output OFF on both compositors, and an output that is off has no
  # rectangle at all -- so it is excluded from both the all-or-nothing positioning requirement and
  # the overlap arithmetic. Including it would forbid the entirely ordinary "this layout turns the
  # laptop panel off while docked" case.
  enabledEntries = lname: l: lib.filter (e: e.output.enable) (entriesOf lname l);

  # Pairwise combinations without repetition -- every unordered pair exactly once, so a colliding
  # pair is reported once rather than twice with the names swapped.
  pairsOf = xs:
    lib.concatLists (lib.imap0 (i: a: map (b: { inherit a b; }) (lib.drop (i + 1) xs)) xs);

  rectOf = e:
    let sz = logicalSize e.output; in
    if sz == null || e.output.position == null then null
    else { x = e.output.position.x * 1.0; y = e.output.position.y * 1.0; inherit (sz) w h; };

  # `builtins.toString` renders EVERY float with six decimal places, so an honest rectangle comes
  # out as "1920.000000x1080.000000" and the one message a human reads while hunting an overlap is
  # mostly zeros. Trim a wholly-zero fraction, and trailing zeros otherwise -- 1706.666667 (a
  # 2560-wide panel at scale 1.5, a real value) must survive intact.
  renderNum = n:
    let
      s = toString n;
      integral = builtins.match "(-?[0-9]+)\\.0*" s;
      trimmed = builtins.match "(-?[0-9]+\\.[0-9]*[1-9])0*" s;
    in
    if integral != null then builtins.elemAt integral 0
    else if trimmed != null then builtins.elemAt trimmed 0
    else s;

  renderRect = r:
    "${renderNum r.w}x${renderNum r.h} logical at (${renderNum r.x}, ${renderNum r.y})"
    + ", spanning x ${renderNum r.x}..${renderNum (r.x + r.w)}"
    + " and y ${renderNum r.y}..${renderNum (r.y + r.h)}";

  # Half-open rectangles: an output ending at x=1920 and one starting at x=1920 are adjacent, not
  # overlapping. That is the single most common correct layout there is, so the comparison has to
  # be strict on both sides or every side-by-side desk fails to build.
  overlaps = p: q: p.x < q.x + q.w && q.x < p.x + p.w && p.y < q.y + q.h && q.y < p.y + p.h;

  overlappingPairs = lib.concatLists (lib.mapAttrsToList
    (lname: l:
      let placed = lib.filter (e: rectOf e != null) (enabledEntries lname l);
      in lib.filter (pr: overlaps (rectOf pr.a) (rectOf pr.b)) (pairsOf placed))
    cfg);

  # An enabled, positioned output whose size cannot be computed from anything available. Not an
  # error -- the layout is legal and the compositor will use the panel's preferred mode -- but the
  # overlap check above cannot see it, and silently checking less than the config says is exactly
  # the class of failure this module exists to remove. So it says so.
  unsizedPlaced = lib.concatLists (lib.mapAttrsToList
    (lname: l: lib.filter
      (e: e.output.position != null && logicalSize e.output == null)
      (enabledEntries lname l))
    cfg);

  partiallyPositioned = lib.concatLists (lib.mapAttrsToList
    (lname: l:
      let
        anyPositioned = lib.any (o: o.position != null) l.outputs;
        missing = lib.filter (e: e.output.position == null) (enabledEntries lname l);
      in
      lib.optionals anyPositioned missing)
    cfg);

  outputModule = {
    options = {
      monitor = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "u4323qe";
        description = ''
          A slug into `nixdesktop.monitors` -- the panel this entry configures, wherever it is
          plugged in. Exactly one of `monitor` or `connector` must be set: the two are the two
          ways an output can be addressed, and setting both would leave it ambiguous which one a
          compositor should emit while setting neither addresses nothing at all.

          Naming the registry rather than repeating make/model/serial here is what makes a layout
          portable between hosts and what lets the overlap arithmetic below fall back to the
          panel's recorded `nativeMode` when this entry pins no mode of its own.
        '';
      };

      connector = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "DVI-I-1";
        description = ''
          A connector name on THIS host -- "eDP-1", "DP-2", "VGA-1", "DVI-I-1". The other of the
          two ways to address an output, and the only one available in three real cases:

            - a panel whose EDID carries no usable serial, so its identity triple is shared with
              every other unit of its model (`nixdesktop.monitors.<name>.identifiable = false`);
            - evdi/DisplayLink outputs, which expose a ZERO-BYTE EDID -- there is no make, model
              or serial to match on at all, ever, so connector matching is the only mechanism;
            - a socket whose occupant is deliberately not part of the estate registry (a
              conference-room projector, a borrowed screen).

          ⚠ evdi hardcodes `DRM_MODE_CONNECTOR_DVII`, so DisplayLink outputs always appear as
          `DVI-I-N`, and N is fixed at module load by `initial_device_count` rather than by what
          is plugged in. WHICH physical panel lands in which slot is decided by the closed
          DisplayLinkManager's enumeration order and is not something this repo can promise.
        '';
      };

      match = mkOption {
        type = types.enum [ "identity" "connector" ];
        default = "identity";
        description = ''
          Which of the two matcher spellings the compositor should emit for this output:
          `"identity"` -- the `"<make> <model> <serial>"` triple derived in
          `nixdesktop.monitors.<name>.identifier` -- or `"connector"`, the connector name.

          Redundant with which of `monitor`/`connector` is set, ON PURPOSE, and asserted to agree
          with it. The two facts are written independently and checked against each other because
          the failure they guard against is silent on both compositors: a matcher that matches
          nothing is not an error, it simply leaves that output at its default mode, position and
          scale. Stating the intent twice makes the build the place that catches a mismatch.

          Defaults to `"identity"`, so a `connector`-addressed entry must say
          `match = "connector"` explicitly. That is deliberate rather than inferred: the two
          addressing modes have genuinely different stability properties (an identity roams with
          the panel, a connector stays with the socket) and quietly swapping one for the other on
          a consumer's behalf is how a layout ends up applying to the wrong screen after a dock
          change.
        '';
      };

      enable = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Whether this output is on. `false` renders it OFF -- the compositor's own disable
          statement, not merely an omitted block -- which is how a docked layout turns the laptop
          panel off. A disabled output occupies no space, so it takes part in neither the
          all-or-nothing positioning rule nor the overlap arithmetic.
        '';
      };

      mode = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "1920x1080@60";
        description = ''
          `WIDTHxHEIGHT@REFRESH`, or `null` to let the compositor pick the panel's preferred
          mode. When null, the overlap arithmetic falls back to
          `nixdesktop.monitors.<name>.nativeMode`, and if that is null too the output's rectangle
          is unknown and the check reports (as a warning) that it could not include it.
        '';
      };

      modeline = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "148.50 1920 2008 2052 2200 1080 1084 1089 1125 +hsync +vsync";
        description = ''
          A RAW MODELINE INCLUDING SYNC POLARITY -- the nine timing numbers followed by the
          `+hsync`/`-hsync` and `+vsync`/`-vsync` flags -- for the case where no named mode can
          express what the hardware needs.

          THIS OPTION EXISTS BECAUSE OF A REAL, MEASURED WALL, not for completeness. On this
          estate's ASPEED ast2500 BMC framebuffer, 1920x1080 is reachable ONLY with POSITIVE
          horizontal and vertical sync. The kernel's own `drm_dmt_modes[]` entry 0x52 carries
          1080p60 with negative/negative polarity, while CTA-861 VIC 16 carries byte-identical
          timing with positive/positive -- and the ast driver's `res_1920x1080[]` table demands
          SyncPP. Which of the two the panel offers therefore decides whether the mode works at
          all, and no `video=` kernel command-line syntax can express `+hsync +vsync`: that
          grammar has no polarity field. A modeline is the only surface in the entire stack that
          can state it, which is why it is an option here rather than an escape hatch.

          Geometry for the overlap check is read from fields 2 and 6 (hdisp/vdisp); the timing and
          polarity are passed through to the compositor untouched.
        '';
      };

      scale = mkOption {
        type = types.nullOr types.numbers.positive;
        default = null;
        example = 1.5;
        description = ''
          Logical-pixel scale factor, or `null` for the compositor's own default (1). Accepts an
          integer or a float -- `2` and `1.5` are both ordinary values and demanding `2.0` would
          be a papercut with no upside -- but never zero or negative, which are not scales and
          would make the logical-size arithmetic below meaningless rather than wrong.

          Load-bearing for the overlap check: logical size is the mode's pixel size DIVIDED by
          this, so a 3840x2160 panel at scale 2 occupies a 1920x1080 rectangle and a layout that
          places its neighbour at x=1920 is correct, not overlapping.
        '';
      };

      position = mkOption {
        type = types.nullOr (types.submodule {
          options = {
            x = mkOption {
              type = types.int;
              description = "Logical-pixel X of this output's top-left corner.";
            };
            y = mkOption {
              type = types.int;
              description = "Logical-pixel Y of this output's top-left corner.";
            };
          };
        });
        default = null;
        description = ''
          Top-left corner in the compositor's LOGICAL pixel space, or `null`.

          ALL-OR-NOTHING, and asserted: if any output in a layout sets this, every ENABLED output
          in that layout must. A partially-positioned layout drifts on both compositors, for two
          different reasons, and neither of them announces itself:

            - sway/scroll auto-place a position-less output immediately to the RIGHT of the
              rightmost already-placed one, walking outputs in the order their connectors appear.
              That order changes across boots, hotplugs and dock re-enumerations, so the unplaced
              screen physically moves between sessions with no config change at all.
            - niri, handed a configured position that overlaps an already-placed output by even
              one logical pixel, SILENTLY DISCARDS it and auto-places that output instead, leaving
              nothing behind but one warn line. The config keeps saying what you wrote.

          Negative coordinates are ordinary and correct: the origin is wherever the first output
          lands, so a screen to the LEFT of it has a negative x.
        '';
      };

      transform = mkOption {
        type = types.enum [
          "normal"
          "90"
          "180"
          "270"
          "flipped"
          "flipped-90"
          "flipped-180"
          "flipped-270"
        ];
        default = "normal";
        description = ''
          How the output is turned, COUNTER-CLOCKWISE -- the same direction and the same
          vocabulary as the `wl_output` protocol's own transform enum. That choice is what makes
          this the NEUTRAL spelling rather than either compositor's:

            - niri's config transform values are already counter-clockwise, so nixniri passes
              these through verbatim.
            - scroll/sway's config transform values are CLOCKWISE. sway calls
              `invert_rotation_direction()` on every transform it parses, so a config saying `90`
              produces a 270 counter-clockwise turn on the wire. nixscroll's translator must
              therefore SWAP 90 <-> 270 and flipped-90 <-> flipped-270 (180, normal, flipped and
              flipped-180 are their own inverses and pass through).

          Getting that inversion wrong is a 180-degree error in the one case a human is least
          likely to have a second machine to compare against, so it is stated here, once, and each
          compositor repo's translator is checked against this sentence rather than against the
          other repo.

          A 90 or 270 transform (flipped or not) EXCHANGES the output's logical width and height,
          which the overlap arithmetic below accounts for.
        '';
      };
    };
  };

  layoutModule = {
    options = {
      description = mkOption {
        type = types.str;
        example = "Docked at the desk: 43\" 4K centre, laptop panel off.";
        description = ''
          What situation this layout is FOR, in a sentence -- "docked at the desk", "undocked",
          "the KVM position". Required, with no default, because a layout's name is a slug and the
          only thing that ever tells the next reader whether `desk2` is the second desk or the
          second arrangement of the first one is a human sentence. Never branched on.
        '';
      };

      outputs = mkOption {
        type = types.listOf (types.submodule outputModule);
        default = [ ];
        description = ''
          The outputs this layout arranges, each addressed either by a `nixdesktop.monitors` slug
          or by a connector name. A list rather than an attrset because an output has two
          different kinds of key (a registry slug and a connector name) and forcing one of them
          into the attribute position would make the other one a second-class citizen.
        '';
      };
    };
  };
in
{
  options.nixdesktop.layouts = mkOption {
    type = types.attrsOf (types.submodule layoutModule);
    default = { };
    example = lib.literalExpression ''
      {
        docked = {
          description = "Docked at the desk: 43\" 4K centre, laptop panel off.";
          outputs = [
            { monitor = "u4323qe"; mode = "3840x2160@60"; scale = 1.5; position = { x = 0; y = 0; }; }
            { connector = "eDP-1"; match = "connector"; enable = false; }
          ];
        };
      }
    '';
    description = ''
      Named output arrangements. A session names one (`nixdesktop.sessions.<name>.layout`) and a
      compositor module translates it. Empty by default: a host with no declared layout leaves
      output configuration entirely to the compositor's own defaults, which is a legitimate
      stance for a single-screen machine.
    '';
  };

  config.assertions =
    # ── EXACTLY ONE SELECTOR ──────────────────────────────────────────────────────────────────
    # Neither set addresses nothing; both set leaves it undecidable which matcher a compositor
    # should emit, and picking one silently would mean the config and the screen disagree.
    map
      (e: {
        assertion = false;
        message = ''
          nixdesktop.layouts.${e.layout}.outputs[${toString e.index}] sets
          ${if e.output.monitor != null then "BOTH `monitor` and `connector`" else "NEITHER `monitor` nor `connector`"}.
          Exactly one must be set: an output is addressed either by a `nixdesktop.monitors` slug
          (matched on the EDID identity triple, follows the panel between hosts) or by a connector
          name on this host (matched on the socket, stays with the machine). Those are the only
          two matchers either compositor has.
        '';
      })
      (lib.filter (e: (e.output.monitor == null) == (e.output.connector == null)) allEntries)

    # ── `match` MUST AGREE WITH THE SELECTOR, BOTH WAYS ───────────────────────────────────────
    # `match = "identity"` with no monitor has no identity triple to emit; `match = "connector"`
    # with no connector has no connector name to emit. Either one produces a matcher that matches
    # nothing, which neither compositor treats as an error -- the output just silently keeps its
    # defaults. Together these two also make an unidentifiable registry entry UNREFERENCEABLE,
    # which is the companion half of modules/monitors.nix's own assertion; see that file.
    ++ map
      (e: {
        assertion = false;
        message = ''
          ${addressOf e} sets `match = "identity"` but no `monitor`. Identity matching emits the
          `"<make> <model> <serial>"` triple from `nixdesktop.monitors.<name>.identifier`, and
          there is no registry entry here to take it from. Either name a `monitor`, or set
          `match = "connector"` to match the connector this entry does name.
        '';
      })
      (lib.filter (e: e.output.match == "identity" && e.output.monitor == null) allEntries)

    ++ map
      (e: {
        assertion = false;
        message = ''
          ${addressOf e} sets `match = "connector"` but no `connector`. Connector matching emits a
          connector NAME, which is a property of the socket on this host -- a
          `nixdesktop.monitors` slug cannot supply one, because the registry is fleet-wide and a
          roaming panel has no fixed socket. Give this entry `connector = "<name>"` instead of (or
          alongside a rewrite of) its `monitor` slug.
        '';
      })
      (lib.filter (e: e.output.match == "connector" && e.output.connector == null) allEntries)

    # ── A SLUG THE REGISTRY DOES NOT DECLARE ──────────────────────────────────────────────────
    # Rename/typo detection, and only meaningful when the registry module is actually composed --
    # a host that addresses only connectors imports no registry, and an empty-registry error there
    # would be an error about nothing.
    ++ lib.optionals monitorsComposed (map
      (e: {
        assertion = false;
        message = ''
          ${addressOf e} names the monitor slug "${e.output.monitor}", which
          `nixdesktop.monitors` does not declare. Declared slugs:
          ${if monitors == { } then "  (none)" else lib.concatMapStringsSep "\n" (n: "            - ${n}") (lib.attrNames monitors)}
        '';
      })
      (lib.filter (e: e.output.monitor != null && !(monitors ? ${e.output.monitor})) allEntries))

    # ── ALL-OR-NOTHING POSITIONING ────────────────────────────────────────────────────────────
    # See the `position` option for the two silent drifts this prevents.
    ++ map
      (e: {
        assertion = false;
        message = ''
          ${addressOf e} has no `position`, but another output in layout "${e.layout}" does.
          Positioning is all-or-nothing across a layout's ENABLED outputs. sway/scroll auto-place
          a position-less output to the right of the rightmost placed one in connector-appearance
          order -- an order that is not stable across boots or dock re-enumerations -- and niri
          auto-places it too. Either give every enabled output in this layout an explicit
          position, or give none of them one and let the compositor arrange the whole set.
        '';
      })
      partiallyPositioned

    # ── OVERLAP ───────────────────────────────────────────────────────────────────────────────
    # The check that makes niri's silent discard impossible to reach. Rectangles are LOGICAL
    # pixels: mode size / scale, axes exchanged by a 90/270 transform.
    ++ map
      (pr: {
        assertion = false;
        message = ''
          nixdesktop.layouts.${pr.a.layout}: two enabled outputs overlap.
            - ${selectorOf pr.a.output} at index ${toString pr.a.index}: ${renderRect (rectOf pr.a)}
            - ${selectorOf pr.b.output} at index ${toString pr.b.index}: ${renderRect (rectOf pr.b)}
          niri does not reject an overlapping position: it SILENTLY DISCARDS the configured
          position of whichever output it places second, auto-places it instead, and logs one warn
          line -- so the running layout stops matching this file with nothing on screen to say so.
          Note these are LOGICAL pixels (mode size divided by `scale`, width and height exchanged
          by a 90/270 transform), which is the space `position` is expressed in; a 3840x2160 panel
          at scale 2 occupies 1920x1080, not 3840x2160.
        '';
      })
      overlappingPairs;

  config.warnings = map
    (e: ''
      ${addressOf e} is enabled and positioned, but its logical size cannot be computed: it pins
      no `mode`, carries no `modeline`, and ${if e.output.monitor == null then "addresses a connector, so there is no registry entry to take a `nativeMode` from" else "its `nixdesktop.monitors` entry records no `nativeMode`"}.
      This layout is legal -- the compositor will use the panel's preferred mode -- but the
      overlap check above could not include this output, so it proves less than it appears to.
      Record `nixdesktop.monitors.<name>.nativeMode`, or pin a `mode` here, to close the gap.
    '')
    unsizedPlaced;
}
