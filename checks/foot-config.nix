# Evaluates home/foot.nix for real and asserts the FILE it renders, not the options a consumer
# handed it. Same reasoning as every sibling check in this directory: `nix flake check` does not
# evaluate `homeManagerModules` -- it lists them as unchecked and moves on -- so without this file
# the only proven claim about foot.ini would be that the module is a module.
#
# WHAT IS ACTUALLY AT RISK HERE. Nothing in home/foot.nix is a value passed through; every line of
# the output is derived. A palette is a pair of eight-element lists flattened into `regular0`
# .. `bright7` by index arithmetic, booleans are re-spelled into foot's own `yes`/`no`, the font
# and its size are two options concatenated into one key, and the whole file is assembled by string
# concatenation into sections whose names foot is picky about (it has deprecated `[colors]` in
# favour of `[colors-dark]`). Every one of those fails silently: an off-by-one in the palette
# renders a terminal in the wrong sixteen colours, `dpi-aware=1` is rejected by the very program
# that never sees a Nix error, and a key emitted into the wrong section is simply ignored. The
# assertions this module raises -- a `settings` key restating one the typed options own, a light
# initial theme with no light palette -- are arithmetic over the same derived data.
#
# The ini is parsed back here by a SECOND, independent implementation rather than by reusing the
# module's own renderer, so that a check can disagree with the module. Reusing it would only prove
# the renderer agrees with itself.
{ pkgs, lib ? pkgs.lib }:
let
  support = import ./support.nix { inherit pkgs lib; };
  inherit (support) countMatching report;

  # The home-manager surface this module touches, and nothing else. Same shape and same reasoning
  # as checks/patchbay.nix's own stub: a faithful stand-in for "a host", not a simplification.
  stubs = { lib, ... }: {
    options = {
      xdg.configFile = lib.mkOption {
        type = lib.types.attrsOf (lib.types.attrsOf lib.types.anything);
        default = { };
      };
      assertions = lib.mkOption { type = lib.types.listOf lib.types.anything; default = [ ]; };
      warnings = lib.mkOption { type = lib.types.listOf lib.types.str; default = [ ]; };
    };
  };

  evalFoot = footCfg: (lib.evalModules {
    modules = [ stubs ../home/foot.nix { nixdesktop.foot = footCfg; } ];
  }).config;

  evalWith = settings: evalFoot ({ enable = true; font = fixtureFont; } // settings);

  # Forces what the module PRODUCES, because a rejected type throws out of the module system
  # rather than landing in `assertions` -- nothing in `firedMessages` can see those at all.
  #
  # The rendered file and the assertions, deliberately, rather than the whole config tree:
  # `config.nixdesktop.foot.font` is itself part of that tree, and a mandatory option throws when
  # something READS it. Forcing the tree wholesale would therefore report a disabled module as an
  # error, erasing the exact distinction these fixtures exist to draw.
  throwsFor = footCfg:
    let cfg = evalFoot footCfg; in
      !(builtins.tryEval (builtins.deepSeq [ cfg.xdg.configFile cfg.assertions ] true)).success;

  firedFor = settings:
    map (a: a.message) (lib.filter (a: !a.assertion) (evalWith settings).assertions);

  iniOf = settings: (evalWith settings).xdg.configFile."foot/foot.ini".text;

  # ── AN INDEPENDENT INI READER ────────────────────────────────────────────────────────────────
  contentLines = text:
    lib.filter (l: l != "" && !(lib.hasPrefix "#" l)) (lib.splitString "\n" text);

  headerName = line: lib.removeSuffix "]" (lib.removePrefix "[" line);

  # The section headers in the order they appear -- a separate claim from what is IN them, and the
  # only one that can catch a file whose keys are all correct and all in the wrong place.
  sectionOrderOf = text:
    map headerName (lib.filter (lib.hasPrefix "[") (contentLines text));

  parseIni = text:
    let
      step = acc: line:
        if lib.hasPrefix "[" line then acc // { current = headerName line; }
        else
          let
            parts = lib.splitString "=" line;
            key = lib.head parts;
            value = lib.concatStringsSep "=" (lib.tail parts);
          in
          acc // {
            sections = acc.sections // {
              ${acc.current} = (acc.sections.${acc.current} or { }) // { ${key} = value; };
            };
          };
    in
    (lib.foldl' step { current = ""; sections = { }; } (contentLines text)).sections;

  sectionsOf = settings: parseIni (iniOf settings);

  # ── FIXTURES ─────────────────────────────────────────────────────────────────────────────────
  # A font name no host could have installed: this check is about the string reaching the file
  # intact, never about a family resolving.
  fixtureFont = "Fixture Mono";

  # A palette whose every entry is distinguishable from every other, so a mis-indexed flatten
  # cannot pass by landing on a colour that happens to match.
  markedPalette = {
    background = "0b0b0b";
    foreground = "0f0f0f";
    regular = [ "a00000" "a10000" "a20000" "a30000" "a40000" "a50000" "a60000" "a70000" ];
    bright = [ "b00000" "b10000" "b20000" "b30000" "b40000" "b50000" "b60000" "b70000" ];
  };

  lightPalette = markedPalette // { background = "fafafa"; };

  defaults = sectionsOf { };

  configured = sectionsOf {
    fontSize = 10;
    dpiAware = true;
    padding = { horizontal = 8; vertical = 6; };
    scrollbackLines = 10000;
    colors.dark = markedPalette;
  };

  withLight = sectionsOf {
    colors.dark = markedPalette;
    colors.light = lightPalette;
    colors.initialTheme = "light";
  };

  extended = sectionsOf {
    settings = {
      "colors-dark".dim0 = "010101";
      cursor.style = "beam";
      scrollback.multiplier = 3;
    };
  };

  disabled = evalFoot { enable = false; };

  results = {
    # ── THE FILE IS SECTIONED, AND `[main]` LEADS ────────────────────────────────────────────
    "the rendered ini opens with [main], the section foot treats as its section-less keys" =
      lib.head (sectionOrderOf (iniOf { })) == "main";
    "a default render emits exactly main, colors-dark and scrollback -- no light section" =
      lib.sort (a: b: a < b) (sectionOrderOf (iniOf { })) == [ "colors-dark" "main" "scrollback" ];
    "no [colors] section is ever emitted -- foot deprecated that spelling in favour of [colors-dark]" =
      !(lib.elem "colors" (sectionOrderOf (iniOf { colors.dark = markedPalette; })));
    "colors-light appears only once a light palette exists" =
      !(defaults ? "colors-light") && withLight ? "colors-light";

    # ── THE FONT IS TWO OPTIONS CONCATENATED INTO ONE KEY ────────────────────────────────────
    "font and fontSize render as a single fontconfig string" =
      configured.main.font == "${fixtureFont}:size=10";
    "the size defaults to foot's own default rather than an opinion of this module's" =
      defaults.main.font == "${fixtureFont}:size=8";

    # ── BOOLEANS ARE RE-SPELLED, NOT STRINGIFIED ─────────────────────────────────────────────
    "dpiAware = true renders foot's yes, not true or 1" =
      configured.main.dpi-aware == "yes";
    "dpiAware = false renders foot's no" =
      defaults.main.dpi-aware == "no";

    # ── GEOMETRY AND SCROLLBACK LAND IN THE RIGHT KEYS AND SECTIONS ──────────────────────────
    "padding renders as foot's XxY pair, horizontal first" =
      configured.main.pad == "8x6";
    "scrollback lines land in [scrollback], not in [main]" =
      configured.scrollback.lines == "10000" && !(configured.main ? lines);

    # ── THE PALETTE FLATTEN IS INDEXED CORRECTLY, IN BOTH DIRECTIONS ─────────────────────────
    "regular0 is the first ANSI colour and regular7 the eighth" =
      configured."colors-dark".regular0 == "a00000" && configured."colors-dark".regular7 == "a70000";
    "bright0 is the first bright colour and bright7 the eighth" =
      configured."colors-dark".bright0 == "b00000" && configured."colors-dark".bright7 == "b70000";
    "the palette renders exactly 18 keys -- 16 indexed, plus background and foreground" =
      lib.length (lib.attrNames configured."colors-dark") == 18;
    "background and foreground are not indexed" =
      configured."colors-dark".background == "0b0b0b"
      && configured."colors-dark".foreground == "0f0f0f";
    "a light palette renders into colors-dark's mirror image, not over it" =
      withLight."colors-light".background == "fafafa"
      && withLight."colors-dark".background == "0b0b0b";
    "the default palette is Breeze Dark, and it is a value like any other" =
      defaults."colors-dark".background == "141618" && defaults."colors-dark".regular4 == "1d99f3";

    # ── A PALETTE IS DEFINED WHOLESALE ───────────────────────────────────────────────────────
    "stating half a palette is an evaluation error, not a silent blend of two" =
      throwsFor { enable = true; font = fixtureFont; colors.dark.background = "000000"; };
    "seven ANSI colours is an evaluation error, not a file missing regular7" =
      throwsFor {
        enable = true;
        font = fixtureFont;
        colors.dark = markedPalette // { regular = lib.take 7 markedPalette.regular; };
      };
    "a colour foot would reject is an evaluation error -- no leading hash" =
      throwsFor {
        enable = true;
        font = fixtureFont;
        colors.dark = markedPalette // { background = "#0b0b0b"; };
      };
    "...and no alpha component either" =
      throwsFor {
        enable = true;
        font = fixtureFont;
        colors.dark = markedPalette // { background = "ff0b0b0b"; };
      };

    # ── `settings` EXTENDS SECTIONS BUT MAY NOT RESTATE A MANAGED KEY ────────────────────────
    "settings can add a key to a section the typed options already write" =
      extended."colors-dark".dim0 == "010101" && extended."colors-dark".regular0 == "232627";
    "settings can open a section this module models nothing in" =
      extended.cursor.style == "beam";
    "extending a managed section trips no restatement assertion" =
      countMatching "restates"
        (firedFor {
          settings."colors-dark".dim0 = "010101";
        }) == 0;
    "restating a managed key trips exactly one assertion" =
      countMatching "restates" (firedFor { settings.main.font = "Other Mono"; }) == 1;
    "...and that assertion names the offending section and key" =
      countMatching "main.font" (firedFor { settings.main.font = "Other Mono"; }) == 1;
    "restating an indexed palette key counts too -- it is derived, not typed by hand" =
      countMatching "colors-dark.regular0"
        (firedFor {
          settings."colors-dark".regular0 = "010101";
        }) == 1;

    # ── A LIGHT INITIAL THEME NEEDS A LIGHT PALETTE ──────────────────────────────────────────
    "initial-color-theme renders whichever theme was asked for" =
      defaults.main.initial-color-theme == "dark"
      && withLight.main.initial-color-theme == "light";
    "initialTheme = light with no light palette trips exactly one assertion" =
      countMatching "colors-light" (firedFor { colors.initialTheme = "light"; }) == 1;
    "initialTheme = light with a light palette trips none" =
      countMatching "colors-light"
        (firedFor {
          colors.initialTheme = "light";
          colors.light = lightPalette;
        }) == 0;
    "a default configuration trips nothing at all" =
      firedFor { } == [ ];

    # ── DISABLED IS INERT, AND DOES NOT PUNISH THE UNSET MANDATORY OPTION ────────────────────
    "disabled writes no foot.ini" =
      !(disabled.xdg.configFile ? "foot/foot.ini");
    "disabled evaluates even though font -- mandatory when enabled -- was never set" =
      !(throwsFor { enable = false; });
    "enabling without a font is an evaluation error naming the option" =
      throwsFor { enable = true; };
  };
in
report "foot-config" results
