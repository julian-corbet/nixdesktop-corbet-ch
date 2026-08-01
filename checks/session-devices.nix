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

  # The estate's real shape: three DRM devices declared, devhome forbidden the RX 6800 outright and
  # owning the BMC framebuffer exclusively.
  estateInventory = { amd = { }; ast = { }; evdi = { }; };
  devhomeClaim = { amd.access = "none"; ast.access = "exclusive"; };

  evalSessions = { host ? [ ], sessions }:
    evalWith (host ++ [ sessionModule { nixdesktop.sessions = sessions; } ]);

  withNixhost = { inventory ? { }, environments ? { }, sessions }:
    evalSessions {
      host = [ nixhostStub { nixhost = { resources.gpu = inventory; inherit environments; }; } ];
      inherit sessions;
    };

  seated = extra: {
    compositor = "scroll";
    user = "richc";
    delivery = "seated";
    renderer = "pixman";
  } // extra;

  headless = extra: {
    compositor = "scroll";
    user = "richc";
    delivery = "headless";
    renderer = "pixman";
  } // extra;

  devhome = withNixhost {
    inventory = estateInventory;
    environments.devhome.resources.gpu = devhomeClaim;
    sessions.desk = seated { environment = "devhome"; };
  };

  # A seated session that ALSO asks for two virtual outputs -- proving `virtualOutputs` is
  # orthogonal to `delivery` right here at the module that owns both fields (see
  # `renderer`'s own doc for why a seated session declaring this must not be forced to pixman).
  devhomeWithVirtualOutputs = withNixhost {
    inventory = estateInventory;
    environments.devhome.resources.gpu = devhomeClaim;
    sessions.desk = seated {
      environment = "devhome";
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
    environments.devhome.resources.gpu = devhomeClaim;
    sessions.desk = seated { environment = "devhom"; };
  };

  # A claim naming a device the inventory does not contain. Deliberately a warning, not an
  # assertion: nixhost itself leaves that question open at the owner.
  claimOffInventory = withNixhost {
    inventory = { ast = { }; };
    environments.devhome.resources.gpu = { nvidia.access = "exclusive"; };
    sessions.desk = seated { environment = "devhome"; };
  };

  # nixhost never composed at all — the ordinary state of a host that has not adopted it. Must be
  # silent: absence is legitimate, only a rename is a defect.
  noNixhost = evalSessions { sessions.remote = headless { }; };

  sessionsOf = cfg: cfg.nixdesktop.sessions;

  results = {
    # ── THE DERIVED SETS ──────────────────────────────────────────────────────────────────────
    "permitted is every device whose access is not none" =
      (sessionsOf devhome).desk.permittedDevices == [ "ast" ];

    # THE COMPLEMENT, over the FULL inventory — the shape niri needs, and the reason a complete
    # inventory is mandatory rather than tidy. `amd` is the forbidden RX 6800; `evdi` is declared
    # but unclaimed and must be excluded just as explicitly, or it leaks into niri's enumeration.
    "denied is the complement over the whole inventory" =
      (sessionsOf devhome).desk.deniedDevices == [ "amd" "evdi" ];

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

    # ── virtualOutputs: DATA PASSTHROUGH, NO CAPABILITY OPINION AT THIS LAYER ────────────────
    # This module declares no compositor mechanics (see its own header) -- the compositor
    # CAPABILITY check lives in modules/launcher.nix (checks/launcher.nix proves that one). All
    # this module owes is that the field exists, defaults to empty, and roundtrips in declaration
    # order for BOTH delivery classes -- it is explicitly orthogonal to `delivery`.
    "virtualOutputs defaults to an empty list" =
      (sessionsOf devhome).desk.virtualOutputs == [ ];

    "virtualOutputs roundtrips width/height in declaration order, on a seated session" =
      (sessionsOf devhomeWithVirtualOutputs).desk.virtualOutputs == [
        { width = 1920; height = 1080; }
        { width = 2560; height = 1440; }
      ];

    "a seated session declaring virtualOutputs still passes the seated-device assertion (orthogonal fields)" =
      countMatching "is seated but permits no device" (firedMessages devhomeWithVirtualOutputs) == 0;

    # The device set is the environment's to own. A consumer writing it here must fail, not win.
    "permittedDevices is readOnly" =
      support.evalThrows [
        nixhostStub
        sessionModule
        { nixdesktop.sessions.desk = seated { environment = "devhome"; } // { permittedDevices = [ "amd" ]; }; }
      ];

    # ── HEADLESS => PIXMAN ────────────────────────────────────────────────────────────────────
    # wlroots' headless BACKEND opens no DRM device, but the auto-selected RENDERER still calls
    # open_drm_render_node() and scans the whole system — on this estate that finds the one card
    # the session is forbidden.
    "a headless session may not use an auto-selected renderer" =
      countMatching "is headless but sets"
        (firedMessages (evalSessions { sessions.remote = headless { renderer = "auto"; }; })) == 1;

    "a headless session using gl or vulkan is rejected too" =
      countMatching "is headless but sets"
        (firedMessages (evalSessions { sessions.remote = headless { renderer = "gl"; }; })) == 1
      && countMatching "is headless but sets"
        (firedMessages (evalSessions { sessions.remote = headless { renderer = "vulkan"; }; })) == 1;

    "a headless session on pixman is fine" =
      countMatching "is headless but sets" (firedMessages noNixhost) == 0;

    # ── SEATED => A DEVICE TO MASTER ──────────────────────────────────────────────────────────
    "a seated session with a real claim is fine" =
      countMatching "is seated but permits no device" (firedMessages devhome) == 0;

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
      lib.hasInfix ''nixhost declares no environment named "devhom"'' m
      && lib.hasInfix "Declared: devhome" m;

    # ── ONE SEATED SESSION PER SEAT ───────────────────────────────────────────────────────────
    # Refused independently by drm_setmaster_ioctl (-EBUSY), seatd's busy check and logind's single
    # ActiveSession — none of which produces a message naming a config file.
    "two enabled seated sessions on one seat are rejected" =
      let
        cfg = withNixhost {
          inventory = estateInventory;
          environments.devhome.resources.gpu = devhomeClaim;
          sessions = {
            desk = seated { environment = "devhome"; };
            other = seated { environment = "devhome"; };
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
            devhome.resources.gpu = devhomeClaim;
            second.resources.gpu = { amd.access = "exclusive"; };
          };
          sessions = {
            desk = seated { environment = "devhome"; };
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
          environments.devhome.resources.gpu = devhomeClaim;
          sessions = {
            desk = seated { environment = "devhome"; };
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
          environments.devhome.resources.gpu = devhomeClaim;
          sessions = {
            desk = seated { environment = "devhome"; };
            other = seated { environment = "devhome"; enable = false; };
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
          ../modules/layouts.nix
          sessionModule
          {
            nixdesktop.layouts.docked = { description = "fixture"; outputs = [ ]; };
            nixdesktop.sessions.remote = headless { layout = "dockd"; };
          }
        ];
      in
      countMatching ''names "dockd"'' (firedMessages cfg) == 1;

    "naming a layout that exists is fine" =
      let
        cfg = evalWith [
          ../modules/layouts.nix
          sessionModule
          {
            nixdesktop.layouts.docked = { description = "fixture"; outputs = [ ]; };
            nixdesktop.sessions.remote = headless { layout = "docked"; };
          }
        ];
      in
      countMatching "which `nixdesktop.layouts` does" (firedMessages cfg) == 0;

    # ── WARNINGS ──────────────────────────────────────────────────────────────────────────────
    "an environment nixhost does not declare warns" =
      lib.length (lib.filter (w: lib.hasInfix ''names environment "devhom"'' w) unknownEnv.warnings) == 1;

    "a claim naming a device outside the inventory warns" =
      lib.length (lib.filter (w: lib.hasInfix ''permits the device "nvidia"'' w) claimOffInventory.warnings) == 1;

    "a correct estate produces no warnings at all" = devhome.warnings == [ ];

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
