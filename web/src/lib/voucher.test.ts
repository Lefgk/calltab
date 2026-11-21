import { describe, expect, it } from "vitest";
import { privateKeyToAccount } from "viem/accounts";
import { hashVoucher, signVoucher, verifyVoucher, voucherTypedData, type Voucher } from "./voucher";

// Well-known Anvil key #0 — test material only, not a secret.
const ANVIL0 = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80" as const;
const account = privateKeyToAccount(ANVIL0);
const contract = "0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512" as const;
const otherContract = "0x5FbDB2315678afecb367f032d93F642f64180aa3" as const;

const voucher: Voucher = {
  tabId: 1n,
  cumulativeAmount: 100_000000n,
  deadline: 0n,
};

describe("voucher helper", () => {
  it("signs and verifies a cumulative voucher", async () => {
    const signature = await signVoucher(account, 1, contract, voucher);
    expect(signature.startsWith("0x")).toBe(true);
    expect(
      await verifyVoucher({
        signer: account.address,
        signature,
        chainId: 1,
        verifyingContract: contract,
        voucher,
      }),
    ).toBe(true);
  });

  it("rejects a voucher replayed on another chain", async () => {
    const signature = await signVoucher(account, 1, contract, voucher);
    expect(
      await verifyVoucher({
        signer: account.address,
        signature,
        chainId: 8453,
        verifyingContract: contract,
        voucher,
      }),
    ).toBe(false);
  });

  it("rejects a voucher replayed against another tab or contract", async () => {
    const signature = await signVoucher(account, 1, contract, voucher);
    expect(
      await verifyVoucher({
        signer: account.address,
        signature,
        chainId: 1,
        verifyingContract: contract,
        voucher: { ...voucher, tabId: 2n },
      }),
    ).toBe(false);
    expect(
      await verifyVoucher({
        signer: account.address,
        signature,
        chainId: 1,
        verifyingContract: otherContract,
        voucher,
      }),
    ).toBe(false);
  });

  it("rejects a tampered cumulative amount", async () => {
    const signature = await signVoucher(account, 1, contract, voucher);
    expect(
      await verifyVoucher({
        signer: account.address,
        signature,
        chainId: 1,
        verifyingContract: contract,
        voucher: { ...voucher, cumulativeAmount: 999_000000n },
      }),
    ).toBe(false);
  });

  it("hashes stably for the same typed data", () => {
    const a = hashVoucher(1, contract, voucher);
    const b = hashVoucher(1, contract, voucher);
    expect(a).toBe(b);
    expect(hashVoucher(8453, contract, voucher)).not.toBe(a);
    expect(voucherTypedData(1, contract, voucher).primaryType).toBe("Voucher");
  });
});
