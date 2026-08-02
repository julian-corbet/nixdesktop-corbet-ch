# home/kanshi.nix — `nixdesktop.dynamicOutputs`: turn declared `nixdesktop.layouts` entries into
# kanshi profiles, so which arrangement applies is decided by WHAT IS PLUGGED IN rather than by a
# compositor config that can only ever describe one union of every output a host might see.
#
# ── THE GAP THIS FILL, PRECISELY ──────────────────────────────────────────────────────────────
# `nixdesktop.layouts` is translated by each compositor module (nixniri, nixscroll) into that
# compositor's own `output` blocks. Both compositors apply every block whose monitor is present and
# ignore the rest, so ONE layout covers every combination of monitors -- with exactly one thing it
# cannot express: switching an output OFF *because other outputs are present*. "The laptop panel is
# off when the desk monitors are attached" is a statement about the SET of connected outputs, and
# neither compositor's config language has any concept of the current set. kanshi's does: a profile
# names a set, and is selected when reality matches it.
#
# So a layout used as a kanshi PROFILE is the same data serving a different question. `layouts`
# already carries `enable = false` (modules/layouts.nix documents it as exactly the "laptop panel
# off while docked" case) -- it simply had nowhere to be true. This module is that somewhere.
#
# ── ⚠ EXACTLY ONE OWNER PER OUTPUT. THIS IS NOT STYLE ─────────────────────────────────────────
# kanshi holds no privileged position: it is an ordinary Wayland client submitting a
# `zwlr_output_configuration_v1`, and the compositor applies its OWN output config at startup and
# on every reload. Both write the same state, so the LAST WRITER WINS and a concurrent change is a
# genuine race with no defined precedence. This is not theoretical -- it is the documented cause of
# swaywm/sway#6863, emersion/kanshi#43 ("when i reload sway, both profiles get applied, resulting
# in both displays being turned on") and niri-wm/niri#676, where kanshi toggling the internal panel
# during a hotplug makes niri drop its own persisted per-output config.
#
# THEREFORE: a host that enables this module must stop its compositor from emitting output blocks
# for the same monitors -- in practice by leaving that compositor module's own `nixdesktop.layout`
# unset (null), which is the whole reason that option is nullable. Splitting attributes between the
# two (scale in the compositor, position in kanshi) is the worst of both and must never be done.
# `assertions` below cannot see into a sibling compositor module's options, so this one is on the
# host; it is stated here, in `enable`'s own description, and in the README.
#
# ── ⚠ MATCHING IS AN EXACT COVER, WHICH THE MAN PAGES DO NOT SAY ──────────────────────────────
# kanshi(1) says only "a profile will be automatically activated if all specified outputs are
# currently connected", and README.md repeats it. Both are HALF the rule. `match_profile()`
# (kanshi 1.9.0 main.c:42-95) enforces a bijection in BOTH directions:
#   1. every output listed in the profile must match some connected head  (the documented half), and
#   2. every connected head must be matched by some listed output -- `// Check that we've matched
#      all heads`, main.c:75-81, undocumented anywhere in the man pages.
#
# Rule 2 is what makes profiles genuinely SELF-SELECTING here, and it is worth understanding before
# changing anything: a `laptop-only` profile naming just the internal panel does NOT match while
# docked, even though that panel is connected, because the desk monitors would be left uncovered.
# Profile ORDER therefore does not decide correctness -- the set does. (Contrast the naive reading
# of the man page, under which a laptop-only profile would match constantly and order would be
# load-bearing.)
#
# Rule 2 also has a cost, and it is the reason `tolerateUnknownOutputs` exists and defaults to
# FALSE: plug in one monitor no profile accounts for and NO profile matches at all. kanshi then
# changes nothing and the compositor's own defaults stand -- a visibly-wrong-but-working desktop,
# which is the right failure. The alternative, `...output *`, absorbs any leftover heads and makes
# every profile greedy again: with it enabled, a laptop-only profile WOULD match while docked and
# silently leave the desk monitors unconfigured. That is a much worse failure than "no profile
# matched", so it is opt-in, per-profile-set, never the default.
{ config, lib, ... }:
let
  cfg = config.nixdesktop.dynamicOutputs;

  layouts = config.nixdesktop.layouts or { };
  monitors = config.nixdesktop.monitors or { };

  # kanshi's own identity string, built exactly as `match_profile_output()` builds the value it
  # compares against (main.c:26-40): `snprintf("%s %s %s", make, model, serial)`, with the literal
  # string "Unknown" substituted for any field the compositor did not advertise. Reproduced here
  # rather than approximated because the comparison is `fnmatch(pattern, identifier, 0)` -- a glob
  # match against that exact string, so a missing space or a dropped serial silently never matches.
  #
  # NOTE the asymmetry this exploits: a CONNECTOR criteria is compared with `strcmp` (exact, no
  # globbing), while an IDENTITY criteria goes through `fnmatch`. So a monitor whose `identifier`
  # deliberately contains a glob (`Foocorp ASDF *`) keeps working, and a connector name never
  # accidentally globs.
  identityOf = mon:
    let f = v: if v == null || v == "" then "Unknown" else v;
    in "${f mon.make} ${f mon.model} ${f mon.serial}";

  # ONE criteria per layout entry -- deliberately not the "identifier plus every alias" expansion
  # the compositor translators do (see nixscroll's `matcherNamesOf`). There, several stanzas for one
  # physical panel are harmless: a compositor applies whichever one matches and ignores the others.
  # Here it would be actively wrong: rule 1 above requires EVERY listed output to be connected, so
  # naming both an identifier and its alias in one profile demands the same panel be plugged in
  # twice, and the profile could never match. Asserted against below rather than silently dropped.
  criteriaOf = o:
    if o.match == "connector" then o.connector
    else identityOf (monitors.${o.monitor} or (throw
      "nixdesktop.dynamicOutputs: layout output references monitor '${o.monitor}', which is not in nixdesktop.monitors."));

  # `WIDTHxHEIGHT[@RATE]` -> `WIDTHxHEIGHT[@RATEHz]`. kanshi accepts a bare rate or an Hz-suffixed
  # one; normalised so the emitted file does not vary with how a layout happened to spell it.
  normaliseMode = m:
    let parts = builtins.match "([0-9]+x[0-9]+)(@([0-9.]+)([Hh][Zz])?)?" m;
    in
    if parts == null then m
    else
      let wh = builtins.elemAt parts 0; rate = builtins.elemAt parts 2;
      in if rate == null then wh else "${wh}@${rate}Hz";

  # ⚠ NO TRANSFORM INVERSION HERE, unlike the sway/scroll translator. sway's config parser calls
  # `invert_rotation_direction()` on every parse, so nixscroll has to emit 270 where the neutral
  # vocabulary says 90. kanshi does no interpretation whatsoever: `config.c:91-112` maps the token
  # 1:1 onto the `wl_output.transform` enum and `main.c:344` hands it straight to
  # `zwlr_output_configuration_head_v1_set_transform`. The Wayland enum is the normative meaning
  # (wayland.xml: "90 degrees counter-clockwise"), which is the same direction `nixdesktop.layouts`
  # itself declares -- so the neutral value passes through untouched, exactly as nixniri emits it.
  renderOutput = o:
    let crit = ''"${criteriaOf o}"'';
    in
    # `disable` stands alone -- mirroring both compositor translators, which short-circuit a
    # disabled entry to a single directive rather than also emitting mode/scale/position for an
    # output that will not be lit. Three translators of one vocabulary should not disagree here.
    if !o.enable then "\toutput ${crit} disable"
    else
      "\toutput ${crit} enable"
      + lib.optionalString (o.mode != null) " mode ${normaliseMode o.mode}"
      # `position <x>,<y>` -- COMMA-separated, where sway/scroll want `position <x> <y>` with a
      # space. Same word, different grammar; kanshi.5 "OUTPUT DIRECTIVES".
      + lib.optionalString (o.position != null) " position ${toString o.position.x},${toString o.position.y}"
      + lib.optionalString (o.scale != null) " scale ${toString o.scale}"
      + " transform ${o.transform}";

  renderProfile = name:
    let l = layouts.${name} or (throw
      "nixdesktop.dynamicOutputs.profiles names '${name}', which is not a declared nixdesktop.layouts entry.");
    in
    lib.concatStringsSep "\n" (
      [ "# ${l.description}" "profile ${name} {" ]
      ++ map renderOutput l.outputs
      ++ lib.optional cfg.tolerateUnknownOutputs
        "\t...output *  # absorb heads no entry above names -- see this file's header on why this is opt-in"
      ++ [ "}" ]
    );

  # Every monitor a profile addresses by identity, for the alias assertion below.
  referencedMonitors = lib.unique (lib.concatMap
    (n: map (o: o.monitor) (lib.filter (o: o.match != "connector") (layouts.${n}.outputs or [ ])))
    cfg.profiles);
