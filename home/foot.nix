# home/foot.nix — declarative foot config (~/.config/foot/foot.ini), sibling to the other
# home/*.nix modules in this repo. Compositor-neutral: foot is a Wayland terminal and does not
# care which compositor is feeding it, so nothing here names one.
#
# CONFIG ONLY, NEVER THE PACKAGE — `xdg.configFile`, deliberately NOT home-manager's own
# `programs.foot`. `programs.foot` installs `pkgs.foot` into ~/.nix-profile/bin, which on a foreign
# distro sits ahead of /usr/bin on PATH and therefore SHADOWS the distro's own foot — the copy a
# platform backend installed for the `terminal` role, the copy a compositor module's keybind
# spawns, and the copy `$TERMINAL` names. That is not a harmless duplicate: on an Arch/CachyOS host
# the nixpkgs build links a different libc and a different Mesa than everything else in the
# session, and it is the one every keybind then reaches, so the terminal that opens is not the
# terminal the rest of the config describes. Every module in this directory follows the same
# contract for the same reason — Nix owns the config, the platform owns the binary — and none of
# them installs anything.
#
# `font` HAS NO DEFAULT, ON PURPOSE. This is the one option a consumer must state, because it is
# the one this module cannot guess and the one whose wrong answer fails quietly. foot's own
# fallback is the fontconfig alias `monospace`, but any *named* family that is not installed does
# not fall back to a monospace face at all: fontconfig substitutes by its own rules and can land on
# a proportional UI face, after which foot prints `font does not appear to be monospace` once at
# startup and renders every subsequent line in a sans face. A default here would be this module
# stating, on every consumer's behalf, a font it has no way to know is installed — and a wrong font
# name is indistinguishable from a right one until a terminal is actually open. So: the consumer
# names the family they installed, ideally by reading it from wherever they already declare it,
# rather than restating it here. Two places stating one fact is how a font name drifts.
#
# `[colors-dark]`, NOT `[colors]`. foot deprecated the plain `[colors]` section; `foot 1.27
# --check-config` on a file containing one answers `[colors]: deprecated; use [colors-dark]
# instead`. `[colors-dark]` is also what makes `colors.light` + `initial-color-theme` (and foot's
# runtime dark/light toggle, and SIGUSR1/SIGUSR2) work at all, so there is no reason to emit the
# older spelling even while it is still accepted.
#
# COLOURS ARE TYPED AS BARE RRGGBB, and that type is not pedantry: foot rejects both of the two
# spellings a person actually reaches for. `#141618` and `ff141618` (with alpha) each fail with
# `color must be in RGB format` — verified against foot 1.27. Transparency is foot's own separate
# `alpha` option, not a fourth colour component. Catching that at evaluation costs nothing and
# turns a terminal that opens with an error banner into a build that says which colour is wrong.
#
# A PALETTE IS DEFINED WHOLESALE OR NOT AT ALL. The colour sub-options are mandatory and the
# `colors.dark` option as a whole carries the default palette, so defining any part of a palette
# means defining all of it — a partial definition is an evaluation error rather than a silent
# blend of two palettes. That is the failure worth preventing: a `colors.light` that states a white
# background and inherits seven dark ANSI colours is a "light theme" nobody can read, and nothing
# about it would be visible in the diff that caused it.
#
# `settings` IS FOR SECTIONS AND KEYS THIS MODULE DOES NOT MANAGE, and restating a managed key
# there is an assertion failure, not a silent override. foot.ini has far more keys than any typed
# surface should try to model (bell, cursor, csd, key-bindings, mouse-bindings, regex, ...), so
# `settings` exists to reach all of them — but a consumer who writes `settings.main.font` alongside
# `font` has created exactly the two-places-one-fact shape the header above describes, and the
# winner would depend on merge order rather than on intent. Extending a managed section is fine and
# expected (`settings."colors-dark".dim0`, `settings.scrollback.multiplier`); restating a key the
# typed options own is not.
{ lib, config, ... }:
let
  cfg = config.nixdesktop.foot;

  # Exactly what foot accepts: six hex digits, no `#`, no alpha component. See the header.
  hexColor = lib.types.strMatching "[0-9a-fA-F]{6}";

  ansiColors = lib.types.addCheck (lib.types.listOf hexColor) (c: builtins.length c == 8) // {
    description = "list of exactly 8 RRGGBB colors (ANSI 0-7)";
  };

  paletteType = lib.types.submodule {
    options = {
      background = lib.mkOption {
        type = hexColor;
        example = "141618";
        description = "Default background colour (`background` in the colour section).";
      };

      foreground = lib.mkOption {
        type = hexColor;
        example = "fcfcfc";
        description = "Default foreground colour (`foreground` in the colour section).";
      };

      regular = lib.mkOption {
        type = ansiColors;
        example = [ "232627" "ed1515" "11d116" "f67400" "1d99f3" "9b59b6" "1abc9c" "fcfcfc" ];
        description = ''
          The eight basic ANSI colours, in palette order (black, red, green, yellow, blue,
          magenta, cyan, white). Rendered as `regular0` .. `regular7`.
        '';
      };

      bright = lib.mkOption {
        type = ansiColors;
        example = [ "7f8c8d" "c0392b" "1cdc9a" "fdbc4b" "3daee9" "8e44ad" "16a085" "ffffff" ];
        description = ''
          The eight bright ANSI colours, in the same palette order as `regular`. Rendered as
          `bright0` .. `bright7`.
        '';
      };
    };
  };

  # Breeze Dark. A DEFAULT, not a mandate: it is a widely recognised, published palette rather than
  # any one desktop's private taste, which is the only property that qualifies a palette to be a
  # default in a library repo. Override `colors.dark` wholesale to use another one.
  breezeDark = {
    background = "141618";
    foreground = "fcfcfc";
    regular = [ "232627" "ed1515" "11d116" "f67400" "1d99f3" "9b59b6" "1abc9c" "fcfcfc" ];
    bright = [ "7f8c8d" "c0392b" "1cdc9a" "fdbc4b" "3daee9" "8e44ad" "16a085" "ffffff" ];
  };

  indexed = prefix: colors:
    lib.listToAttrs (lib.imap0 (i: c: lib.nameValuePair "${prefix}${toString i}" c) colors);

  paletteSection = palette:
    { inherit (palette) background foreground; }
    // indexed "regular" palette.regular
    // indexed "bright" palette.bright;

  # Everything the typed options own, section by section. `settings` may extend these sections but
  # may not restate a key that appears here — see `restatedKeys` below and the header.
  managedSections =
    {
      main = {
        font = "${cfg.font}:size=${toString cfg.fontSize}";
        dpi-aware = cfg.dpiAware;
        pad = "${toString cfg.padding.horizontal}x${toString cfg.padding.vertical}";
        initial-color-theme = cfg.colors.initialTheme;
      };
      scrollback.lines = cfg.scrollbackLines;
      colors-dark = paletteSection cfg.colors.dark;
    }
    // lib.optionalAttrs (cfg.colors.light != null) {
      colors-light = paletteSection cfg.colors.light;
    };

  restatedKeys = lib.concatLists (lib.mapAttrsToList
    (section: keys:
      map (key: "${section}.${key}")
        (lib.filter (key: (managedSections.${section} or { }) ? ${key}) (lib.attrNames keys)))
    cfg.settings);

  sections = lib.recursiveUpdate managedSections cfg.settings;

  # `[main]` first, then the rest in the order `attrNames` yields (sorted, hence stable across
  # evaluations). Section order carries no meaning to foot; determinism is the only thing at stake,
  # and a config file whose byte content changes with nothing else is a diff that costs a reader
  # time for no reason.
  sectionOrder =
    lib.optional (sections ? main) "main"
    ++ lib.filter (name: name != "main") (lib.attrNames sections);

  # foot spells booleans `yes`/`no`. `toString` would emit `1` for true and the EMPTY STRING for
  # false — and foot rejects an empty value outright ("key/value pair has no value"), so the naive
  # stringification fails in both directions, one of them by writing a file foot refuses to read.
  renderValue = value:
    if value == true then "yes"
    else if value == false then "no"
    else toString value;

  renderSection = section:
    lib.concatStringsSep "\n" (
      [ "[${section}]" ]
      ++ lib.mapAttrsToList (key: value: "${key}=${renderValue value}") sections.${section}
    );
