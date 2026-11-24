import { useMemo, useState } from "react";
import { useAccount, useChainId, usePublicClient, useReadContract, useWalletClient } from "wagmi";
import { erc20Abi, formatUnits, isAddress, parseUnits, type Address, type Hex } from "viem";
import { callTabAbi } from "./abi";
import { deployments } from "./config";
import { Addr, Empty, Hint, Loading, Shell, short, useTx } from "./ui";
import { signVoucher, type Voucher } from "./lib/voucher";

const STATUS = ["Open", "Closing", "Closed"] as const;
const ZERO = "0x0000000000000000000000000000000000000000";

export default function App() {
  const { address, isConnected } = useAccount();
  const chainId = useChainId();
  const dep = deployments[chainId] ?? {};
  const [tabId, setTabId] = useState("");
  const validTabId = /^\d+$/.test(tabId);

  return (
    <Shell
      title="Calltab"
      tagline="A prepaid USDC tab between a payer (or their AI agent) and an API provider. Lock USDC once, pay per call with signed off-chain vouchers, and let the provider collect only what the latest voucher says. Pause any time; close with a challenge window."
      steps={[
        "Payer opens a tab: USDC is locked in the contract for one provider.",
        "Payer or their agent signs vouchers for the running total owed (no gas).",
        "Provider redeems the latest voucher and receives only the new amount.",
        "Payer closes: after the challenge window the unspent USDC is refunded.",
      ]}
      contractLabel="CallTab"
      contractOf={(id) => deployments[id]?.calltab}
      refs={[{ label: "USDC", address: dep.usdc }]}
      risk={
        <>
          <strong>Real funds.</strong> This contract is not audited. USDC you lock in a tab can be claimed by the
          provider up to the amount of any voucher you or your agent sign. Only deposit amounts you can afford to lose.
        </>
      }
    >
      {!isConnected && <Empty>Connect a wallet to open a tab or manage one you are part of.</Empty>}

      {isConnected && address && dep.calltab && dep.usdc && (
        <>
          <OpenTab calltab={dep.calltab} usdc={dep.usdc} onOpened={setTabId} />
          <TabPicker address={address} calltab={dep.calltab} tabId={tabId} setTabId={setTabId} />
          {tabId && !validTabId && (
            <div className="card">
              <div className="bad muted">A tab id is a whole number, for example 1.</div>
            </div>
          )}
          {validTabId && <TabActions calltab={dep.calltab} usdc={dep.usdc} tabId={BigInt(tabId)} />}
        </>
      )}
    </Shell>
  );
}

