# checks/oo7-provisioning.nix — proves the SYSTEM-level half of the oo7 mechanism
# (`modules/oo7-credential.nix`, `modules/oo7-keyring-bootstrap.nix`), the same way
# checks/keyring.nix proves the home-manager half (`home/session.nix`'s `keyring.oo7.credential.
# bootstrap`) -- see this repo's own flake.nix, "OO7 KEYRING: THE SYSTEM-LEVEL HALF", for why the
# split between the two check files matches the split between the two module files exactly.
#
# `lib.evalModules` PLUS A STUB, NOT A REAL `nixosSystem`/`makeSystemConfig` BUILD -- unlike
# checks/launcher.nix's own heavier real-build layer, this file's two modules touch only
# `systemd.services`/`systemd.user.services`/`pkgs.writeShellScript`, none of it NixOS-specific
# rendering logic this repo does not itself own (contrast `modules/launcher.nix`'s `DeviceAllow=`/
# `PAMName=` assembly, which checks/launcher.nix's own header explains needed the real thing to
# catch a stub that "accepts anything"). `systemHostStub`/`systemHostStubSystemManager` below
# mirror checks/launcher.nix's OWN stubs of the identical names byte-for-byte in what they declare
# and — just as importantly — what they deliberately omit (no `systemd.user.services` on the
# system-manager one), for the identical reason: a stub that accepts a write to an option the real
# module tree does not have would prove nothing about the one genuine capability gap this file's
# own THROWS tests exist to keep provable rather than silently reintroduced.
#
# WHY `renderedScript`, NOT `builtins.readFile` ON THE REAL `ExecStart` DERIVATION -- both new
# modules expose their shell script's TEXT as a plain, readOnly string option specifically so this
# file can assert on it. `nix flake check` evaluates flakes in PURE mode, where forcing a build of
# a derivation to read its OUTPUT back (`builtins.readFile <store-path-not-yet-realised>`) is
# import-from-derivation and structurally unavailable — a check that tried to inspect `ExecStart`'s
# built content directly would need `--impure`/`allow-import-from-derivation`, a flag this repo has
# no standing reason to require of `nix flake check --all-systems`. `renderedScript` sidesteps that
# by being pure text the module already had to compute anyway, at zero extra cost.
{ pkgs, lib ? pkgs.lib }:
let
  support = import ./support.nix { inherit pkgs lib; };
  inherit (support) report;

  credentialModule = ../modules/oo7-credential.nix;
  bootstrapModule = ../modules/oo7-keyring-bootstrap.nix;

  # ── Stubs, mirroring checks/launcher.nix's own `systemHostStub`/`systemHostStubSystemManager` ──
  # See this file's own header for why these are re-declared here rather than imported from that
  # file: checks/launcher.nix does not export them as reusable values, and re-typing six lines to
  # keep this file self-contained beats introducing a cross-check-file dependency neither needs.
  systemHostStubNixos = { ... }: {
    options = {
      systemd.services = lib.mkOption { type = lib.types.attrsOf lib.types.anything; default = { }; };
      systemd.user.services = lib.mkOption { type = lib.types.attrsOf lib.types.anything; default = { }; };
    };
  };

  # DELIBERATELY NO `systemd.user.services` HERE -- the entire point. See checks/launcher.nix's own
  # comment on its identically-shaped stub: composing `bootstrapModule` against this one is the
  # proof that it CANNOT be used on the system-manager plane, matching flake.nix's own decision to
  # export it under `nixosModules` only.
  systemHostStubSystemManager = { ... }: {
    options = {
      systemd.services = lib.mkOption { type = lib.types.attrsOf lib.types.anything; default = { }; };
    };
  };

  # Both new module files take `pkgs` as a real module argument (`pkgs.writeShellScript`), unlike
  # every module `checks/support.nix`'s own generic `evalWith`/`evalThrows` were originally written
  # against (`home/session.nix`, this repo's other `nixosModules`/`systemManagerModules` -- none of
  # them touch `pkgs` at all, see e.g. `checks/keyring.nix`'s own header). `specialArgs` is what
  # resolves a module's `{ pkgs, ... }:` function argument -- support.nix's own helpers do not
  # thread one through, so this file supplies its own `lib.evalModules` calls (below) and its own
  # `evalThrowsWithPkgs` (mirroring `support.evalThrows` exactly, plus `specialArgs`) rather than
  # silently reaching for the pkgs-less versions and getting an unrelated "attribute pkgs missing"
  # error instead of the real assertion this file is trying to prove.
  evalWithNixos = modules: (lib.evalModules {
    modules = [ support.hostStub systemHostStubNixos credentialModule bootstrapModule ] ++ modules;
    specialArgs = { inherit pkgs; };
  }).config;

  evalCredentialOnSystemManager = modules: (lib.evalModules {
    modules = [ support.hostStub systemHostStubSystemManager credentialModule ] ++ modules;
    specialArgs = { inherit pkgs; };
  }).config;

  evalThrowsWithPkgs = modules:
    !(builtins.tryEval (builtins.deepSeq
      ((lib.evalModules {
        modules = [ support.hostStub ] ++ modules;
        specialArgs = { inherit pkgs; };
      }).config)
      true)).success;

  # ── CREDENTIAL fixtures ──────────────────────────────────────────────────────────────────────
  credentialPath = "/home/alice/.config/credstore.encrypted/oo7.keyring-encryption-password";

  credEnabled = {
    nixdesktop.oo7.credential = {
      enable = true;
      user = "alice";
      path = credentialPath;
    };
  };

  credCfgNixos = evalWithNixos [ credEnabled ];
  credCfgSystemManager = evalCredentialOnSystemManager [ credEnabled ];

  # `enable = false` but `user`/`path` still set -- proves `renderedScript` reads back
  # independently of `enable` (a consumer staging values ahead of flipping the switch), distinct
  # from `credDisabledCfg` below (nothing configured at all, the true rest state).
  credConfiguredButDisabledCfg = evalWithNixos [
    { nixdesktop.oo7.credential = { enable = false; user = "alice"; path = credentialPath; }; }
  ];

  credDisabledCfg = evalWithNixos [ ];

  credService = "oo7-credential-provision-alice";

  # ── BOOTSTRAP fixtures ───────────────────────────────────────────────────────────────────────
  keyringPath = "/home/alice/.local/share/keyrings/login.keyring";
  oo7CliCommand = "/nix/store/fake-oo7/bin/oo7-cli";

  bootstrapEnabled = {
    nixdesktop.oo7.keyringBootstrap = {
      enable = true;
      inherit keyringPath oo7CliCommand;
      credentialPath = credentialPath;
    };
  };

  bootCfg = evalWithNixos [ bootstrapEnabled ];
  bootCfgCustomDaemon = evalWithNixos [
    (lib.recursiveUpdate bootstrapEnabled {
      nixdesktop.oo7.keyringBootstrap.daemonServiceName = "keyring";
    })
  ];
  bootDisabledCfg = evalWithNixos [ ];

  results = {
    # ═══ CREDENTIAL: renders on BOTH planes, from the SAME module, no branch ═══════════════════
    "credential: renders systemd.services.oo7-credential-provision-<user> on NixOS" =
      credCfgNixos.systemd.services ? ${credService};
    "credential: renders the SAME service on system-manager (one module, both planes)" =
      credCfgSystemManager.systemd.services ? ${credService};

    "credential: ConditionPathExists negates the configured path" =
      credCfgNixos.systemd.services.${credService}.unitConfig.ConditionPathExists == "!${credentialPath}";
    "credential: Type=oneshot, RemainAfterExit=true" =
      credCfgNixos.systemd.services.${credService}.serviceConfig.Type == "oneshot"
      && credCfgNixos.systemd.services.${credService}.serviceConfig.RemainAfterExit == true;
    "credential: wantedBy multi-user.target by default" =
      credCfgNixos.systemd.services.${credService}.wantedBy == [ "multi-user.target" ];

    # ═══ CREDENTIAL: the three measured facts, in the actual script text ═══════════════════════
    # `alice` (and this whole fixture's path) needs no shell quoting at all --
    # `lib.escapeShellArg` (nixpkgs' own, confirmed by reading `lib/strings.nix`) only wraps a
    # value in `'...'` when it fails a `[[:alnum:],._+:@%/-]+` match; a bare username or an
    # ordinary absolute path both pass that match and come back UNQUOTED, verbatim -- still safe,
    # just not visually quoted. These assertions match that real, correct behaviour rather than
    # assuming escaping always adds quote marks.
    "credential script: resolves uid at RUNTIME via id -u, never a Nix-eval-time value" =
      lib.hasInfix "uid=$(id -u alice)" credCfgNixos.nixdesktop.oo7.credential.renderedScript;
    "credential script: base64-encodes the random plaintext" =
      lib.hasInfix "base64" credCfgNixos.nixdesktop.oo7.credential.renderedScript;
    "credential script: strips the trailing newline base64 leaves behind" =
      lib.hasInfix "tr -d '\\n'" credCfgNixos.nixdesktop.oo7.credential.renderedScript;
    "credential script: encrypts --user --uid=, never the plain host-key form" =
      lib.hasInfix ''systemd-creds encrypt --user --uid="$uid" --with-key=host''
        credCfgNixos.nixdesktop.oo7.credential.renderedScript;
    "credential script: --with-key=host, never --with-key=tpm2 as an actual flag" =
      lib.hasInfix "--with-key=host" credCfgNixos.nixdesktop.oo7.credential.renderedScript
      # The script's own comments legitimately SAY "tpm2" (explaining the rejection, for anyone
      # reading the deployed unit live) -- this checks the FLAG never does, not that the word
      # never appears at all.
      && !(lib.hasInfix "--with-key=tpm2" credCfgNixos.nixdesktop.oo7.credential.renderedScript);
    "credential script: writes to the configured PER-USER path, never /etc/credstore.encrypted" =
      lib.hasInfix credentialPath credCfgNixos.nixdesktop.oo7.credential.renderedScript
      && !(lib.hasInfix "/etc/credstore.encrypted" credCfgNixos.nixdesktop.oo7.credential.renderedScript);
    "credential script: chowns the blob to the target user, not left root:root" =
      lib.hasInfix "chown alice:alice" credCfgNixos.nixdesktop.oo7.credential.renderedScript;
    "credential script is IDENTICAL text on both planes -- one mechanism, not two copies" =
      credCfgNixos.nixdesktop.oo7.credential.renderedScript
        == credCfgSystemManager.nixdesktop.oo7.credential.renderedScript;

    # ═══ CREDENTIAL: the shared PATH unifies both planes without a Nix-level branch ═══════════
    "credential: Environment=PATH names BOTH planes' canonical bin dirs in one value" =
      let env = credCfgNixos.systemd.services.${credService}.serviceConfig.Environment; in
      lib.hasInfix "/run/current-system/sw/bin" env && lib.hasInfix "/usr/bin" env;

    # ═══ CREDENTIAL: disabled renders nothing, and mandatory options are truly mandatory ═══════
    "credential: disabled renders no service at all" =
      !(credDisabledCfg.systemd.services ? ${credService});
    "credential: renderedScript reads back even with enable=false, once user/path ARE set" =
      builtins.isString credConfiguredButDisabledCfg.nixdesktop.oo7.credential.renderedScript
      && lib.hasInfix credentialPath credConfiguredButDisabledCfg.nixdesktop.oo7.credential.renderedScript;
    "credential: still renders no service while enable=false, even with user/path set" =
      !(credConfiguredButDisabledCfg.systemd.services ? ${credService});
    "credential: enable=true with no `user` set throws (mandatory, no default)" =
      evalThrowsWithPkgs [ credentialModule systemHostStubNixos { nixdesktop.oo7.credential = { enable = true; path = credentialPath; }; } ];
    "credential: enable=true with no `path` set throws (mandatory, no default)" =
      evalThrowsWithPkgs [ credentialModule systemHostStubNixos { nixdesktop.oo7.credential = { enable = true; user = "alice"; }; } ];

    # ═══ BOOTSTRAP: renders on NixOS, ordered strictly before the daemon ═══════════════════════
    "bootstrap: renders systemd.user.services.oo7-keyring-bootstrap" =
      bootCfg.systemd.user.services ? "oo7-keyring-bootstrap";
    "bootstrap: ConditionPathExists negates the configured keyring path" =
      bootCfg.systemd.user.services."oo7-keyring-bootstrap".unitConfig.ConditionPathExists == "!${keyringPath}";
    "bootstrap: Type=oneshot, RemainAfterExit=true (a gate, not a daemon)" =
      bootCfg.systemd.user.services."oo7-keyring-bootstrap".serviceConfig.Type == "oneshot"
      && bootCfg.systemd.user.services."oo7-keyring-bootstrap".serviceConfig.RemainAfterExit == true;
    "bootstrap: LoadCredentialEncrypted reuses the SAME credential name+path, not a second copy" =
      bootCfg.systemd.user.services."oo7-keyring-bootstrap".serviceConfig.LoadCredentialEncrypted
        == [ "oo7.keyring-encryption-password:${credentialPath}" ];

    "bootstrap script: gates on the keyring FILE, creates the parent dir, calls oo7-cli repair" =
      let s = bootCfg.nixdesktop.oo7.keyringBootstrap.renderedScript; in
      lib.hasInfix "install -d -m 0700" s
      && lib.hasInfix keyringPath s
      && lib.hasInfix oo7CliCommand s
      && lib.hasInfix "repair" s;
    "bootstrap script: reads the password from $CREDENTIALS_DIRECTORY, never a literal secret" =
      lib.hasInfix ''$CREDENTIALS_DIRECTORY/oo7.keyring-encryption-password''
        bootCfg.nixdesktop.oo7.keyringBootstrap.renderedScript;

    "bootstrap: wires wants+after onto the DEFAULT daemon unit name (oo7-daemon, nixpkgs' own)" =
      bootCfg.systemd.user.services."oo7-daemon".wants == [ "oo7-keyring-bootstrap.service" ]
      && bootCfg.systemd.user.services."oo7-daemon".after == [ "oo7-keyring-bootstrap.service" ];
    "bootstrap: a custom daemonServiceName wires the edge onto THAT unit instead, not oo7-daemon" =
      bootCfgCustomDaemon.systemd.user.services."keyring".wants == [ "oo7-keyring-bootstrap.service" ]
      && !(bootCfgCustomDaemon.systemd.user.services ? "oo7-daemon");

    "bootstrap: disabled renders no unit and wires no daemon edge" =
      !(bootDisabledCfg.systemd.user.services ? "oo7-keyring-bootstrap")
      && !(bootDisabledCfg.systemd.user.services ? "oo7-daemon");

    "bootstrap: enable=true with no keyringPath throws (mandatory, no default)" =
      evalThrowsWithPkgs [
        bootstrapModule
        systemHostStubNixos
        { nixdesktop.oo7.keyringBootstrap = { enable = true; oo7CliCommand = oo7CliCommand; credentialPath = credentialPath; }; }
      ];
    "bootstrap: enable=true with no oo7CliCommand throws (mandatory, no default -- NAME NO DISTRO PACKAGES)" =
      evalThrowsWithPkgs [
        bootstrapModule
        systemHostStubNixos
        { nixdesktop.oo7.keyringBootstrap = { enable = true; inherit keyringPath; credentialPath = credentialPath; }; }
      ];

    # ═══ THE ARCHITECTURE DECISION ITSELF, WITH TEETH ══════════════════════════════════════════
    # This is the proof for flake.nix's own "genuinely cannot share" claim, not an assumption
    # carried over from modules/launcher.nix's unrelated finding: composing the SAME
    # `bootstrapModule` against a host stub that faithfully omits `systemd.user.services` (the
    # system-manager plane's real shape) must fail outright, because that plane has no such
    # option for this module to write into at all -- exactly why it is exported under
    # `nixosModules` only and never `systemManagerModules`.
    "bootstrap module THROWS when composed against a system-manager-shaped host (no systemd.user.services exists)" =
      evalThrowsWithPkgs [ bootstrapModule systemHostStubSystemManager bootstrapEnabled ];
    # The credential module, by contrast, must NOT trip the identical stub -- the positive half of
    # the same proof: it never touches `systemd.user.services` at all, which is exactly why IT
    # (unlike bootstrap) is exported to both planes.
    #
    # NOT `evalThrowsWithPkgs` here (unlike every other fixture in this file) -- its `deepSeq`
    # forces the ENTIRE config tree, and this is the one fixture that reaches all the way through
    # to a REAL `pkgs.writeShellScript` derivation without erroring first. Measured live: `deepSeq`
    # walking a real nixpkgs derivation's own `__functor`/`overrideAttrs` machinery (designed to be
    # CALLED, not blindly recursed into) genuinely stack-overflows Nix's evaluator -- not a bug in
    # the module under test, a property of `deepSeq` on real derivations that every other fixture
    # in this file avoids by hitting its own expected `throw` first, before ever reaching one. Only
    # forcing the specific leaf this test actually needs (the rendered service NAME) proves
    # composition succeeded without also trying to prove `pkgs.writeShellScript`'s own internals
    # are safe to `deepSeq`, which is not this test's job.
    "credential module evaluates CLEANLY against the same system-manager-shaped host" =
      (builtins.tryEval (builtins.attrNames credCfgSystemManager.systemd.services)).success;
  };
in
report "oo7-provisioning" results
