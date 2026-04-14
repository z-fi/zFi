// ---- Send Tab ----
const COOKBOOK_ADDRESS = "0x000000000000040470635EB91b7CE4D132D616eD";
const COOKBOOK_LOCK_ABI = [
  "function lockup(address token, address to, uint256 id, uint256 amount, uint256 unlockTime) payable returns (bytes32)",
  "function unlock(address token, address to, uint256 id, uint256 amount, uint256 unlockTime)",
  "function lockups(bytes32) view returns (uint256)"
];
const ERC20_TRANSFER_ABI = [
  "function transfer(address to, uint256 amount) returns (bool)",
  "function approve(address spender, uint256 amount) returns (bool)",
  "function allowance(address owner, address spender) view returns (uint256)",
  "function balanceOf(address) view returns (uint256)",
  "function decimals() view returns (uint8)"
];
const INDEXER_BASE = "https://coinchan-indexer-production.up.railway.app";

let _sendToken = 'ETH';
let _sendResolvedAddr = null;
let _sendResolveSeq = 0;
let _sendDebounce = null;
let _sendTokenBal = null;
let _sendTokenDec = 18;

function sendUpdateTokenDisplay() {
  const t = tokens[_sendToken];
  if (!t) return;
  setHTML('sendTokenIcon', iconForSymbol(_sendToken));
  setText('sendTokenSymbol', t.symbol || _sendToken);
}

async function sendUpdateBalance() {
  const balEl = $('sendBalanceText');
  if (!_connectedAddress) { balEl.textContent = 'Balance: --'; return; }
  const sym = _sendToken;
  const t = tokens[sym];
  if (!t) { balEl.textContent = 'Balance: --'; return; }
  try {
    const rpc = await quoteRPC.call(r => r);
    if (t.address === ZERO_ADDRESS) {
      const bal = await rpc.getBalance(_connectedAddress);
      _sendTokenBal = bal;
      _sendTokenDec = 18;
      balEl.textContent = 'Balance: ' + (+ethers.formatEther(bal)).toFixed(5) + ' ' + sym;
    } else {
      const c = new ethers.Contract(t.address, ERC20_TRANSFER_ABI, rpc);
      const [bal, dec] = await Promise.all([c.balanceOf(_connectedAddress), c.decimals().catch(() => t.decimals || 18)]);
      _sendTokenBal = bal;
      _sendTokenDec = Number(dec);
      balEl.textContent = 'Balance: ' + (+ethers.formatUnits(bal, _sendTokenDec)).toFixed(5) + ' ' + sym;
    }
  } catch {
    balEl.textContent = 'Balance: --';
  }
  sendUpdateButton();
}

function sendSetMax() {
  if (_sendTokenBal != null && _sendTokenBal > 0n) {
    $('sendAmount').value = ethers.formatUnits(_sendTokenBal, _sendTokenDec);
  }
}

function sendUpdateButton() {
  const btn = $('sendBtn');
  if (!_connectedAddress) { btn.disabled = false; btn.textContent = 'Connect Wallet'; return; }
  btn.disabled = false;
  btn.textContent = $('sendUnlockTime').value ? 'Create Timelock' : 'Send';
}

// Recipient resolution
document.addEventListener("DOMContentLoaded", () => {
  const el = $('sendTo');
  if (!el) return;
  el.addEventListener('input', () => {
    const v = el.value.trim();
    _sendResolvedAddr = null;
    $('sendToResolved').style.display = 'none';
    if (ethers.isAddress(v)) {
      _sendResolvedAddr = ethers.getAddress(v);
    } else if (v.endsWith('.wei') || v.endsWith('.eth')) {
      clearTimeout(_sendDebounce);
      _sendDebounce = setTimeout(() => sendResolveName(v), 350);
    }
    syncSendURL();
  });
  const sa = $('sendAmount');
  if (sa) {
    sa.addEventListener('input', debounce(syncSendURL, 400));
    sa.addEventListener("blur", () => { if (sa.value && !isNaN(sa.value)) sa.value = +sa.value; });
  }
  const ut = $('sendUnlockTime');
  if (ut) ut.addEventListener('input', sendUpdateButton);
});

