# Experiments

Throwaway trials: spikes, one-off scripts, measurements not yet worth writing up properly.
Nothing here is guaranteed to work, be maintained, or survive the next cleanup pass. If something
here turns out to matter, distill the finding into [`../studies/`](../studies/README.md) and let
the experiment stay disposable (or delete it).

| File | What |
|---|---|
| `eval-smoke-test.nix` | Confirms the policy profile evaluates and `nixdesktop.want` resolves as a backend expects. |
| `eval-nixos-backend.nix` | Confirms `modules/nixos-backend.nix` evaluates alongside the profile and that the default `nixdesktop.want` resolves to real nixpkgs packages (not just role names), including the portals gap being handled through `xdg.portal` rather than dropped. |

## Open questions

Judgment calls that are reasoned but not measured. Each closes into a default in
`profiles/niri-desktop.nix`.

- **Role vocabulary granularity.** `want` currently mixes named implementations
  (`fileManager = "thunar"`) with capability booleans (`clipboardHistory = true`). That reads
  well, but a backend has to know which is which. A second backend now exists
  (`modules/nixos-backend.nix`) and it did not need a different vocabulary to consume `want` —
  both backends' `resolve`/`packagesFor` handle the mix identically. Downgraded from "unproven" to
  "proven adequate, not proven optimal"; still not worth churning without a concrete complaint.
- **The two-evaluation seam.** Policy is evaluated by system-manager/NixOS; config generation by
  home-manager. They are separate evaluations, so a consumer today states the polkit choice twice
  — once as a role, once as `polkitAgentCommand`. A backend shipping a paired home-manager module
  that derives the command from the role would close this. Both backends (`nixarch`'s and this
  project's own `modules/nixos-backend.nix`) already keep the package and the spawn command in one
  table entry for exactly this reason (`lib/desktop-roles.nix`, `lib/nixos-roles.nix`) — what's
  still open is wiring that table into a paired home-manager module instead of a consumer setting
  `polkitAgentCommand` by hand.
- **`bar = "eww"` is under-served.** eww ships no bar, only primitives, so selecting it declares
  an intent the profile cannot fulfil alone. Possibly it should not be an enum value at all.