in
{
  options.nixdesktop.dynamicOutputs = {
    enable = lib.mkEnableOption ''
      kanshi profile generation from `nixdesktop.layouts`, for hosts whose correct output
      arrangement depends on WHICH monitors are attached rather than only on which are present.

      ⚠ The compositor must then NOT configure the same outputs -- leave its own
      `nixdesktop.layout` null. See this file's header: the two race, last writer wins, and the
      failure mode is real and reported upstream against sway and niri alike
    '';

    profiles = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "external-4k-plus-pivot" "external-4k" "laptop-only" ];
      description = ''
        Names of `nixdesktop.layouts` entries to emit as kanshi profiles.

        Order is emitted faithfully but does NOT decide which profile wins: kanshi requires an
        exact cover of the connected outputs (see this file's header), so at most one of a set of
        genuinely distinct arrangements can match. Listing them most-specific-first is still worth
        doing for a human reader, and becomes load-bearing if `tolerateUnknownOutputs` is ever set.

        A layout named here should account for EVERY output the host can have connected in that
        situation -- including ones it wants switched off, which must still be listed (with
        `enable = false`) or the profile cannot match at all.
      '';
    };

    tolerateUnknownOutputs = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Append `...output *` to every generated profile, absorbing any connected output no entry
        names, so an unanticipated monitor does not stop every profile from matching.

        Off by default, and think before turning it on: it also makes every profile greedy, so a
        profile naming only the internal panel will match while docked and leave the desk monitors
        unconfigured. "No profile matched, the compositor's own defaults stand" is a better failure
        than "the wrong profile matched and silently ignored two monitors".
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.profiles != [ ];
        message = "nixdesktop.dynamicOutputs is enabled but names no profiles, which would emit a config with no profile in it -- kanshi treats a missing/empty config as a fatal error (main.c:720), so the session would get no output management at all rather than a harmless no-op.";
      }
      {
        assertion = lib.all (m: (monitors.${m}.aliases or [ ]) == [ ]) referencedMonitors;
        message = ''
          nixdesktop.dynamicOutputs: a profile addresses a monitor that declares `aliases`, which
          this translator cannot express. A compositor emits one stanza per alias and applies
          whichever matches; kanshi instead requires every listed output to be connected, so naming
          a panel's identifier AND its alias in one profile asks for the same panel twice and the
          profile can never match. Give that monitor's `identifier` a glob covering both EDIDs
          (kanshi matches identity with fnmatch, so "Foocorp ASDF *" is legal), or declare a
          separate layout per alias. Monitors with aliases: ${
            lib.concatStringsSep ", " (lib.filter (m: (monitors.${m}.aliases or [ ]) != [ ]) referencedMonitors)
          }.
        '';
      }
    ];

    # kanshi(1): "$XDG_CONFIG_HOME/kanshi/config", literally `config`, no extension, and there is
    # NO system-wide fallback -- `/etc/kanshi/config` is only ever reached through an explicit
    # `include`. A missing file is fatal, not a default-config case.
    xdg.configFile."kanshi/config".text = ''
      # Generated by nixdesktop (nixdesktop.dynamicOutputs) from nixdesktop.layouts.
      # Do not edit by hand -- changes are overwritten on the next home-manager switch.
      #
      # A profile applies when the connected outputs are EXACTLY the set it names (kanshi 1.9.0
      # main.c:42-95 -- both directions, though the man page documents only one). See `man 5 kanshi`.
      ${lib.concatStringsSep "\n\n" (map renderProfile cfg.profiles)}
    '';

    # Type=simple: kanshi never forks -- `main()` falls straight into `kanshi_main_loop()` and
    # returns its result (main.c:690-767). The only fork in the codebase is the `exec` directive's
    # own `/bin/sh -c` child.
    #
    # Deliberately NOT given an `ExecReload`: the obvious `kanshictl reload` is only built when
    # libvali was present at compile time (meson.build wraps it in `if vali.found()`), so a unit
    # asserting it would break on distro builds without it. kanshi rereads its config on SIGHUP
    # regardless, which is what `systemctl --user kill -s HUP` already does with no unit support.
    nixdesktop.session.services.kanshi = {
      command = "kanshi";
      description = "Dynamic output configuration (kanshi profiles from nixdesktop.layouts)";
    };
  };
}