async function sendResolveName(name) {
  const seq = ++_sendResolveSeq;
  const el = $('sendToResolved');
  try {
    let resolved = null;
    if (name.endsWith('.wei')) {
      resolved = await quoteRPC.call(async (rpc) => {
        const ns = getWeinsContract(rpc);
        const tokenId = await ns.computeId(name);
        const owner = await ns.ownerOf(tokenId).catch(() => null);
        if (!owner || owner === ZERO_ADDRESS) return null;
        return ethers.getAddress(owner);
      });
    } else if (name.endsWith('.eth')) {
      resolved = await quoteRPC.call(async (rpc) => rpc.resolveName(name));
    }
    if (seq !== _sendResolveSeq) return;
    if (resolved && resolved !== ZERO_ADDRESS) {
      _sendResolvedAddr = resolved;
      el.style.display = 'block';
      el.style.color = 'var(--fg-muted)';
      el.textContent = resolved;
    } else {
      el.style.display = 'block';
      el.style.color = 'var(--error)';
      el.textContent = 'Name not found';
    }
  } catch {
    if (seq !== _sendResolveSeq) return;
    el.style.display = 'block';
    el.style.color = 'var(--error)';
    el.textContent = 'Failed to resolve';
  }
}

async function doSendOrLock() {
  if (!_connectedAddress) { connectWallet(); return; }
  const sym = _sendToken;
  const amtStr = $('sendAmount').value;
  const toRaw = $('sendTo').value.trim();
  const unlockStr = $('sendUnlockTime').value;
  const statusEl = $('sendStatus');

  if (!amtStr || Number(amtStr) <= 0) { statusEl.textContent = 'Enter an amount'; statusEl.className = 'status show error'; return; }

  // Resolve recipient
  let toAddr = _sendResolvedAddr;
  if (!toAddr && ethers.isAddress(toRaw)) toAddr = ethers.getAddress(toRaw);
  if (!toAddr) { statusEl.textContent = 'Enter a valid recipient'; statusEl.className = 'status show error'; return; }

  const t = tokens[sym];
  if (!t) { statusEl.textContent = 'Unknown token'; statusEl.className = 'status error'; return; }
  const tokenAddr = t.address;
  const isETH = tokenAddr === ZERO_ADDRESS;
  const dec = _sendTokenDec;
  let amount;
  try { amount = ethers.parseUnits(amtStr, dec); } catch { statusEl.textContent = 'Invalid amount'; statusEl.className = 'status show error'; return; }
  if (_sendTokenBal != null && amount > _sendTokenBal) { statusEl.textContent = 'Insufficient ' + sym + ' balance'; statusEl.className = 'status show error'; return; }
  const isTimelock = !!unlockStr;

  try {
    if (isTimelock) {
      const unlockTime = Math.floor(new Date(unlockStr).getTime() / 1000);
      if (unlockTime <= Math.floor(Date.now() / 1000)) {
        statusEl.textContent = 'Unlock time must be in the future';
        statusEl.className = 'status show error';
        return;
      }
      const cookbook = new ethers.Contract(COOKBOOK_ADDRESS, COOKBOOK_LOCK_ABI, _signer);

      // Approve ERC20 if needed
      if (!isETH) {
        statusEl.textContent = 'Checking approval...';
        statusEl.className = 'status show';
        const erc20 = new ethers.Contract(tokenAddr, ERC20_TRANSFER_ABI, _signer);
        const allowance = await erc20.allowance(_connectedAddress, COOKBOOK_ADDRESS);
        if (allowance < amount) {
          statusEl.textContent = 'Approving token...'; statusEl.className = 'status show';
          const approveTx = await erc20.approve(COOKBOOK_ADDRESS, ethers.MaxUint256);
          await approveTx.wait();
        }
      }

      statusEl.textContent = 'Creating timelock...';
      statusEl.className = 'status show';
      const tx = await cookbook.lockup(
        isETH ? ZERO_ADDRESS : tokenAddr,
        toAddr, 0, amount, unlockTime,
        { value: isETH ? amount : 0n }
      );
      statusEl.innerHTML = 'Confirming... <a href="https://etherscan.io/tx/' + escAttr(tx.hash) + '" target="_blank" style="color:inherit;text-decoration:underline">view tx &#8599;</a>'; statusEl.className = 'status show';
      await waitForTx(tx);
      statusEl.innerHTML = 'Timelock created! <a href="https://etherscan.io/tx/' + escAttr(tx.hash) + '" target="_blank" style="color:inherit;text-decoration:underline">view tx &#8599;</a>';
      statusEl.className = 'status show success';
      $('sendAmount').value = '';
      sendUpdateBalance();
      setTimeout(sendLoadTimelocks, 3000);
    } else {
      // Direct send
      statusEl.textContent = 'Sending...';
      statusEl.className = 'status show';
      let tx;
      if (isETH) {
        tx = await _signer.sendTransaction({ to: toAddr, value: amount });
      } else {
        const erc20 = new ethers.Contract(tokenAddr, ERC20_TRANSFER_ABI, _signer);
        tx = await erc20.transfer(toAddr, amount);
      }
      statusEl.innerHTML = 'Confirming... <a href="https://etherscan.io/tx/' + escAttr(tx.hash) + '" target="_blank" style="color:inherit;text-decoration:underline">view tx &#8599;</a>'; statusEl.className = 'status show';
      await waitForTx(tx);
      statusEl.innerHTML = 'Sent! <a href="https://etherscan.io/tx/' + escAttr(tx.hash) + '" target="_blank" style="color:inherit;text-decoration:underline">view tx &#8599;</a>';
      statusEl.className = 'status show success';
      $('sendAmount').value = '';
      sendUpdateBalance();
    }
  } catch (e) {
    console.error(e);
    statusEl.textContent = e.reason || e.message || 'Transaction failed';
    statusEl.className = 'status show error';
  }
}

