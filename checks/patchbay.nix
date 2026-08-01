# Evaluates home/session.nix for real and asserts the `patchbay` component -- the tray/patchbay
# session component (see that option group's own header comment in home/session.nix for the full
# design account: why it is ONE unit and not a pair like `cliphist-text`/`cliphist-image`, why its
# process shape is `Type=simple`/`Restart=always`, and why the StatusNotifierItem-host dependency
# is a consumer-stated fact rather than something this module tries to detect).
#
# WHY THIS FILE EXISTS AT ALL, SAME REASONING AS EVERY SIBLING CHECK IN THIS DIRECTORY: `nix flake
# check` does not evaluate `homeManagerModules` -- it lists them as unchecked and moves on. A green
# check here is the only thing standing between "the `patchbay` option surface compiles" and "the
# unit it renders actually has the process shape the header comment claims, and the SNI-host
# warning actually fires when it should."
{ pkgs, lib ? pkgs.lib }:
let
  support = import ./support.nix { inherit pkgs lib; };
  inherit (support) matching countMatching report;

  # Identical stub to checks/keyring.nix's own (and checks/idle-assembly.nix's before it) -- same
  # six options, same reasoning: a stand-in for "a host", matching the surface home-manager itself
  # declares. `warnings` matters here specifically -- this is the first check in this directory
  # whose fixtures need to read it back, rather than merely declare it defensively.
  stubs = { lib, ... }: {
    options = {
      xdg.configFile = lib.mkOption {
        type = lib.types.attrsOf (lib.types.attrsOf lib.types.anything);
        default = { };
      };
      home.packages = lib.mkOption { type = lib.types.listOf lib.types.anything; default = [ ]; };
      home.file = lib.mkOption { type = lib.types.attrsOf lib.types.anything; default = { }; };
      assertions = lib.mkOption { type = lib.types.listOf lib.types.anything; default = [ ]; };
      warnings = lib.mkOption { type = lib.types.listOf lib.types.str; default = [ ]; };
      systemd.user = lib.mkOption { type = lib.types.anything; default = { }; };
    };
  };

  evalWith = settings: (lib.evalModules {
    modules = [
      stubs
      ../home/session.nix
      { nixdesktop.session = { enable = true; } // settings; }
    ];
    specialArgs = { inherit pkgs; };
  }).config;

  # The intermediate `services.patchbay` attrset -- pre-systemd-unit-rendering, same "read the
  # mechanism's own input, not the rendered unit text" choice every sibling check in this directory
  # makes. `null` when no patchbay service was produced at all (`patchbay.enable = false`).
  patchbayService = settings:
    let services = (evalWith settings).nixdesktop.session.services; in
    if services ? patchbay then services.patchbay else null;

  patchbayWarnings = settings: (evalWith settings).warnings;

  # `nixdesktop.session.enable = true` always (via `evalWith`'s own `{ enable = true; } //
  # settings`) -- `settings` below is `{ patchbay = {...}; }`-shaped, mirroring
  # checks/keyring.nix's own `withKeyring` pattern.
  withPatchbay = extra: { patchbay = { enable = true; } // extra; };

  fakeCommand = "fake-patchbay --start-hidden";

  # ── FIXTURES ─────────────────────────────────────────────────────────────────────────────────
  enabled = patchbayService (withPatchbay { command = fakeCommand; trayHostAvailable = true; });

  # `enable = false` altogether, with NEITHER `command` NOR `trayHostAvailable` ever set -- the
  # ordinary rest state for a consumer who has never touched this component. Must not throw: both
  # sub-options are mandatory (no default) precisely so a consumer who DOES enable this component
  # cannot forget them (see their own docs), but that must never punish a consumer who left the
  # whole component off, the same laziness contract `keyring`'s own `disabledNothingConfiguredMsgs`
  # fixture proves for that component's own mandatory-looking fields.
  disabled = patchbayService { patchbay.enable = false; };
  disabledWarnings = patchbayWarnings { patchbay.enable = false; };

  hostAvailableWarnings = patchbayWarnings (withPatchbay {
    command = fakeCommand;
    trayHostAvailable = true;
  });
  hostMissingWarnings = patchbayWarnings (withPatchbay {
    command = fakeCommand;
    trayHostAvailable = false;
  });

  results = {
    # ── THE UNIT RENDERS WHEN ENABLED, WITH THE RIGHT PROCESS SHAPE ───────────────────────────
    "patchbay renders its own configured command verbatim" =
      enabled.command == fakeCommand;
    "patchbay renders Restart=always -- the opposite of keyring/lock-at-start's restart=no, deliberately" =
      enabled.restart == "always";
    "patchbay renders Type=simple -- the generic submodule's own default, an ordinary foreground GUI process, never forking" =
      enabled.serviceType == "simple";
    "patchbay is plain argv, not shell-wrapped -- no pipe or grouping need, unlike swayidle's own command" =
      enabled.runShell == false;

    # ── THE UNIT DOES NOT RENDER WHEN DISABLED, AND EVALUATION DOES NOT THROW ─────────────────
    "disabled patchbay produces no unit at all" =
      disabled == null;
    "disabled patchbay trips no SNI-host warning, even with trayHostAvailable never set" =
      disabledWarnings == [ ];

    # ── THE SNI-HOST WARNING FIRES EXACTLY WHEN THE CONSUMER SAYS NO HOST EXISTS ──────────────
    "trayHostAvailable = true trips no SNI-host warning" =
      countMatching "StatusNotifierHost" hostAvailableWarnings == 0;
    "trayHostAvailable = false trips exactly one SNI-host warning" =
      countMatching "StatusNotifierHost" hostMissingWarnings == 1;
    "...and that warning names the escape hatch (trayHostAvailable = true) and the bar role" =
      countMatching "nixdesktop.desktop.bar" hostMissingWarnings == 1;
  };
in
report "patchbay" results
