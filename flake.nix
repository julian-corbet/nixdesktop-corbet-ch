{
  description = "nixdesktop — the compositor-neutral desktop policy and shared-component layer for a declarative, CPU-rendered Wayland desktop, as home-manager modules plus a platform-neutral policy profile";

  # DELIBERATELY ONE INPUT. This flake pulls no desktop shell, no compositor, no package set —
  # it generates config and declares roles, and both of those are pure Nix.
  #
  # NOT EVEN THE COMPOSITOR ITSELF IS AN INPUT. A compositor's own config module lives in its own
  # sibling repo (nixniri for niri, nixscroll for scroll, or any future compositor repo that speaks
  # the same `nixdesktop.want.compositor` contract), keeping this flake genuinely
  # compositor-neutral rather than pulling in one compositor's config generator by default — see
  # profiles/desktop.nix and the README's "The split" section.
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

  outputs = { self, nixpkgs }:
    let
      forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];
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
      # Scoped to that assembly rather than the whole session layer: it is the one place here with
      # real branching logic and a silent failure mode (a dropped suspend action, or a lockCommand
      # that reaches three of its four positions, breaks quietly at runtime and only at 3 a.m.).
      checks = forAllSystems (system: {
        idle-assembly = import ./checks/idle-assembly.nix {
          pkgs = nixpkgs.legacyPackages.${system};
        };
      });

      formatter = forAllSystems (system: nixpkgs.legacyPackages.${system}.nixpkgs-fmt);
    };
}