function OpenTab({
  calltab,
  usdc,
  onOpened,
}: {
  calltab: Address;
  usdc: Address;
  onOpened: (id: string) => void;
}) {
  const { writeContractAsync, status, run, safe, fail } = useTx();
  const publicClient = usePublicClient();
  const [provider, setProvider] = useState("");
  const [amount, setAmount] = useState("100");
  const [periodCap, setPeriodCap] = useState("");
  const [periodDays, setPeriodDays] = useState("1");
  const [expiryDays, setExpiryDays] = useState("");
  const [windowHours, setWindowHours] = useState("24");
  const [agent, setAgent] = useState("");

  return (
    <div className="card">
      <h2>1. Open a tab (payer)</h2>
      <p className="muted">
        You are the payer. The provider is the address that will be allowed to collect from this tab.
      </p>
      <div className="row">
        <label>
          Provider address
          <input value={provider} placeholder="0x…" spellCheck={false} onChange={(e) => setProvider(e.target.value.trim())} />
        </label>
        <label>
          Amount (USDC)
          <input value={amount} onChange={(e) => setAmount(e.target.value)} />
        </label>
      </div>
      <div className="row">
        <label>
          Period cap (USDC, optional)
          <input value={periodCap} placeholder="none" onChange={(e) => setPeriodCap(e.target.value)} />
        </label>
        <label>
          Period (days)
          <input value={periodDays} onChange={(e) => setPeriodDays(e.target.value)} />
        </label>
        <label>
          Expiry (days, optional)
          <input value={expiryDays} placeholder="none" onChange={(e) => setExpiryDays(e.target.value)} />
        </label>
        <label>
          Challenge window (hours, 1–168)
          <input value={windowHours} onChange={(e) => setWindowHours(e.target.value)} />
        </label>
      </div>
      <div className="row">
        <label>
          Agent signer (optional)
          <input value={agent} placeholder="0x… or empty" spellCheck={false} onChange={(e) => setAgent(e.target.value.trim())} />
        </label>
        <button
          onClick={safe(async () => {
            if (!isAddress(provider)) return fail("Provider must be a valid address (0x followed by 40 hex characters).");
            if (agent && !isAddress(agent)) return fail("Agent signer must be a valid address, or left empty.");
            const amt = parseUnits(amount, 6);
            if (amt === 0n) return fail("Amount must be greater than 0.");
            const cap = periodCap ? parseUnits(periodCap, 6) : 0n;
            const duration = cap > 0n ? BigInt(Math.floor(Number(periodDays || "1") * 86400)) : 0n;
            const expiry = expiryDays
              ? BigInt(Math.floor(Date.now() / 1000) + Number(expiryDays) * 86400)
              : 0n;
            const window = BigInt(Math.floor(Number(windowHours || "24") * 3600));
            const agentAddr = (agent || ZERO) as Address;
            if (
              await run("Approve USDC", () =>
                writeContractAsync({ address: usdc, abi: erc20Abi, functionName: "approve", args: [calltab, amt] }),
              )
            ) {
              const ok = await run("Open tab", () =>
                writeContractAsync({
                  address: calltab,
                  abi: callTabAbi,
                  functionName: "openTab",
                  args: [provider as Address, amt, cap, duration, expiry, window, agentAddr, 0n, 0n],
                }),
              );
              if (ok && publicClient) {
                const next = await publicClient.readContract({
                  address: calltab,
                  abi: callTabAbi,
                  functionName: "nextTabId",
                });
                onOpened((next - 1n).toString());
              }
            }
          })}
        >
          Approve + open
        </button>
      </div>
      <Hint>
        Two wallet prompts. First an approval for exactly the amount above, then “open tab”, which moves that USDC
        from your wallet into the CallTab contract. The provider can only collect against vouchers signed by you or
        the agent signer; the period cap limits how much can be collected per period. Unspent USDC comes back when
        you close the tab.
      </Hint>
      {status}
    </div>
  );
}

function TabPicker({
  address,
  calltab,
  tabId,
  setTabId,
}: {
  address: Address;
  calltab: Address;
  tabId: string;
  setTabId: (id: string) => void;
}) {
  const { data: asPayer, isLoading } = useReadContract({
    address: calltab,
    abi: callTabAbi,
    functionName: "tabsOfPayer",
    args: [address],
  });
  const { data: asProvider } = useReadContract({
    address: calltab,
    abi: callTabAbi,
    functionName: "tabsOfProvider",
    args: [address],
  });
  const mine = useMemo(() => {
    const set = new Set<string>();
    (asPayer ?? []).forEach((id) => set.add(id.toString()));
    (asProvider ?? []).forEach((id) => set.add(id.toString()));
    return [...set];
  }, [asPayer, asProvider]);

  return (
    <div className="card">
      <h2>2. Select a tab</h2>
      <div className="field-label">Tabs where you are payer or provider</div>
      {isLoading ? (
        <Loading>Looking up your tabs…</Loading>
      ) : mine.length > 0 ? (
        <div className="row">
          {mine.map((id) => (
            <button key={id} className={id === tabId ? "seg seg-on" : "seg"} aria-pressed={id === tabId} onClick={() => setTabId(id)}>
              Tab #{id}
              <span className="seg-sub">{id === tabId ? "selected" : "select"}</span>
            </button>
          ))}
        </div>
      ) : (
        <Empty>This wallet has no tabs on this network yet. Open one above, or enter a tab id to inspect it.</Empty>
      )}
      <div className="row">
        <label>
          Or open a tab by id
          <input value={tabId} placeholder="1" inputMode="numeric" onChange={(e) => setTabId(e.target.value.trim())} />
        </label>
      </div>
    </div>
  );
}