// ---- Timelocks ----
async function sendLoadTimelocks() {
  const el = $('timelockList');
  if (!_connectedAddress) { el.textContent = 'Connect wallet to view timelocks'; return; }
  el.innerHTML = '<div style="color:var(--fg-dim);font-size:12px">Loading...</div>';
  try {
    const res = await fetch(INDEXER_BASE + "/graphql", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        query: `query ($address: String!) {
          account(address: $address) {
            lockupSent { items { id token coinId sender to amount unlockTime createdAt txHash coin { name symbol decimals } } }
            lockupReceived { items { id token coinId sender to amount unlockTime createdAt txHash coin { name symbol decimals } } }
          }
        }`,
        variables: { address: _connectedAddress }
      })
    });
    const { data } = await res.json();
    const account = data ? data.account : null;
    if (!account) { el.textContent = 'No timelocks found'; return; }

    const sent = (account.lockupSent?.items || []).map(l => ({ ...l, direction: 'sent' }));
    const received = (account.lockupReceived?.items || []).map(l => ({ ...l, direction: 'received' }));
    const all = [...sent, ...received].sort((a, b) => Number(b.createdAt) - Number(a.createdAt));
    if (all.length === 0) { el.textContent = 'No timelocks found'; return; }

    // Check on-chain status in batch
    const rpc = await quoteRPC.call(r => r);
    const cookbook = new ethers.Contract(COOKBOOK_ADDRESS, COOKBOOK_LOCK_ABI, rpc);
    const abiCoder = ethers.AbiCoder.defaultAbiCoder();

    // Precompute lock metadata and hashes
    const lockMeta = all.map(lock => {
      const token = lock.token || ZERO_ADDRESS;
      const isETH = token.toLowerCase() === ZERO_ADDRESS.toLowerCase();
      const coinId = isETH ? 0n : (lock.coinId ? BigInt(lock.coinId) : 0n);
      const amount = BigInt(lock.amount || '0');
      const unlockTime = BigInt(lock.unlockTime || '0');
      const encoded = abiCoder.encode(
        ["address", "address", "uint256", "uint256", "uint256"],
        [token, lock.to, coinId, amount, unlockTime]
      );
      return { lock, token, isETH, coinId, amount, unlockTime, hash: ethers.keccak256(encoded) };
    });

    // Batch on-chain status checks
    const onChainResults = await Promise.all(
      lockMeta.map(m => cookbook.lockups(m.hash).catch(() => 1n))
    );
    const now = Math.floor(Date.now() / 1000);

    let html = '';
    for (let i = 0; i < lockMeta.length; i++) {
      const m = lockMeta[i];
      const lock = m.lock;
      const onChain = onChainResults[i];
      let status;
      if (onChain === 0n) continue;
      else if (now >= Number(m.unlockTime)) status = 'unlockable';
      else status = 'locked';

      const asset = m.isETH ? 'ETH' : esc(lock.coin?.symbol || 'ERC20');
      const dec = m.isETH ? 18 : (lock.coin?.decimals ? Number(lock.coin.decimals) : 18);
      const fmtAmt = (+ethers.formatUnits(m.amount, dec)).toFixed(5);
      const unlockDate = new Date(Number(m.unlockTime) * 1000).toLocaleString();
      const counterparty = lock.direction === 'sent'
        ? 'To: ' + lock.to.slice(0, 6) + '...' + lock.to.slice(-4)
        : 'From: ' + lock.sender.slice(0, 6) + '...' + lock.sender.slice(-4);

      html += `<div class="timelock-item ${status}">
        <div class="timelock-head">
          <span class="timelock-amount">${fmtAmt} <span style="font-weight:400;font-size:12px;letter-spacing:0.04em">${asset}</span></span>
          <span class="timelock-status ${status}">${status}</span>
        </div>
        <div class="timelock-meta">
          ${esc(counterparty)} &middot; ${lock.direction} &middot; ${unlockDate}
          &middot; <a href="https://etherscan.io/tx/${escAttr(lock.txHash)}" target="_blank" rel="noopener" style="color:inherit">${esc(lock.txHash.slice(0, 10))}...</a>
        </div>
        ${status === 'unlockable' ? `<div class="timelock-claim"><button onclick="claimTimelock('${escAttr(m.token)}','${escAttr(lock.to)}','${escAttr(String(m.coinId))}','${escAttr(String(m.amount))}','${escAttr(String(m.unlockTime))}',this)">Claim</button></div>` : ''}
      </div>`;
    }
    el.innerHTML = html || 'No active timelocks';
  } catch (e) {
    console.error(e);
    el.textContent = 'Failed to load timelocks';
  }
}

async function claimTimelock(token, to, coinId, amount, unlockTime, btn) {
  if (!_signer) { connectWallet(); return; }
  btn.disabled = true;
  btn.textContent = 'Claiming...';
  try {
    const cookbook = new ethers.Contract(COOKBOOK_ADDRESS, COOKBOOK_LOCK_ABI, _signer);
    const tx = await cookbook.unlock(token, to, BigInt(coinId), BigInt(amount), BigInt(unlockTime));
    btn.innerHTML = 'Confirming... <a href="https://etherscan.io/tx/' + escAttr(tx.hash) + '" target="_blank" style="color:inherit;text-decoration:underline;font-size:11px">tx &#8599;</a>';
    await tx.wait();
    btn.innerHTML = 'Claimed! <a href="https://etherscan.io/tx/' + escAttr(tx.hash) + '" target="_blank" style="color:inherit;text-decoration:underline;font-size:11px">tx &#8599;</a>';
    setTimeout(sendLoadTimelocks, 2000);
  } catch (e) {
    btn.disabled = false;
    btn.textContent = 'Claim';
    alert('Claim failed: ' + (e.reason || e.message));
  }
}
