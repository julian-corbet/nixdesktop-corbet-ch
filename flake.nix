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
  # `nixhost.resources.gpu` (the complete inventory the denied-list complement is computed over).
  # A bare `config.nixhost.environments or { }` cannot tell "nixhost is not composed on this host"
  # from "nixhost IS composed but that leaf moved or was renamed", and the second one would empty
  # the DENIED list silently — which reads exactly like "nothing to deny" while letting a
  # forbidden card leak into niri's enumeration. probeFact is the family's one shared fix for that
  # defect class; consuming it beats vendoring a second copy.
  #
  # THIS IS THE MECHANISM ONLY, NOT THE DATA. nixhost's own config is still read defensively, with
  # no `imports` of nixhost anywhere and no requirement that a consumer compose it at all — a host
  # without nixhost evaluates fine and simply permits nothing. `probeFact`/`collectProbes` are
  # closed over as plain function arguments below, never `_module.args`, so a consumer importing
  # `nixosModules.session` sees an ordinary module function and never needs to know nixhost exists.
  # Same pattern, same reasoning, as nixlxc's own single nixhost input.
  inputs.nixhost = {
    url = "github:julian-corbet/nixhost-corbet-ch";
    inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { self, nixpkgs, nixhost }:
    let
      forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];

      # `probeFact`/`collectProbes` closed over BEFORE the module system ever sees the result — see
      # the input comment above. The exported value is a plain module function taking the usual
      # `{ lib, config, ... }`; nothing about consuming it changes.
      sessionModule = import ./modules/session.nix {
        inherit (nixhost.lib) probeFact collectProbes;
      };
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
      systemManagerModules.monitors = ./modules/monitors.nix;
      systemManagerModules.layouts = ./modules/layouts.nix;

      # ── SESSIONS ──────────────────────────────────────────────────────────────────────────
      # NixOS plane only, deliberately, and this is the one asymmetry above. A session is an
      # instance that will grow a real system unit with `PAMName=` + `User=` (the only shape that
      # can ever be seated — a `--user` unit cannot, because seating is cgroup-structural), plus
      # `DevicePolicy=strict`/`DeviceAllow=` enforcement. None of that has a system-manager
      # equivalent, and exporting the option surface onto a plane that can never implement it
      # would be an invitation to declare something that silently does nothing. The Arch hosts get
      # `monitors` and `layouts`, which is exactly the part that is platform-neutral.
      nixosModules.session = sessionModule;

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
      # only type-checks that they ARE modules. So the three tables below (monitors, layouts,
      # sessions) would ship completely unproven without these: every one of them is assertions
      # over derived arithmetic, which is precisely the code that fails quietly.
      checks = forAllSystems (system:
        let pkgs = nixpkgs.legacyPackages.${system}; in
        {
          idle-assembly = import ./checks/idle-assembly.nix { inherit pkgs; };
          monitor-identity = import ./checks/monitor-identity.nix { inherit pkgs; };
          layout-geometry = import ./checks/layout-geometry.nix { inherit pkgs; };
          # `sessionModule` is passed already closed over nixhost's `probeFact`/`collectProbes`,
          # so the checks exercise the module exactly as a consumer imports it -- decoys included.
          session-devices = import ./checks/session-devices.nix { inherit pkgs sessionModule; };
        });

      formatter = forAllSystems (system: nixpkgs.legacyPackages.${system}.nixpkgs-fmt);
    };
}