in
{
  options.nixdesktop.foot = {
    enable = lib.mkEnableOption "declarative foot config (~/.config/foot/foot.ini)";

    font = lib.mkOption {
      type = lib.types.str;
      example = "JetBrainsMono Nerd Font";
      description = ''
        Font family, in fontconfig syntax and WITHOUT a `size=` component — `fontSize` supplies
        that. Deliberately has no default: see this file's header for why naming a font that is
        not installed is a silent failure rather than a fallback, and why this module refuses to
        guess. Extra fontconfig options may be appended here
        (e.g. `"Iosevka:fontfeatures=cv01=1"`); the size is appended after them.

        Read it from wherever the same fleet already declares its monospace family rather than
        spelling it out a second time here.
      '';
    };

    fontSize = lib.mkOption {
      type = lib.types.numbers.positive;
      default = 8;
      example = 10;
      description = ''
        Font size in points, appended to `font` as `:size=<n>`. Fractional sizes are allowed.
        Defaults to foot's own default size, so a consumer who sets only `font` gets a foot that
        is sized exactly like an unconfigured one. For a pixel size instead, state it in `font`
        (`":pixelsize=n"`) — note that pixel sizes ignore `dpiAware`.
      '';
    };

    dpiAware = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        `dpi-aware`: size the font by the monitor's DPI (so a window keeps its physical size when
        dragged between monitors) instead of by the output's scaling factor. Defaults to foot's
        own default.
      '';
    };

    padding = {
      horizontal = lib.mkOption {
        type = lib.types.ints.unsigned;
        default = 2;
        example = 8;
        description = "Pixels of padding on the left and right edges (the `X` in foot's `pad=XxY`).";
      };

      vertical = lib.mkOption {
        type = lib.types.ints.unsigned;
        default = 2;
        example = 8;
        description = "Pixels of padding on the top and bottom edges (the `Y` in foot's `pad=XxY`).";
      };
    };

    scrollbackLines = lib.mkOption {
      type = lib.types.ints.unsigned;
      default = 1000;
      example = 10000;
      description = ''
        `[scrollback] lines`: how many lines of history a terminal keeps. Defaults to foot's own
        default; raise it in a consumer's own values if a build log should survive being scrolled
        past.
      '';
    };

    colors = {
      dark = lib.mkOption {
        type = paletteType;
        default = breezeDark;
        defaultText = lib.literalMD "the Breeze Dark palette";
        description = ''
          The palette rendered into `[colors-dark]`, and — unless `initialTheme` says otherwise —
          the palette foot starts with. Defined wholesale: stating any part of a palette means
          stating all of it, so that a partial definition is an evaluation error rather than a
          silent blend of two palettes (see this file's header).
        '';
      };

      light = lib.mkOption {
        type = lib.types.nullOr paletteType;
        default = null;
        description = ''
          The palette rendered into `[colors-light]`, or null to emit no light section at all.
          foot switches between the two at runtime via its `color-theme-toggle` binding or
          SIGUSR1/SIGUSR2, so a consumer who wants that toggle to do anything needs both.
        '';
      };

      initialTheme = lib.mkOption {
        type = lib.types.enum [ "dark" "light" ];
        default = "dark";
        description = ''
          `initial-color-theme`: which of the two palettes a new foot window starts with. Setting
          this to `light` without defining `colors.light` is an assertion failure — foot would
          silently start on its own built-in light colours, not on any palette stated here.
        '';
      };
    };

    settings = lib.mkOption {
      type = lib.types.attrsOf (lib.types.attrsOf (lib.types.oneOf [
        lib.types.str
        lib.types.int
        lib.types.float
        lib.types.bool
      ]));
      default = { };
      example = {
        cursor.style = "beam";
        key-bindings.spawn-terminal = "Control+Shift+n";
        scrollback.multiplier = 3.0;
      };
      description = ''
        Any foot.ini section this module does not model, as `<section>.<key> = <value>`. Booleans
        render as foot's `yes`/`no`. The top-level, section-less keys of foot.ini live in the
        explicitly named `main` section, which foot accepts as a synonym for them.

        May extend a section the typed options above already write to
        (`settings."colors-dark".dim0`, `settings.scrollback.multiplier`), but may NOT restate a
        key one of them owns — that is an assertion failure, because it is one fact stated in two
        places whose winner depends on merge order rather than on intent.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = restatedKeys == [ ];
        message =
          "nixdesktop.foot.settings restates ${toString (lib.length restatedKeys)} key(s) the typed "
          + "options already own: ${lib.concatStringsSep ", " restatedKeys}. Set them through their "
          + "own options (font/fontSize, dpiAware, padding, scrollbackLines, colors) and use "
          + "`settings` only for keys this module does not manage.";
      }
      {
        assertion = cfg.colors.initialTheme == "light" -> cfg.colors.light != null;
        message =
          "nixdesktop.foot.colors.initialTheme = \"light\" but colors.light is null, so no "
          + "[colors-light] section is written and foot would start on its own built-in light "
          + "colours instead. Define colors.light, or leave initialTheme at \"dark\".";
      }
    ];

    xdg.configFile."foot/foot.ini".text =
      "# Generated by nixdesktop (home/foot.nix). Edits here are replaced on the next switch.\n\n"
      + lib.concatStringsSep "\n\n" (map renderSection sectionOrder)
      + "\n";
  };
}
