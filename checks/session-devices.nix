# Evaluates modules/session.nix for real and proves the two things it cannot be allowed to get
# wrong: the device sets it derives from nixhost's already-declared claim, and the four assertions
# that stand between a declaration and a session that fails at device-open with an error naming
# nothing in any config file.
#
# THE DENIED LIST IS THE DANGEROUS ONE. niri has no allowlist — it enumerates every DRM device on
# the seat and can only be restricted by exclusion — so `deniedDevices` being wrong does not
# produce a wrong error, it produces a forbidden card being opened while the config that forbids
# it says nothing about it anywhere. An EMPTY denied list looks exactly like "nothing to deny",
# which is why the rename decoys at the bottom of this file exist: a renamed leaf on nixhost's
# side would empty both lists silently, and the whole point of `lib.probeFact` is that it does not.
{ pkgs, sessionModule, lib ? pkgs.lib }:
let
  support = import ./support.nix { inherit pkgs lib; };
  inherit (support) evalWith firedMessages matching countMatching report;
  inherit (lib) types mkOption;

  # ── STAND-IN nixhost, NOT THE REAL ONE ──────────────────────────────────────────────────────
  #
  # Narrowed to exactly the two leaves modules/session.nix reads: `resources.gpu` (keys only — what
  # a device IS belongs to nixgpu and this module never looks inside) and
  # `environments.<name>.resources.gpu.<name>.access`, recursive, because nixhost's environments
  # genuinely nest (`host.vm.container` is a real path) and a desktop session can belong to a
  # nested one.
  #
  # WHY A STAND-IN RATHER THAN THE REAL FLAKE. nixhost is under independent development and can be
  # mid-edit in another session at any moment; a `git+file://` input would make these checks depend
  # on whatever that working tree happens to look like when `nix flake check` runs here. The real
  # nixhost is already an input of this flake — but only for `lib.probeFact`, the MECHANISM, which
  # is what these checks exercise. Its DATA shape is stubbed, exactly as nixlxc stubs the same
  # three siblings for the same reason.
  envSubmodule = { ... }: {
    options = {
      resources.gpu = mkOption {
        type = types.attrsOf (types.submodule {
          options.access = mkOption {
            type = types.enum [ "none" "shared" "exclusive" ];
            default = "none";
          };
        });
        default = { };
      };
      environments = mkOption {
        type = types.attrsOf (types.submodule envSubmodule);
        default = { };
      };
    };
  };

  nixhostStub = { ... }: {
    options.nixhost = {
      resources.gpu = mkOption { type = types.attrsOf types.anything; default = { }; };
      environments = mkOption { type = types.attrsOf (types.submodule envSubmodule); default = { }; };
    };
  };

  # ── STAND-IN nixdisplay, NOT THE REAL ONE ───────────────────────────────────────────────────
  #
  # Same reasoning as the nixhost stub above: the output layouts moved to the sibling repo
  # nixdisplay, which modules/session.nix reads through `lib.probeFact` (the MECHANISM, exercised by
  # the launcher/session checks) — not by importing nixdisplay's DATA modules, which are under
  # independent development and would make these checks depend on that working tree. Only the one
  # leaf session.nix reads is declared: `nixdisplay.layouts`, keys only (the layout details belong
  # to nixdisplay and this module only asks which names exist). Composing this makes `config ?
  # nixdisplay` true, so probeFact reports state "resolved" and the missing-layout assertion the two
  # tests below exercise can fire.
  nixdisplayStub = { ... }: {
    options.nixdisplay.layouts = mkOption { type = types.attrsOf types.anything; default = { }; };
  };

  # ── THE RENAME DECOYS ───────────────────────────────────────────────────────────────────────
  #
  # Each composes the SAME top-level `nixhost` namespace the real module would — so `config ?
  # nixhost` is true and state (a), "not composed at all", is NOT what is being exercised — while
  # the one leaf this repo reads is missing, renamed to a plausible neighbour. Each decoy leaves
  # the OTHER leaf intact, so exactly one probe can be the source of the resulting warning and the
  # test can attribute it.
  environmentsRenamedStub = { ... }: {
    options.nixhost = {
      resources.gpu = mkOption { type = types.attrsOf types.anything; default = { }; };
      workloads = mkOption { type = types.attrsOf types.anything; default = { }; };
    };
  };

  inventoryRenamedStub = { ... }: {
    options.nixhost = {
      resources.gpus = mkOption { type = types.attrsOf types.anything; default = { }; };
      environments = mkOption { type = types.attrsOf (types.submodule envSubmodule); default = { }; };
    };
  };

  # ── Fixtures ────────────────────────────────────────────────────────────────────────────────

  # A representative shape: three DRM devices declared, primary forbidden the RX 6800 outright and
  # owning the BMC framebuffer exclusively.
  estateInventory = { amd = { }; ast = { }; evdi = { }; };
  primaryClaim = { amd.access = "none"; ast.access = "exclusive"; };

  evalSessions = { host ? [ ], sessions }:
    evalWith (host ++ [ sessionModule { nixdesktop.sessions = sessions; } ]);

  withNixhost = { inventory ? { }, environments ? { }, sessions }:
    evalSessions {
      host = [ nixhostStub { nixhost = { resources.gpu = inventory; inherit environments; }; } ];
      inherit sessions;
    };

  seated = extra: {
    compositor = "scroll";
    user = "alice";
    delivery = "seated";
    renderer = "software";
  } // extra;

  headless = extra: {
    compositor = "scroll";
    user = "alice";
    delivery = "headless";
    renderer = "software";
  } // extra;

  primary = withNixhost {
    inventory = estateInventory;
    environments.primary.resources.gpu = primaryClaim;
    sessions.desk = seated { environment = "primary"; };
  };

  # The SAME estate, but VT-backed (`vt = 1` -- primary on the server owns VT 1, see this module's
  # own `nixdesktop.sessions` example) -- the other seated shape, proving `seatdVtBound`/
  # `requiredGroups` actually flip with it rather than being hardcoded to the workstation's own shape.
  primaryVtBacked = withNixhost {
    inventory = estateInventory;
    environments.primary.resources.gpu = primaryClaim;
    sessions.desk = seated { environment = "primary"; vt = 1; };
  };

  # A headless session naming a VT it has no seat to own -- see the assertion this fixture trips
  # below. Otherwise identical to `noNixhost`'s own `remote` fixture.
  headlessWithVt = evalSessions { sessions.remote = headless { vt = 1; }; };

  # A seated session that ALSO asks for two virtual outputs -- proving `virtualOutputs` is
  # orthogonal to `delivery` right here at the module that owns both fields (see
  # `renderer`'s own doc for why a seated session declaring this must not be forced to pixman).
  primaryWithVirtualOutputs = withNixhost {
    inventory = estateInventory;
    environments.primary.resources.gpu = primaryClaim;
    sessions.desk = seated {
      environment = "primary";
      virtualOutputs = [ { width = 1920; height = 1080; } { width = 2560; height = 1440; } ];
    };
  };

  ordering = withNixhost {
    inventory = { alpha = { }; omega = { }; zulu = { }; };
    environments.mixed.resources.gpu = {
      alpha.access = "shared";
      omega.access = "shared";
      zulu.access = "exclusive";
    };
    sessions.desk = seated { environment = "mixed"; };
  };

  nested = withNixhost {
    inventory = estateInventory;
    environments.bigvm.environments.guest.resources.gpu = { amd.access = "shared"; };
    sessions.desk = seated { environment = "guest"; };
  };

  # nixhost composed but this session's environment is not declared there — a typo or a rename on
  # the consumer's side, not on nixhost's.
  unknownEnv = withNixhost {
    inventory = estateInventory;
    environments.primary.resources.gpu = primaryClaim;
    sessions.desk = seated { environment = "primar"; };
  };

  # A claim naming a device the inventory does not contain. Deliberately a warning, not an
  # assertion: nixhost itself leaves that question open at the owner.
  claimOffInventory = withNixhost {
    inventory = { ast = { }; };
    environments.primary.resources.gpu = { nvidia.access = "exclusive"; };
    sessions.desk = seated { environment = "primary"; };
  };

  # nixhost never composed at all — the ordinary state of a host that has not adopted it. Must be
  # silent: absence is legitimate, only a rename is a defect.
  noNixhost = evalSessions { sessions.remote = headless { }; };

  sessionsOf = cfg: cfg.nixdesktop.sessions;

  results = {
    # ── THE DERIVED SETS ──────────────────────────────────────────────────────────────────────
    "permitted is every device whose access is not none" =
      (sessionsOf primary).desk.permittedDevices == [ "ast" ];

    # THE COMPLEMENT, over the FULL inventory — the shape niri needs, and the reason a complete
    # inventory is mandatory rather than tidy. `amd` is the forbidden RX 6800; `evdi` is declared
    # but unclaimed and must be excluded just as explicitly, or it leaks into niri's enumeration.
    "denied is the complement over the whole inventory" =
      (sessionsOf primary).desk.deniedDevices == [ "amd" "evdi" ];

    # wlroots takes the FIRST device in WLR_DRM_DEVICES that opens as the primary, so the order is
    # a real statement about which card backs the renderer — not incidental.
    "exclusive claims come first, then shared, each alphabetically" =
      (sessionsOf ordering).desk.permittedDevices == [ "zulu" "alpha" "omega" ];

    "a nested environment is found by name at any depth" =
      (sessionsOf nested).desk.permittedDevices == [ "amd" ]
      && (sessionsOf nested).desk.deniedDevices == [ "ast" "evdi" ];

    "a session naming no environment permits nothing and denies the whole inventory" =
      let
        cfg = withNixhost {
          inventory = estateInventory;
          sessions.remote = headless { };
        };
      in
      (sessionsOf cfg).remote.permittedDevices == [ ]
      && (sessionsOf cfg).remote.deniedDevices == [ "amd" "ast" "evdi" ];

    "without nixhost both lists are empty and nothing is claimed" =
      (sessionsOf noNixhost).remote.permittedDevices == [ ]
      && (sessionsOf noNixhost).remote.deniedDevices == [ ];

    # ── vt / seatdVtBound / requiredGroups: THE VT-BACKED VS NOT DISTINCTION ────────────────────
    # See modules/session.nix's own header for the measured facts these two shapes are built on:
    # the workstation has a real seat0 but no /dev/tty0 at all, while primary (vt = 1) owns a real VT.
    "vt defaults to null (the workstation's own shape, not stated as a fixture default)" =
      (sessionsOf primary).desk.vt == null;

    "a seat with no VT is NOT seatdVtBound, and needs every device-access group, alphabetical" =
      (sessionsOf primary).desk.seatdVtBound == false
      && (sessionsOf primary).desk.requiredGroups == [ "input" "render" "seat" "video" ];

    "a VT-backed seat (vt = 1) IS seatdVtBound, and needs no groups at all" =
      (sessionsOf primaryVtBacked).desk.seatdVtBound == true
      && (sessionsOf primaryVtBacked).desk.requiredGroups == [ ];

    "a headless session (no seat at all) is never seatdVtBound and needs no groups either" =
      (sessionsOf noNixhost).remote.seatdVtBound == false
      && (sessionsOf noNixhost).remote.requiredGroups == [ ];

    # ── HEADLESS NEVER DECLARES A VT ────────────────────────────────────────────────────────────
    "a headless session declaring a vt is rejected" =
      countMatching "is headless but declares" (firedMessages headlessWithVt) == 1;

    "the headless-vt message names the session and the declared VT number" =
      let m = lib.head (matching "is headless but declares" (firedMessages headlessWithVt)); in
      lib.hasInfix "nixdesktop.sessions.remote" m && lib.hasInfix "vt = 1" m;

    "a headless session that declares no vt at all trips no such rejection" =
      countMatching "is headless but declares" (firedMessages noNixhost) == 0;

    "a seated session declaring a vt trips no such rejection either (the estate's own VT-backed fixture)" =
      countMatching "is headless but declares" (firedMessages primaryVtBacked) == 0;

    # ── virtualOutputs: DATA PASSTHROUGH, NO CAPABILITY OPINION AT THIS LAYER ────────────────
    # This module declares no compositor mechanics (see its own header) -- the compositor
    # CAPABILITY check lives in modules/launcher.nix (checks/launcher.nix proves that one). All
    # this module owes is that the field exists, defaults to empty, and roundtrips in declaration
    # order for BOTH delivery classes -- it is explicitly orthogonal to `delivery`.
    "virtualOutputs defaults to an empty list" =
      (sessionsOf primary).desk.virtualOutputs == [ ];

    "virtualOutputs roundtrips width/height in declaration order, on a seated session" =
      (sessionsOf primaryWithVirtualOutputs).desk.virtualOutputs == [
        { width = 1920; height = 1080; }
        { width = 2560; height = 1440; }
      ];

    "a seated session declaring virtualOutputs still passes the seated-device assertion (orthogonal fields)" =
      countMatching "is seated but permits no device" (firedMessages primaryWithVirtualOutputs) == 0;

    # The device set is the environment's to own. A consumer writing it here must fail, not win.
    "permittedDevices is readOnly" =
      support.evalThrows [
        nixhostStub
        sessionModule
        { nixdesktop.sessions.desk = seated { environment = "primary"; } // { permittedDevices = [ "amd" ]; }; }
      ];

    # ── HEADLESS => SOFTWARE ──────────────────────────────────────────────────────────────────
    # wlroots' headless BACKEND opens no DRM device, but the auto-selected RENDERER still calls
    # open_drm_render_node() and scans the whole system — on this estate that finds the one card
    # the session is forbidden.
    "a headless session may not use an auto-selected renderer" =
      countMatching "is headless but sets"
        (firedMessages (evalSessions { sessions.remote = headless { renderer = "auto"; }; })) == 1;

    "a headless session requesting hardware is rejected too" =
      countMatching "is headless but sets"
        (firedMessages (evalSessions { sessions.remote = headless { renderer = "hardware"; }; })) == 1;

    "a headless session using software rendering is fine" =
      countMatching "is headless but sets" (firedMessages noNixhost) == 0;

    # ── SEATED => A DEVICE TO MASTER ──────────────────────────────────────────────────────────
    "a seated session with a real claim is fine" =
      countMatching "is seated but permits no device" (firedMessages primary) == 0;

    "a seated session naming no environment is rejected" =
      countMatching "is seated but permits no device"
        (firedMessages (evalSessions { sessions.desk = seated { }; })) == 1;

    "a seated session whose every claim is none is rejected" =
      let
        cfg = withNixhost {
          inventory = estateInventory;
          environments.locked.resources.gpu = { amd.access = "none"; ast.access = "none"; };
          sessions.desk = seated { environment = "locked"; };
        };
      in
      countMatching ''is `access = "none"`'' (firedMessages cfg) == 1;

    "the message distinguishes an unknown environment from an empty claim" =
      let m = lib.head (matching "is seated but permits no device" (firedMessages unknownEnv)); in
      lib.hasInfix ''nixhost declares no environment named "primar"'' m
      && lib.hasInfix "Declared: primary" m;

    # ── ONE SEATED SESSION PER SEAT ───────────────────────────────────────────────────────────
    # Refused independently by drm_setmaster_ioctl (-EBUSY), seatd's busy check and logind's single
    # ActiveSession — none of which produces a message naming a config file.
    "two enabled seated sessions on one seat are rejected" =
      let
        cfg = withNixhost {
          inventory = estateInventory;
          environments.primary.resources.gpu = primaryClaim;
          sessions = {
            desk = seated { environment = "primary"; };
            other = seated { environment = "primary"; };
          };
        };
      in
      countMatching "enabled seated sessions claim seat" (firedMessages cfg) == 1
      && lib.hasInfix "desk, other"
        (lib.head (matching "enabled seated sessions claim seat" (firedMessages cfg)));

    "two seated sessions on DIFFERENT seats are fine" =
      let
        cfg = withNixhost {
          inventory = estateInventory;
          environments = {
            primary.resources.gpu = primaryClaim;
            second.resources.gpu = { amd.access = "exclusive"; };
          };
          sessions = {
            desk = seated { environment = "primary"; };
            other = seated { environment = "second"; seat = "seat1"; };
          };
        };
      in
      countMatching "enabled seated sessions claim seat" (firedMessages cfg) == 0;

    # Headless has no seat at all, so it can never contend for one — this is the whole scaling
    # story and must not be accidentally forbidden.
    "a headless session sharing the seat name does not contend" =
      let
        cfg = withNixhost {
          inventory = estateInventory;
          environments.primary.resources.gpu = primaryClaim;
          sessions = {
            desk = seated { environment = "primary"; };
            remote = headless { };
          };
        };
      in
      countMatching "enabled seated sessions claim seat" (firedMessages cfg) == 0;

    # Parking a session is how a seat is handed over declaratively; a disabled session must not
    # keep contending for one.
    "a disabled seated session does not contend for the seat" =
      let
        cfg = withNixhost {
          inventory = estateInventory;
          environments.primary.resources.gpu = primaryClaim;
          sessions = {
            desk = seated { environment = "primary"; };
            other = seated { environment = "primary"; enable = false; };
          };
        };
      in
      countMatching "enabled seated sessions claim seat" (firedMessages cfg) == 0;

    # ── IDENTITY ──────────────────────────────────────────────────────────────────────────────
    "an empty user is rejected" =
      countMatching "is empty. That is not"
        (firedMessages (evalSessions { sessions.remote = headless { user = ""; }; })) == 1;

    # ── THE LAYOUT REFERENCE ──────────────────────────────────────────────────────────────────
    "a layout the layouts table does not declare is rejected" =
      let
        cfg = evalWith [
          nixdisplayStub
          sessionModule
          {
            nixdisplay.layouts.docked = { };
            nixdesktop.sessions.remote = headless { layout = "dockd"; };
          }
        ];
      in
      countMatching ''names "dockd"'' (firedMessages cfg) == 1;

    "naming a layout that exists is fine" =
      let
        cfg = evalWith [
          nixdisplayStub
          sessionModule
          {
            nixdisplay.layouts.docked = { };
            nixdesktop.sessions.remote = headless { layout = "docked"; };
          }
        ];
      in
      countMatching "which `nixdisplay.layouts` does" (firedMessages cfg) == 0;

    # ── WARNINGS ──────────────────────────────────────────────────────────────────────────────
    "an environment nixhost does not declare warns" =
      lib.length (lib.filter (w: lib.hasInfix ''names environment "primar"'' w) unknownEnv.warnings) == 1;

    "a claim naming a device outside the inventory warns" =
      lib.length (lib.filter (w: lib.hasInfix ''permits the device "nvidia"'' w) claimOffInventory.warnings) == 1;

    "a correct estate produces no warnings at all" = primary.warnings == [ ];

    # ── THE RENAME DECOYS ─────────────────────────────────────────────────────────────────────
    #
    # State (a) — nixhost never composed — is legitimate and must be silent. State (c) — composed,
    # but the leaf this repo reads moved — is a defect, and a bare `or { }` cannot tell the two
    # apart: both land on the same empty fallback, and an empty DENIED list reads exactly like
    # "nothing to deny" while a forbidden card leaks into niri's enumeration.
    "nixhost absent produces no warnings" = noNixhost.warnings == [ ];

    "nixhost.environments renamed warns exactly once, naming the leaf" =
      let
        cfg = evalWith [
          environmentsRenamedStub
          sessionModule
          { nixdesktop.sessions.remote = headless { }; }
        ];
      in
      lib.length cfg.warnings == 1
      && lib.hasInfix "nixhost.environments" (lib.head cfg.warnings)
      && lib.hasInfix "IS composed" (lib.head cfg.warnings);

    "nixhost.resources.gpu renamed warns exactly once, naming the leaf" =
      let
        cfg = evalWith [
          inventoryRenamedStub
          sessionModule
          { nixdesktop.sessions.remote = headless { }; }
        ];
      in
      lib.length cfg.warnings == 1
      && lib.hasInfix "nixhost.resources.gpu" (lib.head cfg.warnings);

    # The decoy must not merely warn — it must not FAIL the build. probeFact defaults to
    # mode = "warn" for exactly this: an assertion here would make the option unadoptable on every
    # host that has not composed nixhost yet.
    "a renamed leaf warns rather than failing the build" =
      !(support.evalThrows [
        environmentsRenamedStub
        sessionModule
        { nixdesktop.sessions.remote = headless { }; }
      ]);
  };
in
report "session devices" results
