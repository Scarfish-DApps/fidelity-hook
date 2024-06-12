# FidelityHook 🦄
### **Overview**

The FidelityHook project aims to enhance the Uniswap V4 protocol by introducing dynamic fees and fidelity tokens. These tokens provide traders with a discount based on their trading volume, creating an incentive for higher trading activity within the pool. The project includes a smart contract (FidelityHook) that integrates with Uniswap V4, enabling these functionalities.

### **Features**

1. Dynamic Fees: Adjusts the swap fees based on trading volume, offering fee reductions to high-volume traders.
2. Fidelity Tokens: Rewards traders with tokens based on their trading volume. These tokens can be used to earn fee discounts.
3. Liquidity Management: Allows liquidity providers to add, remove, and recenter liquidity in the pool, with considerations for dynamic fee adjustments.
4. Trading Campaigns: Implements time-bound trading campaigns during which trading volume is tracked, and fidelity tokens are issued accordingly.

## Set up

*requires [foundry](https://book.getfoundry.sh)*

```
forge install
forge test
```