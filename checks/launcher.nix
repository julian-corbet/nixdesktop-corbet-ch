# Evaluates modules/launcher.nix for real, wired to the real modules/session.nix exactly as a
# consumer composes both (mirrors checks/session-devices.nix's own nixhost fixture), and proves
# the shapes that matter most: a seated session is unrepresentable as a `--user` unit and a
# headless one can never carry `PAMName=`, because getting that backwards is the exact defect this
# whole module exists to remove (see modules/launcher.nix's header — the elitebook's live, silent
# polkit failure is what a `--user` "seated" session actually looks like).
#
# FOUR LAYERS, DELIBERATELY, NOT ONE OR TWO. modules/launcher.nix is now curried on `plane`
# ("nixos" | "system-manager" — see its own header for the full account of what system-manager
# genuinely does and does not support, read from its actual module tree rather than assumed), and
# each plane gets both a lightweight `lib.evalModules` layer (fast, proves the WIRING) and a real
# build layer (`nixpkgs.lib.nixosSystem` / `system-manager.lib.makeSystemConfig`, the actual
# upstream module trees, proving the literal RENDERED UNIT TEXT). An EARLIER version of this file
# stubbed `systemd.*`/`users.*` as bare `attrsOf anything` — which happily accepted `DevicePolicy =
# "strict"` with an empty starting `DeviceAllow=`, a bare non-absolute `ExecStart`, and a
# `users.users.<name> = { linger = true; }` write, reporting 21/21 green against a module that
# could not actually start a session (measured live on corbet-server: `status=208/STDIN`). A stub
# that accepts anything proves nothing about whether systemd itself would accept it — and, for the
# system-manager plane specifically, a stub that DOES declare `systemd.user.services` (when the
# real system-manager module tree never does) would prove nothing about the one genuine capability
# gap this pass exists to degrade explicitly. So layers three and four below use a stub, and a real
# module tree, that both faithfully omit `systemd.user.services` — see `systemHostStubSystemManager`
# and the real-`makeSystemConfig` fixtures for how that absence is itself part of the proof.
{ pkgs, sessionModule, launcherModuleNixos, launcherModuleSystemManager, nixpkgs, system, systemManagerLib, lib ? pkgs.lib }:
let
  support = import ./support.nix { inherit pkgs lib; };
  inherit (support) firedMessages matching countMatching report;

  # ── The same nixhost stand-in checks/session-devices.nix uses, narrowed to what
  # modules/session.nix reads (see that file's own header for why a stand-in and not the real
  # nixhost flake) -- PLUS `cardPath`/`renderPath` on each device now, since modules/launcher.nix
  # is the first consumer that reads past the device NAME.
  envSubmodule = { ... }: {
    options = {
      resources.gpu = lib.mkOption {
        type = lib.types.attrsOf (lib.types.submodule {
          options.access = lib.mkOption {
            type = lib.types.enum [ "none" "shared" "exclusive" ];
            default = "none";
          };
        });
        default = { };
      };
      environments = lib.mkOption {
        type = lib.types.attrsOf (lib.types.submodule envSubmodule);
        default = { };
      };
    };
  };

  nixhostStub = { ... }: {
    options.nixhost = {
      resources.gpu = lib.mkOption { type = lib.types.attrsOf lib.types.anything; default = { }; };
      environments = lib.mkOption { type = lib.types.attrsOf (lib.types.submodule envSubmodule); default = { }; };
    };
  };

  # The minimal slice of real NixOS host surface modules/launcher.nix actually writes to, for the
  # LIGHTWEIGHT `evalModules` layer only -- the real-`nixosSystem` layer further down uses the
  # actual `systemd`/`users` modules instead of this. Not `systemd.package`/a `pkgsStub`: neither
  # is read by this module any more (no `pkgs.writeShellScript`, no `ExecStartPre`, no
  # `systemctl set-property` -- see modules/launcher.nix's header for why that mechanism is gone).
  systemHostStub = { ... }: {
    options = {
      systemd.services = lib.mkOption { type = lib.types.attrsOf lib.types.anything; default = { }; };
      systemd.user.services = lib.mkOption { type = lib.types.attrsOf lib.types.anything; default = { }; };
      systemd.tmpfiles.rules = lib.mkOption { type = lib.types.listOf lib.types.str; default = [ ]; };
      users.users = lib.mkOption { type = lib.types.attrsOf lib.types.anything; default = { }; };
    };
  };

  # The system-manager-plane equivalent stub, for the LIGHTWEIGHT layer only -- and the whole
  # point is what it does NOT declare. system-manager's own module tree (`nix/modules/systemd.nix`,
  # confirmed by reading it at the pinned rev, not assumed) declares `systemd.services`/`sockets`/
  # `timers`/`paths`/`targets`/`mounts`/`automounts`/`slices` on the SYSTEM instance only --
  # `systemd.tmpfiles.rules` is real (`nix/modules/tmpfiles.nix`), `users.users` is real (vendored
  # from nixpkgs, `nix/modules/upstream/nixpkgs/users-groups.nix`) -- but there is no
  # `systemd.user.services` ANYWHERE in that tree. Composing modules/launcher.nix's
  # system-manager-plane value against a stub that faithfully omits it is itself part of the proof:
  # if this module ever again wrote to that path unconditionally (the exact bug class this pass
  # fixes), even a SEATED-ONLY config -- zero headless sessions at all -- would throw "The option
  # `systemd.user.services' does not exist" the moment `config` is forced, because the module
  # system requires every written config path to match a declared option regardless of whether any
  # session actually needed it. See `seatedOnlyCfgSm`'s own result below for that exact proof.
  systemHostStubSystemManager = { ... }: {
    options = {
      systemd.services = lib.mkOption { type = lib.types.attrsOf lib.types.anything; default = { }; };
      systemd.tmpfiles.rules = lib.mkOption { type = lib.types.listOf lib.types.str; default = [ ]; };
      users.users = lib.mkOption { type = lib.types.attrsOf lib.types.anything; default = { }; };
      # DELIBERATELY NO `systemd.user.services` HERE -- see the comment above.
    };
  };

  evalWith = modules: (lib.evalModules {
    modules = [ support.hostStub systemHostStub nixhostStub sessionModule launcherModuleNixos ] ++ modules;
  }).config;

  evalWithSystemManager = modules: (lib.evalModules {
    modules = [ support.hostStub systemHostStubSystemManager nixhostStub sessionModule launcherModuleSystemManager ] ++ modules;
  }).config;

  # Two devices, matching nixgpu's own worked examples (see the review instructions this pass
  # implements): "ast" is a display-only device with NO render node (an AST-class BMC framebuffer,
  # `DRIVER_GEM | DRIVER_MODESET` and no more); "amd" has both. devhome permits "ast" exclusively
  # and denies "amd" outright -- the SAME claim shape checks/session-devices.nix's own fixture uses,
  # so `permittedDevices` here resolves to exactly `[ "ast" ]`, as it does there.
  estateInventory = {
    ast = { cardPath = "/dev/dri/by-path/pci-0000:03:00.0-card"; renderPath = null; };
    amd = { cardPath = "/dev/dri/by-path/pci-0000:0a:00.0-card"; renderPath = "/dev/dri/by-path/pci-0000:0a:00.0-render"; };
  };
  devhomeClaim = { ast.access = "exclusive"; amd.access = "none"; };

  baseModules = [
    { nixhost = { resources.gpu = estateInventory; environments.devhome.resources.gpu = devhomeClaim; }; }
  ];

  # Gives "scroll" an already-absolute `command`, so the happy-path fixtures below resolve their
  # ExecStart without needing a fabricated `package` derivation -- exactly the "spell command as an
  # already-absolute path yourself" escape hatch `nixdesktop.launcher.compositors.<n>.command`'s own
  # doc describes.
  absoluteCompositorOverride = { nixdesktop.launcher.compositors.scroll.command = "/nix/store/fake-scroll-path/bin/scroll"; };

  seated = extra: {
    compositor = "scroll";
    user = "richc";
    delivery = "seated";
    renderer = "pixman";
    environment = "devhome";
    seat = "seat0";
  } // extra;

  headless = extra: {
    compositor = "scroll";
    user = "richc";
    delivery = "headless";
    renderer = "pixman";
  } // extra;

  seatedCfg = evalWith (baseModules ++ [ absoluteCompositorOverride { nixdesktop.sessions.desk = seated { }; } ]);
  headlessCfg = evalWith (baseModules ++ [ absoluteCompositorOverride { nixdesktop.sessions.remote = headless { }; } ]);
  unknownCompositorCfg = evalWith (baseModules ++ [ { nixdesktop.sessions.desk = seated { compositor = "mystery"; }; } ]);

  # NO `absoluteCompositorOverride` here, deliberately: the built-in `scroll` default entry leaves
  # `command = "scroll"` (non-absolute) and `package = null`, which is exactly the unresolved shape
  # the new assertion exists to catch.
  unresolvedCommandCfg = evalWith (baseModules ++ [ { nixdesktop.sessions.desk = seated { }; } ]);

  # Trips modules/monitors.nix-style raw-name detection (§8 assertion 10): a device NAME shaped
  # like the exact thing this design exists to remove, arriving from nixhost's claim exactly as it
  # would from a real (mis-)declared inventory -- launcher.nix has no way to tell this apart from a
  # legitimate slug except by shape. Deliberately has no `cardPath`/`renderPath` at all: proving
  # this assertion fires never has to force `deviceAllowFor`/`cardPathsFor` (those are read only
  # from `systemd.services`, which this test never inspects for this fixture -- see this file's
  # own note by `firedMessages` below), so the missing fields are never a problem here.
  rawNameCfg = evalWith (baseModules ++ [
    {
      nixhost = {
        resources.gpu = { "card0" = { }; };
        environments.devhome.resources.gpu."card0".access = "exclusive";
      };
    }
    { nixdesktop.sessions.desk = seated { }; }
  ]);

  # A DRM card count never reaches three digits on any hardware this estate owns or is likely to;
  # checking every "cardD"/"renderDD" for a single digit D catches ANY literal numbered reference
  # regardless of how many digits it actually has (a two-or-more-digit number still starts with one
  # of these ten digits) without needing a real regex engine.
  digits = [ "0" "1" "2" "3" "4" "5" "6" "7" "8" "9" ];
  containsLiteralCardNumber = text:
    lib.any (d: lib.hasInfix ("card" + d) text) digits
    || lib.any (d: lib.hasInfix ("renderD" + d) text) digits;

  deskUnit = seatedCfg.systemd.services."nixdesktop-desk";
  remoteUnit = headlessCfg.systemd.user.services."nixdesktop-remote";

  lightweightResults = {
    # ── SEATED IS A SYSTEM UNIT, NEVER A --user ONE ─────────────────────────────────────────────
    "a seated session is a system unit with PAMName=login and User= set" =
      deskUnit.serviceConfig.PAMName == "login"
      && deskUnit.serviceConfig.User == "richc";

    "a seated session never appears under systemd.user.services" =
      !(seatedCfg.systemd.user.services ? "nixdesktop-desk");

    # ── HEADLESS IS A --user UNIT, NEVER PAMName ────────────────────────────────────────────────
    "a headless session renders a systemd.user.services unit" =
      headlessCfg.systemd.user.services ? "nixdesktop-remote";

    "a headless session never sets PAMName or User" =
      !(remoteUnit.serviceConfig ? PAMName) && !(remoteUnit.serviceConfig ? User);

    "a headless session never appears under systemd.services" =
      !(headlessCfg.systemd.services ? "nixdesktop-remote");

    "a headless unit is scoped to its own user via ConditionUser" =
      remoteUnit.unitConfig.ConditionUser == "richc";

    "a headless unit gets WLR_BACKENDS=headless and the session's renderer, never auto" =
      lib.any (e: e == "WLR_BACKENDS=headless") remoteUnit.serviceConfig.Environment
      && lib.any (e: e == "WLR_RENDERER=pixman") remoteUnit.serviceConfig.Environment;

    # ── LINGERING IS A TMPFILES MARKER, NEVER A users.users WRITE ───────────────────────────────
    # See modules/launcher.nix's own comment for why: `users.users.<name> = { linger = true; }`
    # forces NixOS to treat that name as a locally-managed account, which breaks the
    # externally-managed (lldap) identity path this module's own comments say it accommodates.
    "lingering is a declarative tmpfiles marker file, never a users.users definition" =
      lib.any (r: lib.hasInfix "/var/lib/systemd/linger/richc" r) headlessCfg.systemd.tmpfiles.rules
      && !(headlessCfg.users.users ? richc);

    "a seated-only config declares no linger marker at all (no headless session to need one)" =
      seatedCfg.systemd.tmpfiles.rules == [ ];

    # ── DEVICE POLICY: closed, never strict, plus the static tty/pts/input floor ────────────────
    "the seated unit's DevicePolicy is closed, never strict" =
      deskUnit.serviceConfig.DevicePolicy == "closed";

    "DeviceAllow includes the static tty/pts/input floor a graphical session needs" =
      lib.all (e: lib.elem e deskUnit.serviceConfig.DeviceAllow)
        [ "/dev/ptmx rw" "/dev/tty rw" "char-tty rw" "char-pts rw" "char-input rw" ];

    "DeviceAllow includes the permitted device's card node, and no render node for it (ast has none)" =
      lib.elem "/dev/dri/by-path/pci-0000:03:00.0-card rw" deskUnit.serviceConfig.DeviceAllow
      && !(lib.elem "/dev/dri/by-path/pci-0000:03:00.0-render rw" deskUnit.serviceConfig.DeviceAllow);

    "DeviceAllow never mentions the denied device (amd) at all" =
      !(lib.any (e: lib.hasInfix "0000:0a:00.0" e) deskUnit.serviceConfig.DeviceAllow);

    "DeviceAllow is entirely STATIC -- no ExecStartPre exists on the seated unit any more" =
      !(deskUnit.serviceConfig ? ExecStartPre);

    # ── EXECSTART IS ABSOLUTE ────────────────────────────────────────────────────────────────────
    "the seated unit's ExecStart is an absolute path" =
      lib.hasPrefix "/" deskUnit.serviceConfig.ExecStart;

    # ── WLR_DRM_DEVICES CARRIES CARD PATHS ONLY, NEVER A RENDER NODE ────────────────────────────
    "the compositor's own device env var carries the card path only" =
      lib.any (e: e == "WLR_DRM_DEVICES=/dev/dri/by-path/pci-0000:03:00.0-card") deskUnit.serviceConfig.Environment;

    # ── NEVER A LITERAL CARD NUMBER, ANYWHERE ON THE RENDERED UNIT ──────────────────────────────
    "no literal card or render-node number appears anywhere on the seated unit" =
      let
        allText = lib.concatStringsSep "\n"
          (deskUnit.serviceConfig.DeviceAllow
            ++ [ deskUnit.serviceConfig.ExecStart ]
            ++ deskUnit.serviceConfig.Environment);
      in
      !(containsLiteralCardNumber allText);

    # ── AN UNKNOWN COMPOSITOR FAILS LOUDLY ──────────────────────────────────────────────────────
    "a session naming a compositor absent from the exec table is a build failure" =
      countMatching "is neither one of" (firedMessages unknownCompositorCfg) == 1;

    "the unknown-compositor message names the session and the compositor" =
      let m = lib.head (matching "is neither one of" (firedMessages unknownCompositorCfg)); in
      lib.hasInfix ''sessions.desk names compositor "mystery"'' m;

    "a known compositor (the estate's real fixture) produces no such failure" =
      countMatching "is neither one of" (firedMessages seatedCfg) == 0;

    # ── AN UNRESOLVABLE COMPOSITOR COMMAND FAILS LOUDLY, INDEPENDENTLY ──────────────────────────
    "a compositor command that is neither absolute nor package-resolved is its own build failure" =
      countMatching "does not start with an absolute path" (firedMessages unresolvedCommandCfg) == 1;

    "that failure fires exactly once, not doubled up with the unknown-compositor one" =
      countMatching "is neither one of" (firedMessages unresolvedCommandCfg) == 0;

    "a resolved compositor command (the estate's fixture, absolute) produces no such failure" =
      countMatching "does not start with an absolute path" (firedMessages seatedCfg) == 0;

    # ── A DEVICE NAME SHAPED LIKE THE THING THIS DESIGN FORBIDS ─────────────────────────────────
    # NB: the search string stops at "raw", not "raw device node" — the assertion message wraps
    # onto a new source line right after "raw", and a Nix indented string keeps that line break
    # verbatim, so a search phrase spanning it would never match even when the assertion fired.
    "a device name shaped like a raw cardN is rejected" =
      countMatching "shaped like a raw" (firedMessages rawNameCfg) == 1;

    "the estate's real device names (ast, amd) trip no such rejection" =
      countMatching "shaped like a raw" (firedMessages seatedCfg) == 0;
  };

  # ── LAYER THREE: system-manager, LIGHTWEIGHT `evalModules` ────────────────────────────────────
  #
  # Mirrors the lightweight NixOS layer above, but wired to `launcherModuleSystemManager` and the
  # `systemHostStubSystemManager` fixture that faithfully omits `systemd.user.services` -- see that
  # stub's own comment for why its absence is itself part of the proof.
  seatedCfgSm = evalWithSystemManager (baseModules ++ [ absoluteCompositorOverride { nixdesktop.sessions.desk = seated { }; } ]);
  headlessUnsupportedCfgSm = evalWithSystemManager (baseModules ++ [ absoluteCompositorOverride { nixdesktop.sessions.remote = headless { }; } ]);

  deskUnitSm = seatedCfgSm.systemd.services."nixdesktop-desk";

  # The core structural proof: a SEATED-ONLY config (zero headless sessions anywhere in the
  # session table) forced all the way down (`deepSeq`) against a host stub that never declared
  # `systemd.user.services` at all. If modules/launcher.nix ever again wrote to that path
  # unconditionally -- the exact bug class this pass fixes -- this would throw "The option
  # `systemd.user.services' does not exist" regardless of there being no headless session to
  # trigger it, because the module system checks declared-vs-defined paths, not "was this path
  # ever going to be non-empty". A clean `deepSeq` here is therefore not a weak "nothing crashed"
  # check -- it is the one fixture that can catch a regression the headless-specific checks below
  # structurally cannot (they all compose a headless session, which fails for an UNRELATED, correct
  # reason -- the assertion -- long before the `systemd.user.services` key would ever matter).
  seatedOnlySmForcesCleanly = (builtins.tryEval (builtins.deepSeq seatedCfgSm true)).success;

  lightweightSystemManagerResults = {
    "SM: a seated session on the system-manager plane is a system unit with PAMName=login and User= set" =
      deskUnitSm.serviceConfig.PAMName == "login"
      && deskUnitSm.serviceConfig.User == "richc";

    "SM: DeviceAllow/DevicePolicy/ExecStart render identically to the NixOS plane for the same fixture" =
      deskUnitSm.serviceConfig.DevicePolicy == "closed"
      && lib.elem "/dev/dri/by-path/pci-0000:03:00.0-card rw" deskUnitSm.serviceConfig.DeviceAllow
      && !(lib.any (e: lib.hasInfix "0000:0a:00.0" e) deskUnitSm.serviceConfig.DeviceAllow)
      && lib.hasPrefix "/" deskUnitSm.serviceConfig.ExecStart;

    "SM: a seated-only config (no headless sessions at all) forces cleanly against a stub with NO systemd.user.services declared" =
      seatedOnlySmForcesCleanly;

    "SM: a seated-only config declares no linger marker at all" =
      seatedCfgSm.systemd.tmpfiles.rules == [ ];

    # ── THE ONE GENUINE PLANE DIVERGENCE: HEADLESS FAILS LOUDLY, NEVER SILENTLY ─────────────────
    "SM: a headless session on the system-manager plane is a build failure, named explicitly" =
      countMatching "system-manager plane of" (firedMessages headlessUnsupportedCfgSm) == 1;

    "SM: the headless-unsupported message names the offending session" =
      let m = lib.head (matching "system-manager plane of" (firedMessages headlessUnsupportedCfgSm)); in
      lib.hasInfix "nixdesktop.sessions.remote" m;

    "SM: the same headless session composed on the NixOS plane trips no such rejection" =
      countMatching "system-manager plane of" (firedMessages headlessCfg) == 0;

    "SM: a seated session (the estate's real fixture) trips no headless-unsupported rejection" =
      countMatching "system-manager plane of" (firedMessages seatedCfgSm) == 0;
  };

  # ── LAYER FOUR: system-manager, A REAL `system-manager.lib.makeSystemConfig` ──────────────────
  #
  # Mirror image of the NixOS `realSystem` proof below, using the ACTUAL upstream system-manager
  # module tree (`numtide/system-manager`, pinned in flake.nix) rather than a stand-in -- the same
  # discipline nixram's own `checks/system-manager-eval-tests.nix` already applies for its sibling
  # dual-plane module. `makeSystemConfig` gates its ENTIRE return value on its own internal
  # assertion check (`returnIfNoAssertions`, in `nix/lib.nix`): unlike NixOS's `eval-config.nix`,
  # `.config` itself is unreachable when any assertion fails -- the whole call throws first. So the
  # headless-on-this-plane proof below is checked via `builtins.tryEval` confirming the throw
  # happens, exactly like nixram's own `evalFails` helper, not by inspecting an `assertions` list
  # post-hoc the way the lightweight layer above does.
  realSystemManagerFor = extraConfig: systemManagerLib.makeSystemConfig {
    modules = [
      nixhostStub
      sessionModule
      launcherModuleSystemManager
      {
        nixhost = { resources.gpu = estateInventory; environments.devhome.resources.gpu = devhomeClaim; };
        nixdesktop.launcher.compositors.scroll.command = "/nix/store/fake-scroll-path/bin/scroll";
        nixpkgs.hostPlatform = system;
      }
      extraConfig
    ];
  };

  realSystemManagerSeated = realSystemManagerFor { nixdesktop.sessions.desk = seated { }; };

  # `deepSeq` here is CORRECT for the negative (fails-outright) proof, and would be WRONG for a
  # positive one -- the two are not symmetric. `makeSystemConfig` returns `returnIfNoAssertions
  # toplevel` (`nix/lib.nix`): `if failedAssertions != [] then throw ... else lib.showWarnings
  # config.warnings drv`. Forcing that expression to WHNF is already enough to pick a branch --
  # and picking the `throw` branch (an assertion genuinely failed) IS the exception, full stop, no
  # further forcing required. So `builtins.seq` (shallow -- WHNF only) on the raw
  # `makeSystemConfig {...}` return value itself, NEVER `.config`, and NEVER `builtins.deepSeq`, is
  # both sufficient and safer than what this helper first tried: an earlier revision called
  # `builtins.deepSeq (...).config true`, which -- on the SUCCESS branch specifically, i.e. when
  # proving a fixture that should NOT fail actually doesn't -- walks the ENTIRE real `config`
  # attrset, including `meta.maintainers`. That NixOS-vendored module (`nixos/modules/misc/meta.
  # nix`, pulled in unconditionally by system-manager's own `upstream/nixpkgs/default.nix`) keys an
  # attrset by each definition's `_file` location (`modules/generic/meta-maintainers.nix`), and
  # under a flake-sourced nixpkgs every `_file` is a `/nix/store/...` path -- Nix's `listToAttrs`
  # refuses a bare string that "looks like" an uncontexted store-path reference used as an
  # attribute name. That is an unrelated, pre-existing incompatibility between system-manager's
  # real module tree and flake-sourced nixpkgs (confirmed live: the identical `deepSeq`-a-
  # clean-config pattern also fires it against nixram's own sibling `checks/
  # system-manager-eval-tests.nix`, so this is not something this pass introduced), nothing to do
  # with `nixdesktop.sessions`/`nixdesktop.launcher` at all -- but `deepSeq` walked into it anyway,
  # and WORSE, that specific Nix error class is NOT reliably caught by `builtins.tryEval` (measured
  # live: reintroducing the headless-unsupported-assertion bug this check exists to catch made the
  # WHOLE `nix flake check` invocation crash uncatchably instead of reporting a clean, named
  # failure, once the deleted assertion stopped gating `.config` shut). Forcing only WHNF of the
  # gated return value sidesteps the entire class: it never reaches `meta.maintainers` (or any
  # other option this repo does not touch) on EITHER branch, so a regression here reports as a
  # normal, named, readable check failure exactly like every other assertion in this file, rather
  # than an opaque internal Nix error.
  realSystemManagerFails = extraConfig:
    !(builtins.tryEval (builtins.seq (realSystemManagerFor extraConfig) true)).success;

  deskUnitTextSm = realSystemManagerSeated.config.systemd.units."nixdesktop-desk.service".text;

  realSystemManagerResults = {
    "REAL SYSTEM-MANAGER: the seated unit is a systemd.services unit with PAMName=login and User=richc" =
      lib.hasInfix "PAMName=login\n" deskUnitTextSm
      && lib.hasInfix "User=richc\n" deskUnitTextSm;

    "REAL SYSTEM-MANAGER: the rendered seated unit's ExecStart is absolute" =
      lib.hasInfix "ExecStart=/nix/store/fake-scroll-path/bin/scroll\n" deskUnitTextSm;

    "REAL SYSTEM-MANAGER: the rendered seated unit sets DevicePolicy=closed, never strict" =
      lib.hasInfix "DevicePolicy=closed\n" deskUnitTextSm
      && !(lib.hasInfix "DevicePolicy=strict" deskUnitTextSm);

    "REAL SYSTEM-MANAGER: DeviceAllow includes the permitted device's card node" =
      lib.hasInfix "DeviceAllow=/dev/dri/by-path/pci-0000:03:00.0-card rw\n" deskUnitTextSm;

    "REAL SYSTEM-MANAGER: DeviceAllow never names the denied device's node anywhere" =
      !(lib.hasInfix "0000:0a:00.0" deskUnitTextSm);

    "REAL SYSTEM-MANAGER: no ExecStartPre line at all" =
      !(lib.hasInfix "ExecStartPre=" deskUnitTextSm);

    "REAL SYSTEM-MANAGER: no literal card or render-node number anywhere in the rendered unit" =
      !(containsLiteralCardNumber deskUnitTextSm);

    "REAL SYSTEM-MANAGER: a headless session on this plane fails the WHOLE BUILD outright (makeSystemConfig throws)" =
      realSystemManagerFails { nixdesktop.sessions.remote = headless { }; };

    "REAL SYSTEM-MANAGER: the identical seated fixture that passes above does NOT fail the build" =
      !(realSystemManagerFails { nixdesktop.sessions.desk = seated { }; });
  };

  # ── LAYER TWO: A REAL `lib.nixosSystem`, THE ACTUAL systemd/users MODULES ─────────────────────
  #
  # `support.hostStub` is NOT composed here: real NixOS already declares `options.assertions`/
  # `options.warnings` (`nixos/modules/misc/assertions.nix`), and redeclaring either would be a
  # genuine "option declared twice" eval error, not a harmless no-op. `nixhostStub` above IS reused
  # unmodified -- `nixhost` names no real nixpkgs option, so it composes alongside the entire
  # upstream module list exactly as it does alongside the lightweight stubs.
  #
  # `boot.isContainer = true` and `system.stateVersion` are set for hygiene (a config that would
  # also survive a real `nixos-rebuild` unmodified), not because anything read below needs them:
  # `config.systemd.units.*.text` is plain string concatenation inside nixpkgs' own
  # `systemd-lib.nix` and forces nothing about a bootloader, a filesystem, or
  # `config.system.build.toplevel` (which is where NixOS's own assertion-checking machinery
  # actually lives — never forced here, so an unrelated upstream module's assertion elsewhere in
  # the full module-list.nix tree can never fail this check by surprise).
  realSystem = nixpkgs.lib.nixosSystem {
    inherit system;
    modules = [
      nixhostStub
      sessionModule
      launcherModuleNixos
      {
        nixhost = { resources.gpu = estateInventory; environments.devhome.resources.gpu = devhomeClaim; };
        nixdesktop.sessions.desk = seated { };
        nixdesktop.sessions.remote = headless { };
        nixdesktop.launcher.compositors.scroll.command = "/nix/store/fake-scroll-path/bin/scroll";
        system.stateVersion = "24.11";
        boot.isContainer = true;
      }
    ];
  };

  deskUnitText = realSystem.config.systemd.units."nixdesktop-desk.service".text;
  # A headless session renders through `systemd.user.services`, which is a SEPARATE module
  # (`nixos/modules/system/boot/systemd/user.nix`) with its own unit table --
  # `config.systemd.user.units`, not `config.systemd.units` (that one covers only the system
  # instance's `systemd.services`/`.sockets`/etc, never `systemd.user.services`).
  remoteUnitText = realSystem.config.systemd.user.units."nixdesktop-remote.service".text;

  realNixosSystemResults = {
    "REAL SYSTEM: the seated unit is a systemd.services unit, never systemd.user.services" =
      (realSystem.config.systemd.services ? "nixdesktop-desk")
      && !(realSystem.config.systemd.user.services ? "nixdesktop-desk");

    "REAL SYSTEM: the rendered seated unit carries PAMName=login and User=richc" =
      lib.hasInfix "PAMName=login\n" deskUnitText
      && lib.hasInfix "User=richc\n" deskUnitText;

    "REAL SYSTEM: the rendered seated unit's ExecStart is an absolute path" =
      lib.hasInfix "ExecStart=/nix/store/fake-scroll-path/bin/scroll\n" deskUnitText;

    "REAL SYSTEM: the rendered seated unit sets DevicePolicy=closed" =
      lib.hasInfix "DevicePolicy=closed\n" deskUnitText;

    "REAL SYSTEM: the rendered seated unit never sets DevicePolicy=strict" =
      !(lib.hasInfix "DevicePolicy=strict" deskUnitText);

    "REAL SYSTEM: the rendered seated unit's DeviceAllow includes the static tty/pts/input floor" =
      lib.all (e: lib.hasInfix "DeviceAllow=${e}\n" deskUnitText)
        [ "/dev/ptmx rw" "/dev/tty rw" "char-tty rw" "char-pts rw" "char-input rw" ];

    "REAL SYSTEM: the rendered seated unit's DeviceAllow includes the permitted device's card node" =
      lib.hasInfix "DeviceAllow=/dev/dri/by-path/pci-0000:03:00.0-card rw\n" deskUnitText;

    "REAL SYSTEM: the rendered seated unit never names the denied device's node anywhere" =
      !(lib.hasInfix "0000:0a:00.0" deskUnitText);

    "REAL SYSTEM: the rendered seated unit has no ExecStartPre line at all" =
      !(lib.hasInfix "ExecStartPre=" deskUnitText);

    "REAL SYSTEM: the rendered seated unit contains no literal card or render-node number anywhere" =
      !(containsLiteralCardNumber deskUnitText);

    "REAL SYSTEM: the rendered headless unit is a systemd.user.services unit, never systemd.services" =
      (realSystem.config.systemd.user.services ? "nixdesktop-remote")
      && !(realSystem.config.systemd.services ? "nixdesktop-remote");

    "REAL SYSTEM: the rendered headless unit's ExecStart is also absolute, and carries no PAMName" =
      lib.hasInfix "ExecStart=/nix/store/fake-scroll-path/bin/scroll\n" remoteUnitText
      && !(lib.hasInfix "PAMName=" remoteUnitText);

    "REAL SYSTEM: lingering is rendered as a real systemd.tmpfiles.rules entry, never users.users" =
      lib.any (r: lib.hasInfix "/var/lib/systemd/linger/richc" r) realSystem.config.systemd.tmpfiles.rules
      && !(realSystem.config.users.users ? richc);
  };
in
report "launcher" (lightweightResults // realNixosSystemResults // lightweightSystemManagerResults // realSystemManagerResults)
