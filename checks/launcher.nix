# Evaluates modules/launcher.nix for real, wired to the real modules/session.nix exactly as a
# consumer composes both (mirrors checks/session-devices.nix's own nixhost fixture), and proves
# the shapes that matter most: a seated session is unrepresentable as a `--user` unit and a
# headless one can never carry `PAMName=`, because getting that backwards is the exact defect this
# whole module exists to remove (see modules/launcher.nix's header — the laptop's live, silent
# polkit failure is what a `--user` "seated" session actually looks like); a seated unit is a true
# AUTOLOGIN with no greeter anywhere upstream of it (Design A — see that file's own header); its
# `Environment=` is VT-AWARE in both directions (`XDG_VTNR` present iff `vt != null`); and the
# resolved `WLR_DRM_DEVICES` it exports is built from nixgpu's colon-FREE `cardNamePath`, never the
# colon-BEARING `cardPath` — the entire reason `cardNamePath` exists at all (wlroots'
# `strtok_r`-based parser, see modules/launcher.nix's own header for the full account); and
# `permittedDevicePaths` — the hand-stated escape hatch for a device class no GPU inventory owns
# (today: sound) — is appended to `DeviceAllow=` verbatim, LAST (after the static tty/input floor
# and the derived DRM paths, so a rendered unit reads as "everything after the DRM lines was asked
# for by hand" — see modules/session.nix's own doc and modules/launcher.nix's `deviceFenceFor`),
# changes nothing when left at its default `[ ]`, is mirrored identically onto the read-only
# `nixdesktop.launcher.deviceFence`, and never loosens `DevicePolicy` off `"closed"`.
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
# could not actually start a session (measured live on the server: `status=208/STDIN`). A stub
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
  # nixhost flake) -- PLUS `cardPath`/`renderPath`/`cardNamePath`/`renderNamePath` on each device
  # now, since modules/launcher.nix is the first consumer that reads past the device NAME.
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
  # `users.users` is read (never written) for the group-membership assertion.
  systemHostStub = { ... }: {
    options = {
      systemd.services = lib.mkOption { type = lib.types.attrsOf lib.types.anything; default = { }; };
      systemd.user.services = lib.mkOption { type = lib.types.attrsOf lib.types.anything; default = { }; };
      systemd.tmpfiles.rules = lib.mkOption { type = lib.types.listOf lib.types.str; default = [ ]; };
      # NixOS's masking surface -- `systemd.units.<name>.enable = false`. Declared here because
      # this module writes it for a VT-backed seated session (see `vtGettyMaskUnits`).
      systemd.units = lib.mkOption { type = lib.types.attrsOf lib.types.anything; default = { }; };
      # Read (never written) by `mkSeatedUnit`'s `ExecStartPost=` session-id import on every seated
      # compositor, and by the additional readiness bridge for a supportsNotify compositor.
      systemd.package = lib.mkOption { type = lib.types.str; default = "/nix/store/fake-systemd"; };
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
  # session actually needed it. See `seatedOnlySmForcesCleanly`'s own result below for that exact
  # proof.
  systemHostStubSystemManager = { ... }: {
    options = {
      systemd.services = lib.mkOption { type = lib.types.attrsOf lib.types.anything; default = { }; };
      systemd.tmpfiles.rules = lib.mkOption { type = lib.types.listOf lib.types.str; default = [ ]; };
      # system-manager's OWN masking surface (`nix/modules/systemd.nix`), a plain list -- not
      # NixOS's `systemd.units.<name>.enable`. The two planes genuinely differ here, which is why
      # modules/launcher.nix emits one or the other rather than a single shared write.
      systemd.maskedUnits = lib.mkOption { type = lib.types.listOf lib.types.str; default = [ ]; };
      systemd.package = lib.mkOption { type = lib.types.str; default = "/nix/store/fake-systemd"; };
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
  # `DRIVER_GEM | DRIVER_MODESET` and no more); "amd" has both. primary permits "ast" exclusively
  # and denies "amd" outright -- the SAME claim shape checks/session-devices.nix's own fixture uses,
  # so `permittedDevices` here resolves to exactly `[ "ast" ]`, as it does there. `cardNamePath`/
  # `renderNamePath` follow nixgpu's own `/dev/dri/by-name/<name>-{card,render}` convention exactly
  # -- see modules/launcher.nix's header, "WLR_DRM_DEVICES: cardNamePath, NEVER cardPath", for why
  # this is the field the compositor's own env var actually reads.
  estateInventory = {
    ast = {
      cardPath = "/dev/dri/by-path/pci-0000:03:00.0-card"; renderPath = null;
      cardNamePath = "/dev/dri/by-name/ast-card"; renderNamePath = null;
    };
    amd = {
      cardPath = "/dev/dri/by-path/pci-0000:0a:00.0-card"; renderPath = "/dev/dri/by-path/pci-0000:0a:00.0-render";
      cardNamePath = "/dev/dri/by-name/amd-card"; renderNamePath = "/dev/dri/by-name/amd-render";
    };
  };
  primaryClaim = { ast.access = "exclusive"; amd.access = "none"; };

  baseModules = [
    { nixhost = { resources.gpu = estateInventory; environments.primary.resources.gpu = primaryClaim; }; }
  ];

  # Gives "scroll" an already-absolute `command`, so the happy-path fixtures below resolve their
  # ExecStart without needing a fabricated `package` derivation -- exactly the "spell command as an
  # already-absolute path yourself" escape hatch `nixdesktop.launcher.compositors.<n>.command`'s own
  # doc describes.
  absoluteCompositorOverride = { nixdesktop.launcher.compositors.scroll.command = "/nix/store/fake-scroll-path/bin/scroll"; };

  # Same escape hatch, for niri: gives it an already-absolute `command` so a virtualOutputs
  # fixture below trips ONLY the capability assertion under test, never ALSO the unrelated
  # unresolved-command one (niri's own built-in `command = "niri --session"` is not absolute).
  niriAbsoluteOverride = { nixdesktop.launcher.compositors.niri.command = "/nix/store/fake-niri-path/bin/niri"; };

  # `vt` LEFT AT ITS DEFAULT (`null`) -- deliberately. This is the workstation's own shape: a seated
  # session whose seat has no VT, which is the estate's real, live case and therefore the one worth
  # exercising by default (`seatdVtBound == false`, `requiredGroups != [ ]`, no `XDG_VTNR` on the
  # unit). A VT-backed sibling is its own fixture, `vtBackedCfg`, below.
  seated = extra: {
    compositor = "scroll";
    user = "alice";
    delivery = "seated";
    renderer = "pixman";
    environment = "primary";
    seat = "seat0";
  } // extra;

  headless = extra: {
    compositor = "scroll";
    user = "alice";
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

  # ── VT-BACKED, THE OTHER SEATED SHAPE ─────────────────────────────────────────────────────────
  # primary on the server owns VT 1 (see modules/session.nix's own example) -- `seatdVtBound ==
  # true`, `requiredGroups == [ ]`, the unit's own `Environment=` must carry `XDG_VTNR=1`, and must
  # carry NO `SEATD_VTBOUND` key at all (there is nothing to work around: a VT-bound seatd follows
  # the VT normally here). This is the estate's OTHER real, live case (primary), not a synthetic one.
  vtBackedCfg = evalWith (baseModules ++ [ absoluteCompositorOverride { nixdesktop.sessions.desk = seated { vt = 1; }; } ]);

  # ── THE VT's OTHER CLAIMANTS: the opt-out, and the seatless case ────────────────────────────
  # Both directions of `maskVtGetty` against the SAME VT-backed fixture above, plus the `vt = null`
  # case where there is no VT to have a getty on at all. Without these, "masks both instances"
  # would pass just as happily for a module that masked unconditionally.
  vtBackedNoMaskCfg = evalWith (baseModules ++ [
    absoluteCompositorOverride
    { nixdesktop.sessions.desk = seated { vt = 1; maskVtGetty = false; }; }
  ]);

  # ── permittedDevicePaths: A HOST-STATED PATH FOR A DEVICE CLASS NO INVENTORY OWNS ────────────
  # A by-path ALSA node -- the estate's own worked example (modules/session.nix's own doc, and the
  # commit that introduced this option) -- appended on top of the estate's real `primary` fixture,
  # so this proves the append composes with a real GPU claim rather than standing in for one.
  sndPath = "/dev/snd/by-path/pci-0000:0c:00.4";
  devicePathsCfg = evalWith (baseModules ++ [
    absoluteCompositorOverride
    { nixdesktop.sessions.desk = seated { permittedDevicePaths = [ sndPath ]; }; }
  ]);

  # ── GROUP MEMBERSHIP, THE THREE STATES ────────────────────────────────────────────────────────
  # `seatedCfg` itself is the THIRD state (no `users.users.alice` entry at all -- an externally-
  # managed identity) and needs no separate fixture; the assertion must be silent for it precisely
  # because this module cannot see a fact lldap owns.
  groupsPresentCfg = evalWith (baseModules ++ [
    absoluteCompositorOverride
    { users.users.alice.extraGroups = [ "video" "render" "input" "seat" "wheel" ]; }
    { nixdesktop.sessions.desk = seated { }; }
  ]);

  groupsMissingCfg = evalWith (baseModules ++ [
    absoluteCompositorOverride
    { users.users.alice.extraGroups = [ "video" "wheel" ]; }
    { nixdesktop.sessions.desk = seated { }; }
  ]);

  # ── VIRTUAL OUTPUTS: THE CAPABILITY BOUNDARY, PROVEN BOTH WAYS ────────────────────────────────
  # niri's own built-in row declares `supportsVirtualOutputs = false` (measured fact, see
  # `builtinCompositors`'s own comment) -- a session naming niri with `virtualOutputs != [ ]` must
  # fail the build, naming niri, never silently producing a session with no display.
  vo = [ { width = 1920; height = 1080; } ];

  niriVirtualOutputsCfg = evalWith (baseModules ++ [
    niriAbsoluteOverride
    { nixdesktop.sessions.desk = seated { compositor = "niri"; virtualOutputs = vo; }; }
  ]);

  # Same compositor, same override, but NO virtualOutputs declared -- proves the assertion is
  # keyed on `virtualOutputs != [ ]`, not on "this session merely names niri".
  niriNoVirtualOutputsCfg = evalWith (baseModules ++ [
    niriAbsoluteOverride
    { nixdesktop.sessions.desk = seated { compositor = "niri"; }; }
  ]);

  # scroll's own built-in row declares `supportsVirtualOutputs = true` -- the estate's real
  # fixture (compositor defaults to "scroll" via the `seated`/`headless` helpers above) must trip
  # no such rejection at all.
  scrollVirtualOutputsCfg = evalWith (baseModules ++ [
    absoluteCompositorOverride
    { nixdesktop.sessions.desk = seated { virtualOutputs = vo; }; }
  ]);

  # A consumer can WITHDRAW scroll's own built-in support by restating the field explicitly --
  # proving the assertion actually reads `nixdesktop.launcher.compositors.<name>.
  # supportsVirtualOutputs`, rather than special-casing the compositor NAME "scroll"/"niri"
  # somewhere it never told us about.
  scrollVirtualOutputsWithdrawnCfg = evalWith (baseModules ++ [
    absoluteCompositorOverride
    { nixdesktop.launcher.compositors.scroll.supportsVirtualOutputs = false; }
    { nixdesktop.sessions.desk = seated { virtualOutputs = vo; }; }
  ]);

  # ── XDG_CURRENT_DESKTOP: THE ONE ESCAPE-HATCH PROOF ─────────────────────────────────────────────
  # `currentDesktop`'s own doc already covers the estate's real fixture (`scroll`, exercised by
  # `seatedCfg`/`headlessCfg` themselves — no separate fixture needed for that) and niri's
  # fallback-to-`name` shape (`niriNoVirtualOutputsCfg`, already composed above, reused below rather
  # than duplicated). This is the one shape neither already exercises: a consumer overriding the
  # field explicitly, on a compositor whose BUILT-IN row already sets it, and winning.
  currentDesktopOverrideCfg = evalWith (baseModules ++ [
    absoluteCompositorOverride
    { nixdesktop.launcher.compositors.scroll.currentDesktop = "custom-desktop"; }
    { nixdesktop.sessions.desk = seated { }; }
  ]);

  # Trips nixdisplay monitors-style raw-name detection (§8 assertion 10): a device NAME shaped
  # like the exact thing this design exists to remove, arriving from nixhost's claim exactly as it
  # would from a real (mis-)declared inventory -- launcher.nix has no way to tell this apart from a
  # legitimate slug except by shape. Deliberately has no `cardPath`/`cardNamePath` etc at all:
  # proving this assertion fires never has to force `deviceAllowFor`/`cardNamePathsFor` (those are
  # read only from `systemd.services`, which this test never inspects for this fixture -- see this
  # file's own note by `firedMessages` below), so the missing fields are never a problem here.
  rawNameCfg = evalWith (baseModules ++ [
    {
      nixhost = {
        resources.gpu = { "card0" = { }; };
        environments.primary.resources.gpu."card0".access = "exclusive";
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

  # `DeviceAllow=`, IN RENDERED-UNIT ORDER -- proves `permittedDevicePaths` lands LAST against the
  # literal unit text, not just the pre-render Nix list. `attrsToSection`
  # (nixos/lib/systemd-lib.nix) renders a list-valued `serviceConfig` field as one `KEY=value` line
  # PER ENTRY, via a plain `map` over that entry's own list -- so splitting the rendered text on
  # newlines and filtering for the `DeviceAllow=` prefix recovers the exact declaration order, on
  # both the real NixOS unit text and the real system-manager one (system-manager's own
  # `nix/modules/systemd.nix` renders the identical shape -- the REAL SYSTEM-MANAGER checks already
  # below match single `DeviceAllow=... rw\n` lines on that assumption).
  deviceAllowLines = text: lib.filter (l: lib.hasPrefix "DeviceAllow=" l) (lib.splitString "\n" text);

  deskUnit = seatedCfg.systemd.services."nixdesktop-desk";
  vtBackedUnit = vtBackedCfg.systemd.services."nixdesktop-desk";
  remoteUnit = headlessCfg.systemd.user.services."nixdesktop-remote";
  devicePathsUnit = devicePathsCfg.systemd.services."nixdesktop-desk";

  lightweightResults = {
    # ── SEATED IS A SYSTEM UNIT, NEVER A --user ONE ─────────────────────────────────────────────
    "a seated session is a system unit with PAMName=login and User= set" =
      deskUnit.serviceConfig.PAMName == "login"
      && deskUnit.serviceConfig.User == "alice";

    "a seated session never appears under systemd.user.services" =
      !(seatedCfg.systemd.user.services ? "nixdesktop-desk");

    # ── HEADLESS IS A --user UNIT, NEVER PAMName ────────────────────────────────────────────────
    "a headless session renders a systemd.user.services unit" =
      headlessCfg.systemd.user.services ? "nixdesktop-remote";

    "a headless session never sets PAMName or User" =
      !(remoteUnit.serviceConfig ? PAMName) && !(remoteUnit.serviceConfig ? User);

    "a headless session never appears under systemd.services" =
      !(headlessCfg.systemd.services ? "nixdesktop-remote");

    # ── THE VT's OTHER CLAIMANTS ────────────────────────────────────────────────────────────
    # The regression these exist for is not hypothetical: the laptop's own config asserted in a
    # comment that both units were masked, nothing implemented it, and the seated unit lost the
    # race to a getty every boot for weeks while `start-limit-hit` was the only visible symptom.
    "a VT-backed seated session masks getty on its VT" =
      vtBackedCfg.systemd.units."getty@tty1.service".enable == false;

    # BOTH instances -- masking `getty@` alone leaves `autovt@` to re-enter one VT-switch later.
    "a VT-backed seated session masks autovt on its VT too" =
      vtBackedCfg.systemd.units."autovt@tty1.service".enable == false;

    "a seatless session masks no getty at all" =
      seatedCfg.systemd.units == { };

    "maskVtGetty = false leaves the VT's getty alone" =
      vtBackedNoMaskCfg.systemd.units == { };

    # The system-manager plane uses a DIFFERENT mechanism for the same fact -- a plain list, not
    # `units.<name>.enable`. `enable = false` is a silent no-op there for a unit system-manager
    # does not itself generate, which is exactly how a mask can look applied and do nothing.
    "the system-manager plane masks through maskedUnits, not units.enable" =
      vtBackedCfgSm.systemd.maskedUnits == [ "getty@tty1.service" "autovt@tty1.service" ];

    "a seatless session masks nothing on the system-manager plane either" =
      seatedCfgSm.systemd.maskedUnits == [ ];

    "a headless unit is scoped to its own user via ConditionUser" =
      remoteUnit.unitConfig.ConditionUser == "alice";

    "a headless unit gets WLR_BACKENDS=headless and the session's renderer, never auto" =
      lib.any (e: e == "WLR_BACKENDS=headless") remoteUnit.serviceConfig.Environment
      && lib.any (e: e == "WLR_RENDERER=pixman") remoteUnit.serviceConfig.Environment;

    # ── LINGERING IS A TMPFILES MARKER, NEVER A users.users WRITE ───────────────────────────────
    # See modules/launcher.nix's own comment for why: `users.users.<name> = { linger = true; }`
    # forces NixOS to treat that name as a locally-managed account, which breaks the
    # externally-managed (lldap) identity path this module's own comments say it accommodates.
    "lingering is a declarative tmpfiles marker file, never a users.users definition" =
      lib.any (r: lib.hasInfix "/var/lib/systemd/linger/alice" r) headlessCfg.systemd.tmpfiles.rules
      && !(headlessCfg.users.users ? alice);

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

    # ── permittedDevicePaths: HAND-WRITTEN PATHS, APPENDED LAST -- see modules/session.nix's own
    # doc and modules/launcher.nix's `deviceFenceFor` comment for why the ordering is deliberate: a
    # rendered unit should read as "everything after the DRM lines was asked for by hand".
    "a declared permittedDevicePaths entry lands in DeviceAllow with a trailing ' rw'" =
      lib.elem "${sndPath} rw" devicePathsUnit.serviceConfig.DeviceAllow;

    "permittedDevicePaths entries land LAST, after the static tty/input floor and the derived DRM paths" =
      devicePathsUnit.serviceConfig.DeviceAllow == [
        "/dev/ptmx rw" "/dev/tty rw" "char-tty rw" "char-pts rw" "char-input rw"
        "/dev/dri/by-path/pci-0000:03:00.0-card rw"
        "${sndPath} rw"
      ];

    "a session declaring no permittedDevicePaths (the default) renders EXACTLY the pre-feature DeviceAllow, with nothing appended" =
      deskUnit.serviceConfig.DeviceAllow == [
        "/dev/ptmx rw" "/dev/tty rw" "char-tty rw" "char-pts rw" "char-input rw"
        "/dev/dri/by-path/pci-0000:03:00.0-card rw"
      ];

    "nixdesktop.launcher.deviceFence mirrors permittedDevicePaths identically to the unit, single-sourced" =
      devicePathsCfg.nixdesktop.launcher.deviceFence.desk.deviceAllow == devicePathsUnit.serviceConfig.DeviceAllow;

    "DevicePolicy stays closed even when permittedDevicePaths widens the allowlist" =
      devicePathsUnit.serviceConfig.DevicePolicy == "closed";

    # ── THE DEVICE FENCE IS MIRRORED READ-ONLY, IDENTICALLY TO THE UNIT ─────────────────────────
    "nixdesktop.launcher.deviceFence mirrors the unit's own DevicePolicy=/DeviceAllow= exactly" =
      seatedCfg.nixdesktop.launcher.deviceFence.desk.devicePolicy == deskUnit.serviceConfig.DevicePolicy
      && seatedCfg.nixdesktop.launcher.deviceFence.desk.deviceAllow == deskUnit.serviceConfig.DeviceAllow;

    "a headless session gets no deviceFence entry at all" =
      !(headlessCfg.nixdesktop.launcher.deviceFence ? "remote");

    # ── EXECSTART IS ABSOLUTE ────────────────────────────────────────────────────────────────────
    "the seated unit's ExecStart is an absolute path" =
      lib.hasPrefix "/" deskUnit.serviceConfig.ExecStart;

    # ── WLR_DRM_DEVICES: BY-NAME, COLON-FREE -- THE ENTIRE POINT OF cardNamePath ────────────────
    "the compositor's own device env var carries the colon-free by-name card path" =
      lib.any (e: e == "WLR_DRM_DEVICES=/dev/dri/by-name/ast-card") deskUnit.serviceConfig.Environment;

    "WLR_DRM_DEVICES contains no colon at all" =
      let e = lib.head (lib.filter (x: lib.hasPrefix "WLR_DRM_DEVICES=" x) deskUnit.serviceConfig.Environment); in
      !(lib.hasInfix ":" e);

    # ── XDG_VTNR: PRESENT IFF vt != null -- SEE THIS FILE'S HEADER AND modules/launcher.nix's OWN
    # "THE VT FACT" ──────────────────────────────────────────────────────────────────────────────
    "a non-VT-backed seated session's unit carries no XDG_VTNR at all (the workstation's own shape)" =
      !(lib.any (e: lib.hasPrefix "XDG_VTNR=" e) deskUnit.serviceConfig.Environment);

    "a VT-backed seated session's unit carries XDG_VTNR set to the declared VT (primary's own shape)" =
      lib.any (e: e == "XDG_VTNR=1") vtBackedUnit.serviceConfig.Environment;

    # ── SEATD_VTBOUND: PRESENT EXACTLY WHEN THE SEAT HAS NO VT ──────────────────────────────────
    "a non-VT-backed seated session's unit exports SEATD_VTBOUND=0" =
      lib.any (e: e == "SEATD_VTBOUND=0") deskUnit.serviceConfig.Environment;

    "a VT-backed seated session's unit carries no SEATD_VTBOUND at all" =
      !(lib.any (e: lib.hasPrefix "SEATD_VTBOUND=" e) vtBackedUnit.serviceConfig.Environment);

    "a VT-backed seated session needs no groups, and trips no group assertion regardless of users.users" =
      vtBackedCfg.nixdesktop.sessions.desk.requiredGroups == [ ]
      && countMatching "needs group(s)" (firedMessages vtBackedCfg) == 0;

    # ── NEVER A LITERAL CARD NUMBER, ANYWHERE ON THE RENDERED UNIT ──────────────────────────────
    "no literal card or render-node number appears anywhere on the seated unit" =
      let
        allText = lib.concatStringsSep "\n"
          (deskUnit.serviceConfig.DeviceAllow
            ++ [ deskUnit.serviceConfig.ExecStart ]
            ++ deskUnit.serviceConfig.Environment);
      in
      !(containsLiteralCardNumber allText);

    # ── GROUP MEMBERSHIP FOR A NON-VT-BACKED SEAT IS ACTUALLY VERIFIED ──────────────────────────
    "the estate's baseline fixture (no users.users.alice entry -- externally managed) trips no missing-groups assertion" =
      countMatching "needs group(s)" (firedMessages seatedCfg) == 0;

    "a NixOS-managed user missing required groups trips the assertion, naming them" =
      countMatching "needs group(s)" (firedMessages groupsMissingCfg) == 1;

    "the missing-groups message names the absent groups and the present-but-irrelevant one is not mistaken for satisfying them" =
      let m = lib.head (matching "needs group(s)" (firedMessages groupsMissingCfg)); in
      lib.hasInfix "render" m && lib.hasInfix "input" m && lib.hasInfix "seat" m;

    "a NixOS-managed user with every required group trips no such assertion" =
      countMatching "needs group(s)" (firedMessages groupsPresentCfg) == 0;

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

    # ── VIRTUAL OUTPUTS DECLARED ON A COMPOSITOR THAT CANNOT CREATE ONE FAILS LOUDLY ────────────
    "a session naming niri with virtualOutputs declared is a build failure" =
      countMatching "cannot create one" (firedMessages niriVirtualOutputsCfg) == 1;

    "the niri-virtualOutputs failure names the session and the compositor" =
      let m = lib.head (matching "cannot create one" (firedMessages niriVirtualOutputsCfg)); in
      lib.hasInfix "nixdesktop.sessions.desk" m && lib.hasInfix ''compositor "niri"'' m;

    "the same niri session with NO virtualOutputs declared trips no such rejection" =
      countMatching "cannot create one" (firedMessages niriNoVirtualOutputsCfg) == 0;

    "a session naming scroll (built-in supportsVirtualOutputs = true) with virtualOutputs declared produces no such failure" =
      countMatching "cannot create one" (firedMessages scrollVirtualOutputsCfg) == 0;

    "a consumer can explicitly withdraw scroll's own built-in support, and the assertion still fires" =
      countMatching "cannot create one" (firedMessages scrollVirtualOutputsWithdrawnCfg) == 1;

    # ── A DEVICE NAME SHAPED LIKE THE THING THIS DESIGN FORBIDS ─────────────────────────────────
    # NB: the search string stops at "raw", not "raw device node" — the assertion message wraps
    # onto a new source line right after "raw", and a Nix indented string keeps that line break
    # verbatim, so a search phrase spanning it would never match even when the assertion fired.
    "a device name shaped like a raw cardN is rejected" =
      countMatching "shaped like a raw" (firedMessages rawNameCfg) == 1;

    "the estate's real device names (ast, amd) trip no such rejection" =
      countMatching "shaped like a raw" (firedMessages seatedCfg) == 0;

    # ── XDG_CURRENT_DESKTOP: NEVER EMPTY, AND MEASURED-CORRECT PER COMPOSITOR ───────────────────
    # See `currentDesktop`'s own option doc (modules/launcher.nix) for the full, live-checked
    # account of why "scroll" and not "sway" is the estate's real fixture's value.
    "a seated session's unit carries XDG_CURRENT_DESKTOP=scroll (the estate's real fixture, compositor = scroll)" =
      lib.any (e: e == "XDG_CURRENT_DESKTOP=scroll") deskUnit.serviceConfig.Environment;

    "a headless session's unit carries XDG_CURRENT_DESKTOP=scroll too -- the gap this closes is not seated-only" =
      lib.any (e: e == "XDG_CURRENT_DESKTOP=scroll") remoteUnit.serviceConfig.Environment;

    # One PATH must serve both planes. The NixOS profile entries are what let a compositor spawn
    # declaratively installed helpers such as swaybg; the FHS entry is what keeps the same unit
    # usable on system-manager/Arch. Checking the concrete user catches an accidental literal or
    # a path derived from the wrong account.
    "the seated PATH exposes both NixOS profiles and foreign-distro binaries" =
      let
        paths = lib.filter (e: lib.hasPrefix "PATH=" e) deskUnit.serviceConfig.Environment;
        path = lib.head paths;
      in
      lib.length paths == 1
      && lib.hasInfix "/run/current-system/sw/bin" path
      && lib.hasInfix "/etc/profiles/per-user/alice/bin" path
      && lib.hasInfix "/usr/bin" path;

    "a compositor with no built-in currentDesktop entry (niri) falls through to its own declared name" =
      lib.any (e: e == "XDG_CURRENT_DESKTOP=niri")
        niriNoVirtualOutputsCfg.systemd.services."nixdesktop-desk".serviceConfig.Environment;

    "a consumer can override a built-in compositor's currentDesktop, and the override wins" =
      lib.any (e: e == "XDG_CURRENT_DESKTOP=custom-desktop")
        currentDesktopOverrideCfg.systemd.services."nixdesktop-desk".serviceConfig.Environment;

    "the override does not also leave the built-in value sitting in the same unit" =
      !(lib.any (e: e == "XDG_CURRENT_DESKTOP=scroll")
        currentDesktopOverrideCfg.systemd.services."nixdesktop-desk".serviceConfig.Environment);

    "every seated compositor imports logind's dynamic display-session id into the user manager" =
      let post = deskUnit.serviceConfig.ExecStartPost; in
      lib.length post == 1
      && lib.hasInfix "loginctl show-user \"alice\" --property=Display --value" (lib.head post)
      && lib.hasInfix "set-environment \"XDG_SESSION_ID=$session_id\"" (lib.head post);

    "a notify compositor imports XDG_SESSION_ID before its graphical-session bridge starts" =
      let post = niriNoVirtualOutputsCfg.systemd.services."nixdesktop-desk".serviceConfig.ExecStartPost; in
      lib.length post == 2
      && lib.hasInfix "set-environment" (lib.elemAt post 0)
      && lib.hasInfix "start niri.service" (lib.elemAt post 1);
  };

  # ── LAYER THREE: system-manager, LIGHTWEIGHT `evalModules` ────────────────────────────────────
  #
  # Mirrors the lightweight NixOS layer above, but wired to `launcherModuleSystemManager` and the
  # `systemHostStubSystemManager` fixture that faithfully omits `systemd.user.services` -- see that
  # stub's own comment for why its absence is itself part of the proof.
  seatedCfgSm = evalWithSystemManager (baseModules ++ [ absoluteCompositorOverride { nixdesktop.sessions.desk = seated { }; } ]);
  vtBackedCfgSm = evalWithSystemManager (baseModules ++ [ absoluteCompositorOverride { nixdesktop.sessions.desk = seated { vt = 1; }; } ]);
  headlessUnsupportedCfgSm = evalWithSystemManager (baseModules ++ [ absoluteCompositorOverride { nixdesktop.sessions.remote = headless { }; } ]);

  # permittedDevicePaths, same fixture shape as the lightweight NixOS layer above (`sndPath`,
  # `devicePathsCfg`) but composed against the system-manager plane's own stub.
  devicePathsCfgSm = evalWithSystemManager (baseModules ++ [
    absoluteCompositorOverride
    { nixdesktop.sessions.desk = seated { permittedDevicePaths = [ sndPath ]; }; }
  ]);
  devicePathsUnitSm = devicePathsCfgSm.systemd.services."nixdesktop-desk";

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
      && deskUnitSm.serviceConfig.User == "alice";

    "SM: DeviceAllow/DevicePolicy/ExecStart render identically to the NixOS plane for the same fixture" =
      deskUnitSm.serviceConfig.DevicePolicy == "closed"
      && lib.elem "/dev/dri/by-path/pci-0000:03:00.0-card rw" deskUnitSm.serviceConfig.DeviceAllow
      && !(lib.any (e: lib.hasInfix "0000:0a:00.0" e) deskUnitSm.serviceConfig.DeviceAllow)
      && lib.hasPrefix "/" deskUnitSm.serviceConfig.ExecStart;

    "SM: deviceFence mirrors the unit identically to the NixOS plane too" =
      seatedCfgSm.nixdesktop.launcher.deviceFence.desk.deviceAllow == deskUnitSm.serviceConfig.DeviceAllow;

    # ── permittedDevicePaths ON THE SYSTEM-MANAGER PLANE, IDENTICALLY ─────────────────────────
    "SM: permittedDevicePaths entries land LAST, after the static floor and the derived DRM paths" =
      devicePathsUnitSm.serviceConfig.DeviceAllow == [
        "/dev/ptmx rw" "/dev/tty rw" "char-tty rw" "char-pts rw" "char-input rw"
        "/dev/dri/by-path/pci-0000:03:00.0-card rw"
        "${sndPath} rw"
      ];

    "SM: deviceFence mirrors permittedDevicePaths identically to the unit too" =
      devicePathsCfgSm.nixdesktop.launcher.deviceFence.desk.deviceAllow == devicePathsUnitSm.serviceConfig.DeviceAllow;

    "SM: DevicePolicy stays closed even when permittedDevicePaths widens the allowlist" =
      devicePathsUnitSm.serviceConfig.DevicePolicy == "closed";

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

    "SM: the seated unit carries XDG_CURRENT_DESKTOP=scroll, identically to the NixOS plane" =
      lib.any (e: e == "XDG_CURRENT_DESKTOP=scroll") deskUnitSm.serviceConfig.Environment;

    "SM: the seated unit imports logind's display-session id identically to the NixOS plane" =
      deskUnitSm.serviceConfig.ExecStartPost == deskUnit.serviceConfig.ExecStartPost;

    "SM: the combined NixOS/FHS PATH renders identically to the NixOS plane" =
      lib.filter (e: lib.hasPrefix "PATH=" e) deskUnitSm.serviceConfig.Environment
      == lib.filter (e: lib.hasPrefix "PATH=" e) deskUnit.serviceConfig.Environment;
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
        nixhost = { resources.gpu = estateInventory; environments.primary.resources.gpu = primaryClaim; };
        nixdesktop.launcher.compositors.scroll.command = "/nix/store/fake-scroll-path/bin/scroll";
        nixpkgs.hostPlatform = system;
      }
      extraConfig
    ];
  };

  # `permittedDevicePaths` is on this fixture too, deliberately -- see `deviceAllowLines`'s own
  # comment: the ordering proof below needs the REAL rendered unit text, not the lightweight
  # layers' pre-render Nix list, and the estate's real `primary` claim (a genuine DRM device
  # already permitted) is what proves the append composes with a real GPU claim rather than
  # standing in for one.
  realSystemManagerSeated = realSystemManagerFor { nixdesktop.sessions.desk = seated { permittedDevicePaths = [ sndPath ]; }; };

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
    "REAL SYSTEM-MANAGER: the seated unit is a systemd.services unit with PAMName=login and User=alice" =
      lib.hasInfix "PAMName=login\n" deskUnitTextSm
      && lib.hasInfix "User=alice\n" deskUnitTextSm;

    "REAL SYSTEM-MANAGER: the rendered seated unit's ExecStart is absolute" =
      lib.hasInfix "ExecStart=/nix/store/fake-scroll-path/bin/scroll\n" deskUnitTextSm;

    "REAL SYSTEM-MANAGER: the rendered seated unit sets DevicePolicy=closed, never strict" =
      lib.hasInfix "DevicePolicy=closed\n" deskUnitTextSm
      && !(lib.hasInfix "DevicePolicy=strict" deskUnitTextSm);

    "REAL SYSTEM-MANAGER: DeviceAllow includes the permitted device's card node" =
      lib.hasInfix "DeviceAllow=/dev/dri/by-path/pci-0000:03:00.0-card rw\n" deskUnitTextSm;

    "REAL SYSTEM-MANAGER: DeviceAllow never names the denied device's node anywhere" =
      !(lib.hasInfix "0000:0a:00.0" deskUnitTextSm);

    "REAL SYSTEM-MANAGER: the rendered seated unit's Environment carries the colon-free WLR_DRM_DEVICES" =
      lib.hasInfix "WLR_DRM_DEVICES=/dev/dri/by-name/ast-card" deskUnitTextSm;

    "REAL SYSTEM-MANAGER: no ExecStartPre line at all" =
      !(lib.hasInfix "ExecStartPre=" deskUnitTextSm);

    "REAL SYSTEM-MANAGER: no literal card or render-node number anywhere in the rendered unit" =
      !(containsLiteralCardNumber deskUnitTextSm);

    # ── permittedDevicePaths, AGAINST THE REAL RENDERED UNIT TEXT ───────────────────────────────
    "REAL SYSTEM-MANAGER: the rendered seated unit's DeviceAllow carries the permittedDevicePaths entry with a trailing rw" =
      lib.hasInfix "DeviceAllow=${sndPath} rw\n" deskUnitTextSm;

    "REAL SYSTEM-MANAGER: permittedDevicePaths' entry is the LAST DeviceAllow= line, after the static floor and the derived DRM card line" =
      lib.last (deviceAllowLines deskUnitTextSm) == "DeviceAllow=${sndPath} rw";

    "REAL SYSTEM-MANAGER: DevicePolicy stays closed even with permittedDevicePaths declared" =
      lib.hasInfix "DevicePolicy=closed\n" deskUnitTextSm
      && !(lib.hasInfix "DevicePolicy=strict" deskUnitTextSm);

    "REAL SYSTEM-MANAGER: a headless session on this plane fails the WHOLE BUILD outright (makeSystemConfig throws)" =
      realSystemManagerFails { nixdesktop.sessions.remote = headless { }; };

    "REAL SYSTEM-MANAGER: the identical seated fixture that passes above does NOT fail the build" =
      !(realSystemManagerFails { nixdesktop.sessions.desk = seated { }; });

    "REAL SYSTEM-MANAGER: the rendered seated unit's Environment carries XDG_CURRENT_DESKTOP=scroll" =
      lib.hasInfix "XDG_CURRENT_DESKTOP=scroll\n" deskUnitTextSm;

    "REAL SYSTEM-MANAGER: the rendered seated unit publishes XDG_SESSION_ID to the user manager" =
      lib.hasInfix "loginctl show-user" deskUnitTextSm
      && lib.hasInfix "set-environment" deskUnitTextSm
      && lib.hasInfix "XDG_SESSION_ID=" deskUnitTextSm;
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
        nixhost = { resources.gpu = estateInventory; environments.primary.resources.gpu = primaryClaim; };
        # `permittedDevicePaths` rides the same VT-backed fixture -- see `deviceAllowLines`'s own
        # comment for why the ordering proof below needs this REAL rendered text.
        nixdesktop.sessions.desk = seated { vt = 1; permittedDevicePaths = [ sndPath ]; };
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

    "REAL SYSTEM: the rendered seated unit carries PAMName=login and User=alice" =
      lib.hasInfix "PAMName=login\n" deskUnitText
      && lib.hasInfix "User=alice\n" deskUnitText;

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

    # ── permittedDevicePaths, AGAINST THE REAL RENDERED UNIT TEXT ───────────────────────────────
    "REAL SYSTEM: the rendered seated unit's DeviceAllow carries the permittedDevicePaths entry with a trailing rw" =
      lib.hasInfix "DeviceAllow=${sndPath} rw\n" deskUnitText;

    "REAL SYSTEM: permittedDevicePaths' entry is the LAST DeviceAllow= line, after the static floor and the derived DRM card line" =
      lib.last (deviceAllowLines deskUnitText) == "DeviceAllow=${sndPath} rw";

    "REAL SYSTEM: DevicePolicy stays closed even with permittedDevicePaths declared" =
      lib.hasInfix "DevicePolicy=closed\n" deskUnitText
      && !(lib.hasInfix "DevicePolicy=strict" deskUnitText);

    # ── THIS FIXTURE IS VT-BACKED (vt = 1) -- so XDG_VTNR must be present, real system tree ──────
    "REAL SYSTEM: the rendered seated unit (VT-backed, vt = 1) carries XDG_VTNR=1" =
      lib.hasInfix "XDG_VTNR=1\n" deskUnitText;

    "REAL SYSTEM: the rendered seated unit carries the colon-free by-name WLR_DRM_DEVICES" =
      lib.hasInfix "WLR_DRM_DEVICES=/dev/dri/by-name/ast-card" deskUnitText;

    "REAL SYSTEM: the rendered headless unit is a systemd.user.services unit, never systemd.services" =
      (realSystem.config.systemd.user.services ? "nixdesktop-remote")
      && !(realSystem.config.systemd.services ? "nixdesktop-remote");

    "REAL SYSTEM: the rendered headless unit's ExecStart is also absolute, and carries no PAMName" =
      lib.hasInfix "ExecStart=/nix/store/fake-scroll-path/bin/scroll\n" remoteUnitText
      && !(lib.hasInfix "PAMName=" remoteUnitText);

    "REAL SYSTEM: lingering is rendered as a real systemd.tmpfiles.rules entry, never users.users" =
      lib.any (r: lib.hasInfix "/var/lib/systemd/linger/alice" r) realSystem.config.systemd.tmpfiles.rules
      && !(realSystem.config.users.users ? alice);

    # ── XDG_CURRENT_DESKTOP, AGAINST THE REAL RENDERED UNIT TEXT, BOTH DELIVERY CLASSES ─────────
    "REAL SYSTEM: the rendered seated unit's Environment carries XDG_CURRENT_DESKTOP=scroll" =
      lib.hasInfix "XDG_CURRENT_DESKTOP=scroll\n" deskUnitText;

    "REAL SYSTEM: the rendered seated unit publishes XDG_SESSION_ID to the user manager" =
      lib.hasInfix "loginctl show-user" deskUnitText
      && lib.hasInfix "set-environment" deskUnitText
      && lib.hasInfix "XDG_SESSION_ID=" deskUnitText;

    "REAL SYSTEM: the rendered headless unit's Environment carries XDG_CURRENT_DESKTOP=scroll too" =
      lib.hasInfix "XDG_CURRENT_DESKTOP=scroll\n" remoteUnitText;
  };
in
report "launcher" (lightweightResults // realNixosSystemResults // lightweightSystemManagerResults // realSystemManagerResults)
