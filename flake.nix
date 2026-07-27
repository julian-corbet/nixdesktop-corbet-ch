{
  description = "nixdesktop — a declarative, CPU-rendered Wayland desktop (niri), as home-manager modules plus a platform-neutral policy profile";

  # DELIBERATELY ONE INPUT. This flake pulls no desktop shell, no compositor, no package set —
  # it generates config and declares roles, and both of those are pure Nix.
  #
  # In particular noctalia (a QML shell, supported by home/noctalia.nix) is NOT an input here,
  # though nixarch carried it as one while these modules lived there. A flake input is fetched
  # whenever this flake is evaluated, so declaring it would put a QML shell in the closure of
  # every consumer — including the large majority running waybar, for whom it is dead weight.
  # home/noctalia.nix therefore supplies only the SUPPLEMENT (the EGL-vendor-ICD fix a nix-built
  # GPU client needs on a non-NixOS host, plus startup wiring); a consumer who wants noctalia
  # adds the upstream flake as their own input and imports both modules together:
  #
  #   imports = [ inputs.noctalia.homeModules.default inputs.nixdesktop.homeManagerModules.noctalia ];
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];
    in
    {
      # ── POLICY ────────────────────────────────────────────────────────────────────────────
      # Platform-neutral: declares which roles a niri session wants filled and publishes the
      # result as the read-only `nixdesktop.want` attrset. Installs nothing. A platform backend
      # (nixarch's, for Arch/CachyOS) reads `nixdesktop.want` and produces real packages.
      #
      # Exposed under both module classes because the two module systems that consume it differ
      # by host, and the profile itself is just options + a computed attrset — it touches
      # neither NixOS-specific nor system-manager-specific config. Import it wherever the
      # backend that reads it lives.
      systemManagerModules.niri-desktop = ./profiles/niri-desktop.nix;
      systemManagerModules.default = ./profiles/niri-desktop.nix;
      nixosModules.niri-desktop = ./profiles/niri-desktop.nix;
      nixosModules.default = ./profiles/niri-desktop.nix;

      # ── NIXOS BACKEND ─────────────────────────────────────────────────────────────────────
      # The NixOS half of the platform-backend split (nixarch ships the Arch/CachyOS half, in its
      # own repo — see modules/nixos-backend.nix's header for why this one, unlike that one, lives
      # here). Reads `nixdesktop.want` and resolves it into `environment.systemPackages` via
      # lib/nixos-roles.nix. Not `.default`: a consumer must opt in explicitly, and `.default`
      # stays the platform-neutral policy profile above so importing it on a non-NixOS host (via
      # `systemManagerModules.default`) never drags a NixOS-only module along.
      nixosModules.backend = ./modules/nixos-backend.nix;

      # ── CONFIG GENERATION ─────────────────────────────────────────────────────────────────
      # home-manager modules that write real dotfiles. None of these install packages either:
      # they assume the named binaries exist, which is the backend's job.
      #
      # `homeManagerModules`, not `homeModules`: home-manager upstream has moved to the shorter
      # name, but every other project in this family (nixarch, nixsh, nixremote) exports
      # `homeManagerModules`, and a consumer importing four of them at once should not have to
      # remember which one is spelled differently. Family consistency wins over upstream fashion.
      homeManagerModules = {
        niri = ./home/niri.nix;

        # Session components as systemd user services rather than niri
        # `spawn-at-startup` lines. Not a style preference: spawn-at-startup runs
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

        # niri is the module this project exists for; everything else decorates it.
        default = ./home/niri.nix;
      };

      formatter = forAllSystems (system: nixpkgs.legacyPackages.${system}.nixpkgs-fmt);
    };
}
