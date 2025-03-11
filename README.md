# Sui Crankless Time Weighted Average Price (TWAP) oracle

## License
Licensed under the Business Source License (BSL) 1.1 for non-commercial use only; see the LICENSE file for details.

## How to use
Full logic is available in ./oracle.move. For full test suite see ./oracle-tests/

## Comparision with Leading implementation on Solana
Here is an crankless TWAP oracle implementation on Solana https://github.com/metaDAOproject/futarchy/blob/develop/programs/amm/src/state/amm.rs

The Solana implementation is vulnerable to attack and manipulation as the oracle takes readings only once every 60 seconds. This means attackers can focus their spending to only manipulate the oracle at the measurement points. Our implementation in Sui Move in this repo, measures every checkpoint (every ~250 ms), that is 240x more than the Solana implementation so an attacker will have to spend much more to manipulate the TWAP if there is even one other sophisticated trader in the market.

Our Sui implementation also uses a relative TWAP step size cap between windows, meaning small projects can safely launch and scale without having TWAP capping or lag issues. The Solana implementation uses a fixed absolute step that must be updated every time the token price moves significantly (10-100x), to maintain accuracy. 








