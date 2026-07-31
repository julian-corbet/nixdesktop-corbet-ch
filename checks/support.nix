# checks/support.nix — the three things every eval check in this repo needs, built once.
#
# WHAT THESE CHECKS ARE FOR. `nix flake check` does not evaluate `nixosModules`,
# `systemManagerModules` or `homeManagerModules` — it verifies they ARE modules and moves on,
# listing the home ones as unchecked outright. So every table this repo publishes (monitors,
# layouts, sessions) would ship completely unproven without these files: each is assertions over
# derived arithmetic — an identity string, a logical rectangle, a set complement — which is
# exactly the code that fails quietly rather than loudly.
#
# WHY `lib.evalModules` AND NOT `nixosSystem`. Not one of the three modules touches `pkgs`,
# systemd, or anything NixOS-specific; two of them are exported on the system-manager plane as
# well. Evaluating a whole NixOS system to test them would prove the same thing far more slowly
# while quietly making them look NixOS-coupled. `evalModules` plus the two-option stub below is
# the entire host surface any of them reads.
{ pkgs, lib ? pkgs.lib }:
rec {
  # The whole of "a host", as far as these three modules are concerned: somewhere for assertions
  # and warnings to land. Both NixOS and system-manager declare these two options themselves —
  # nixhost, exported on both planes, already relies on exactly that — so a stub matching their
  # shape is a faithful stand-in rather than a simplification.
  #
  # DELIBERATELY DOES NOT ENFORCE assertions the way NixOS does. These checks want to READ which
  # assertions fired and name them; a stub that threw on the first false one could only ever prove
  # "something failed", never which thing, and never that exactly one thing did.
  hostStub = { lib, ... }: {
    options = {
      assertions = lib.mkOption { type = lib.types.listOf lib.types.anything; default = [ ]; };
      warnings = lib.mkOption { type = lib.types.listOf lib.types.str; default = [ ]; };
    };
  };

  evalWith = modules: (lib.evalModules { modules = [ hostStub ] ++ modules; }).config;

  # The messages of the assertions that actually FIRED. Every check below matches on message
  # infixes rather than on counts alone: a fixture usually trips one assertion on purpose and must
  # be free to trip none, or others, incidentally without the test silently changing meaning.
  firedMessages = cfg: map (a: a.message) (lib.filter (a: !a.assertion) cfg.assertions);

  matching = infix: msgs: lib.filter (m: lib.hasInfix infix m) msgs;
  countMatching = infix: msgs: lib.length (matching infix msgs);

  # For proving that an evaluation fails OUTRIGHT — a rejected type, a `readOnly` option a
  # consumer tried to define. Those never reach `assertions` at all: they throw out of the module
  # system, so `firedMessages` above cannot see them and only `tryEval` over a fully-forced config
  # can.
  evalThrows = modules:
    !(builtins.tryEval (builtins.deepSeq (evalWith modules) true)).success;

  # ── The marker derivation, and why it is `pkgs.emptyFile` ───────────────────────────────────
  #
  # These checks decide everything at EVALUATION time; the derivation exists only because
  # `nix flake check` requires each check to be one. That makes its build a pure formality — and a
  # formality that must not need a builder for a foreign CPU, because `nix flake check
  # --all-systems` (which this repo's CI runs, and rightly: without it every non-runner system
  # goes unevaluated while CI reports green) asks for a marker on every declared system.
  #
  # `pkgs.runCommand "..." {} "touch $out"` cannot satisfy that: its output path is
  # system-dependent, so the aarch64 marker is a real aarch64 build and fails with "platform
  # mismatch" on any x86_64 machine — turning a passing test suite into a red check about nothing.
  # `pkgs.emptyFile` is a FIXED-OUTPUT derivation, so its output path is derived from the content
  # hash alone and is byte-identical on every system: Nix substitutes it (or finds it already
  # realised) rather than building it, on any host, for any declared system. Verified against
  # `legacyPackages.aarch64-linux.emptyFile` on an x86_64 box with no emulation configured.
  #
  # The cost is that a passing check carries no name in its store path. That costs nothing here,
  # because a FAILING check never produces a path at all — it throws, with the message below.
  report = name: results:
    let failed = lib.attrNames (lib.filterAttrs (_: passed: !passed) results);
    in
    if failed == [ ]
    then pkgs.emptyFile
    else
      throw ''
        nixdesktop: ${name} — ${toString (lib.length failed)} of ${toString (lib.length (lib.attrNames results))} assertions failed:
        ${lib.concatMapStringsSep "\n" (f: "  - ${f}") failed}
      '';
}
