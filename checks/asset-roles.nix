# The five roles this profile fills with PACKAGES AND NOTHING ELSE — `syntheticTyping`,
# `iconThemes`, `inputAutomation`, `brightness` and `wallpapers` — proven against the real NixOS
# backend, in both directions.
#
# WHY THEY SHARE A FILE. checks/file-manager.nix and checks/input-substrate.nix each exist because
# their role's package is only half the mechanism on NixOS: the other half is a nixpkgs option
# (`programs.thunar.enable`, `services.keyd.enable`) that the package alone does not imply, and
# forgetting it produces the silent failure those files are built to catch. None of these five is
# like that. `wtype` is an unprivileged Wayland client, an icon theme and a wallpaper set are
# directories of files; on both platforms the package IS the whole mechanism, and there is no
# option half to forget. What is worth proving about them is therefore the same single question —
# does the role reach `environment.systemPackages`, and does the unfilled role reach nothing — so
# they are tested together rather than in five files that would differ only in a string.
#
# `brightness` LOOKS LIKE THE EXCEPTION AND IS NOT, which is exactly why it is proven here rather
# than in a file of its own. A reader who knows keyd's story goes looking for the option half, and
# on NixOS there used to be one: `hardware.brightnessctl` installed the package's udev rules. It was
# REMOVED, because the tool now takes logind's `SetBrightness` route and needs no rules — so the
# missing option is a settled decision rather than an oversight, and the package is once again the
# whole mechanism. See lib/nixos-roles.nix's own entry for the full account.
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

  # `compositor` has no default and is mandatory the moment the profile is enabled. It is session
  # metadata only; a compositor integration owns the runtime package.
  desktopOn = compositor: extra:
    { nixdesktop.desktop = { enable = true; inherit compositor; } // extra; };
  desktop = desktopOn "niri";

  typing = configFor (desktop { syntheticTyping = true; });
  automating = configFor (desktop { inputAutomation = true; });
  themed = configFor (desktop { iconThemes = [ "papirus-icon-theme" ]; });
  # cosmic-wallpapers is a real top-level nixpkgs attribute and an image set and nothing else — the
  # positive case has to be a name THIS platform carries, which the one an Arch/CachyOS host really
  # sets deliberately is not (see the negative case below).
  wallpapered = configFor (desktop { wallpapers = [ "cosmic-wallpapers" ]; });
  brightened = configFor (desktop { brightness = "brightnessctl"; });
  osdOnly = configFor (desktop { osd = "swayosd"; });
  unfilled = configFor (desktop { });
  disabled = configFor { nixdesktop.desktop = { enable = false; compositor = "niri"; }; };

  # `pname`, not `name`: the version suffix is exactly the kind of detail that makes a prefix match
  # quietly stop matching after a bump.
  pnames = cfg: map (p: p.pname or p.name or "") cfg.environment.systemPackages;
  has = n: cfg: lib.elem n (pnames cfg);

  # THE ASSET ROLES THAT RESOLVE FREE-FORM NAMES -- `iconThemes` and `wallpapers` -- share one
  # negative-case harness, because they share the failure. Both go through `pkgs.${name}`, so a name
  # this platform does not carry must fail the evaluation outright rather than resolve to nothing:
  # a host whose declared theme is silently absent gets a session that falls back to hicolor with no
  # error anywhere, and a host whose declared wallpapers are silently absent gets a picker pointed
  # at an empty directory. `evalThrows` over a stub is enough HERE (unlike every assertion below it)
  # because what is under test is the throw itself, not what a successful resolution produces.
  assetEval = settings: support.evalThrows [
    { options.environment.systemPackages = lib.mkOption { type = lib.types.listOf lib.types.anything; default = [ ]; }; }
    ../profiles/desktop.nix
    ../modules/nixos-backend.nix
    {
      nixdesktop.nixosBackend.enable = true;
      nixdesktop.desktop = { enable = true; compositor = "niri"; } // settings;
    }
  ];

  themeEval = names: assetEval { iconThemes = names; };

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

  # THE SAME THROW FOR THE WALLPAPER SET THE ARCH SIDE OF THIS PROJECT ACTUALLY INSTALLS. Wallpaper
  # packages are named after the distribution that ships them: `cachyos-wallpapers` is an ordinary
  # package name through the Arch backend and is no nixpkgs attribute at all, so the identical
  # policy value has to fail here. Pinned rather than left to chance because it is the concrete
  # portability limit the option's own documentation promises, and because "installs nothing on
  # NixOS" would be the tempting, wrong alternative.
  foreignWallpapers = assetEval { wallpapers = [ "cachyos-wallpapers" ]; };

  results = {
    "the selected compositor is metadata, never a platform package role" =
      !(unfilled.nixdesktop.want ? compositor)
      && !(has "niri" unfilled);

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

    # ── wallpapers ────────────────────────────────────────────────────────────────────────────
    "wallpapers installs the named image set" =
      has "cosmic-wallpapers" wallpapered;

    # IMAGES, NOT A DAEMON — the line this role exists to draw, asserted rather than only written
    # down. Painting an image onto an output takes a layer-shell client (`swaybg` and its kin) that
    # the COMPOSITOR's own repo owns and spawns by name; installing one here would put a
    # compositor-specific process into a compositor-neutral profile and fight the copy that repo
    # already installs.
    "...and no wallpaper daemon, which belongs to the compositor's own repo" =
      !(has "swaybg" wallpapered);

    # The empty default is what every existing consumer evaluates, same as `iconThemes` above.
    "an empty wallpapers list installs no images" =
      !(has "cosmic-wallpapers" unfilled);

    "a wallpaper set that exists only on another distribution fails the evaluation" =
      foreignWallpapers;

    # ── brightness ────────────────────────────────────────────────────────────────────────────
    "brightness = brightnessctl installs the backlight setter" =
      has "brightnessctl" brightened;

    # THE SILENT FAILURE THE ROLE EXISTS FOR: an OSD is not a brightness tool, it spawns one. A
    # session with swayosd and no brightness role has working volume keys and dead brightness keys
    # and logs nothing about it. (On NixOS swayosd's own derivation wraps brightnessctl onto ITS OWN
    # PATH, so the OSD's own adjustment still works — which is exactly why "the bar moved" proves
    # nothing about the session's PATH, and why this assertion is about the package list.)
    "an osd on its own installs no brightness setter" =
      !(has "brightnessctl" osdOnly);

    "an unfilled brightness role installs no setter" =
      !(has "brightnessctl" unfilled);

    # THE OPTION THIS ROLE MUST NOT GROW, the mirror image of `inputAutomation`'s assertion above.
    # nixpkgs REMOVED `hardware.brightnessctl` — the module that installed this package's udev
    # rules — because the logind path needs none, and this backend takes that at its word. An edit
    # that "completed" the role by feeding the package to `services.udev.packages` would hand a
    # group write access to every backlight on the machine to fix a problem that is not there.
    "...and the filled role wires no udev rules, which the logind path does not need" =
      !(lib.any (p: (p.pname or "") == "brightnessctl") brightened.services.udev.packages);

    # ── The profile off entirely ──────────────────────────────────────────────────────────────
    #
    # `nixdesktop.want` is `{}` here, so `packagesFor` short-circuits before any of the five is
    # read — including the compositor, which is what makes brightnessctl absent here despite the
    # niri bundle two assertions up.
    "a disabled profile installs none of them" =
      !(has "wtype" disabled)
      && !(has "ydotool" disabled)
      && !(has "papirus-icon-theme" disabled)
      && !(has "cosmic-wallpapers" disabled)
      && !(has "brightnessctl" disabled);
  };
in
report "asset-roles" results
