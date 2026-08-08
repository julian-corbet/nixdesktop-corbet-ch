# The three roles this profile added that produce nothing but PACKAGES — `syntheticTyping`,
# `iconThemes` and `inputAutomation` — proven against the real NixOS backend, in both directions.
#
# WHY THEY SHARE A FILE. checks/file-manager.nix and checks/input-substrate.nix each exist because
# their role's package is only half the mechanism on NixOS: the other half is a nixpkgs option
# (`programs.thunar.enable`, `services.keyd.enable`) that the package alone does not imply, and
# forgetting it produces the silent failure those files are built to catch. None of these three is
# like that. `wtype` is an unprivileged Wayland client and an icon theme is a directory of files;
# on both platforms the package IS the whole mechanism, and there is no option half to forget. What
# is worth proving about them is therefore the same single question — does the role reach
# `environment.systemPackages`, and does the unfilled role reach nothing — so they are tested
# together rather than in three files that would differ only in a string.
#
# `inputAutomation` IS THE NEAR MISS, and it is here rather than beside the input substrate for a
# precise reason. Its package is genuinely a partial answer on NixOS — `programs.ydotool.enable`
# supplies the group and the `/dev/uinput` access that the derivation does not — but this profile
# deliberately does NOT wire that option (it also starts a standing input-injection daemon; see
# lib/nixos-roles.nix's own entry). So what the role does is install a package and nothing else,
# exactly like the two above it, and what has to be proven is exactly the same question. The
# assertion that it wires no option is part of that proof rather than an afterthought: a later edit
# that "completed" the role by turning `programs.ydotool.enable` on would start a daemon nobody
# asked for, and it must fail here.
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
  automating = configFor (desktop { inputAutomation = true; });
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
  themeEval = names: support.evalThrows [
    { options.environment.systemPackages = lib.mkOption { type = lib.types.listOf lib.types.anything; default = [ ]; }; }
    ../profiles/desktop.nix
    ../modules/nixos-backend.nix
    {
      nixdesktop.nixosBackend.enable = true;
      nixdesktop.desktop = { enable = true; compositor = "niri"; iconThemes = names; };
    }
  ];

  unresolvableTheme = themeEval [ "definitely-not-a-nixpkgs-attribute" ];

  # THE SAME THROW FOR A PACKAGE THAT REALLY EXISTS, which is the case worth pinning because it is
  # the one that surprises people. `iconThemes` takes a single ATTRIBUTE, never a path, so a set
  # that nixpkgs keeps nested is out of reach here: KDE's Breeze icons are `kdePackages.breeze-icons`
  # and there is no top-level `breeze-icons`, so this name throws exactly like the nonsense one
  # above. That is deliberate rather than a gap -- a backend that split names on dots and walked
  # into attrsets would be inventing a second package language beside nixpkgs' own -- and the
  # option's own documentation promises this behaviour, so a later "helpful" resolver has to fail
  # here. The Arch backend has no such limit: `breeze-icons` is an ordinary pacman name in `extra`,
  # which is precisely the platform asymmetry that makes these names the consumer's problem.
  nestedAttrTheme = themeEval [ "breeze-icons" ];

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

    # ── inputAutomation ───────────────────────────────────────────────────────────────────────
    "inputAutomation installs the uinput automation tool" =
      has "ydotool" automating;

    # THE ROLE THIS ONE MUST NOT BECOME. `programs.ydotool.enable` is the option that would make
    # the tool actually work on NixOS, and turning it on also runs `ydotoold` — a standing process
    # able to synthesize input into every window on the seat. This profile installs the package and
    # stops there, deliberately, so that a consumer decides whether that daemon exists. A later
    # edit "completing" the role has to fail right here.
    "...and wires no option, so no input-injection daemon is started on a consumer's behalf" =
      !(automating.programs.ydotool.enable or false);

    # The two neighbouring key-related roles, neither of which this one is. Filling it must not
    # drag in the remapping daemon below the compositor, nor the protocol-level typing client that
    # covers a strict subset of what it does.
    "...and pulls in neither the input substrate nor the typing client" =
      !automating.services.keyd.enable
      && !(has "keyd" automating)
      && !(has "wtype" automating);

    # ...and the converse, which is what stops the two from silently merging into one role: asking
    # for text-into-the-focused-window must not install a uinput writer.
    "syntheticTyping does not install the uinput automation tool either" =
      !(has "ydotool" typing);

    "an unfilled inputAutomation installs no automation tool" =
      !(has "ydotool" unfilled);

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

    "...and so does a real package nixpkgs keeps nested, because a name here is never a path" =
      nestedAttrTheme;

    # ── The profile off entirely ──────────────────────────────────────────────────────────────
    #
    # `nixdesktop.want` is `{}` here, so `packagesFor` short-circuits before any of the three is
    # read.
    "a disabled profile installs none of them" =
      !(has "wtype" disabled)
      && !(has "ydotool" disabled)
      && !(has "papirus-icon-theme" disabled);
  };
in
report "asset-roles" results
