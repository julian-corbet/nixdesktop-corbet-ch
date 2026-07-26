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
  #   imports = [ inputs.noctalia.homeModules.default inputs.nixdesktop.homeModules.noctalia ];
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
      nixosModules.niri-desktop = ./profiles/niri-desktop.nix;

      # ── CONFIG GENERATION ─────────────────────────────────────────────────────────────────
      # home-manager modules that write real dotfiles. None of these install packages either:
      # they assume the named binaries exist, which is the backend's job.
      homeModules = {
        niri = ./home/niri.nix;
        waybar = ./home/waybar.nix;
        mako = ./home/mako.nix;
        swaylock = ./home/swaylock.nix;
        nwgBar = ./home/nwg-bar.nix;
        eww = ./home/eww.nix;

        # Supplement only — see the input comment above. Import alongside
        # `noctalia.homeModules.default` from noctalia's own flake.
        noctalia = ./home/noctalia.nix;
      };

      formatter = forAllSystems (system: nixpkgs.legacyPackages.${system}.nixpkgs-fmt);
    };
}
