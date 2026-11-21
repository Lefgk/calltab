import { hashTypedData, verifyTypedData, type Address, type Hex } from "viem";

export const CALLTAB_NAME = "Calltab";
export const CALLTAB_VERSION = "1";

export const voucherTypes = {
  Voucher: [
    { name: "tabId", type: "uint256" },
    { name: "cumulativeAmount", type: "uint256" },
    { name: "deadline", type: "uint256" },
  ],
} as const;

export type Voucher = {
  tabId: bigint;
  cumulativeAmount: bigint;
  deadline: bigint;
};

export function voucherDomain(chainId: number, verifyingContract: Address) {
  return {
    name: CALLTAB_NAME,
    version: CALLTAB_VERSION,
    chainId,
    verifyingContract,
  } as const;
}

export function voucherTypedData(chainId: number, verifyingContract: Address, voucher: Voucher) {
  return {
    domain: voucherDomain(chainId, verifyingContract),
    types: voucherTypes,
    primaryType: "Voucher" as const,
    message: voucher,
  };
}

export function hashVoucher(chainId: number, verifyingContract: Address, voucher: Voucher): Hex {
  return hashTypedData(voucherTypedData(chainId, verifyingContract, voucher));
}

export type SignTypedDataAccount = {
  signTypedData: (params: ReturnType<typeof voucherTypedData>) => Promise<Hex>;
};

/** Sign a cumulative voucher with a viem wallet client or local account. */
export async function signVoucher(
  account: SignTypedDataAccount,
  chainId: number,
  verifyingContract: Address,
  voucher: Voucher,
): Promise<Hex> {
  return account.signTypedData(voucherTypedData(chainId, verifyingContract, voucher));
}

export async function verifyVoucher(args: {
  signer: Address;
  signature: Hex;
  chainId: number;
  verifyingContract: Address;
  voucher: Voucher;
}): Promise<boolean> {
  return verifyTypedData({
    ...voucherTypedData(args.chainId, args.verifyingContract, args.voucher),
    address: args.signer,
    signature: args.signature,
  });
}
