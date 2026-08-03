# Evaluates home/session.nix for real and asserts the keyring PROVIDER assembly it owns -- the
# provider choice (`oo7.enable`/`gnomeKeyring.enable`), the exactly-one-provider assertion, and the
# credential-based unlock wiring (`LoadCredentialEncrypted=`, populated by `oo7.credential.*`).
#
# WHY THIS FILE EXISTS AT ALL, SAME REASONING AS checks/idle-assembly.nix's OWN HEADER: `nix flake
# check` does not evaluate `homeManagerModules` -- it lists them as unchecked and moves on. A green
# check here is the only thing standing between "the provider surface compiles" and "the provider
# surface actually renders the unit it claims to" -- exactly the gap this pass exists to close (see
# home/session.nix's own "keyring provider, assembled HERE" header comment for the full account of
# why a bare `command` string was not enough).
#
# THIS IS ALSO THE FIRST CHECK FILE IN THIS REPO TO EXERCISE home/session.nix's OWN
# `config.assertions`. Before this pass the module wrote none -- every prior home/session.nix
# behaviour (idle timeouts, lock-at-start, the well-known service blocks) was either a legitimate
# "off" state or unconditionally correct by construction, so checks/idle-assembly.nix's own stub
# declares `assertions`/`warnings` defensively without ever reading them back. "Exactly one
# provider" and "enabled with nothing to run" are the first genuinely INVALID states this module
# can be put into, so they are the first real assertions -- and the first real `firedMessages`
# reads, reusing checks/support.nix's own helper for exactly that purpose.
{ pkgs, lib ? pkgs.lib }:
let
  support = import ./support.nix { inherit pkgs lib; };
  inherit (support) firedMessages matching countMatching report;

  # Identical stub to checks/idle-assembly.nix's own -- same six options, same reasoning (a stand-
  # in for "a host", matching the surface home-manager itself declares, not a simplification of
  # it). `xdg.configFile`/`home.packages`/`home.file` are not read or written by this module today
  # but are kept anyway for parity with the sibling check file rather than trimmed to only what
  # this one currently needs.
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

  # The intermediate `services.keyring` attrset -- pre-systemd-unit-rendering, same "read the
  # mechanism's own input, not the rendered unit text" choice checks/idle-assembly.nix's `idleUnit`
  # makes and explains in its own comment. `null` when no keyring service was produced at all
  # (either `keyring.enable = false`, or enabled with nothing to run -- the guard that keeps the
  # latter from ever reaching the generic submodule's non-nullable `command` option, see
  # home/session.nix's own comment on that `optionalAttrs` guard).
  keyringService = settings:
    let services = (evalWith settings).nixdesktop.session.services; in
    if services ? keyring then services.keyring else null;

  # Same shape, for the bootstrap convenience's own rendered entry.
  bootstrapService = settings:
    let services = (evalWith settings).nixdesktop.session.services; in
    if services ? "oo7-keyring-bootstrap" then services."oo7-keyring-bootstrap" else null;

  # `assertions` lands at the TOP LEVEL of the evaluated config (the stub's own flat option,
  # matching real home-manager's shape), not nested under `nixdesktop.session` -- `firedMessages`
  # is handed the whole evaluated config accordingly, exactly like checks/support.nix's own
  # `evalWith`/`firedMessages` pairing.
  keyringAssertionMessages = settings: firedMessages (evalWith settings);

  # `nixdesktop.session.enable = true` always (via `evalWith`'s own `{ enable = true; } //
  # settings`) -- `settings` below is `{ keyring = {...}; }`-shaped, one level under that, mirroring
  # checks/idle-assembly.nix's own `merge`/`base` pattern for `idleAndLock`.
  withKeyring = extra: { keyring = { enable = true; } // extra; };

  fakeOo7Command = "/nix/store/fake-oo7-server/libexec/oo7-daemon";
  fakeCredentialPath = "/etc/credstore.encrypted/oo7.keyring-encryption-password";

  # ── PROVIDER FIXTURES ────────────────────────────────────────────────────────────────────────
  oo7Service = keyringService (withKeyring {
    oo7 = { enable = true; command = fakeOo7Command; };
  });

  # `gnomeKeyring.command` has a working DEFAULT (unlike `oo7.command`, mandatory -- see that
  # option's own doc for why) -- this fixture deliberately does not set it, to prove the default
  # itself is what renders, not merely that a hand-supplied command round-trips.
  gnomeService = keyringService (withKeyring { gnomeKeyring.enable = true; });

  # Neither provider enabled -- the escape hatch alone, exactly the pre-existing (pre-this-pass)
  # usage pattern.
  overrideOnlyService = keyringService (withKeyring { command = "custom-keyring --foreground"; });

  # The escape hatch used ALONGSIDE an enabled provider -- proves `serviceType`/`restart` still
  # follow `oo7.enable`, independent of what `command` literally says (see home/session.nix's own
  # comment on `keyring.command` for why that coupling is deliberate).
  overrideWithOo7Service = keyringService (withKeyring {
    oo7 = { enable = true; command = fakeOo7Command; };
    command = "custom-keyring --foreground";
  });

  # ── CREDENTIAL FIXTURES ──────────────────────────────────────────────────────────────────────
  oo7WithCredential = keyringService (withKeyring {
    oo7 = {
      enable = true;
      command = fakeOo7Command;
      credential = { enable = true; path = fakeCredentialPath; };
    };
  });

  oo7WithoutCredential = oo7Service;

  # ── ASSERTION FIXTURES ───────────────────────────────────────────────────────────────────────
  bothProvidersMsgs = keyringAssertionMessages (withKeyring {
    oo7 = { enable = true; command = fakeOo7Command; };
    gnomeKeyring.enable = true;
  });

  singleProviderMsgs = keyringAssertionMessages (withKeyring {
    oo7 = { enable = true; command = fakeOo7Command; };
  });

  gnomeAloneMsgs = keyringAssertionMessages (withKeyring { gnomeKeyring.enable = true; });

  noProviderNoCommandMsgs = keyringAssertionMessages (withKeyring { });

  # `keyring.enable = false` altogether -- the umbrella off, nothing configured underneath it
  # either. Must trip NEITHER assertion: an off keyring with nothing set is the ordinary rest
  # state, not a misconfiguration.
  disabledNothingConfiguredMsgs = keyringAssertionMessages { keyring.enable = false; };
  disabledService = keyringService { keyring.enable = false; };

  credentialNoPathMsgs = keyringAssertionMessages (withKeyring {
    oo7 = { enable = true; command = fakeOo7Command; credential.enable = true; };
  });

  # ── BOOTSTRAP FIXTURES ───────────────────────────────────────────────────────────────────────
  fakeKeyringPath = "/home/alice/.local/share/keyrings/login.keyring";
  fakeOo7CliCommand = "/nix/store/fake-oo7/bin/oo7-cli";

  # The full, correctly-nested chain: oo7 the provider, its credential, and the bootstrap step
  # that reuses that same credential -- the shape a real host actually wants.
  withBootstrap = extra: withKeyring ({
    oo7 = {
      enable = true;
      command = fakeOo7Command;
      credential = {
        enable = true;
        path = fakeCredentialPath;
        bootstrap = {
          enable = true;
          keyringPath = fakeKeyringPath;
          oo7CliCommand = fakeOo7CliCommand;
        };
      };
    };
  } // extra);

  bootstrapEnabledService = bootstrapService (withBootstrap { });
  bootstrapDisabledService = bootstrapService (withKeyring {
    oo7 = { enable = true; command = fakeOo7Command; credential = { enable = true; path = fakeCredentialPath; }; };
  });

  # bootstrap.enable = true but credential.enable left false -- the credential the bootstrap step
  # would reuse was never turned on at all.
  bootstrapNoCredentialMsgs = keyringAssertionMessages (withKeyring {
    oo7 = {
      enable = true;
      command = fakeOo7Command;
      credential.bootstrap = { enable = true; keyringPath = fakeKeyringPath; oo7CliCommand = fakeOo7CliCommand; };
    };
  });

  # bootstrap.enable = true, credential.enable = true too, but oo7.enable itself left false --
  # nothing for `before = [ "keyring.service" ]` to ever matter against.
  bootstrapNoOo7Msgs = keyringAssertionMessages {
    keyring = {
      enable = true;
      gnomeKeyring.enable = true; # so "nothing tells it what to run" does not ALSO fire here
      oo7.credential = {
        enable = true;
        path = fakeCredentialPath;
        bootstrap = { enable = true; keyringPath = fakeKeyringPath; oo7CliCommand = fakeOo7CliCommand; };
      };
    };
  };

  results = {
    # ── THE PROVIDER CHOICE RENDERS THE RIGHT UNIT ────────────────────────────────────────────
    "oo7 renders its own configured command verbatim" =
      oo7Service.command == fakeOo7Command;
    "oo7 renders Type=simple -- confirmed against the real packaged 0.6.0 unit, never forking" =
      oo7Service.serviceType == "simple";
    "oo7 renders Restart=on-failure -- confirmed against the same unit, never no" =
      oo7Service.restart == "on-failure";

    "gnome-keyring renders its own documented default command with no override needed" =
      gnomeService.command == "gnome-keyring-daemon --start --components=secrets";
    "gnome-keyring renders Type=forking, unchanged from before this option group existed" =
      gnomeService.serviceType == "forking";
    "gnome-keyring renders Restart=no, unchanged from before this option group existed" =
      gnomeService.restart == "no";

    # ── TWO PROVIDERS IS A BUILD FAILURE ──────────────────────────────────────────────────────
    "enabling both oo7 and gnomeKeyring trips the exactly-one-provider assertion" =
      countMatching "choose exactly one provider" bothProvidersMsgs == 1;
    "a single enabled provider (oo7) trips no such assertion" =
      countMatching "choose exactly one provider" singleProviderMsgs == 0;
    "a single enabled provider (gnome-keyring) trips no such assertion either" =
      countMatching "choose exactly one provider" gnomeAloneMsgs == 0;

    # ── ENABLED WITH NOTHING TO RUN IS ALSO A BUILD FAILURE, NEVER A SILENT NO-OP ────────────
    # Unlike the idle daemon (where "enabled, nothing to run" is a legitimate rest state -- see
    # checks/idle-assembly.nix), a keyring with nothing configured to run is always a mistake:
    # this must be a NAMED failure, not a service that quietly never appears.
    "keyring.enable with no provider and no command trips the nothing-to-run assertion" =
      countMatching "nothing tells it what to run" noProviderNoCommandMsgs == 1;
    "...and produces no unit at all rather than a broken one" =
      keyringService (withKeyring { }) == null;
    "keyring.enable = false trips no assertion, even with nothing configured underneath it" =
      countMatching "nothing tells it what to run" disabledNothingConfiguredMsgs == 0
      && countMatching "choose exactly one provider" disabledNothingConfiguredMsgs == 0;
    "...and produces no unit either" =
      disabledService == null;

    # ── THE CREDENTIAL WIRING APPEARS WHEN ENABLED, NOT WHEN DISABLED ────────────────────────
    "oo7 with credential.enable carries loadCredentialEncrypted, keyed by the default credential ID" =
      oo7WithCredential ? loadCredentialEncrypted
      && oo7WithCredential.loadCredentialEncrypted ? "oo7.keyring-encryption-password"
      && oo7WithCredential.loadCredentialEncrypted."oo7.keyring-encryption-password" == fakeCredentialPath;
    # The generic submodule DECLARES `loadCredentialEncrypted` (default `{ }`) on every instance,
    # so the key always EXISTS once evalModules resolves it -- `?` alone cannot distinguish "the
    # credential convenience populated this" from "the option merely defaulted". The VALUE is the
    # actual proof: empty unless `oo7.credential.enable` is what put something there.
    "oo7 without credential.enable carries an EMPTY loadCredentialEncrypted, not merely absent" =
      oo7WithoutCredential.loadCredentialEncrypted == { };
    "gnome-keyring never carries a populated loadCredentialEncrypted, having no such concept" =
      gnomeService.loadCredentialEncrypted == { };

    "credential.enable with no path is its own build failure" =
      countMatching "credential.enable is true but" credentialNoPathMsgs == 1;
    "...and does not also trip the other two keyring assertions" =
      countMatching "choose exactly one provider" credentialNoPathMsgs == 0
      && countMatching "nothing tells it what to run" credentialNoPathMsgs == 0;

    # ── THE ESCAPE HATCH STILL WORKS ──────────────────────────────────────────────────────────
    "an explicit command overrides both providers' own assembly verbatim" =
      overrideOnlyService.command == "custom-keyring --foreground";
    "the override alone (no provider enabled) keeps the backward-compatible gnome-keyring-shaped Type/Restart" =
      overrideOnlyService.serviceType == "forking" && overrideOnlyService.restart == "no";
    "the override alongside oo7.enable keeps oo7's own Type/Restart, not gnome-keyring's" =
      overrideWithOo7Service.command == "custom-keyring --foreground"
      && overrideWithOo7Service.serviceType == "simple"
      && overrideWithOo7Service.restart == "on-failure";

    # ── THE MISSING MECHANISM: oo7 KEYRING BOOTSTRAP ─────────────────────────────────────────
    "bootstrap.enable renders an oo7-keyring-bootstrap service" =
      bootstrapEnabledService != null;
    "bootstrap command names both the configured oo7-cli command and the keyring path" =
      lib.hasInfix fakeOo7CliCommand bootstrapEnabledService.command
      && lib.hasInfix fakeKeyringPath bootstrapEnabledService.command
      && lib.hasInfix "repair" bootstrapEnabledService.command;
    "bootstrap runs through a shell (needs $(...) substitution), oneshot, RemainAfterExit" =
      bootstrapEnabledService.runShell == true
      && bootstrapEnabledService.serviceType == "oneshot"
      && bootstrapEnabledService.remainAfterExit == true;
    "bootstrap never restarts -- a one-shot gate that wins once or not at all" =
      bootstrapEnabledService.restart == "no";
    "bootstrap's ConditionPathExists negates the configured keyring path, systemd's own '!' syntax" =
      bootstrapEnabledService.conditionPathExists == "!${fakeKeyringPath}";
    "bootstrap orders itself Before the daemon's own unit (keyring.service), never After" =
      bootstrapEnabledService.before == [ "keyring.service" ];
    "bootstrap reuses the SAME LoadCredentialEncrypted as the daemon -- one credential, two readers" =
      bootstrapEnabledService.loadCredentialEncrypted == { "oo7.keyring-encryption-password" = fakeCredentialPath; };

    "bootstrap.enable = false (the default) renders no such service at all" =
      bootstrapDisabledService == null;

    "bootstrap.enable with credential.enable = false trips its own named assertion" =
      countMatching "credential.enable" bootstrapNoCredentialMsgs == 1;
    "...and produces no bootstrap service either (guarded, not merely warned about)" =
      bootstrapService (withKeyring {
        oo7.credential.bootstrap = { enable = true; keyringPath = fakeKeyringPath; oo7CliCommand = fakeOo7CliCommand; };
      }) == null;

    "bootstrap.enable with oo7.enable = false trips its own named assertion" =
      countMatching "oo7.enable" bootstrapNoOo7Msgs == 1;
  };
in
report "keyring" results
