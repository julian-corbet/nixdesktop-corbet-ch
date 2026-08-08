# The two roles this profile fills with nothing but a PACKAGE — `syntheticTyping` and
# `inputAutomation` — proven against the real NixOS backend, in both directions.
#
# WHY THEY SHARE A FILE. checks/file-manager.nix and checks/input-substrate.nix each exist because
# their role's package is only half the mechanism on NixOS: the other half is a nixpkgs option
# (`programs.thunar.enable`, `services.keyd.enable`) that the package alone does not imply, and
# forgetting it produces the silent failure those files are built to catch. Neither of these two is
# like that. `wtype` is an unprivileged Wayland client, so the package IS the whole mechanism and
# there is no option half to forget. What is worth proving about them is therefore the same single
# question — does the role reach `environment.systemPackages`, and does the unfilled role reach
# nothing — so they are tested together rather than in two files that would differ only in a string.
#
# `inputAutomation` IS THE NEAR MISS, and it is here rather than beside the input substrate for a
# precise reason. Its package is genuinely a partial answer on NixOS — `programs.ydotool.enable`
# supplies the group and the `/dev/uinput` access that the derivation does not — but this profile
# deliberately does NOT wire that option (it also starts a standing input-injection daemon; see
# lib/nixos-roles.nix's own entry). So what the role does is install a package and nothing else,
# exactly like the one above it, and what has to be proven is exactly the same question. The
# assertion that it wires no option is part of that proof rather than an afterthought: a later edit
# that "completed" the role by turning `programs.ydotool.enable` on would start a daemon nobody
# asked for, and it must fail here.
#
# `lib.evalModules` + a stub would NOT do here, for checks/file-manager.nix's reason: what is under
# test is the package list a real NixOS evaluation ends up with, and a stub declaring
# `environment.systemPackages` as `listOf anything` would accept the write without ever forcing the
# derivations behind it. `inputAutomation` adds a second reason of its own — the thing that has to
# stay false is one of nixpkgs' OWN options, which no stub could report on at all.
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
  unfilled = configFor (desktop { });
  disabled = configFor { nixdesktop.desktop = { enable = false; compositor = "niri"; }; };

  # `pname`, not `name`: the version suffix is exactly the kind of detail that makes a prefix match
  # quietly stop matching after a bump.
  pnames = cfg: map (p: p.pname or p.name or "") cfg.environment.systemPackages;
  has = n: cfg: lib.elem n (pnames cfg);

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

    # ── The profile off entirely ──────────────────────────────────────────────────────────────
    #
    # `nixdesktop.want` is `{}` here, so `packagesFor` short-circuits before either of the two is
    # read.
    "a disabled profile installs neither" =
      !(has "wtype" disabled)
      && !(has "ydotool" disabled);
  };
in
report "asset-roles" results