function TabActions({ calltab, usdc, tabId }: { calltab: Address; usdc: Address; tabId: bigint }) {
  const chainId = useChainId();
  const { address } = useAccount();
  const { data: walletClient } = useWalletClient();
  const { writeContractAsync, status, run, safe, fail } = useTx();
  const { data: t, refetch, isLoading } = useReadContract({
    address: calltab,
    abi: callTabAbi,
    functionName: "getTab",
    args: [tabId],
  });
  const remaining = t ? t.deposited - t.claimed - t.refunded : 0n;
  const [topUpAmt, setTopUpAmt] = useState("25");
  const [cum, setCum] = useState("10");
  const [deadlineHours, setDeadlineHours] = useState("");
  const [signature, setSignature] = useState("");

  if (!t || t.payer === ZERO) {
    return (
      <div className="card">
        <h2>3. Tab #{tabId.toString()}</h2>
        {isLoading ? <Loading /> : <Empty>No tab with that id on this network.</Empty>}
      </div>
    );
  }

  const statusLabel = STATUS[t.status] ?? String(t.status);
  const isPayer = address && address.toLowerCase() === t.payer.toLowerCase();
  const isProvider = address && address.toLowerCase() === t.provider.toLowerCase();

  const buildVoucher = (): Voucher => ({
    tabId,
    cumulativeAmount: parseUnits(cum || "0", 6),
    deadline: deadlineHours
      ? BigInt(Math.floor(Date.now() / 1000) + Number(deadlineHours) * 3600)
      : 0n,
  });

  return (
    <div className="card">
      <h2>3. Tab #{tabId.toString()}</h2>
      <dl className="dl">
        <dt>Status</dt>
        <dd>
          <span className={t.status === 0 && !t.paused ? "ok" : "bad"}>{statusLabel}</span>
          {t.paused ? " · paused (redeems blocked)" : ""}
        </dd>
        <dt>Payer</dt>
        <dd>
          <Addr value={t.payer} /> {isPayer && <span className="ok">(you)</span>}
        </dd>
        <dt>Provider</dt>
        <dd>
          <Addr value={t.provider} /> {isProvider && <span className="ok">(you)</span>}
        </dd>
        {t.agent !== ZERO && (
          <>
            <dt>Agent signer</dt>
            <dd>
              <Addr value={t.agent} />
            </dd>
          </>
        )}
      </dl>
      {!isPayer && !isProvider && (
        <div className="info">
          You are neither the payer nor the provider of this tab ({short(address)}). You can read it and finalize a
          close, but the other actions are disabled.
        </div>
      )}
      <table>
        <tbody>
          <tr>
            <td>Deposited</td>
            <td>{formatUnits(t.deposited, 6)} USDC</td>
          </tr>
          <tr>
            <td>Claimed</td>
            <td>{formatUnits(t.claimed, 6)} USDC</td>
          </tr>
          <tr>
            <td>Remaining</td>
            <td>{formatUnits(remaining, 6)} USDC</td>
          </tr>
          <tr>
            <td>Period cap</td>
            <td>{t.periodCap === 0n ? "none" : `${formatUnits(t.periodCap, 6)} / ${Number(t.periodDuration) / 86400}d`}</td>
          </tr>
          <tr>
            <td>Challenge window</td>
            <td>{Number(t.challengeWindow) / 3600} hours</td>
          </tr>
        </tbody>
      </table>

      <h3>Payer controls</h3>
      <div className="row">
        <label>
          Top up (USDC)
          <input value={topUpAmt} onChange={(e) => setTopUpAmt(e.target.value)} />
        </label>
        <button
          disabled={!isPayer}
          onClick={safe(async () => {
            const amt = parseUnits(topUpAmt, 6);
            if (
              await run("Approve USDC", () =>
                writeContractAsync({ address: usdc, abi: erc20Abi, functionName: "approve", args: [calltab, amt] }),
              )
            ) {
              await run("Top up", () =>
                writeContractAsync({ address: calltab, abi: callTabAbi, functionName: "topUp", args: [tabId, amt] }),
              );
              refetch();
            }
          })}
        >
          Approve + top up
        </button>
        <button
          disabled={!isPayer}
          className={t.paused ? "" : "ghost"}
          onClick={safe(async () => {
            await run(t.paused ? "Unpause" : "Pause", () =>
              writeContractAsync({
                address: calltab,
                abi: callTabAbi,
                functionName: t.paused ? "unpause" : "pause",
                args: [tabId],
              }),
            );
            refetch();
          })}
        >
          {t.paused ? "Unpause" : "Pause"}
        </button>
        <button
          disabled={!isPayer || t.status !== 0}
          className="danger"
          onClick={safe(async () => {
            await run("Initiate close", () =>
              writeContractAsync({
                address: calltab,
                abi: callTabAbi,
                functionName: "initiateClose",
                args: [tabId],
              }),
            );
            refetch();
          })}
        >
          Initiate close
        </button>
        <button
          disabled={t.status !== 1}
          onClick={safe(async () => {
            await run("Finalize close", () =>
              writeContractAsync({
                address: calltab,
                abi: callTabAbi,
                functionName: "finalizeClose",
                args: [tabId],
              }),
            );
            refetch();
          })}
        >
          Finalize close
        </button>
      </div>
      <Hint>
        Top up adds USDC from your wallet to this tab (approval, then top up). Pause blocks the provider from
        redeeming until you unpause.
      </Hint>
      <Hint tone="danger">
        Initiate close starts the challenge window ({Number(t.challengeWindow) / 3600} hours): the provider can still
        redeem the latest voucher during it. After the window, “Finalize close” (anyone can press it) refunds the
        unspent USDC to the payer and the tab is closed for good.
      </Hint>

      <h3>Voucher (payer or agent signs, provider redeems)</h3>
      <p className="muted">
        A voucher states the total owed since the tab opened, not the next payment. Signing 10 and later 25 lets the
        provider collect 25 in total.
      </p>
      <div className="row">
        <label>
          Cumulative USDC
          <input value={cum} onChange={(e) => setCum(e.target.value)} />
        </label>
        <label>
          Deadline (hours, optional)
          <input value={deadlineHours} placeholder="none" onChange={(e) => setDeadlineHours(e.target.value)} />
        </label>
        <button
          disabled={!walletClient}
          onClick={safe(async () => {
            const v = buildVoucher();
            if (v.cumulativeAmount > t.deposited)
              return fail("Cumulative amount is larger than the tab deposit. Top up first or lower the amount.");
            const sig = await signVoucher(walletClient!, chainId, calltab, v);
            setSignature(sig);
          })}
        >
          Sign voucher
        </button>
      </div>
      <Hint>
        Signing is free and sends no transaction, but it is a payment promise: whoever holds this signature and is
        the provider can collect up to the cumulative amount from the tab. The wallet shows the tab id, amount and
        deadline before you sign.
      </Hint>
      <label>
        Signature
        <textarea value={signature} spellCheck={false} onChange={(e) => setSignature(e.target.value.trim())} placeholder="0x…" />
      </label>
      <div className="row" style={{ marginTop: 8 }}>
        <button
          disabled={!isProvider || !signature}
          onClick={safe(async () => {
            const v = buildVoucher();
            await run("Redeem", () =>
              writeContractAsync({
                address: calltab,
                abi: callTabAbi,
                functionName: "redeem",
                args: [tabId, v.cumulativeAmount, v.deadline, signature as Hex],
              }),
            );
            refetch();
          })}
        >
          Redeem (provider)
        </button>
      </div>
      <Hint>
        Redeem sends one transaction that pays the provider the cumulative amount minus what was already claimed.
        The amount and deadline fields above must match the signed voucher exactly.
      </Hint>
      {status}
    </div>
  );
}
