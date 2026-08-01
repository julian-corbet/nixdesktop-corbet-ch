# modules/session.nix — a desktop session as an INSTANCE: this user, this compositor, delivered
# this way, on this seat, with this device claim and this output layout.
#
# SESSIONS ARE AN ATTRSET, NOT A SINGLETON. `nixdesktop.desktop.*` (profiles/desktop.nix) describes
# what a desktop CONSISTS of and there is one of those per machine image; how many sessions stand
# on a machine is a completely different question, and the answer is not one. Scale here comes
# from instantiation, never from typing: a hundred headless sessions is one profile folded over an
# identity registry, not a hundred hand-written blocks.
#
# ── THE TWO DELIVERY CLASSES ARE A HARDWARE FACT, NOT A PRODUCT DECISION ─────────────────────
#
# One seat carries exactly one active graphical session, and that is enforced three times
# independently: `drm_setmaster_ioctl` returns -EBUSY when a master already exists
# (drivers/gpu/drm/drm_auth.c), seatd's `seat_open_client()` has an unconditional busy check that
# is not gated on VT binding (seatd/seat.c), and logind gives a `Seat` exactly one `ActiveSession`.
# DRM master is per-DEVICE, not per-connector, so a second SEATED session needs a second GPU. That
# is what bounds the seated class: GPU count, full stop. VTs are not a concurrency mechanism --
# they are how one seat time-multiplexes its single active client.
#
# Headless sessions are bounded by nothing but the payload. In wlroots only the `drm` and
# `libinput` backends call `session_create_and_wait()`; `attempt_headless_backend()` never touches
# libseat at all. So `delivery` is the discriminator this whole module is organised around, and
# every assertion below is downstream of it.
#
# ── A SEATED SESSION MAY OR MAY NOT HAVE A VT, AND THAT IS A SECOND, INDEPENDENT HARDWARE FACT ──
#
# There are TWO delivery classes above, not three. The arch LXC is not a special third class -- it
# is an ordinary SEATED session whose seat happens to have no VT. Verified live: `loginctl` inside
# the container reports a real `seat0` and a genuine `class=user` session sitting on it (an earlier
# note claiming containers have no seat at all was WRONG) -- but `/dev/tty0` does not exist there
# at all (`/dev/console` does, and it is a pty, not a VT). `vt`, below, is what turns that into a
# first-class, asserted fact instead of something a consumer has to already know before they can
# explain why their cursor is dead: see its own doc for the two shapes, and `seatdVtBound`/
# `requiredGroups` for the concrete consequence each one carries downstream.
#
# ── THE DEVICE SET IS NOT DECLARED HERE, AND THAT IS THE POINT ───────────────────────────────
#
# A session names an `environment`; which devices that environment may touch is already declared,
# already conflict-checked, and already carries this estate's real intent:
#
#     host file        nixgpu.stableDevicePaths.devices.<name>          the facts
#          | probeFact, readOnly
#     mirror           nixhost.resources.gpu.<name>                     the complete inventory
#          |
#     the CLAIM        nixhost.environments.<env>.resources.gpu.<name>.access
#                        = "none" | "shared" | "exclusive"
#
# nixhost already fails the build when two environments contradict each other about one card. A
# second device list here would not merely duplicate that -- it would DISARM it, because the
# conflict arithmetic would go on checking a table nothing reads while the sessions ran off a
# different one. So this module declares no devices at all. It READS that claim through
# `lib.probeFact` (never a flake input on the domain, never an `imports` of nixhost) and turns it
# into the two shapes the compositors actually need.
#
# ── WHY BOTH A PERMIT LIST AND ITS COMPLEMENT ────────────────────────────────────────────────
#
# The two compositors restrict devices in OPPOSITE directions, and neither can be expressed in the
# other's terms without knowing the full inventory:
#
#   scroll (wlroots)  WLR_DRM_DEVICES, colon-separated             ALLOWLIST, first that opens is primary
#   niri (Smithay)    debug{ignore-drm-device} + debug{render-drm-device}   DENYLIST only
#
# niri enumerates every DRM device on the seat unconditionally; exclusion is the only lever it
# offers. So `deniedDevices` is the complement of the permitted set over the WHOLE inventory, and
# THAT is why a complete inventory is mandatory rather than merely tidy: a device that physically
# exists but was never declared in `nixgpu.stableDevicePaths.devices` appears in neither list, is
# therefore never ignored, and silently leaks into niri's enumeration -- on this estate that means
# the forbidden RX 6800 being opened by the one session forbidden to touch it.
#
# ⚠ Both niri keys live under `debug`, which niri's own documentation explicitly excludes from its
# config stability policy. That volatility belongs to nixniri's translator, which must pin itself
# to a niri version; this module's vocabulary is version-independent by construction because it
# emits device NAMES and no syntax at all.
{ probeFact, collectProbes }:
{ lib, config, ... }:
let
  inherit (lib) types mkOption;

  cfg = config.nixdesktop.sessions;

  # ── The two cross-repo reads, both through lib.probeFact ────────────────────────────────────
  #
  # A bare `config.nixhost.environments or { }` cannot tell "nixhost is not composed on this host"
  # (legitimate, silent) from "nixhost IS composed but the leaf moved or was renamed" (a defect
  # that would silently empty the permitted set and, worse, silently empty the DENIED set -- the
  # exact failure mode described in this file's header). probeFact separates the two and warns
  # only on the second. See nixhost's own lib/facts.nix for the defect class.
  environmentsProbe = probeFact {
    inherit config;
    namespace = "nixhost";
    path = [ "environments" ];
    fallback = { };
  };

  # The COMPLETE inventory, level-1 in nixhost's vocabulary: a read-only mirror of
  # `nixgpu.stableDevicePaths.devices`. Only the KEYS are read here -- what a device is (vendor,
  # PCI id, VRAM) belongs to nixgpu and is none of this module's business; the name is the whole
  # contract, because it is the same name the claim above is keyed by.
  inventoryProbe = probeFact {
    inherit config;
    namespace = "nixhost";
    path = [ "resources" "gpu" ];
    fallback = { };
  };

  # nixhost's `environments` is a RECURSIVE type -- a VM hosts containers, `host.vm.container` is
  # a real path -- and a desktop session can perfectly well belong to a nested one. Names are
  # host-scoped at every depth (nixhost's own conflict check flattens the whole tree for exactly
  # this reason), so flattening by name here reads the same object nixhost's arithmetic does.
  flattenEnvironments = envs:
    lib.foldl'
      (acc: name:
        let env = envs.${name}; in
        acc // { ${name} = env; } // flattenEnvironments (env.environments or { }))
      { }
      (lib.attrNames envs);

  allEnvironments = flattenEnvironments environmentsProbe.value;

  # Sorted, because `lib.attrNames` is: the ordering of both emitted lists has to be a pure
  # function of the declaration, or a no-op edit elsewhere reshuffles WLR_DRM_DEVICES and silently
  # changes which card becomes primary.
  inventory = lib.attrNames inventoryProbe.value;

  claimsOf = envName:
    let env = allEnvironments.${envName} or null; in
    if env == null then { } else env.resources.gpu;

  # ORDERING IS PART OF THE CONTRACT, because wlroots takes the FIRST device in WLR_DRM_DEVICES
  # that successfully opens as the primary (the one whose render node backs the renderer and whose
  # GBM allocates for every output). So the order cannot be incidental:
  #
  #   "exclusive" first -- a device this environment owns outright is by definition the one it is
  #   meant to master -- then "shared", each alphabetically for determinism.
  #
  # On this estate that resolves devhome to `[ "ast" ]`: `gpu.ast.access = "exclusive"` is the BMC
  # framebuffer it drives, `gpu.amd.access = "none"` keeps the RX 6800 out entirely.
  permittedFor = envName:
    if envName == null then [ ] else
    let
      claims = claimsOf envName;
      withAccess = a: lib.filter (n: claims.${n}.access == a) (lib.attrNames claims);
    in
    withAccess "exclusive" ++ withAccess "shared";

  # THE COMPLEMENT, over the full inventory -- see the header. A device in the inventory that this
  # environment does not permit must be named explicitly, because niri has no way to be told what
  # to use, only what to ignore.
  deniedFor = envName:
    let permitted = permittedFor envName; in
    lib.filter (n: !(lib.elem n permitted)) inventory;

  sessionModule = { config, name, ... }: {
    options = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Whether this session is instantiated. Defaults to TRUE, unlike a top-level
          `mkEnableOption`: an entry in this attrset exists because somebody wrote it down, and a
          registry whose entries all need a second "yes" is a registry with a class of entry that
          silently does nothing. Set it false to park a session -- a seat handed to someone else
          for a week, a headless tenant suspended -- without deleting the declaration, and note
          that a disabled session takes no part in the one-seated-session-per-seat arithmetic
          below, which is precisely how a seat is handed over declaratively.
        '';
      };

      compositor = mkOption {
        type = types.str;
        example = "niri";
        description = ''
          Which compositor runs this session -- the same free-form vocabulary as
          `nixdesktop.desktop.compositor`, resolved by whichever sibling compositor-module repo
          (nixniri, nixscroll, ...) is composed alongside. Free-form rather than an enum for the
          same reason it is there: a new compositor must become usable by naming it, never by
          editing this repo.

          Per-session rather than per-host because it genuinely varies per session: a seated
          session on a card with no render node and a headless session on the same box have
          different constraints and can reasonably run different compositors.
        '';
      };

      user = mkOption {
        type = types.str;
        example = "richc";
        description = ''
          The POSIX user this session runs as, BY NAME. Never a uid, and never a uid anywhere
          downstream either: the consumer resolves this name through
          `nixiam.posix.identities.<name>.uid`, which is the family's single identity registry and
          already carries an `identityRange` of 3000-3999 for exactly this kind of fan-out. Two
          places holding a number that must agree is how a session ends up owning the wrong
          home directory, and there is no version of that failure that announces itself.

          Asserted non-empty below. An empty string is not "unset" -- it is a name that resolves
          to nothing while looking like it was configured.
        '';
      };

      delivery = mkOption {
        type = types.enum [ "seated" "headless" ];
        example = "seated";
        description = ''
          How this session reaches a human. Required, with no default, because the two classes
          have different hard constraints and guessing either way is wrong:

          `"seated"` -- a physical output on a logind seat. Needs a DRM device and a seat, and is
          bounded by GPU COUNT: DRM master is per-device, so one active session per seat, enforced
          independently by `drm_setmaster_ioctl` (-EBUSY), seatd's busy check and logind's single
          `ActiveSession`. The consumer must run it as a SYSTEM unit with `PAMName=` + `User=`; a
          `--user` unit can never be seated, because `sd_pid_get_session()` requires the process's
          own cgroup path to contain `session-<N>.scope` and a user manager's does not -- no
          exported `XDG_SESSION_ID` can fake that. That unit is an AUTOLOGIN, deliberately, never a
          greeter -- see `nixdesktop.launcher`'s own header, "DESIGN A", for why a greeter is
          exactly one password too many on this estate. A session with no seat is also why a
          polkit agent silently fails to register.

          `"headless"` -- no output, no seat, no DRM device; reached over wayvnc/waypipe/RDP. This
          is the class that scales, and it is the same mechanism as "a full session in a browser".
          Needs `loginctl enable-linger` on the user so `user@<uid>.service` exists with no
          session at all. ⚠ systemd v256+ `user-light`/`background-light` session classes
          explicitly skip starting `user@.service`; this path needs the plain `user` class.
        '';
      };

      seat = mkOption {
        type = types.str;
        default = "seat0";
        example = "seat1";
        description = ''
          The logind seat this session occupies. MEANINGLESS when `delivery = "headless"` -- a
          headless session has no seat at all -- and left at its default there rather than made
          nullable, because a nullable field invites the reader to wonder what a null seat means.

          Seat assignment is fully declarative and needs no imperative step: `loginctl attach`
          does nothing but write `/etc/udev/rules.d/72-seat-<id>.rules` containing
          `TAG=="seat", ENV{ID_FOR_SEAT}=="...", ENV{ID_SEAT}="seatN"` and re-trigger udev, and a
          module rendering the identical rule is indistinguishable to logind. A seat needs a
          graphics device and NOTHING else: `seat_can_graphical()` is literally
          `seat_has_master_device()` -- there is no input-device check anywhere in that path, so a
          seat with a card and no dedicated keyboard is fully graphical-capable.
        '';
      };

      vt = mkOption {
        type = types.nullOr types.ints.positive;
        default = null;
        example = 1;
        description = ''
          MEANINGLESS when `delivery = "headless"` -- asserted null there, below, for the same
          reason `seat` above is left at its ordinary default rather than made to mean something
          extra: a session with no seat has no VT to speak of either.

          For a seated session, this is the fact that actually distinguishes the two shapes a seat
          on this estate can take -- a HARDWARE fact, never a style choice:

          A NUMBER (the laptop; devhome on the server, which owns VT 1) means the seat is
          VT-BACKED: `loginctl`'s ordinary mechanics apply, seatd follows VT-switch ioctls, and
          logind's active-session ACL (`uaccess`) is what grants device access to whoever is
          active on that VT. `seatdVtBound`/`requiredGroups` below are both irrelevant here.

          `null` (the default, and the arch LXC's only honest answer) means the seat is REAL but
          has NO VT to be backed by -- see this file's header for the measured `loginctl`/
          `/dev/tty0` facts behind that. A VT-bound seatd never activates a session with nothing to
          switch to, and the compositor's libinput backend then times out with "couldn't create
          backend" and a permanently dead cursor -- fixed by `SEATD_VTBOUND=0`, which is exactly
          why `seatdVtBound` exists below rather than leaving every consumer to re-derive `vt ==
          null` for itself. `nixdesktop.launcher` reads this same fact to decide whether its
          generated unit's `Environment=` may state `XDG_VTNR` at all -- see that module's own
          header, "THE VT FACT", for the two measured failures (one per direction) that make
          getting this wrong a real, live outcome rather than a theoretical one.
        '';
      };

      seatdVtBound = mkOption {
        type = types.bool;
        readOnly = true;
        description = ''
          READ-ONLY, derived: `vt != null`. `false` is the signal `nixdesktop.launcher`'s generated
          wrapper reads to decide it MUST export `SEATD_VTBOUND=0` -- see `vt`'s own doc for the
          measured failure ("couldn't create backend", a dead cursor) that fixes. Exposed as its
          own named fact, rather than leaving every downstream consumer to re-derive `vt == null`
          for itself, for the identical reason `permittedDevices`/`deniedDevices` are: one true
          statement about this session, computed once, read wherever it is needed.
        '';
      };

      requiredGroups = mkOption {
        type = types.listOf types.str;
        readOnly = true;
        description = ''
          READ-ONLY, derived: `[ "input" "render" "seat" "video" ]` (alphabetical, same determinism
          reason `permittedDevices` is ordered) for a seated session with `vt == null`; `[ ]` for
          every other session, seated-and-VT-backed or headless alike.

          WHY THIS EXISTS. A VT-backed seated session gets its device access from logind's own
          `uaccess` ACL, applied to whoever is active on that VT -- group membership is not the
          mechanism there at all. A seat with NO VT has no VT to be active ON, so `uaccess` never
          fires either, and GROUP MEMBERSHIP IS THE ONLY REMAINING PATH granting this session's
          user access to `/dev/dri/*` (`video`/`render`), its input devices (`input`), and a
          non-VT-bound seatd's own listening socket (`seat`) at all. `nixdesktop.launcher` asserts
          these are actually present in `users.users.<name>.extraGroups` for a NixOS/system-
          manager-managed user (see that module's own assertion) precisely because this is the one
          failure mode with no error message pointing at it: a group silently missing from
          `extraGroups` does not fail this session to start, it fails it to draw anything, and both
          libinput and the DRM backend report nothing more specific than "couldn't create backend".
        '';
      };

      environment = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "devhome";
        description = ''
          A `nixhost.environments.<name>` -- and THE DEVICE CLAIM LIVES THERE, not here. Every GPU
          this session may touch is `resources.gpu.<name>.access != "none"` on that environment;
          everything else on the host is denied. Read through `lib.probeFact`, never imported, so
          this repo stays usable by someone who has never heard of nixhost.

          `null` means this session claims no device at all, which is correct and complete for a
          headless session and is asserted to be a build failure for a seated one.

          Nested environments are found by name at any depth: nixhost's `environments` is
          recursive (`host.vm.container` is a real path) and names are host-scoped at every level,
          so a session belonging to a nested environment names it exactly as a top-level one does.
        '';
      };

      layout = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "docked";
        description = ''
          A `nixdesktop.layouts.<name>` -- which panels this session expects and where. `null`
          leaves output arrangement entirely to the compositor's defaults, which is the right
          answer for a headless session and for a single-screen machine nobody has an opinion
          about.
        '';
      };

      virtualOutputs = mkOption {
        type = types.listOf (types.submodule {
          options = {
            width = mkOption {
              type = types.ints.positive;
              example = 1920;
              description = "Pixel width of this virtual output.";
            };
            height = mkOption {
              type = types.ints.positive;
              example = 1080;
              description = "Pixel height of this virtual output.";
            };
          };
        });
        default = [ ];
        example = lib.literalExpression ''[ { width = 1920; height = 1080; } ]'';
        description = ''
          Outputs this session needs that NO PHYSICAL PANEL BACKS -- how many, and at what
          resolution. This is invariant 1b of the workstation-story design doc made concrete: an
          agent identity "needs no speakers and no monitor, but it DOES need a display to render
          into the moment it does anything browser-shaped, because a browser cannot be driven
          without one." One list entry per output; `[ ]`, the default, is the ordinary case for
          every session that only ever draws to real hardware.

          MODELED AS PART OF THE SESSION, NOT AS A `layout` ENTRY. `nixdesktop.layouts` exists to
          arrange NAMED, IDENTIFIABLE hardware (an EDID triple or a connector) in physical
          POSITION relative to other panels -- see modules/layouts.nix's own header. A virtual
          output has neither: no EDID, no connector, no position to overlap-check against a real
          screen, and no identity that could roam between hosts the way a `nixdesktop.monitors`
          entry does. It belongs to whichever session asked for it, exactly the way `renderer` or
          `environment` do -- not to a layout describing a desk.

          ORTHOGONAL TO `delivery`, DELIBERATELY -- allowed on `"headless"` AND `"seated"` alike.
          The obvious case is headless (an agent with no seat at all still needs somewhere to
          draw), but a seated workstation session asking for an EXTRA output nothing physical
          backs (to hand an agent's browser a place to render alongside the human's own screen) is
          exactly as legitimate, and forbidding it here would be modeling less than the compositor
          can actually do -- see `renderer`'s own doc below for why this does not reopen the
          headless render-node trap on a seated session.

          COMPOSITOR SUPPORT IS A REAL, ASSERTED CAPABILITY BOUNDARY, enforced in
          `nixdesktop.launcher` (`nixdesktop.launcher.compositors.<name>.supportsVirtualOutputs`),
          NEVER HERE: this module declares no compositor mechanics, the same way it declares no
          device list -- see this file's header. A session naming a compositor that cannot create
          one is a BUILD FAILURE naming the compositor, not a silent no-op: the alternative is an
          agent identity with no display and no error saying why.
        '';
      };

      renderer = mkOption {
        type = types.enum [ "auto" "gl" "vulkan" "pixman" ];
        default = "auto";
        description = ''
          Which renderer the compositor should use. `"pixman"` is CPU-only and is the only value
          that touches no GPU AT ALL -- which is not a performance note but a containment one.

          ⚠ HEADLESS DOES NOT MEAN "NO GPU TOUCHED", and this is the trap the assertion below
          exists for. wlroots' headless BACKEND opens no DRM device, but the auto-selected
          RENDERER still calls `open_drm_render_node()` and scans the WHOLE system for one. On a
          host whose only render node belongs to a card this session is forbidden to touch, "auto"
          finds exactly that card. So `delivery = "headless"` requires `"pixman"`, asserted, not
          recommended.

          For a seated session the value is a capability question: `"auto"` is right on a card
          with a render node, and `"pixman"` is right on one without -- evdi's `drm_driver` never
          sets `DRIVER_RENDER`, so an evdi device can NEVER have a render node; that is a
          compile-time property of the driver, true on every host, not a configuration.

          ⚠ A SEATED SESSION THAT ALSO DECLARES `virtualOutputs` DOES NOT REOPEN THIS TRAP, AND
          MUST NOT BE FORCED TO `"pixman"` ON THAT ACCOUNT -- a temptation worth naming explicitly
          so nobody "fixes" this later by widening the headless-only assertion below. The renderer
          is a property of the COMPOSITOR PROCESS, shared by every output it drives, physical or
          virtual: a wlroots-multi-backend compositor (scroll) already attaches a secondary
          headless backend ALONGSIDE its DRM one on every session it runs, seated or headless
          alike (see nixscroll's own `home/scroll.nix` for the measured source citation), so a
          virtual output on a seated session rides the SAME renderer this option already resolved
          for that session's real device -- `"auto"` where that device has a render node,
          `"pixman"` where it does not, exactly as the paragraph above already states. There is no
          second renderer to get wrong per output, and forcing pixman here unconditionally would
          needlessly discard GPU-accelerated rendering for the WHOLE session, virtual output and
          real one alike, on a card that has a perfectly good render node.
        '';
      };

      extraEnvironment = mkOption {
        type = types.attrsOf types.str;
        default = { };
        example = { XCURSOR_SIZE = "24"; };
        description = ''
          Extra environment variables for this session's own unit. Escape hatch for things this
          module has no opinion about. NOT the place for device restriction: `WLR_DRM_DEVICES` and
          niri's ignore/render keys are derived from `permittedDevices`/`deniedDevices` by the
          compositor modules, and a hand-written copy here would be a second, unchecked statement
          about which card this session may open -- the exact duplication this module was built to
          delete.
        '';
      };

      permittedDevices = mkOption {
        type = types.listOf types.str;
        readOnly = true;
        description = ''
          READ-ONLY, derived from `nixhost.environments.<environment>.resources.gpu`: every device
          whose `access` is not `"none"`. ORDERED, PRIMARY FIRST -- `"exclusive"` claims before
          `"shared"` ones, alphabetical within each -- because wlroots takes the first device in
          `WLR_DRM_DEVICES` that successfully opens as the primary, so the order is a real
          statement about which card backs the renderer and allocates buffers.

          THESE ARE NAMES, NOT PATHS, AND THAT IS DELIBERATE. `/dev/dri/cardN`, the DRM minor
          `226:N` and even a PCI path are all resolved at START time by the launcher, against live
          sysfs -- never here. Card numbers and minor numbers are assigned in kernel probe order
          and genuinely renumber: an evdi module load reshuffled this estate's host on 2026-07-29
          and turned four hand-written `card1`/`226:1` references into lies pointing at the wrong
          hardware. An eval-time path is a fact about the machine that booted last time.
        '';
      };

      deniedDevices = mkOption {
        type = types.listOf types.str;
        readOnly = true;
        description = ''
          READ-ONLY, derived: the COMPLEMENT of `permittedDevices` over the full
          `nixhost.resources.gpu` inventory. niri has no allowlist -- it enumerates every DRM
          device on the seat and can only be restricted by `debug { ignore-drm-device }` -- so
          this is the only shape that can express "use nothing else" to it.

          Which is why the inventory must be COMPLETE. A device that exists on the machine but was
          never declared in `nixgpu.stableDevicePaths.devices` is in neither list: not permitted,
          and therefore never ignored either. It leaks straight into niri's enumeration, and the
          config that forbids it says nothing about it anywhere. Empty here does not mean "nothing
          is denied"; it can equally mean the inventory never arrived, which is why the probe
          above warns rather than falling back silently.

          Names, not paths, for the same reason as `permittedDevices`.
        '';
      };
    };

    # Definitions rather than option `default`s: `readOnly` rejects a SECOND definition, so
    # defining these here makes a consumer's attempt to write them a build failure. A `default`
    # would have been silently replaceable, because readOnly counts definitions and one is allowed.
    config = {
      permittedDevices = permittedFor config.environment;
      deniedDevices = deniedFor config.environment;
      seatdVtBound = config.vt != null;
      requiredGroups =
        if config.delivery == "seated" && config.vt == null
        then [ "input" "render" "seat" "video" ]
        else [ ];
    };
  };

  enabledSessions = lib.filterAttrs (_: s: s.enable) cfg;
  seatedSessions = lib.filterAttrs (_: s: s.delivery == "seated") enabledSessions;

  # One entry per seat that more than one enabled seated session claims.
  contestedSeats = lib.filterAttrs (_: names: lib.length names > 1)
    (lib.groupBy (n: seatedSessions.${n}.seat) (lib.attrNames seatedSessions));

  layoutsComposed = config.nixdesktop ? layouts;
  declaredLayouts = if layoutsComposed then config.nixdesktop.layouts else { };
