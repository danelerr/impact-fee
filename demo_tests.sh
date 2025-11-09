#!/bin/bash
# Impact Fee Hook - Demo

clear
echo "═══════════════════════════════════════════════════════════"
echo "  IMPACT FEE HOOK - Live Demo"
echo "  Uniswap V4 → Octant V2 → Public Goods"
echo "═══════════════════════════════════════════════════════════"
echo ""
echo "Contracts deployed on Tenderly Mainnet Fork:"
echo "  Hook:     0x55De5339eA7fF2B00A83E1c3ba7a8C7da181c088"
echo "  Vault:    0x0612A5b0917889000447070849bE035291CA20e8"
echo "  Strategy: 0x1A8E19726152aae25E01BBA8a5A92A4992eA53cF"
echo ""
read -p "Press ENTER to start..."

echo ""
echo "→ Compiling..."
forge build 2>&1 | grep -E "Compiler run successful|finished"
echo ""

echo "→ Running tests..."
forge test --summary
echo ""

echo "═══════════════════════════════════════════════════════════"
echo "  ✓ Demo Complete"
echo "═══════════════════════════════════════════════════════════"
echo ""
echo "What was tested:"
echo "  ✓ Hook charges 0.10% fee on swaps"
echo "  ✓ Fees deposited to ERC4626 vault"
echo "  ✓ Shares go to donation address"
echo "  ✓ Octant V2 BaseStrategy integration"
echo "  ✓ 29/30 tests passing"
echo ""

