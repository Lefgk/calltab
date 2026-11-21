import { useMemo, useState } from "react";
import {
  useAccount,
  useChainId,
  useConnect,
  useDisconnect,
  usePublicClient,
  useReadContract,
  useSwitchChain,
  useWalletClient,
  useWriteContract,
} from "wagmi";
import { erc20Abi, formatUnits, parseUnits, type Address, type Hex } from "viem";
import { callTabAbi } from "./abi";
import { deployments } from "./config";
import { signVoucher, type Voucher } from "./lib/voucher";

const short = (a?: string) => (a ? `${a.slice(0, 6)}…${a.slice(-4)}` : "");
const STATUS = ["Open", "Closing", "Closed"] as const;

export default function App() {
  const { address, isConnected } = useAccount();
  const chainId = useChainId();
  const { connect, connectors } = useConnect();
  const { disconnect } = useDisconnect();
  const { switchChain, chains } = useSwitchChain();
  const dep = deployments[chainId] ?? {};
  const [tabId, setTabId] = useState("");

  return (
    <div className="wrap">
      <h1>Calltab</h1>
      <div className="muted">
        Prepaid USDC tabs for agents: lock once, sign cumulative EIP-712 vouchers, redeem only the
        delta, pause any time, close with a challenge window. Prototype — not audited. Ethereum,
        Base and local anvil.
      </div>

      <div className="card">
        <h2>Wallet</h2>
        {!isConnected ? (
          <div className="row">
            {connectors.map((c) => (
              <button key={c.uid} onClick={() => connect({ connector: c })}>
                Connect {c.name}
              </button>
            ))}
          </div>
        ) : (
          <div className="row">
            <span>
              Connected <code>{address}</code>
            </span>
            <button className="ghost" onClick={() => disconnect()}>
              Disconnect
            </button>
          </div>
        )}
        <div className="row">
          {chains.map((c) => (
            <button
              key={c.id}
              className={c.id === chainId ? "" : "ghost"}
              onClick={() => switchChain({ chainId: c.id })}
            >
              {c.name}
            </button>
          ))}
        </div>
        {!deployments[chainId] && (
          <div className="warn">Unsupported chain: use Ethereum, Base or local anvil.</div>
        )}
        {deployments[chainId] && !dep.calltab && (
          <div className="warn">
            <strong>Not deployed yet</strong> on this chain — the CallTab address is empty. Core
            flows stay disabled until you deploy (<code>make deploy-mainnet</code> or{" "}
            <code>make deploy-base</code>), which writes the address into{" "}
            <code>web/src/deployments.json</code>.
          </div>
        )}
        {deployments[chainId]?.live && dep.calltab && (
          <div className="warn">
            Live chain with real funds. This contract is NOT audited — only deposit amounts you can
            afford to lose.
          </div>
        )}
      </div>

      {isConnected && address && dep.calltab && dep.usdc && (
        <>
          <OpenTab calltab={dep.calltab} usdc={dep.usdc} onOpened={setTabId} />
          <TabPicker
            address={address}
            calltab={dep.calltab}
            tabId={tabId}
            setTabId={setTabId}
          />
          {tabId && <TabActions calltab={dep.calltab} usdc={dep.usdc} tabId={BigInt(tabId)} />}
        </>
      )}
    </div>
  );
}

