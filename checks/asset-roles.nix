# The two roles this profile added that produce nothing but PACKAGES — `syntheticTyping` and
# `iconThemes` — proven against the real NixOS backend, in both directions.
#
# WHY THEY SHARE A FILE. checks/file-manager.nix and checks/input-substrate.nix each exist because
# their role's package is only half the mechanism on NixOS: the other half is a nixpkgs option
# (`programs.thunar.enable`, `services.keyd.enable`) that the package alone does not imply, and
# forgetting it produces the silent failure those files are built to catch. Neither of these two is
# like that. `wtype` is an unprivileged Wayland client and an icon theme is a directory of files;
# on both platforms the package IS the whole mechanism, and there is no option half to forget. What
# is worth proving about them is therefore the same single question — does the role reach
# `environment.systemPackages`, and does the unfilled role reach nothing — so they are tested
# together rather than in two files that would differ only in a string.
#
# `lib.evalModules` + a stub would NOT do here, for checks/file-manager.nix's reason: what is under
# test is the package list a real NixOS evaluation ends up with, and a stub declaring
# `environment.systemPackages` as `listOf anything` would accept the write without ever forcing the
# derivations behind it. `iconThemes` in particular resolves free-form strings through
# `pkgs.${name}`, so forcing is the entire point — an unresolvable name must be an error rather
# than a silently absent theme.
{ pkgs, nixpkgs, system, lib ? pkgs.lib }:
let
  support = import ./support.nix { inherit pkgs lib; };
  inherit (support) report;

  configFor = settings: (nixpkgs.lib.nixosSystem {
    inherit system;
    modules = [
      ../profiles/desktop.nix
      ../modules/nixos-backend.nix
      {
        nixdesktop.nixosBackend.enable = true;
        system.stateVersion = "24.11";
        boot.isContainer = true;
      }
      settings
    ];
  }).config;

  # `compositor` has no default and is mandatory the moment the profile is enabled. Which one is
  # irrelevant to both roles under test.
  desktop = extra: { nixdesktop.desktop = { enable = true; compositor = "niri"; } // extra; };

  typing = configFor (desktop { syntheticTyping = true; });
  themed = configFor (desktop { iconThemes = [ "papirus-icon-theme" ]; });
  unfilled = configFor (desktop { });
  disabled = configFor { nixdesktop.desktop = { enable = false; compositor = "niri"; }; };

  # `pname`, not `name`: the version suffix is exactly the kind of detail that makes a prefix match
  # quietly stop matching after a bump.
  pnames = cfg: map (p: p.pname or p.name or "") cfg.environment.systemPackages;
  has = n: cfg: lib.elem n (pnames cfg);

  # A theme name that is not a nixpkgs attribute. `iconThemes` resolves through `pkgs.${name}`, so
  # this must fail the evaluation outright rather than resolve to nothing -- a host whose declared
  # theme is silently absent gets a session that falls back to hicolor and no error anywhere.
  unresolvableTheme = support.evalThrows [
    { options.environment.systemPackages = lib.mkOption { type = lib.types.listOf lib.types.anything; default = [ ]; }; }
    ../profiles/desktop.nix
    ../modules/nixos-backend.nix
    {
      nixdesktop.nixosBackend.enable = true;
      nixdesktop.desktop = { enable = true; compositor = "niri"; iconThemes = [ "definitely-not-a-nixpkgs-attribute" ]; };
    }
  ];

  results = {
    # ── syntheticTyping ───────────────────────────────────────────────────────────────────────
    "syntheticTyping installs the Wayland typing client" =
      has "wtype" typing;

    # THE ROLE BOUNDARY, and the reason this capability is not another entry in `input`'s enum.
    # The two are about keys and are otherwise unrelated: one is a compositor client injecting
    # events through virtual-keyboard-v1, the other a daemon rewriting them below the compositor.
    # A regression that merged them would show up here as a remapping daemon arriving with a
    # typing tool nobody connected it to.
    "...and does not drag in the input substrate, which is a different layer entirely" =
      !typing.services.keyd.enable && !(has "keyd" typing);

    # ...and the converse: filling `input` must not install a keystroke injector.
    "the input role does not install a typing client either" =
      !(has "wtype" (configFor (desktop { input = "keyd"; })));

    "an unfilled syntheticTyping installs no keystroke injector" =
      !(has "wtype" unfilled);

    # ── iconThemes ────────────────────────────────────────────────────────────────────────────
    "iconThemes installs the named theme package" =
      has "papirus-icon-theme" themed;

    # INSTALLING IS NOT SELECTING: the option must not write a theme NAME anywhere. Nothing in this
    # backend sets `gtk-icon-theme-name` or its Qt/cursor counterparts, and a regression that
    # started doing so would silently override a consumer's own home-manager `gtk` block.
    "...and selects nothing: no session variable names a theme" =
      !(themed.environment.sessionVariables ? GTK_ICON_THEME_NAME)
      && !(themed.environment.sessionVariables ? XCURSOR_THEME);

    # The empty default is what every existing consumer evaluates. A regression that installed a
    # default theme would put an opinionated asset on every desktop in the family.
    "an empty iconThemes installs no theme at all" =
      !(has "papirus-icon-theme" unfilled);

    "an unresolvable theme name fails the evaluation rather than resolving to nothing" =
      unresolvableTheme;

    # ── The profile off entirely ──────────────────────────────────────────────────────────────
    #
    # `nixdesktop.want` is `{}` here, so `packagesFor` short-circuits before either role is read.
    "a disabled profile installs neither" =
      !(has "wtype" disabled) && !(has "papirus-icon-theme" disabled);
  };
in
report "asset-roles" results
