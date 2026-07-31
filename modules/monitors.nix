# modules/monitors.nix — the FLEET-WIDE monitor registry: every physical panel this estate owns,
# addressed by the identity its own EDID actually carries.
#
# WHY THIS IS ESTATE-LEVEL AND NOT HOST STANCE. A monitor is not a property of a machine. The same
# 4K panel sits in front of whichever box is plugged into it this week; a laptop carries its own
# eDP panel between three docks; a DisplayLink dock moves between two desks. Declaring panels
# per-host would mean writing the same make/model/serial triple down once per host that has ever
# seen it — and the moment two hosts spell one panel differently, they are describing two objects
# that do not exist. So identity lives HERE, once, imported everywhere, and a host says only which
# panels a given layout expects and where they sit (modules/layouts.nix). Nothing in this file is
# host-specific and nothing in it is a stance; it is a table of facts about hardware.
#
# WHAT THE COMPOSITORS ACTUALLY MATCH ON — read out of both sources, not assumed. niri and
# scroll/sway share exactly one output-identity vocabulary, with two spellings:
#
#   1. the CONNECTOR name — "eDP-1", "DP-2", "DVI-I-1" — a property of the socket on the host, and
#      therefore not something this file can ever carry (see above: a panel roams, a socket does
#      not). Layouts carry connector names; the registry never does.
#   2. a single-space-separated "<make> <model> <serial>" triple, with the literal word `Unknown`
#      substituted for any EDID field the panel did not supply.
#
# `identifier` below assembles spelling 2 ONCE, here, so that no compositor repo ever builds that
# string a second time. Two independent assemblies is one separator disagreement or one differing
# Unknown-substitution away from a matcher that silently matches nothing — and a matcher that
# matches nothing does not error on either compositor, it just leaves the output at its default
# mode, position and scale, which reads as "my config was ignored" with no line to blame.
#
# WHY IDENTITY IS A CORRECTNESS PROBLEM AND NOT A CONVENIENCE. Both compositors remember which
# workspaces belong to which output, keyed by exactly this identity (niri's `original_output`,
# sway/scroll's `output_priority`). Two outputs that resolve to the SAME identity string are
# niri #734: not a clean "ambiguous match" error but workspace-assignment corruption — workspaces
# migrate to the wrong panel and, on the reported crash path, take the compositor with them. That
# is why the uniqueness assertion below is the point of this module rather than a nicety.
{ lib, config, ... }:
let
  inherit (lib) types mkOption;

  cfg = config.nixdesktop.monitors;

  # THE LITERAL BOTH COMPOSITORS SUBSTITUTE, not a placeholder this repo invented. Writing
  # anything else here (an empty string, "unknown", "-") produces a triple that matches no output
  # on either compositor, silently.
  unknownField = "Unknown";
  orUnknown = v: if v == null || v == "" then unknownField else v;

  identifierOf = e: "${orUnknown e.make} ${orUnknown e.model} ${orUnknown e.serial}";

  # THE 0x-FALLBACK TRAP, and it is live in this estate rather than theoretical.
  #
  # EDID carries a serial in two independent places: a 4-byte NUMERIC field in the base block, and
  # an optional 0xFF descriptor holding a real serial STRING. libdisplay-info — the library both
  # compositors reach the EDID through — renders the numeric field as `0x%08X` when the 0xFF
  # descriptor is absent, and that rendered hex is what lands in the "serial" position of the
  # matcher triple. The numeric field is not required to be unique and is routinely a constant:
  # this estate's HP LA2306 ships the dummy value 0x01010101, so EVERY LA2306 ever manufactured
  # would present the identical triple "HP Inc. HP LA2306 0x01010101". That panel is rescued only
  # because HP also wrote a real 0xFF descriptor — which is luck, not a property of the model.
  #
  # So a serial matching `0x` + exactly 8 hex digits is treated as NO IDENTITY. A false positive
  # here (a genuine serial string that happens to look like that) costs one explicit
  # connector-matched layout entry; a false negative costs the niri #734 corruption above.
  isNumericSerialFallback = s: s != null && builtins.match "0x[0-9A-Fa-f]{8}" s != null;

  # The three EDID fields, shared verbatim by a monitor and by each of its aliases — an alias is
  # the SAME panel seen through a different input, so it is described by exactly the same fields.
  edidOptions = {
    make = mkOption {
      type = types.str;
      example = "Dell Inc.";
      description = ''
        The vendor NAME as the compositors report it — the expanded string, not the three-letter
        PNP id. EDID stores the manufacturer as a packed PNP id (`DEL`), and libdisplay-info
        expands it against the UEFI PNP-id registry before either compositor sees it, so a
        matcher written with the raw id matches nothing. Take this from the compositor's own
        output listing (`niri msg outputs`, `swaymsg -t get_outputs`) rather than from a
        datasheet: the registry's expansion is the only spelling that matters here.
      '';
    };

    model = mkOption {
      type = types.str;
      example = "DELL U4323QE";
      description = ''
        The model as carried by the EDID 0xFC (display-name) descriptor. Frequently NOT the
        marketing name and frequently oddly cased — vendors write whatever fits the 13-byte
        descriptor — so, again, copy it from the compositor's own listing rather than from the
        box the panel came in.
      '';
    };

    serial = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "9BQR2P3";
      description = ''
        The serial as carried by the EDID 0xFF (serial-string) descriptor, or `null` for a panel
        that ships no such descriptor. `null` renders as the literal `Unknown` inside
        `identifier` and sets `identifiable` to false — a panel with no serial is
        indistinguishable from every other unit of the same model, which is a fact about the
        hardware, not a gap in this table.

        ⚠ DO NOT paste a `0x` + 8-hex-digit value here believing it is a serial. That shape is
        libdisplay-info's fallback rendering of EDID's numeric serial FIELD, emitted precisely
        BECAUSE the 0xFF descriptor was absent, and the numeric field is routinely a per-model
        constant rather than a per-unit value (this estate's HP LA2306: 0x01010101, shared by
        every LA2306 ever made). Such a value is detected and treated as no identity at all — see
        `identifiable` and this file's own header.
      '';
    };
  };

  # An alias, and a monitor, both derive their `identifier` from the same three fields — so the
  # derivation lives in one submodule fragment used by both.
  identityModule = { config, ... }: {
    options = edidOptions // {
      identifier = mkOption {
        type = types.str;
        readOnly = true;
        description = ''
          READ-ONLY, derived. The exact `"<make> <model> <serial>"` string both niri and
          scroll/sway match an output against, with the literal `Unknown` substituted for a
          missing field. Derived here and nowhere else — a compositor module reads this string
          and emits it verbatim, and therefore cannot disagree with any other compositor module
          about how the triple is spelled.
        '';
      };
    };
    # A `config` DEFINITION, never an option `default`, and the difference is the whole guard:
    # `readOnly` rejects a SECOND definition, so defining it here means a consumer who tries to
    # set `identifier` gets a build failure. Had this been a `default`, a consumer's single
    # definition would simply have replaced it -- readOnly counts definitions, and one is allowed.
    config.identifier = identifierOf config;

  };

  monitorModule = { config, ... }: {
    options = edidOptions // {
      aliases = mkOption {
        type = types.listOf (types.submodule identityModule);
        default = [ ];
        example = lib.literalExpression ''
          [ { make = "Dell Inc."; model = "DELL U4323QE"; serial = "9BQR2P3"; } ]
        '';
        description = ''
          Per-INPUT EDID variants of the SAME panel. Not a list of other monitors: a single panel
          with several inputs commonly presents a DIFFERENT EDID on each one (a distinct model
          string for the USB-C input versus the DisplayPort input is the usual shape, and some
          KVM-style panels rewrite the descriptor per input entirely). A compositor sees each of
          those as a different identity, so a layout that names this panel has to be emitted once
          per variant or it silently fails to apply on whichever input happens to be live.

          Each alias derives its own `identifier` exactly as the monitor does, and every one of
          them participates in the uniqueness assertion below — an alias that collides with
          another panel is the identical niri #734 hazard as a monitor that does.
        '';
      };

      nativeMode = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "3840x2160@60";
        description = ''
          The panel's own preferred mode, as `WIDTHxHEIGHT@REFRESH`, or `null` when it is not
          worth recording. This is a FACT about the panel, never a request: a layout that wants a
          mode says so itself (`nixdesktop.layouts.<name>.outputs.*.mode`). It is recorded here
          because it is the size an output actually takes when a layout does NOT pin a mode, which
          makes it the only way the overlap arithmetic in modules/layouts.nix can compute a
          logical rectangle for a mode-less output rather than give up on it.
        '';
      };

      physicalSize = mkOption {
        type = types.nullOr (types.submodule {
          options = {
            widthMm = mkOption {
              type = types.ints.positive;
              example = 941;
              description = "Active image width in millimetres, as carried by EDID.";
            };
            heightMm = mkOption {
              type = types.ints.positive;
              example = 529;
              description = "Active image height in millimetres, as carried by EDID.";
            };
          };
        });
        default = null;
        description = ''
          The panel's physical active area, or `null`. Recorded rather than computed because EDID
          is the only source for it and it is the input to any honest DPI statement — but nothing
          in this repo branches on it, deliberately: picking a scale from DPI is a taste decision
          that belongs in a layout, where a human wrote a number they can see the effect of.
        '';
      };

      notes = mkOption {
        type = types.str;
        default = "";
        example = "Panel-side scaler mangles 1080p over DVI; use the DP input.";
        description = ''
          Free text for whoever reads this table next — a quirk, a desk, a cable. NEVER branched
          on by any module in this family, and that is a guarantee rather than an accident: the
          moment a note becomes load-bearing it is a fact that deserves its own typed option, and
          the right move is to add one, not to grep this string.
        '';
      };

      identifier = mkOption {
        type = types.str;
        readOnly = true;
        description = ''
          READ-ONLY, derived — see the identical option on `aliases` above. This is the string a
          compositor module emits when a layout matches this monitor by identity.
        '';
      };

      identifiable = mkOption {
        type = types.bool;
        readOnly = true;
        description = ''
          READ-ONLY, derived. False when this panel has NO STABLE IDENTITY — either `serial` is
          `null`, or it is libdisplay-info's `0x`+8-hex-digit rendering of EDID's numeric serial
          field, which is regularly a per-model constant rather than a per-unit value (see this
          file's header for the HP LA2306 case that makes this real rather than defensive).

          An unidentifiable panel cannot be addressed by identity at all: its triple is shared
          with every other unit of the same model, and two outputs resolving to one identity is
          the niri #734 workspace-corruption path, not a clean error. So a layout must address it
          by connector instead — asserted below.
        '';
      };
    };

    # Definitions rather than option `default`s, for the reason spelled out on `identityModule`
    # above: only a definition makes `readOnly` actually reject a consumer overriding a derived
    # fact.
    config = {
      identifier = identifierOf config;
      identifiable = config.serial != null && !(isNumericSerialFallback config.serial);
    };
  };

  # ── Every identity this registry puts on the wire, monitors and aliases alike ────────────────
  #
  # Flattened into one list with its own provenance string, because the uniqueness assertion has
  # to name WHERE each colliding declaration lives — "two things collide" is not actionable, "this
  # monitor and that monitor's second alias collide" is.
  identities = lib.concatLists (lib.mapAttrsToList
    (slug: m:
      [{ where = "nixdesktop.monitors.${slug}"; inherit (m) identifier; }]
      ++ lib.imap0
        (i: a: {
          where = "nixdesktop.monitors.${slug}.aliases[${toString i}]";
          inherit (a) identifier;
        })
        m.aliases)
    cfg);

  collisions = lib.filterAttrs (_: entries: lib.length entries > 1)
    (lib.groupBy (e: e.identifier) identities);

  # ── The layout cross-check ───────────────────────────────────────────────────────────────────
  #
  # WHY IT LIVES HERE AND NOT IN modules/layouts.nix. The fact being defended is a property of the
  # MONITOR — "this panel has no stable identity" — and this is the module that knows it. Reading
  # layouts defensively (`config.nixdesktop ? layouts`) rather than the other way round also keeps
  # the dependency one-way: layouts may be composed without monitors (a host that only ever
  # addresses connectors needs no registry at all), and monitors may be composed without layouts
  # (every host imports the estate registry; only some declare layouts).
  #
  # This is an INTRA-repo read, so a bare `?` is correct here and `lib.probeFact` would be the
  # wrong tool: probeFact exists to tell "the sibling REPO is not composed" from "it is composed
  # but the leaf was renamed", and a rename inside this repo is caught by this repo's own checks
  # in the same commit that makes it.
  layouts = if config.nixdesktop ? layouts then config.nixdesktop.layouts else { };

  slugReferences = lib.concatLists (lib.mapAttrsToList
    (lname: l: lib.imap0 (i: o: { layout = lname; index = i; output = o; }) l.outputs)
    layouts);

  # Only a reference that (a) names a slug this registry actually declares, (b) whose panel has no
  # stable identity, and (c) asks to be matched by that identity anyway. A slug this registry does
  # not declare is layouts.nix's assertion to make, not this one's.
  unidentifiableByIdentity = lib.filter
    (r:
      r.output.monitor != null
      && cfg ? ${r.output.monitor}
      && !cfg.${r.output.monitor}.identifiable
      && r.output.match != "connector")
    slugReferences;