in
{
  options.nixdesktop.sessions = mkOption {
    type = types.attrsOf (types.submodule sessionModule);
    default = { };
    example = lib.literalExpression ''
      {
        # The one seated session on the BMC framebuffer: the RX 6800 is `access = "none"` in
        # nixhost's devhome environment, so it lands in deniedDevices and niri is told to ignore it.
        devhome = {
          compositor = "scroll";
          user = "richc";
          delivery = "seated";
          environment = "devhome";
          layout = "console";
          renderer = "pixman";
          vt = 1; # devhome owns VT 1 on the server -- a VT-backed seat, unlike the arch LXC's.
        };
        # Its headless sibling -- the browser leg -- on no seat and no device at all.
        devhome-remote = {
          compositor = "scroll";
          user = "richc";
          delivery = "headless";
          renderer = "pixman";
        };
      }
    '';
    description = ''
      Every desktop session standing on this host, keyed by a short name. An attrset rather than a
      singleton: how many sessions a machine runs is not a property of the machine, and 100
      headless sessions must be one profile folded over an identity registry rather than 100
      blocks of text.
    '';
  };

  config.assertions =
    # ── HEADLESS => PIXMAN ────────────────────────────────────────────────────────────────────
    lib.mapAttrsToList
      (name: s: {
        assertion = s.renderer == "pixman";
        message = ''
          nixdesktop.sessions.${name} is headless but sets `renderer = "${s.renderer}"`. Headless
          does not mean "no GPU touched": wlroots' headless BACKEND opens no DRM device, but the
          auto-selected RENDERER still calls `open_drm_render_node()` and scans the entire system
          for one -- so on a host whose only render node belongs to a card this session is
          forbidden to touch, that is exactly the card it opens. `renderer = "pixman"` is the only
          value that makes a headless session genuinely zero-GPU.
        '';
      })
      (lib.filterAttrs (_: s: s.delivery == "headless") enabledSessions)

    # ── HEADLESS NEVER DECLARES A VT ──────────────────────────────────────────────────────────
    # A headless session has no seat at all (see `delivery`'s own doc), and a VT belongs to a
    # seat -- so a VT number on a headless session does not describe a smaller version of the
    # seated case, it names hardware this session will never touch. Silently ignoring the field
    # would hide exactly that mistake rather than name it.
    ++ lib.mapAttrsToList
      (name: s: {
        assertion = false;
        message = ''
          nixdesktop.sessions.${name} is headless but declares `vt = ${toString s.vt}`. A headless
          session has no seat at all (see `delivery`'s own doc), and a VT belongs to a seat -- there
          is nothing here for this number to mean. Drop `vt`, or give this session `delivery =
          "seated"` if it is meant to own a real seat.
        '';
      })
      (lib.filterAttrs (_: s: s.delivery == "headless" && s.vt != null) enabledSessions)

    # ── SEATED => AT LEAST ONE PERMITTED DEVICE ───────────────────────────────────────────────
    # A seated session is a DRM master on a real card. With nothing permitted there is nothing to
    # master, and the failure at runtime is an opaque backend-start error rather than anything
    # naming the missing claim.
    ++ lib.mapAttrsToList
      (name: s: {
        assertion = s.permittedDevices != [ ];
        message = ''
          nixdesktop.sessions.${name} is seated but permits no device.
          ${if s.environment == null
            then "It names no `environment`, so there is no device claim to read at all."
            else if !(allEnvironments ? ${s.environment})
            then ''nixhost declares no environment named "${s.environment}"${
              if allEnvironments == { }
              then " -- in fact it declares none at all here, which usually means nixhost (or nixgpu, which supplies its inventory) is not composed on this host"
              else ". Declared: " + lib.concatStringsSep ", " (lib.attrNames allEnvironments)}.''
            else ''every GPU in nixhost.environments."${s.environment}".resources.gpu is `access = "none"`.''}
          A seated session takes DRM master on a real device; permitting none leaves it nothing to
          master. Declare the claim where it belongs -- `nixhost.environments.<env>.resources.gpu.
          <device>.access` -- not here; this module deliberately owns no device list.
        '';
      })
      (lib.filterAttrs (_: s: s.delivery == "seated") enabledSessions)

    # ── AT MOST ONE ENABLED SEATED SESSION PER SEAT ───────────────────────────────────────────
    # Not a misconfiguration to discover at runtime. See the header: three independent mechanisms
    # each refuse the second one, and none of them produces a message that names a config file.
    ++ lib.mapAttrsToList
      (seat: names: {
        assertion = false;
        message = ''
          nixdesktop.sessions: ${toString (lib.length names)} enabled seated sessions claim seat
          "${seat}": ${lib.concatStringsSep ", " names}. A seat carries exactly ONE active
          graphical session, enforced independently three times -- `drm_setmaster_ioctl` returns
          -EBUSY when a master already exists, seatd's `seat_open_client()` has an unconditional
          busy check, and logind gives a Seat exactly one ActiveSession. The second session does
          not get a black screen; it fails at device-open with an error naming none of this.
          Concurrency comes from separate SEATS, never separate VTs (a VT is how one seat
          time-multiplexes its single client) -- and a second seat needs its own GPU, because DRM
          master is per-device. Give one of these `delivery = "headless"`, or a seat of its own
          with a device of its own.
        '';
      })
      contestedSeats

    # ── A USER NAME THAT IS NOT A NAME ────────────────────────────────────────────────────────
    ++ lib.mapAttrsToList
      (name: _: {
        assertion = false;
        message = ''
          nixdesktop.sessions.${name}.user is empty. That is not "unset" -- it is a name that
          resolves to nothing while looking configured. Name a POSIX user; the consumer resolves
          it through `nixiam.posix.identities.<name>.uid` and never writes a raw uid anywhere.
        '';
      })
      (lib.filterAttrs (_: s: s.user == "") enabledSessions)

    # ── A LAYOUT THAT DOES NOT EXIST ──────────────────────────────────────────────────────────
    # Only meaningful when modules/layouts.nix is composed at all; a host that leaves output
    # arrangement to the compositor imports no layouts and names none.
    ++ lib.optionals layoutsComposed (lib.mapAttrsToList
      (name: s: {
        assertion = false;
        message = ''
          nixdesktop.sessions.${name}.layout names "${s.layout}", which `nixdesktop.layouts` does
          not declare. Declared layouts:
          ${if declaredLayouts == { } then "  (none)" else lib.concatMapStringsSep "\n" (n: "            - ${n}") (lib.attrNames declaredLayouts)}
        '';
      })
      (lib.filterAttrs (_: s: s.layout != null && !(declaredLayouts ? ${s.layout})) enabledSessions));

  config.warnings =
    # The probes' own report: nixhost IS composed here, but one of the two leaves this module
    # reads moved, was renamed, or was rejected by its own type. Silent in either direction
    # without this -- and the denied-list direction is the dangerous one, because an empty
    # complement reads exactly like "nothing to deny".
    (collectProbes [ environmentsProbe inventoryProbe ]).warnings

    # A session naming an environment nixhost does not declare. A WARNING rather than an
    # assertion, and only when the table is non-empty: an empty table legitimately means nixhost
    # is not composed on this host, while a populated table missing this one name is a typo or a
    # rename. The seated case is a hard failure anyway, via the permitted-devices assertion above.
    ++ lib.optionals (allEnvironments != { }) (lib.mapAttrsToList
      (name: s: ''
        nixdesktop.sessions.${name} names environment "${s.environment}", which nixhost does not
        declare on this host (declared: ${lib.concatStringsSep ", " (lib.attrNames allEnvironments)}).
        Its permittedDevices is therefore empty and every device in the inventory lands in
        deniedDevices.
      '')
      (lib.filterAttrs
        (_: s: s.environment != null && !(allEnvironments ? ${s.environment}))
        enabledSessions))

    # A claim naming a device the inventory does not contain. Deliberately NOT an assertion:
    # nixhost itself leaves "must a claim name a declared device" as an open question at the
    # owner, and this repo has no business answering it more strictly than the module that owns
    # the table. But it is worth saying, because such a device is permitted while being invisible
    # to the complement -- so the two lists disagree about how many devices exist.
    ++ lib.optionals (inventory != [ ]) (lib.concatLists (lib.mapAttrsToList
      (name: s:
        map
          (d: ''
            nixdesktop.sessions.${name} permits the device "${d}", which nixhost.resources.gpu does
            not list (it has: ${lib.concatStringsSep ", " inventory}). The claim comes from
            nixhost.environments."${toString s.environment}".resources.gpu; the inventory comes from
            nixgpu.stableDevicePaths.devices. One of the two is misspelled, or the inventory is
            incomplete -- and an incomplete inventory is what lets an undeclared device leak past
            niri's ignore list.
          '')
          (lib.filter (d: !(lib.elem d inventory)) s.permittedDevices))
      enabledSessions));
}
