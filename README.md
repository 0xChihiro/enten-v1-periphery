# Enten Periphery

Periphery contracts for the `enten-v1` core system. This repo is expected to sit next to `enten-v1`:

```text
Shinsekai/
  enten-v1/
  enten-periphery/
```

## NAV Issuance Curve

`src/modules/NavIssuanceCurve.sol` implements a buy-side `CURVE` module for `enten-v1`.

The module mints ENTEN through `Controller.settle` and prices buys from:

```text
buyPrice = backingPerToken * premium(utilization)
premium(utilization) = 1 + maxPremium * utilization^2
utilization = totalSupply / maxSupply
```

For production buys, the module integrates the premium over the full supply interval consumed by the purchase:

```text
netBackingIn =
  backingPerToken *
  [
    amount
    + maxPremium * (endSupply^3 - startSupply^3) / (3 * maxSupply^2)
  ]
```

The cube difference is factored in Solidity as:

```text
endSupply^3 - startSupply^3 =
  amount * (endSupply^2 + endSupply * startSupply + startSupply^2)
```

The module then grosses up the user payment for the current `enten-v1` controller mint fee, credits the post-fee amount to `Vault.Backing`, and mints ENTEN to the recipient.

## Assumptions

- The NAV issuance curve uses one configured reserve asset per module.
- Reserve asset amounts are normalized to 18 decimals internally.
- The reserve asset must be non-deflationary; the current core vault accounting assumes `transferFrom` receives the requested amount.
- Users approve the core `Vault`, not this module.
- `Slots.MAX_SUPPLY_SLOT` must be set in the core `Kernel` before quotes or buys.
- The controller must install and activate the module, then grant mint permission for `CURVE`.

## Bancor Issuance Curve

`src/modules/BancorIssuanceCurve.sol` implements a buy-only Bancor-style `CURVE` module. It accepts a fixed basket of reserve assets configured at deployment. Users choose the payment asset for each buy, and the module normalizes all accepted backing into 18-decimal value units for aggregate NAV and Bancor pricing.

The configured reserve assets are assumed to share the same value denomination, such as USD stable assets. The v1 module does not include an oracle or asset weighting layer.

It supports fixed closed-form curve shapes:

```text
y = x^(1/4)  reserve ratio = 80%
y = x^(1/2)  reserve ratio = 66.67%
y = x        reserve ratio = 50%
```

Exact-token buys use:

```text
bancorBackingIn =
  curveReserve * ((supplyAfter / supplyBefore)^(1 / reserveRatio) - 1)
```

The module also enforces a 5% NAV accretion floor:

```text
navFloorBackingIn = tokenAmount * currentNAV * 1.05
requiredBackingIn = max(bancorBackingIn, navFloorBackingIn)
```

`bancorBackingIn` uses the module's aggregate WAD-denominated `CURVE_RESERVE_SLOT`, while the NAV floor uses live vault backing summed across every configured reserve asset. This lets external backing additions or non-redeem burns raise NAV without locking out new mints: buyers pay at least NAV + 5% until the curve reserve catches up and Bancor pricing becomes larger again.

For future redemption modules, `quoteCurveReserveReductionForBurn(burnAmount)` returns the pro-rata WAD-denominated curve reserve amount that should be subtracted from `CURVE_RESERVE_SLOT` alongside a pro-rata token burn. The helper rounds down, so standard redemptions preserve or slightly increase curve reserve per token rather than lowering the mint spot price.

Setup also requires granting state permission for `BancorIssuanceCurve.CURVE_RESERVE_SLOT`.

## Commands

```shell
forge fmt --check
forge build
forge test --offline
```
