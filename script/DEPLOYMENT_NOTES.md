# Deployment notes

Scope of this round: **Minter (MINTR), Admin (ADMIN), Burner (BRNER) modules + Gateway, PresaleAuction,
EntenDeflationHook policies.** The `Auction` policy is intentionally excluded until it has been reviewed.
Governance is a single EOA admin for now (no timelock handoff yet).

The deployment assumes the audited core (Kernel / Vault / Token / Controller) is already launched
(e.g. via `LaunchCore.s.sol` / the `ControllerFactory`). This script only deploys and wires the periphery.

## OPEN ISSUE — genesis bootstrap vs. the backing floor (decision deferred, no code change yet)

We chose **team-locked genesis** so the per-asset bootstrap floor (`MIN_BACKING_RATIO_RAY`, set via
`Gateway.addAsset`) would be enforced on-chain. There is a mechanical tension to resolve before a real
backed launch:

- The core's bootstrap floor (`Dispatch._validateBacking`) only fires on a `settle` while
  `startingSupply == 0`, where `startingSupply = totalSupply - TEAM_LOCKED_TOKENS` (effective supply).
  For it to bind, the **first** backing-affecting settlement must happen at `effectiveSupply == 0`.
- But `PresaleAuction.minimumPrice()` **cannot price while `effectiveSupply == 0`**: `backingPerToken`
  early-returns an empty array on zero supply, so `minimumPrice()` / `open()` revert. The presale needs
  `effectiveSupply > 0` to function.

So the presale **cannot itself be the bootstrap mint**, and this round deploys no other minter. The genesis
seed (the transition of `effectiveSupply` from 0 to a small positive amount, with floor-satisfying backing)
must be handled by one of:

- **(A) Small unlocked genesis seed + seeded backing.** Premine a small unlocked amount (`nonTeamAmount > 0`)
  and team-lock the rest; seed backing via transfer + `controller.sync(asset, Redeem)`. The presale then
  prices off that ratio. Trade-off: `effectiveSupply > 0` from genesis, so the on-chain floor branch never
  fires — the deployer must set the seed's backing ratio correctly at launch (the RAY floor becomes
  documentation, not enforcement). This matches the existing testnet pattern and is what this script targets.
- **(B) Fully team-locked genesis + a dedicated bootstrap minter.** Keep `effectiveSupply == 0` so the floor
  binds, but add a one-shot bootstrap minting path (a temporary permitted policy or admin path) that performs
  the first seed mint at `effectiveSupply == 0`. Genuinely enforces the floor on-chain, but adds a component
  outside the six contracts in scope.

**Status:** deferred. This script follows shape (A): it expects the core to have been launched with a small
unlocked genesis seed so that `effectiveSupply > 0` before `presale.open()`. If a future launch wants the
floor enforced on-chain (shape B), a bootstrap minter must be designed and added first.

Related: `Gateway.addAsset` NatSpec ("FLOOR SCOPE") documents that backed launches preminting unlocked supply
should seed dust backing first; that is the same constraint surfaced here.

## Pre-mainnet checklist (carried from the review)

- **Hook address mining** — `EntenDeflationHook` must deploy to a CREATE2 address encoding its permission
  flags. The script mines a salt and deploys via the canonical CREATE2 factory; `validateHookPermissions`
  in the constructor reverts on a wrong address.
- **Decimal scaling** — `START_PRICE`, `VIRTUAL_TOKEN_RESERVE`, `MIN_BID` are in the backing asset's
  "wei per 1e18 token" scale, and `MIN_BACKING_RATIO_RAY = asset_wei * 1e27 / token_wei`. For a 6-decimal
  asset (USDC) backing an 18-decimal token, a 1:1 floor is `1e15`, not `1e27`.
- **MAX_SUPPLY headroom** — `PresaleAuction` does not check the token cap; ensure genesis + presale size fits.
- **MINTR.mint scope** — only `PresaleAuction` is granted `MINTR.mint` this round (it is the only activated
  minting policy). When `Auction` is added, it will request the same permission at activation.
- **Activate-then-open** — activate the presale policy and seed backing before calling `open()`.
- **Governance (deferred)** — admin/upgrade control stays with the EOA admin this round. Before mainnet,
  transfer Gateway `DEFAULT_ADMIN_ROLE` / `UPGRADE_ROLE` to the `SystemUpgradeTimelock` and renounce the EOA
  (finding #2), and consider timelocking `Gateway.addAsset` (finding #3).
- **External audit** — recommended before mainnet funds, focused on the v4 hook.
