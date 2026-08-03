# Evaluates home/thunar.nix for real and asserts the uca.xml it renders. Same reasoning as every
# sibling check in this directory: `nix flake check` does not evaluate `homeManagerModules`, so
# without this file nothing about the generated document would be proven at all.
#
# THE ONE CLAIM THIS FILE EXISTS FOR: every rendered action carries a `<unique-id>`. That is not a
# tidiness rule. Thunar generates ids for a file that lacks them and saves the whole file back
# immediately -- writing a temporary beside the target and renaming over the PATH, which replaces
# home-manager's symlink with a regular file the first time a Thunar window opens. The declarative
# config is then detached from the store, silently, on a fresh login. Every other assertion here
# guards a failure of the same character: an action Thunar can parse but can never display (an
# empty file-type set), two actions Thunar cannot tell apart (a reused id), a name or command whose
# `&` makes the document unparseable so that ALL actions vanish, or a rendered file whose bytes
# change when a consumer merely reorders their own attribute set, forcing a switch that changes
# nothing.
#
# The document is read back here with a small, independent extractor rather than by reusing the
# module's own renderer -- reusing it would only prove the renderer agrees with itself.
{ pkgs, lib ? pkgs.lib }:
let
  support = import ./support.nix { inherit pkgs lib; };
  inherit (support) countMatching report;

  # Same stub, same reasoning, as checks/foot-config.nix's own: the home-manager surface this
  # module touches and nothing more.
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

  evalThunar = thunarCfg: (lib.evalModules {
    modules = [ stubs ../home/thunar.nix { nixdesktop.thunar = thunarCfg; } ];
  }).config;

  # `null` means "state no actions at all", which is how the shipped default set gets exercised.
  configWith = actions: evalThunar ({ enable = true; }
    // lib.optionalAttrs (actions != null) { customActions = actions; });

  xmlOf = actions: (configWith actions).xdg.configFile."Thunar/uca.xml".text;

  firedFor = actions:
    map (a: a.message) (lib.filter (a: !a.assertion) (configWith actions).assertions);

  # A rejected type, or a mandatory option left unset, throws out of the module system rather than
  # landing in `assertions`, so only a forced evaluation can see it.
  #
  # What is forced is the module's OUTPUT -- the rendered document and the assertions -- not the
  # whole config tree. `config.nixdesktop.thunar.customActions.<name>.command` is itself part of
  # that tree, and a mandatory option throws when something READS it, so forcing the tree
  # wholesale would report a DISABLED module with an incomplete action as an error, erasing the
  # exact distinction these fixtures exist to draw.
  throwsFor = thunarCfg:
    let cfg = evalThunar thunarCfg; in
      !(builtins.tryEval (builtins.deepSeq [ cfg.xdg.configFile cfg.assertions ] true)).success;

  # ── AN INDEPENDENT DOCUMENT READER ───────────────────────────────────────────────────────────
  # Everything between one <action> and the next, as a list of trimmed lines. Enough to assert
  # which elements exist, in which action, and in which order -- and nothing about how they were
  # produced.
  actionBlocks = text:
    let
      lines = map (lib.removePrefix "\t") (lib.splitString "\n" text);
      step = acc: line:
        if line == "<action>" then acc // { current = [ ]; }
        else if line == "</action>" then acc // { blocks = acc.blocks ++ [ acc.current ]; current = null; }
        else if acc.current == null then acc
        else acc // { current = acc.current ++ [ line ]; };
    in
    (lib.foldl' step { blocks = [ ]; current = null; } lines).blocks;

  # The text of one element, or null when the element is absent. Deliberately naive: an element
  # rendered across two lines, or nested, reads as absent and fails the test rather than passing
  # it by accident.
  elementOf = tag: block:
    let matches = lib.filter (l: lib.hasPrefix "<${tag}>" l) block;
    in
    if matches == [ ] then null
    else lib.removeSuffix "</${tag}>" (lib.removePrefix "<${tag}>" (lib.head matches));

  # The file-type flags only. `<startup-notify/>` is an empty element too and is deliberately not
  # one of them -- counting it as a type flag is exactly the confusion this separation prevents.
  typeFlagsOf = block:
    lib.filter (l: lib.hasSuffix "/>" l && l != "<startup-notify/>") block;

  countDuplicateId = msgs: countMatching "unique-id" msgs;

  # ── FIXTURES ─────────────────────────────────────────────────────────────────────────────────
  minimal = { name = "Minimal"; command = "true"; };

  # Defined zebra-first on purpose: the rendered order must come from the attribute names, not
  # from the order they were written in.
  pair = {
    zebra = minimal // { name = "Zebra"; };
    alpha = minimal // { name = "Alpha"; };
  };

  defaultBlocks = actionBlocks (xmlOf null);
  defaultBlock = lib.head defaultBlocks;

  pairBlocks = actionBlocks (xmlOf pair);
  alphaBlock = lib.head pairBlocks;

  fullBlock = lib.head (actionBlocks (xmlOf {
    full = {
      name = "Full";
      command = "run --all %F";
      description = "Everything set";
      icon = "utilities-terminal";
      id = "adopted-1785499983066591-1";
      patterns = [ "*.tar.gz" "*.zip" ];
      # Stated back-to-front, to prove the renderer imposes its own order.
      fileTypes = [ "video-files" "directories" ];
      startupNotify = true;
      range = "2-";
      submenu = "Archive";
    };
  }));

  escapedBlock = lib.head (actionBlocks (xmlOf {
    escaped = {
      name = "Sync & Compare <all>";
      command = ''sh -c 'diff "$1" "$2" & wait' _ %F'';
      description = "a & b < c > d";
    };
  }));

  blindActions = { blind = minimal // { fileTypes = [ ]; }; };

  disabled = evalThunar { enable = false; };

  results = {
    # ── THE UNIQUE-ID CONTRACT ───────────────────────────────────────────────────────────────
    "every rendered action carries a unique-id -- without one Thunar rewrites the file, and the symlink with it" =
      lib.all (block: elementOf "unique-id" block != null) pairBlocks
      && elementOf "unique-id" defaultBlock != null;
    "the id is derived from the attribute name, so it is stable across evaluations" =
      map (elementOf "unique-id") pairBlocks == [ "nixdesktop-alpha" "nixdesktop-zebra" ];
    "an id Thunar generated earlier can be adopted verbatim" =
      elementOf "unique-id" fullBlock == "adopted-1785499983066591-1";
    "two actions sharing an id trip exactly one assertion" =
      countDuplicateId
        (firedFor {
          one = minimal // { id = "shared"; };
          two = minimal // { id = "shared"; };
        }) == 1;
    "distinct ids trip none" =
      countDuplicateId (firedFor pair) == 0;

    # ── THE DOCUMENT ─────────────────────────────────────────────────────────────────────────
    "the document is one <actions> root under an XML declaration" =
      lib.hasPrefix ''<?xml version="1.0" encoding="UTF-8"?>'' (xmlOf null)
      && lib.hasInfix "\n<actions>\n" (xmlOf null)
      && lib.hasSuffix "</actions>\n" (xmlOf null);
    "stating one action replaces the default set rather than merging with it" =
      throwsFor { enable = true; customActions.open-terminal-here.command = "foot"; };
    "the default is exactly the one action Thunar itself ships" =
      lib.length defaultBlocks == 1 && elementOf "name" defaultBlock == "Open Terminal Here";
    "actions render in attribute-name order, not definition order" =
      map (elementOf "name") pairBlocks == [ "Alpha" "Zebra" ];

    # ── ELEMENTS RENDER WHERE, AND ONLY WHERE, THEY WERE ASKED FOR ───────────────────────────
    "a fully specified action renders every element it set" =
      elementOf "name" fullBlock == "Full"
      && elementOf "command" fullBlock == "run --all %F"
      && elementOf "description" fullBlock == "Everything set"
      && elementOf "icon" fullBlock == "utilities-terminal"
      && elementOf "submenu" fullBlock == "Archive"
      && elementOf "range" fullBlock == "2-";
    "a minimal action renders no empty icon, description, submenu or range" =
      elementOf "icon" alphaBlock == null
      && elementOf "description" alphaBlock == null
      && elementOf "submenu" alphaBlock == null
      && elementOf "range" alphaBlock == null;
    "patterns are joined with the semicolon Thunar splits on" =
      elementOf "patterns" fullBlock == "*.tar.gz;*.zip";
    "an unstated pattern list still renders the catch-all Thunar would have defaulted to" =
      elementOf "patterns" alphaBlock == "*";
    "startup-notify is an empty element, emitted only when asked for" =
      lib.elem "<startup-notify/>" fullBlock && !(lib.elem "<startup-notify/>" alphaBlock);

    # ── FILE TYPES ARE FLAGS, IN A CANONICAL ORDER ───────────────────────────────────────────
    "an unnarrowed action carries all six type flags" =
      lib.length (typeFlagsOf alphaBlock) == 6;
    "type flags render in the module's canonical order, so reordering the list changes no bytes" =
      typeFlagsOf fullBlock == [ "<directories/>" "<video-files/>" ];
    "the shipped default is narrowed to directories, as Thunar's own action is" =
      typeFlagsOf defaultBlock == [ "<directories/>" ];
    "an empty file-type list trips exactly one assertion, and it names the action" =
      countMatching "invisible" (firedFor blindActions) == 1
      && countMatching "blind" (firedFor blindActions) == 1;
    "a file type Thunar has no element for is an evaluation error" =
      throwsFor {
        enable = true;
        customActions.bad = minimal // { fileTypes = [ "spreadsheets" ]; };
      };

    # ── XML ESCAPING ─────────────────────────────────────────────────────────────────────────
    "an ampersand in a name is escaped -- unescaped it makes the document unparseable, taking every action with it" =
      elementOf "name" escapedBlock == "Sync &amp; Compare &lt;all&gt;";
    "quotes and ampersands in a command are escaped too" =
      elementOf "command" escapedBlock
      == "sh -c &apos;diff &quot;$1&quot; &quot;$2&quot; &amp; wait&apos; _ %F";
    "a description is escaped on the same footing" =
      elementOf "description" escapedBlock == "a &amp; b &lt; c &gt; d";

    # ── MANDATORY FIELDS, AND A DISABLED MODULE THAT DOES NOT PUNISH THEM ────────────────────
    "an action without a command is an evaluation error naming the option" =
      throwsFor { enable = true; customActions.nameless = { name = "No command"; }; };
    "an action without a name is an evaluation error too -- a slug is not a menu label" =
      throwsFor { enable = true; customActions.unnamed = { command = "true"; }; };
    "disabled writes no uca.xml" =
      !(disabled.xdg.configFile ? "Thunar/uca.xml");
    "disabled evaluates even with an action that would not have been valid" =
      !(throwsFor { enable = false; customActions.broken = { name = "No command"; }; });
  };
in
report "thunar-actions" results
