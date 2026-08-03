{
  description = "nixdesktop — the compositor-neutral desktop policy and shared-component layer for a declarative, CPU-rendered Wayland desktop: the estate's monitor registry, its output layouts, its session instances, plus home-manager modules for the components around whichever compositor you run";

  # NO COMPOSITOR, NO DESKTOP SHELL, NO PACKAGE SET IS AN INPUT HERE. This flake generates config,
  # declares roles and declares identity/geometry, and all of that is pure Nix.
  #
  # NOT EVEN THE COMPOSITOR ITSELF IS AN INPUT. A compositor's own config module lives in its own
  # sibling repo (nixniri for niri, nixscroll for scroll, or any future compositor repo that speaks
  # the same `nixdesktop.want` / `nixdesktop.monitors` / `nixdesktop.layouts` contracts), keeping
  # this flake genuinely compositor-neutral rather than pulling in one compositor's config
  # generator by default — see profiles/desktop.nix and the README's "The split" section.
  #
  # In particular noctalia (a QML shell, supported by home/noctalia.nix) is NOT an input here. A
  # flake input is fetched whenever this flake is evaluated, so declaring it would put a QML shell
  # in the closure of every consumer — including the large majority running waybar, for whom it is
  # dead weight. home/noctalia.nix therefore supplies only the SUPPLEMENT (the EGL-vendor-ICD fix a
  # nix-built GPU client needs on a non-NixOS host, plus startup wiring); a consumer who wants
  # noctalia adds the upstream flake as their own input and imports both modules together:
  #
  #   imports = [ inputs.noctalia.homeModules.default inputs.nixdesktop.homeManagerModules.noctalia ];
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  # nixhost IS an input, for EXACTLY ONE THING: `lib.probeFact`/`lib.collectProbes` (its
  # `lib/facts.nix`). modules/session.nix reads two facts nixhost owns —
  # `nixhost.environments.<env>.resources.gpu.<device>.access` (the device CLAIM) and
  # `nixhost.resources.gpu` (the complete inventory the denied-list complement is computed over,
  # and — as of nixgpu's stable-device-paths work — the same mirror modules/launcher.nix reads its
  # `cardPath`/`renderPath`/`cardNamePath` values from). A bare `config.nixhost.environments or { }`
  # cannot tell "nixhost is not composed on this host" from "nixhost IS composed but that leaf moved or was
  # renamed", and the second one would empty the DENIED list silently — which reads exactly like
  # "nothing to deny" while letting a forbidden card leak into niri's enumeration. probeFact is the
  # family's one shared fix for that defect class; consuming it beats vendoring a second copy.
  #
  # THIS IS THE MECHANISM ONLY, NOT THE DATA. nixhost's own config is still read defensively, with
  # no `imports` of nixhost anywhere and no requirement that a consumer compose it at all — a host
  # without nixhost evaluates fine and simply permits nothing. `probeFact`/`collectProbes` are
  # closed over as plain function arguments below, never `_module.args`, so a consumer importing
  # `nixosModules.session` (or `nixosModules.launcher`) sees an ordinary module function and never
  # needs to know nixhost exists. Same pattern, same reasoning, as nixlxc's own single nixhost
  # input.
  inputs.nixhost = {
    url = "github:julian-corbet/nixhost-corbet-ch";
    inputs.nixpkgs.follows = "nixpkgs";
  };

  # system-manager IS an input, for exactly one thing too: `lib.makeSystemConfig`, so
  # checks/launcher.nix can build a REAL system-manager configuration and inspect the literal unit
  # text it renders — the same discipline checks/launcher.nix already applies to the NixOS plane
  # via `nixpkgs.lib.nixosSystem`, and the exact pattern nixram (a sibling repo with the identical
  # dual-plane shape) already uses for its own `checks/system-manager-eval-tests.nix`. Nothing
  # about the MODULES this repo ships (modules/session.nix, modules/launcher.nix) depends on this
  # input — `systemManagerModules.session`/`.launcher` are ordinary module values a consumer's own
  # `system-manager.lib.makeSystemConfig` call composes; this input exists purely so THIS repo's
  # own `nix flake check` can prove those values actually work against the real thing, not a stub
  # that "accepts anything" (see checks/launcher.nix's header for why a stub alone was previously
  # not enough).
  inputs.system-manager = {
    url = "github:numtide/system-manager";
    inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { self, nixpkgs, nixhost, system-manager }:
    let
      forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];

      # `probeFact`/`collectProbes` closed over BEFORE the module system ever sees the result — see
      # the input comment above. The exported value is a plain module function taking the usual
      # `{ lib, config, ... }`; nothing about consuming it changes.
      sessionModule = import ./modules/session.nix {
        inherit (nixhost.lib) probeFact collectProbes;
      };

      # Same closure, same reasoning, for modules/launcher.nix: it reads the identical
      # `nixhost.resources.gpu` mirror session.nix does (for `cardPath`/`renderPath`/`cardNamePath`
      # this time, rather than device names) through its own `lib.probeFact` call — see that
      # module's own header for why a second, independent probe call is preferable to threading
      # session.nix's result through as extra module state.
      #
      # `launcherModuleFor plane`, NOT a single `launcherModule` value, because modules/launcher.nix
      # itself is curried on `plane` ("nixos" | "system-manager") — see that file's own header
      # for the full reasoning (system-manager renders `systemd.services`/`PAMName=`/`DeviceAllow=`
      # identically to NixOS, proven live by `infra/hosts/archlxc/niri-session.nix`'s own
      # `niri-seat.service`, but has no `systemd.user.services` anywhere in its module tree — so the
      # one real divergence, `delivery = "headless"`, has to be selected before either module value
      # is handed to a consumer, never decided by a `config`-derived condition inside one shared
      # value). `plane` is closed over here, at the exact same point `probeFact`/`collectProbes`
      # already are, for the identical reason: a consumer importing `nixosModules.launcher` or
      # `systemManagerModules.launcher` sees an ordinary module function and never needs to know
      # this file exists, let alone that it is one file wearing two plane-specific hats.
      launcherModuleFor = plane: import ./modules/launcher.nix
        { inherit (nixhost.lib) probeFact collectProbes; }
        plane;
      launcherModuleNixos = launcherModuleFor "nixos";
      launcherModuleSystemManager = launcherModuleFor "system-manager";
    in
    {
      # ── POLICY ────────────────────────────────────────────────────────────────────────────
      # Compositor-neutral: declares which roles a desktop session wants filled — and, via the
      # `compositor` option, which compositor is in use at all — and publishes the result as the
      # read-only `nixdesktop.want` attrset. Installs nothing. A platform backend (nixarch's, for
      # Arch/CachyOS, or this repo's own `nixosModules.backend`) reads `nixdesktop.want` and
      # produces real packages.
      #
      # Exposed under both module classes because the two module systems that consume it differ
      # by host, and the profile itself is just options + a computed attrset — it touches
      # neither NixOS-specific nor system-manager-specific config. Import it wherever the
      # backend that reads it lives.
      systemManagerModules.desktop = ./profiles/desktop.nix;
      systemManagerModules.default = ./profiles/desktop.nix;
      nixosModules.desktop = ./profiles/desktop.nix;
      nixosModules.default = ./profiles/desktop.nix;

      # ── IDENTITY AND GEOMETRY ─────────────────────────────────────────────────────────────
      # The two tables the compositor repos read. Pure options and assertions — no `pkgs`, no
      # units, nothing platform-specific — so both are offered on BOTH planes, and that is not
      # symmetry for its own sake: the Arch boxes (archlxc, the elitebook) run system-manager and
      # have exactly the same monitors on exactly the same desks as the NixOS ones. A registry
      # that only existed on one plane would be re-typed on the other, which is the duplication
      # `monitors` exists to delete.
      #
      # `monitors` is FLEET-WIDE identity (a panel roams between hosts); `layouts` is per-host
      # arrangement (a desk does not). They are separate modules, not one, because a host that
      # addresses only connectors — a headless box, an evdi-only dock — legitimately wants the
      # second and not the first, and each reads the other defensively rather than importing it.
      nixosModules.monitors = ./modules/monitors.nix;
      nixosModules.layouts = ./modules/layouts.nix;
      # desktops: the per-machine identity-accent registry. Exported under all three plane names
      # for the same reason monitors/layouts are -- it is a plain option+assertion module with no
      # `pkgs` dependency and no plane-specific config, so the SAME file composes into a NixOS, a
      # system-manager or a home-manager evaluation unchanged. That is what makes it usable as a
      # cross-plane carrier at all: a consumer on the user plane (a compositor config) and one on
      # the system plane can both read the same table. See the module's own header.
      nixosModules.desktops = ./modules/desktops.nix;
      systemManagerModules.monitors = ./modules/monitors.nix;
      systemManagerModules.layouts = ./modules/layouts.nix;
      systemManagerModules.desktops = ./modules/desktops.nix;
      homeManagerModules.desktops = ./modules/desktops.nix;

      # ── SESSIONS ──────────────────────────────────────────────────────────────────────────
      # A session instance: this user, this compositor, delivered this way, on this seat, with
      # this device claim and this output layout. Every option here is DATA — a string, an enum, a
      # derived NAME list (`permittedDevices`/`deniedDevices`) — and every assertion is arithmetic
      # over that data (contested seats, an unresolvable environment, a headless session that
      # isn't pixman). None of it touches `pkgs`, `systemd`, or `users` at all, which is exactly
      # the same shape `monitors`/`layouts` above already have, and exactly why this is offered on
      # BOTH planes too: the Arch boxes (archlxc, the elitebook) declare sessions with precisely
      # the same `delivery`/`seat`/`environment` vocabulary as a NixOS host, and a registry that
      # only existed on one plane would force the other to re-type it.
      #
      # A PRIOR REVISION of this comment claimed sessions would "grow a system unit with PAMName=
      # / User= ... none of which system-manager can implement", and kept this NixOS-only on that
      # basis. That claim was about modules/launcher.nix's job (turning an instance into a running
      # unit), never about this module's own option surface, which was never anything but data —
      # and it was wrong about launcher.nix too: see that file's own header for the corrected,
      # source-read account of what system-manager actually supports. `nixdesktop.launcher` is
      # what actually starts a session and is what has the one real (headless-only) plane split;
      # `nixdesktop.sessions` itself needed no change at all.
      nixosModules.session = sessionModule;
      systemManagerModules.session = sessionModule;

      # ── LAUNCHER ──────────────────────────────────────────────────────────────────────────
      # Where a session instance above actually turns into a running unit — a system unit with
      # PAMName for `delivery = "seated"` (a true AUTOLOGIN, deliberately: no greeter runs first,
      # ever — see modules/launcher.nix's own header, "DESIGN A", for the operator's own decision
      # this rests on and what it costs), a `--user` unit for `delivery = "headless"`. See
      # modules/launcher.nix's own header for why this had to be its own module (three desktops on
      # this estate currently have three different, private, hand-written answers to exactly this
      # problem), for how it resolves `DeviceAllow=` as a plain, static Nix value from nixgpu's
      # stable device paths rather than mutating the unit at runtime, for why the compositor's own
      # `WLR_DRM_DEVICES` reads `cardNamePath` (colon-free) while `DeviceAllow=` itself still reads
      # `cardPath`, and for the two-plane split below. `nixdesktop.launcher.deviceFence` mirrors
      # the unit's own `DevicePolicy=`/`DeviceAllow=` a second time as read-only DATA, so a host or
      # a check can read the enforced policy without inspecting a rendered unit.
      #
      # BOTH PLANES, because the seated case (a SYSTEM unit — `systemd.services`, `PAMName=`,
      # `User=`, `DevicePolicy=`/`DeviceAllow=`) renders through the identical nixpkgs unit code on
      # system-manager as on NixOS — confirmed by reading numtide/system-manager's own
      # `nix/modules/systemd.nix`, not assumed, and proven live for months by
      # `infra/hosts/archlxc/niri-session.nix`'s own hand-written `niri-seat.service` on exactly
      # that plane. Only `delivery = "headless"` (a `--user` unit) has no system-manager
      # equivalent — its module tree has no `systemd.user.services`, or any per-user-manager unit
      # surface, anywhere — and modules/launcher.nix degrades that case to a named, loud build
      # failure on the system-manager plane rather than silently dropping the session. See that
      # file's own header and its `headlessUnsupportedAssertions` for the full account.
      nixosModules.launcher = launcherModuleNixos;
      systemManagerModules.launcher = launcherModuleSystemManager;

      # ── NIXOS BACKEND ─────────────────────────────────────────────────────────────────────
      # The NixOS half of the platform-backend split (nixarch ships the Arch/CachyOS half, in its
      # own repo — see modules/nixos-backend.nix's header for why this one, unlike that one, lives
      # here). Reads `nixdesktop.want` and resolves it into `environment.systemPackages` via
      # lib/nixos-roles.nix, including any compositor a consumer supplies through the backend's
      # own `extraCompositors` option (for a compositor with no nixpkgs package, e.g. scroll). Not
      # `.default`: a consumer must opt in explicitly, and `.default` stays the platform-neutral
      # policy profile above so importing it on a non-NixOS host (via `systemManagerModules.
      # default`) never drags a NixOS-only module along.
      nixosModules.backend = ./modules/nixos-backend.nix;

      # ── OO7 KEYRING: THE SYSTEM-LEVEL HALF ────────────────────────────────────────────────
      # `home/session.nix`'s own `nixdesktop.session.keyring.oo7` (a home-manager module) wires
      # the DAEMON unit and its `LoadCredentialEncrypted=`, but has no way to PROVISION that
      # credential (a root-run act) or to bootstrap a first keyring FILE from it (oo7-daemon 0.6.0
      # will not do so from a credential alone — see modules/oo7-credential.nix's and
      # modules/oo7-keyring-bootstrap.nix's own headers for the full, measured account). These two
      # modules are that missing system-level mechanism, split exactly where the NixOS and
      # Arch/system-manager planes genuinely cannot share one module and nowhere else:
      #
      #   - `oo7Credential` (this file's own credential-provisioning module) needs only
      #     `systemd.services` — a plain root oneshot, which renders identically on both planes
      #     (see nixosModules.launcher's own comment on this file, above, for the confirmed-not-
      #     assumed fact this rests on) — so it is exported to BOTH `nixosModules` and
      #     `systemManagerModules`, the same shared-value pattern `monitors`/`layouts`/`session`
      #     above already use.
      #   - `oo7KeyringBootstrap` needs `systemd.user.services` — a `--user` unit — which NixOS can
      #     render directly at system level (no home-manager required; `hosts/nixnas-devhome.nix`
      #     in the infra checkout is the live proof) but system-manager structurally cannot render
      #     AT ALL (modules/launcher.nix's own header states this as a read-from-source fact: its
      #     module tree has no `systemd.user.services` anywhere). So this one is `nixosModules`
      #     ONLY — a system-manager/Arch host reaches for `home/session.nix`'s own
      #     `keyring.oo7.credential.bootstrap` convenience instead, the identical mechanism
      #     (same measured facts, same `oo7-cli ... repair` invocation shape) wired through
      #     home-manager, the only path that plane actually has to a `--user` unit. Two module-
      #     system entry points sharing one set of facts, not two independently reinvented shapes.
      nixosModules.oo7Credential = ./modules/oo7-credential.nix;
      systemManagerModules.oo7Credential = ./modules/oo7-credential.nix;
      nixosModules.oo7KeyringBootstrap = ./modules/oo7-keyring-bootstrap.nix;

      # ── CONFIG GENERATION ─────────────────────────────────────────────────────────────────
      # home-manager modules that write real dotfiles. None of these install packages either:
      # they assume the named binaries exist, which is the backend's job. None of these is a
      # compositor's own config module — that job belongs to sibling repos like nixniri.
      #
      # `homeManagerModules`, not `homeModules`: home-manager upstream has moved to the shorter
      # name, but every other project in this family (nixarch, nixniri, nixsh, nixremote) exports
      # `homeManagerModules`, and a consumer importing several of them at once should not have to
      # remember which one is spelled differently. Family consistency wins over upstream fashion.
      homeManagerModules = {
        # Session components as systemd user services rather than a compositor's own
        # `spawn-at-startup`-style lines. Not a style preference: that kind of line runs
        # once at session start and cannot fire into a session that is already
        # running, so a `home-manager switch` silently fails to converge the
        # session and needs a re-login. It also has no ordering primitive, which
        # is why real configs end up writing `sleep 1 && waybar`.
        session = ./home/session.nix;

        # kanshi profiles generated from `nixdesktop.layouts`, for the one thing a compositor's own
        # output config cannot express: switching an output off BECAUSE others are present. Needs
        # `session` composed alongside it (it declares its daemon through
        # `nixdesktop.session.services`), and needs the compositor's own `nixdesktop.layout` left
        # null on the same host -- see that file's header on why exactly one owner per output.
        kanshi = ./home/kanshi.nix;

        waybar = ./home/waybar.nix;
        mako = ./home/mako.nix;
        swaylock = ./home/swaylock.nix;
        nwgBar = ./home/nwg-bar.nix;
        eww = ./home/eww.nix;

        # Supplement only — see the input comment above. Import alongside
        # `noctalia.homeModules.default` from noctalia's own flake (theirs, not ours — noctalia
        # is an unrelated upstream project and uses the short spelling).
        noctalia = ./home/noctalia.nix;

        # The `nixdesktop.startup` contract only — see home/startup.nix's own header. Exported
        # standalone (not folded into `session` or `noctalia`) so a compositor module such as
        # nixniri can depend on the contract alone, without pulling in this repo's systemd-service
        # or noctalia-specific machinery. `session` and `noctalia` both import it themselves too,
        # so a consumer who already has either need not add this on top.
        startup = ./home/startup.nix;

        # NO `default` HERE, DELIBERATELY. home/*.nix is a set of independent, separately opt-in
        # components (a bar, a notifier, a session-service layer, a startup contract), none of
        # which is "the" module a generic consumer wants by default. Picking one anyway (say,
        # `session`, since it is the most broadly useful glue) would misrepresent it as the repo's
        # primary artifact for a consumer who only wants, say, `mako`. Every other module class
        # above still gets its `.default` (the policy profile), so this omission is scoped to
        # `homeManagerModules` only.
      };

      # ── CHECKS ────────────────────────────────────────────────────────────────────────────
      # `nix flake check` does NOT evaluate `homeManagerModules` — it lists them as unchecked and
      # moves on. Everything under home/ is therefore untested by default, which matters little
      # for a module that only renders an attrset a consumer supplied, and matters a great deal for
      # home/session.nix, which assembles the swayidle invocation itself with real branching logic.
      #
      # `nixosModules`/`systemManagerModules` are not evaluated by `nix flake check` either — it
      # only type-checks that they ARE modules. So the tables below (monitors, layouts, sessions,
      # launcher) would ship completely unproven without these: every one of them is assertions
      # over derived arithmetic, or — for `launcher` — a real rendered systemd unit, which is
      # precisely the code that fails quietly.
      checks = forAllSystems (system:
        let pkgs = nixpkgs.legacyPackages.${system}; in
        {
          idle-assembly = import ./checks/idle-assembly.nix { inherit pkgs; };
          # Same shape and same reasoning as idle-assembly above (a home-manager module `nix flake
          # check` never evaluates on its own) -- proves the keyring PROVIDER assembly instead:
          # oo7 vs gnome-keyring render the right (verified-not-assumed) Type=/Restart=, two
          # providers enabled at once is a build failure, and the credential wiring
          # (`LoadCredentialEncrypted=`) appears iff `oo7.credential.enable` does.
          keyring = import ./checks/keyring.nix { inherit pkgs; };
          # Proves the SYSTEM-level half of the same oo7 story keyring.nix proves the home-manager
          # half of: `modules/oo7-credential.nix` (shared nixos+system-manager) and
          # `modules/oo7-keyring-bootstrap.nix` (nixos-only) — see that file's own header for why
          # the split falls exactly there and nowhere else.
          oo7-provisioning = import ./checks/oo7-provisioning.nix { inherit pkgs; };
          # Same shape and reasoning as idle-assembly/keyring above -- proves the `patchbay`
          # component instead: one unit (not a pair), Restart=always (not the class default,
          # deliberately the opposite of keyring/lock-at-start's restart=no), and the
          # StatusNotifierItem-host warning that fires iff `trayHostAvailable = false`.
          patchbay = import ./checks/patchbay.nix { inherit pkgs; };
          monitor-identity = import ./checks/monitor-identity.nix { inherit pkgs; };
          layout-geometry = import ./checks/layout-geometry.nix { inherit pkgs; };
          # `sessionModule` is passed already closed over nixhost's `probeFact`/`collectProbes`,
          # so the checks exercise the module exactly as a consumer imports it -- decoys included.
          session-devices = import ./checks/session-devices.nix { inherit pkgs sessionModule; };
          # Composed with the same `sessionModule` and both already-closed, plane-specific
          # `launcherModule*` values, for the same reason: modules/launcher.nix reads
          # `permittedDevices`/`deniedDevices`, which only exist once session.nix has derived them.
          # `nixpkgs` itself (not just `pkgs`) is threaded through too: this check's real-
          # `lib.nixosSystem` proof (see that file's own header) needs `nixpkgs.lib.nixosSystem`,
          # not only `legacyPackages.${system}` -- and `system-manager.lib` is threaded through for
          # the mirror-image real-`makeSystemConfig` proof on the system-manager plane.
          launcher = import ./checks/launcher.nix {
            inherit pkgs sessionModule nixpkgs system;
            launcherModuleNixos = launcherModuleNixos;
            launcherModuleSystemManager = launcherModuleSystemManager;
            systemManagerLib = system-manager.lib;
          };
        });

      formatter = forAllSystems (system: nixpkgs.legacyPackages.${system}.nixpkgs-fmt);
    };
}