in
{
  options.nixdesktop.monitors = mkOption {
    type = types.attrsOf (types.submodule monitorModule);
    default = { };
    example = lib.literalExpression ''
      {
        u4323qe = {
          make = "Dell Inc.";
          model = "DELL U4323QE";
          serial = "9BQR2P3";
          nativeMode = "3840x2160@60";
          physicalSize = { widthMm = 941; heightMm = 529; };
        };
        la2306 = {
          make = "HP Inc.";
          model = "HP LA2306";
          serial = "3CQ1234567";  # a REAL 0xFF descriptor — see `serial`'s own warning
        };
      }
    '';
    description = ''
      The estate's monitors, keyed by a short slug a layout refers to. Fleet-wide, not per-host: a
      panel roams between machines, so its identity is declared once and imported everywhere,
      while WHICH panels a machine expects and WHERE they sit is a layout
      (`nixdesktop.layouts`). Empty by default — a host that only ever addresses connectors
      (a headless box, an evdi-only dock) needs no entries here at all.
    '';
  };

  config.assertions =
    # ── COLLIDING IDENTITIES ──────────────────────────────────────────────────────────────────
    # The one assertion this module exists for. See the header: a duplicate identity is not an
    # ambiguous match that errors, it is niri #734 — workspace assignment silently attaches to the
    # wrong panel, and on the reported path takes the compositor down with it. Aliases count,
    # because a compositor cannot tell an alias from a monitor; both are just strings on the wire.
    lib.mapAttrsToList
      (identifier: entries: {
        assertion = false;
        message = ''
          nixdesktop.monitors: ${toString (lib.length entries)} declarations resolve to the SAME
          output identity "${identifier}":
          ${lib.concatMapStringsSep "\n" (e: "            - ${e.where}") entries}
          Both niri and scroll/sway match outputs on exactly this string and key remembered
          workspaces to it, so a duplicate does not produce an "ambiguous output" error — it
          produces workspace assignments attached to whichever panel resolved first (niri #734).
          Give the colliding panels distinguishing EDID serials, or, if they genuinely share one
          (two identical units of a model that ships no 0xFF descriptor), stop addressing them by
          identity and give each layout entry an explicit `connector` instead.
        '';
      })
      collisions

    # ── AN UNIDENTIFIABLE PANEL ADDRESSED BY IDENTITY ─────────────────────────────────────────
    # `identifiable = false` means the triple this panel produces is shared with every other unit
    # of its model — so matching on it is the collision above, waiting for the second unit to
    # arrive. The only correct address for such a panel is the connector it is plugged into.
    #
    # COMPANION RULE, and the two are only complete together: modules/layouts.nix asserts that
    # `match = "connector"` requires a `connector` to actually be set, and that exactly one of
    # `monitor`/`connector` is set per output. Taken together those make an unidentifiable slug
    # UNREFERENCEABLE — `match = "identity"` fails here, `match = "connector"` fails there for
    # want of a connector name — which is exactly the intent: declare the panel in the registry
    # for the record, address it in layouts by its socket.
    ++ map
      (r: {
        assertion = false;
        message = ''
          nixdesktop.layouts.${r.layout}.outputs[${toString r.index}] addresses the monitor
          "${r.output.monitor}" by identity (match = "${r.output.match}"), but that panel's
          `identifiable` is false: its EDID carries no 0xFF serial descriptor, or carries only
          libdisplay-info's `0x`+8-hex-digit rendering of the numeric serial field, which is
          regularly a per-model constant. Its identity string
          "${cfg.${r.output.monitor}.identifier}" is therefore shared with every other unit of
          this model, and two outputs resolving to one identity corrupts remembered workspace
          assignment on both compositors (niri #734) rather than erroring.
          Address this output by its socket instead: replace `monitor = "${r.output.monitor}"`
          with `connector = "<name>"` and `match = "connector"`.
        '';
      })
      unidentifiableByIdentity;
}
