# modules/desktops.nix — the FLEET-WIDE desktop registry: every machine in an estate that runs a
# graphical session, and the identity colour that says which one you are looking at.
#
# WHY THIS IS ESTATE-LEVEL AND NOT HOST STANCE, the same argument ./monitors.nix makes for panels.
# An accent is not a property of the machine that owns it — it is a property of the RELATIONSHIP
# between machines. A host needs its own colour to paint its own frames, but it needs EVERY OTHER
# host's colour too, because the entire point is marking a window that arrived from somewhere else.
# Declared per-host, each machine would carry its own colour plus a hand-copied guess at everyone
# else's, and the moment two hosts disagree about a third host's colour they are describing two
# machines that do not exist. So the table lives here, once, imported everywhere.
#
# WHAT CONSUMES IT. A compositor config reads the whole table and generates, for each OTHER entry,
# a rule matching windows forwarded from that machine and painting them in its accent — see
# nixscroll's `for_window ... title_format`/`decoration` generation. n rows yield n×(n−1) directed
# marking rules with nothing written per pair, so adding a machine is one row and no permutation
# can be forgotten.
#
# WHY THIS BELONGS TO nixdesktop SPECIFICALLY, and is not an application-level concern. In a split
# evaluation — a system plane (NixOS/system-manager) and a user plane (home-manager) — most module
# namespaces exist on exactly one side. A forwarding/remoting module is typically user-plane; a
# network module is typically system-plane; those two can never read each other. A desktop module
# is one of the few that is legitimately composed into BOTH, because a desktop session has a system
# half (seat, login, VT) and a user half (compositor config, bars, keyring). That makes this module
# the correct carrier for any desktop fact both planes need, and it is why ./monitors.nix and
# ./layouts.nix already live here rather than in whichever consumer happened to want them first.
#
# WHY ACCENTS MUST BE UNIQUE, asserted below rather than merely documented. A duplicate accent does
# not fail — it renders. Two machines simply become indistinguishable, silently, at exactly the
# moment the feature exists to tell them apart, and the failure surfaces as a human trusting the
# wrong colour. That is the worst shape a bug can take: no error, no log line, and a confident
# wrong answer. Uniqueness is cheap to check and expensive to miss.
#
# NOTE ON WHAT UNIQUENESS DOES NOT BUY YOU. Distinct hex values are not the same as distinguishable
# colours. Two accents 15 degrees apart in hue pass this assertion and still fail a human at a
# glance. The assertion catches the mechanical mistake; picking colours that are far apart
# perceptually — not merely different — remains a judgement the estate has to make.
{ lib, config, ... }:
let
  inherit (lib) mkOption types;

  desktopModule = { name, ... }: {
    options = {
      accent = mkOption {
        type = types.strMatching "#[0-9a-fA-F]{6}";
        example = "#15803D";
        description = ''
          This desktop's identity colour, as `#RRGGBB`.

          Used by compositor configs both for this machine's own window frames and title bars, and
          — on every OTHER machine in the registry — to mark windows forwarded here from this one.
          Must be unique across the registry; see this module's own header for why that is asserted
          rather than assumed, and for why uniqueness alone is not sufficient.

          Constrained to a 6-digit hex literal deliberately: consumers append their own alpha
          channel (a shadow wants `''${accent}FF`) and interpolate the value into compositor config
          text and Pango markup, both of which accept a bare `#RRGGBB` and neither of which would
          report a named colour or an `#RRGGBBAA` value as an error — they would render something
          unintended instead.
        '';
      };

      addresses = mkOption {
        type = types.listOf types.str;
        default = [ ];
        # Documentation-range addresses (RFC 5737 / RFC 3849), never a real network. An example in
        # a public module is read as a template, so a working private range here would publish one
        # operator's topology and invite a reader to copy it into their own unrelated one.
        example = [ "192.0.2.10" "2001:db8::10" ];
        description = ''
          Where this desktop can be reached, most-preferred first, for the purpose of forwarding a
          window to or from it. Consumed by a remoting module to build its peer set.

          DELIBERATELY NOT A ROUTING TABLE, and deliberately not the same thing as a network
          module's peer entry. A network module's peers are each observing host's own VIEW of
          reachability — transport priorities, probe methods, provider ids, what to do when every
          leg is down — and that view is legitimately ASYMMETRIC: one host may reach a machine over
          two transports while another, sitting in the same failure domain, deliberately declares
          only one. Flattening that into a shared table would erase real decisions.

          What this list carries is the narrower fact a remoting consumer actually needs: the
          addresses at which this machine answers, in preference order. If an estate also runs a
          network module with a richer peer table, that module stays the owner of policy and this
          stays the owner of "where is it" — they overlap in the literal string and not in meaning.

          Empty by default: a desktop that is never a forwarding target needs no address at all.
        '';
      };

      description = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "the laptop";
        description = ''
          Optional human note about which machine this is. Carried so the registry can be read on
          its own without cross-referencing host files; never consumed by any generator.
        '';
      };
    };
  };

  accents = lib.mapAttrsToList (_: d: d.accent) config.nixdesktop.desktops;
  duplicates = lib.unique (lib.filter (a: lib.count (b: b == a) accents > 1) accents);
in
{
  options.nixdesktop.desktops = mkOption {
    type = types.attrsOf (types.submodule desktopModule);
    default = { };
    example = lib.literalExpression ''
      {
        laptop.accent = "#15803D";
        workstation.accent = "#B45309";
      }
    '';
    description = ''
      Every machine in this estate that runs a graphical session, keyed by a short stable name.

      The key is the vocabulary everything else uses to talk about that machine — a compositor
      generating per-origin marking rules names it, and a forwarding wrapper tags a forwarded
      window with it. Keep it short and stable; renaming one is a fleet-wide rename.

      Empty by default: an estate that does not mark windows by origin composes this module and
      sets nothing, and no consumer generates anything.
    '';
  };

  config.assertions = [
    {
      assertion = duplicates == [ ];
      message = ''
        nixdesktop.desktops: duplicate accent colour(s): ${lib.concatStringsSep ", " duplicates}.

        Every desktop's accent must be unique — the accent IS the machine's identity at a glance,
        so two machines sharing one makes their windows indistinguishable precisely when it
        matters, and does so silently rather than failing. Give each machine its own colour, and
        prefer one far from the others in hue rather than merely different in hex.

        Declared: ${lib.concatStringsSep ", " (lib.mapAttrsToList (n: d: "${n}=${d.accent}") config.nixdesktop.desktops)}
      '';
    }
  ];
}
