"""Record a HIP-3 perp's oracle, mark and best bid/ask on HyperEVM, once a second, live.

    python3 -I script/record_hip3.py <dex> <index> <szDecimals> <seconds> <out.json>

The price precompiles (0x806 mark, 0x807 oracle, 0x80e best bid/ask) answer with the current
state whatever block a call names, so a round cannot be replayed from history: it has to be
recorded while it happens. Each sample is one JSON-RPC batch: the latest block, then the three
precompile calls, all at that block number.
"""
import json, sys, time, urllib.request

RPC = "https://rpc.hyperliquid.xyz/evm"
dex, index, sz, seconds, out = int(sys.argv[1]), int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4]), sys.argv[5]
perp = dex * 10000 + index
bbo_idx = index if dex == 0 else 100000 + dex * 10000 + index


def word(n):
    return "0x" + n.to_bytes(32, "big").hex()


def batch(calls):
    body = json.dumps([{"jsonrpc": "2.0", "id": i, "method": m, "params": p} for i, (m, p) in enumerate(calls)]).encode()
    req = urllib.request.Request(RPC, body, {"content-type": "application/json", "user-agent": "curl/8.7.1"})
    res = json.load(urllib.request.urlopen(req, timeout=10))
    return [r.get("result") for r in sorted(res, key=lambda r: r["id"])]


samples, end = [], time.time() + seconds
while time.time() < end:
    t0 = time.time()
    try:
        blk = batch([("eth_getBlockByNumber", ["latest", False])])[0]
        tag = blk["number"]
        o, m, b = batch([
            ("eth_call", [{"to": "0x0000000000000000000000000000000000000807", "data": word(perp)}, tag]),
            ("eth_call", [{"to": "0x0000000000000000000000000000000000000806", "data": word(perp)}, tag]),
            ("eth_call", [{"to": "0x000000000000000000000000000000000000080e", "data": word(bbo_idx)}, tag]),
        ])
        samples.append({
            "block": int(tag, 16), "ts": int(blk["timestamp"], 16), "wall": t0,
            "oracle": int(o, 16), "mark": int(m, 16), "bid": int(b[2:66], 16), "ask": int(b[66:130], 16),
        })
    except Exception as e:
        samples.append({"wall": t0, "error": str(e)[:200]})
    time.sleep(max(0, 1 - (time.time() - t0)))

json.dump({"dex": dex, "index": index, "szDecimals": sz, "samples": samples}, open(out, "w"), indent=0)
ok = [s for s in samples if "error" not in s]
print(f"{len(ok)} samples, {len(samples) - len(ok)} errors, blocks {ok[0]['block']}..{ok[-1]['block']}" if ok else "no samples")