function useTx() {
  const { writeContractAsync } = useWriteContract();
  const client = usePublicClient();
  const [status, setStatus] = useState("");
  const run = async (label: string, fn: () => Promise<`0x${string}`>) => {
    try {
      setStatus(`${label}: confirm in wallet…`);
      const hash = await fn();
      setStatus(`${label}: pending ${short(hash)}`);
      await client!.waitForTransactionReceipt({ hash });
      setStatus(`${label}: confirmed ✓`);
      return true;
    } catch (e) {
      setStatus(`${label}: ${(e as Error).message.split("\n")[0]}`);
      return false;
    }
  };
  return { writeContractAsync, status, run };
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
  const { writeContractAsync, status, run } = useTx();
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
      <h2>1. Open a tab</h2>
      <div className="row">
        <label>
          Provider address
          <input value={provider} placeholder="0x…" onChange={(e) => setProvider(e.target.value)} />
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
          <input value={agent} placeholder="0x… or empty" onChange={(e) => setAgent(e.target.value)} />
        </label>
        <button
          onClick={async () => {
            const amt = parseUnits(amount, 6);
            const cap = periodCap ? parseUnits(periodCap, 6) : 0n;
            const duration = cap > 0n ? BigInt(Math.floor(Number(periodDays || "1") * 86400)) : 0n;
            const expiry = expiryDays
              ? BigInt(Math.floor(Date.now() / 1000) + Number(expiryDays) * 86400)
              : 0n;
            const window = BigInt(Math.floor(Number(windowHours || "24") * 3600));
            const agentAddr = (agent || "0x0000000000000000000000000000000000000000") as Address;
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
          }}
        >
          Approve + open
        </button>
      </div>
      <div className="muted">{status}</div>
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
  const { data: asPayer } = useReadContract({
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
      <div className="row">
        <label>
          Tab id
          <input value={tabId} placeholder="1" onChange={(e) => setTabId(e.target.value)} />
        </label>
      </div>
      {mine.length > 0 && (
        <div className="row">
          {mine.map((id) => (
            <button key={id} className={id === tabId ? "" : "ghost"} onClick={() => setTabId(id)}>
              #{id}
            </button>
          ))}
        </div>
      )}
    </div>
  );
}

function TabActions({ calltab, usdc, tabId }: { calltab: Address; usdc: Address; tabId: bigint }) {
  const chainId = useChainId();
  const { address } = useAccount();
  const { data: walletClient } = useWalletClient();
  const { writeContractAsync, status, run } = useTx();
  const { data: t, refetch } = useReadContract({
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

  if (!t || t.payer === "0x0000000000000000000000000000000000000000") {
    return (
      <div className="card">
        <h2>3. Tab</h2>
        <div className="muted">No tab with that id on this chain.</div>
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
      <div className="muted">
        {statusLabel}
        {t.paused ? " · paused" : ""} · payer {short(t.payer)} · provider {short(t.provider)}
        {t.agent !== "0x0000000000000000000000000000000000000000" ? ` · agent ${short(t.agent)}` : ""}
      </div>
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

      <div className="row" style={{ marginTop: 12 }}>
        <label>
          Top up (USDC)
          <input value={topUpAmt} onChange={(e) => setTopUpAmt(e.target.value)} />
        </label>
        <button
          disabled={!isPayer}
          onClick={async () => {
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
          }}
        >
          Top up
        </button>
        <button
          disabled={!isPayer}
          className={t.paused ? "" : "ghost"}
          onClick={async () => {
            await run(t.paused ? "Unpause" : "Pause", () =>
              writeContractAsync({
                address: calltab,
                abi: callTabAbi,
                functionName: t.paused ? "unpause" : "pause",
                args: [tabId],
              }),
            );
            refetch();
          }}
        >
          {t.paused ? "Unpause" : "Pause"}
        </button>
        <button
          disabled={!isPayer || t.status !== 0}
          className="danger"
          onClick={async () => {
            await run("Initiate close", () =>
              writeContractAsync({
                address: calltab,
                abi: callTabAbi,
                functionName: "initiateClose",
                args: [tabId],
              }),
            );
            refetch();
          }}
        >
          Initiate close
        </button>
        <button
          disabled={t.status !== 1}
          onClick={async () => {
            await run("Finalize close", () =>
              writeContractAsync({
                address: calltab,
                abi: callTabAbi,
                functionName: "finalizeClose",
                args: [tabId],
              }),
            );
            refetch();
          }}
        >
          Finalize close
        </button>
      </div>

      <h2 style={{ marginTop: 16 }}>Sign voucher</h2>
      <div className="muted">Payer or authorized agent signs a cumulative amount (USDC, all-time owed).</div>
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
          onClick={async () => {
            const v = buildVoucher();
            const sig = await signVoucher(walletClient!, chainId, calltab, v);
            setSignature(sig);
          }}
        >
          Sign voucher
        </button>
      </div>
      <label>
        Signature
        <textarea value={signature} onChange={(e) => setSignature(e.target.value)} placeholder="0x…" />
      </label>
      <div className="row" style={{ marginTop: 8 }}>
        <button
          disabled={!isProvider || !signature}
          onClick={async () => {
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
          }}
        >
          Redeem (provider)
        </button>
      </div>
      <div className="muted">{status}</div>
    </div>
  );
}
