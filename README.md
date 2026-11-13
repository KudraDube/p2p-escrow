# P2PEscrow

A peer-to-peer escrow contract for trading tokens against off-chain fiat (a bank transfer, for example), built as part of my path into smart-contract development.

Think of it as a locker with three keys. The seller puts tokens in the locker and names the buyer. The buyer says "I've sent the money". The seller checks their bank and opens the locker for the buyer. If the two disagree, an arbiter decides who gets the contents. The contract's whole job is to make sure that nobody, including a buggy or hostile token, can take tokens out of the locker in any way except those steps.

## Why I built it

Escrow is the standard "real money, no trust" problem in Web3. It forced me to treat a contract as a **state machine**: every function is only legal in certain states and for certain callers, and everything else must revert. That is the same discipline I want to bring to a junior Solidity role, where most real bugs are "this function was callable when it shouldn't have been".

## Status

| Item | State |
|---|---|
| Contract | Complete, patched against the Contracts Pack escrow issue |
| Tests | 46 passing (unit, state machine, reentrancy, fuzz, invariant) |
| Audit | None. This is a learning project, **do not deploy with real funds** |

## How it works

```
Funded --markAsPaid (buyer)--> PaymentClaimed --releaseFunds (seller)--> Released
  |                                  |
  |--cancelOrder (seller)--> Cancelled
  |                                  |
  +--raiseDispute (either party)-----+--> Disputed --resolveDispute (arbiter)--> Released
```

| Function | Who | Allowed in state |
|---|---|---|
| `createOrder` | seller | creates the order, locks tokens |
| `markAsPaid` | buyer | Funded |
| `releaseFunds` | seller | PaymentClaimed |
| `cancelOrder` | seller | Funded only |
| `raiseDispute` | seller or buyer | Funded or PaymentClaimed |
| `resolveDispute` | arbiter (owner) | Disputed |

## Design decisions

- **The seller names the buyer up front.** Nobody else can claim payment on that order later.
- **Cancel only before payment is claimed.** After the buyer says they paid, a seller could otherwise cancel and keep both the tokens and the money.
- **State is updated before tokens move** (checks-effects-interactions), and every function that moves tokens is also `nonReentrant`. Two layers of defence, because a hostile token's `transfer` is attacker-controlled code.
- **The patch: measure what actually arrived.** The seller chooses the token. A fee-on-transfer token delivers less than the amount sent, so recording the nominal amount would leave the contract owing tokens it doesn't hold, and the last person to withdraw would be left short. `createOrder` now records the real balance change and reverts if nothing arrived.

## Known limitations

I would rather list these honestly than pretend the contract is finished.

- **The arbiter is a single point of trust.** One address decides every dispute. A real product would use a multisig, a DAO or several arbiters.
- **`renounceOwnership` would strand disputed funds**, because nobody could resolve them any more.
- **Resolving a dispute in the seller's favour still sets the status to `Released`.** The event says which side won, but the status doesn't.
- **Rebasing and negative-rebase tokens are not supported.** Only fee-on-transfer tokens are handled.
- **No timeouts.** A buyer or seller who goes silent leaves the order open until the arbiter steps in.
- **The fiat payment can't be verified on-chain.** The contract trusts the seller to confirm it, which is why the dispute path exists.

## Tests

`test/P2PEscrow.t.sol`, 46 tests:

- every function: the happy path, every `require`, events, and "can't be run twice"
- a state-machine test that tries all 5 actions in all 6 states and checks each against the table above
- a wrong-caller test for every action
- 5 fee-on-transfer tests, which **fail against the unpatched contract** and pass against the patched one
- 2 reentrancy tests using a hostile token that calls back into the escrow
- fuzz tests on amounts and fees
- an invariant test: after 128,000 random actions, the contract's token balance always equals what its open orders are owed

## Run it

```bash
forge install OpenZeppelin/openzeppelin-contracts foundry-rs/forge-std
forge test
forge test --match-test feeOnTransfer -vv
```

## What I practised

- modelling a contract as a state machine and testing every transition, not just the happy path
- the checks-effects-interactions pattern, plus `nonReentrant`, and proving both with an attacking token
- writing test helper contracts (a fee-on-transfer token, a hook token) to simulate hostile input
- invariant testing with a handler contract
- thinking about trust: who holds power in a contract, and what happens if that party disappears
- reading a security finding in the Contracts Pack, reproducing it as a failing test, then fixing it

## Where this is going

I'm a WeThinkCode blockchain graduate building towards a junior Solidity or Web3 role. This repository is one of a set (SimpleDEX, EthVault, MultiSigWallet, P2PEscrow) where each contract comes with tests I can explain line by line.
