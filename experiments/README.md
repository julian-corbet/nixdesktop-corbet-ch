# Experiments

Throwaway trials: spikes, one-off scripts, measurements not yet worth writing up properly.
Nothing here is guaranteed to work, be maintained, or survive the next cleanup pass. If something
here turns out to matter, distill the finding into [`../studies/`](../studies/README.md) and let
the experiment stay disposable (or delete it).

| File | What |
|---|---|
| `eval-smoke-test.nix` | Confirms the policy profile evaluates and `nixdesktop.want` resolves as a backend expects, including `compositor` (no default; the consumer's own value must reach `want` unchanged). |
| `eval-nixos-backend.nix` | Confirms `modules/nixos-backend.nix` evaluates alongside the profile and that the default `nixdesktop.want` resolves to real nixpkgs packages (not just role names), including the portals gap being handled through `xdg.portal` rather than dropped, and that a compositor with no nixpkgs package resolves via the backend's `extraCompositors` option with no edit to this repo. |

## Open questions

Judgment calls that are reasoned but not measured. Each closes into a default in
`profiles/desktop.nix`.

- **Role vocabulary granularity.** `want` currently mixes named implementations
  (`fileManager = "thunar"`) with capability booleans (`clipboardHistory = true`). That reads
  well, but a backend has to know which is which. A second backend now exists
  (`modules/nixos-backend.nix`) and it did not need a different vocabulary to consume `want` —
  both backends' `resolve`/`packagesFor` handle the mix identically. Downgraded from "unproven" to
  "proven adequate, not proven optimal"; still not worth churning without a concrete complaint.
- **The two-evaluation seam is now a two-*repo* seam too.** Policy is evaluated by
  system-manager/NixOS; compositor config generation now lives in a sibling repo entirely
  (nixniri, nixscroll, ...) rather than just a separate home-manager evaluation. A consumer who
  wants the idle daemon's timeout assembly wired to the systemd service that runs it states the
  connection explicitly at their own top-level config — `nixniri.niri.idle.command` into
  `nixdesktop.session.idleAndLock.command`, documented as a worked example in nixniri's own
  README. The polkit-agent and keyring commands have no such compositor-side assembly to wire at
  all (they're just a binary invocation, not a timeout calculation), so those still come from a
  platform backend's role table (`lib/nixos-roles.nix`'s `polkitAgents`/`keyrings`) rather than
  from any compositor module.
- **`bar = "eww"` is under-served.** eww ships no bar, only primitives, so selecting it declares
  an intent the profile cannot fulfil alone. Possibly it should not be an enum value at all.
- **The startup contract (`home/startup.nix`) has exactly one producer and zero confirmed
  consumers yet.** `homeManagerModules.noctalia` writes to `nixdesktop.startup`; no compositor
  module in this family has been confirmed to *read* it yet (nixniri's niri.nix, at the time of
  writing, still only has its own `extraStartup` option, which is niri-specific and not this
  contract). Until a compositor module reads `config.nixdesktop.startup`, noctalia's startup
  command silently goes nowhere for a niri consumer — worth flagging rather than assuming solved
  just because nixdesktop's side of the contract now exists.
