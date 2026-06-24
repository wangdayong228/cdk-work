#!/usr/bin/env python3
"""
自动对比 InvalidProof (0x09bde339) 两边的数据。

从 aggregator 数据库提取 prover public inputs，与 L1 合约的 inputSnark 字段逐字段对比，
定位 212 字节中具体哪个字段不匹配。

用法:
    # 对比指定 batch 的 proof
    python3 compare-invalidproof.py --batch 1

    # 只对比已知的 publics 数组和 L1 数据（离线模式）
    python3 compare-invalidproof.py --offline \
        --publics '2420688097,2333259367,...' \
        --l1-rpc http://184.32.182.132/espace \
        --rollup-manager 0x9dfC9f5864F1d1a7dB83EC2e81F876BFD68dF1EE

    # 从 aggregator 容器自动提取并对比
    python3 compare-invalidproof.py --from-aggregator \
        --aggregator-container cdk-node-1--3b00054c8e994fd1822ab67923f076ec
"""

import argparse
import json
import os
import re
import requests
import subprocess
import sys

# Goldilocks 域的素数
GOLDILOCKS_PRIME = 2**64 - 2**32 + 1  # 18446744069414584321


# ========================= 自动发现辅助函数 =========================

def _docker_ps(filter_name=None):
    """列出运行中的 docker 容器名称。"""
    cmd = ["docker", "ps", "--format", "{{.Names}}"]
    if filter_name:
        cmd += ["--filter", f"name={filter_name}"]
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        return []
    return [ln.strip() for ln in r.stdout.splitlines() if ln.strip()]


def find_cdk_node_container():
    """自动查找 cdk-node aggregator 容器名。"""
    names = _docker_ps("cdk-node")
    if names:
        return names[0]
    names = _docker_ps("cdk")
    for n in names:
        if "node" in n and "erigon" not in n:
            return n
    return None


def read_container_config(container_name):
    """
    从 cdk-node 容器的 /etc/cdk/cdk-node-config.toml 提取关键配置。
    """
    config = {}
    if not container_name:
        return config
    r = subprocess.run(
        ["docker", "exec", container_name, "cat", "/etc/cdk/cdk-node-config.toml"],
        capture_output=True, text=True,
    )
    if r.returncode != 0:
        return config
    text = r.stdout
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("#") or line.startswith("["):
            continue
        m = re.match(r'^(\w+)\s*=\s*"([^"]*)"', line)
        if m:
            config[m.group(1)] = m.group(2)
    # [L1Config] section
    in_l1 = False
    for line in text.splitlines():
        stripped = line.strip()
        if stripped == "[L1Config]":
            in_l1 = True
            continue
        if stripped.startswith("[") and in_l1:
            in_l1 = False
            continue
        if in_l1:
            m = re.match(r'^(\w+)\s*=\s*"([^"]*)"', stripped)
            if m:
                config[f"L1_{m.group(1)}"] = m.group(2)
    return config


def read_pipeline_state():
    """读取 output/cdk_pipe.state 中的部署参数。"""
    candidates = [
        os.path.join(os.path.dirname(__file__), "../../output/cdk_pipe.state"),
        os.path.expanduser("~/workspace/ydyl-deployment-suite/output/cdk_pipe.state"),
    ]
    for path in candidates:
        path = os.path.realpath(path)
        if os.path.isfile(path):
            state = {}
            with open(path) as f:
                for line in f:
                    line = line.strip()
                    if "=" in line and not line.startswith("#"):
                        k, _, v = line.partition("=")
                        state[k.strip()] = v.strip()
            return state
    return {}


def cast_keccak(data_hex):
    """用 cast keccak 计算 keccak256（本地计算，不需要 RPC）。"""
    if not data_hex.startswith('0x'):
        data_hex = '0x' + data_hex
    cmd = f"cast keccak {data_hex}"
    result = subprocess.run(cmd, shell=True, capture_output=True, text=True)
    if result.returncode != 0:
        print(f"ERROR cast keccak: {result.stderr}", file=sys.stderr)
        return None
    return result.stdout.strip()


def calculate_acc_input_hash(old_acc, batch_l2_data_hash, info_root, timestamp, coinbase, forced_hash):
    """
    手动计算 accInputHash，对应 L1 合约中的公式：
      keccak256(abi.encodePacked(oldAcc, batchL2DataHash, infoRoot, timestamp, coinbase, forcedHash))

    注意 abi.encodePacked 的编码：
      - bytes32: 32 bytes
      - uint64: 8 bytes (big-endian)
      - address: 20 bytes
    """
    # 清理 hex，去掉 0x 前缀
    old_acc_clean = old_acc.replace('0x', '').lower()
    batch_l2_data_hash_clean = batch_l2_data_hash.replace('0x', '').lower()
    info_root_clean = info_root.replace('0x', '').lower()
    coinbase_clean = coinbase.replace('0x', '').lower()[-40:]  # address 取后 40 hex = 20 bytes
    forced_hash_clean = forced_hash.replace('0x', '').lower()

    # uint64 大端 8 bytes = 16 hex chars
    ts_hex = f"{int(timestamp):016x}"

    data = old_acc_clean + batch_l2_data_hash_clean + info_root_clean + ts_hex + coinbase_clean + forced_hash_clean
    return cast_keccak(data)


def get_input_prover_from_aggregator(container_name, batch_num):
    """从 aggregator 容器的数据库中提取 input_prover。"""
    sql = f'SELECT input_prover FROM proof WHERE batch_num={batch_num} ORDER BY updated_at DESC LIMIT 1;'
    cmd = f'docker exec {container_name} sqlite3 /tmp/aggregator_db.sqlite "{sql}"'
    result = subprocess.run(cmd, shell=True, capture_output=True, text=True)
    if result.returncode != 0:
        print(f"ERROR reading input_prover from aggregator DB: {result.stderr}", file=sys.stderr)
        return None

    input_prover_str = result.stdout.strip()
    if not input_prover_str:
        return None

    try:
        return json.loads(input_prover_str)
    except json.JSONDecodeError as e:
        print(f"ERROR parsing input_prover JSON: {e}", file=sys.stderr)
        return None


def get_rollup_contract_address(rollup_manager, rollup_id, l1_rpc):
    """从 L1 RollupManager 读取 rollup 合约地址。"""
    out = run_cast(
        f'call {rollup_manager} "rollupIDToRollupData(uint32)(address,uint64,address,uint64,bytes32,uint64,uint64,uint64,uint64,uint64,uint64,uint8)" {rollup_id}',
        l1_rpc
    )
    if out:
        lines = [ln.strip() for ln in out.strip().split('\n') if ln.strip()]
        if lines:
            return lines[0]
    return None


def run_sqlite_on_container(container_name, db_path, sql):
    """在 aggregator 容器里执行 sqlite3 查询。"""
    cmd = f'docker exec {container_name} sqlite3 {db_path} "{sql}"'
    result = subprocess.run(cmd, shell=True, capture_output=True, text=True)
    if result.returncode != 0:
        print(f"ERROR sqlite3: {result.stderr}", file=sys.stderr)
        return None
    return result.stdout.strip()


def get_virtual_batch_from_sync_db(container_name, batch_num):
    """
    从 aggregator_sync_db.sqlite 的 virtual_batch 表读取 batch 元数据。
    返回字段：batch_num, fork_id, raw_txs_data(hex), coinbase, sequencer_addr,
             l1_info_root, batch_timestamp, sequence_from_batch_num
    """
    sql = (
        f"SELECT batch_num, fork_id, hex(raw_txs_data), coinbase, sequencer_addr, "
        f"l1_info_root, batch_timestamp, sequence_from_batch_num "
        f"FROM virtual_batch WHERE batch_num = {batch_num};"
    )
    out = run_sqlite_on_container(container_name, '/tmp/aggregator_sync_db.sqlite', sql)
    if not out:
        return None

    parts = out.split('|')
    if len(parts) < 8:
        print(f"ERROR unexpected virtual_batch row format: {out}", file=sys.stderr)
        return None

    return {
        'batch_num': int(parts[0]),
        'fork_id': int(parts[1]),
        'raw_txs_data_hex': parts[2],
        'coinbase': parts[3],
        'sequencer_addr': parts[4],
        'l1_info_root': parts[5] if parts[5] else None,
        'batch_timestamp': parts[6],
        'sequence_from_batch_num': int(parts[7]),
    }


def get_sequenced_batch_from_sync_db(container_name, from_batch_num):
    """
    从 aggregator_sync_db.sqlite 的 sequenced_batches 表读取 sequence 元数据。
    """
    sql = (
        f"SELECT block_num, from_batch_num, to_batch_num, fork_id, timestamp, "
        f"l1_info_root, source "
        f"FROM sequenced_batches WHERE from_batch_num = {from_batch_num};"
    )
    out = run_sqlite_on_container(container_name, '/tmp/aggregator_sync_db.sqlite', sql)
    if not out:
        return None

    parts = out.split('|')
    if len(parts) < 7:
        return None

    return {
        'block_num': int(parts[0]),
        'from_batch_num': int(parts[1]),
        'to_batch_num': int(parts[2]),
        'fork_id': int(parts[3]),
        'timestamp': parts[4],
        'l1_info_root': parts[5] if parts[5] else None,
        'source': parts[6],
    }


def get_block_from_sync_db(container_name, block_num):
    """从 aggregator_sync_db.sqlite 的 block 表读取 block 信息。"""
    sql = f"SELECT block_num, block_hash, parent_hash, received_at FROM block WHERE block_num = {block_num};"
    out = run_sqlite_on_container(container_name, '/tmp/aggregator_sync_db.sqlite', sql)
    if not out:
        return None

    parts = out.split('|')
    if len(parts) < 4:
        return None

    return {
        'block_num': int(parts[0]),
        'block_hash': parts[1],
        'parent_hash': parts[2],
        'received_at': parts[3],
    }


def fea2scalar(fe_list):
    """
    把 8 个 Goldilocks field elements 转换为 32 字节的 bytes32 (hex string)。

    对应 zkevm-prover 中的 fea2scalar() 函数：
    - 每 2 个元素组成一个 64 位值（高 32 位来自奇数索引元素，低 32 位来自偶数索引元素）
    - 4 对元素组成 256 位 = 32 字节
    - 整体是大端排列（第 7/6 对在最前面）
    """
    if len(fe_list) != 8:
        raise ValueError(f"Expected 8 field elements, got {len(fe_list)}")

    scalar = 0
    # fe7+fe6, fe5+fe4, fe3+fe2, fe1+fe0
    for i in range(3, -1, -1):
        fe_high = int(fe_list[i * 2 + 1])
        fe_low = int(fe_list[i * 2])
        if fe_high >= 0x100000000 or fe_low >= 0x100000000:
            raise ValueError(f"Field element out of 32-bit range: high={fe_high}, low={fe_low}")
        pair = (fe_high << 32) + fe_low
        scalar = (scalar << 64) | pair

    # 转为 64 字符 hex（补前导零）
    return f"0x{scalar:064x}"


def run_cast(command, l1_rpc):
    """执行 cast 命令并返回输出。"""
    full_cmd = f"cast {command} --rpc-url {l1_rpc}"
    result = subprocess.run(full_cmd, shell=True, capture_output=True, text=True)
    if result.returncode != 0:
        print(f"ERROR running cast: {result.stderr}", file=sys.stderr)
        return None
    return result.stdout.strip()


def get_l1_data(rollup_manager, rollup_id, batch_num, l1_rpc):
    """从 L1 合约读取关键数据。"""
    data = {}

    # batchNumToStateRoot[batch_num - 1] (oldStateRoot)
    out = run_cast(
        f'call {rollup_manager} "getRollupBatchNumToStateRoot(uint32,uint64)(bytes32)" {rollup_id} {batch_num - 1}',
        l1_rpc
    )
    if out:
        data['oldStateRoot'] = out.strip()

    # batchNumToStateRoot[batch_num] (newStateRoot)
    out = run_cast(
        f'call {rollup_manager} "getRollupBatchNumToStateRoot(uint32,uint64)(bytes32)" {rollup_id} {batch_num}',
        l1_rpc
    )
    if out:
        data['newStateRoot'] = out.strip()

    # sequencedBatches[batch_num - 1] (oldAccInputHash)
    out = run_cast(
        f'call {rollup_manager} "getRollupSequencedBatches(uint32,uint64)((bytes32,uint64,uint64))" {rollup_id} {batch_num - 1}',
        l1_rpc
    )
    if out:
        # cast 输出: (0x..., 1781588966 [1.781e9], 0)
        match = re.search(r'\(0x([0-9a-fA-F]+),\s*(\d+)', out)
        if match:
            data['oldAccInputHash'] = f"0x{match.group(1)}"

    # sequencedBatches[batch_num] (newAccInputHash)
    out = run_cast(
        f'call {rollup_manager} "getRollupSequencedBatches(uint32,uint64)((bytes32,uint64,uint64))" {rollup_id} {batch_num}',
        l1_rpc
    )
    if out:
        match = re.search(r'\(0x([0-9a-fA-F]+),\s*(\d+)', out)
        if match:
            data['newAccInputHash'] = f"0x{match.group(1)}"

    # forkID and chainID via rollupIDToRollupData
    # RollupDataReturn = (address rollupContract, uint64 chainID, address verifier,
    #   uint64 forkID, bytes32 lastLocalExitRoot, uint64 lastBatchSequenced,
    #   uint64 lastVerifiedBatch, uint64 _legacyLastPendingState,
    #   uint64 _legacyLastPendingStateConsolidated, uint64 lastVerifiedBatchBeforeUpgrade,
    #   uint64 rollupTypeID, VerifierType rollupVerifierType)
    out = run_cast(
        f'call {rollup_manager} "rollupIDToRollupData(uint32)(address,uint64,address,uint64,bytes32,uint64,uint64,uint64,uint64,uint64,uint64,uint8)" {rollup_id}',
        l1_rpc
    )
    if out:
        # cast 输出多行:
        # line 0 = rollupContract (address)
        # line 1 = chainID (uint64)
        # line 2 = verifier (address)
        # line 3 = forkID (uint64)
        lines = [ln.strip() for ln in out.strip().split('\n') if ln.strip()]
        if len(lines) >= 4:
            # line 1 = chainID
            chain_line = lines[1].split()[0] if lines[1] else None
            if chain_line:
                try:
                    data['chainID'] = int(chain_line)
                except ValueError:
                    pass
            # line 3 = forkID
            fork_line = lines[3].split()[0] if lines[3] else None
            if fork_line:
                try:
                    data['forkID'] = int(fork_line)
                except ValueError:
                    pass

    return data


def get_rpc_batch_state_root(rpc_url, batch_num):
    """通过 zkevm_getBatchByNumber RPC 查询 batch 的 stateRoot。"""
    payload = {
        "jsonrpc": "2.0",
        "method": "zkevm_getBatchByNumber",
        "params": [hex(batch_num), True],
        "id": 1,
    }
    try:
        resp = requests.post(rpc_url, json=payload, headers={"Content-Type": "application/json"}, timeout=10)
        resp.raise_for_status()
        result = resp.json().get("result", {})
        return {
            "stateRoot": result.get("stateRoot"),
            "accInputHash": result.get("accInputHash"),
            "localExitRoot": result.get("localExitRoot"),
            "batchL2Data": result.get("batchL2Data"),
            "timestamp": result.get("timestamp"),
        }
    except Exception as e:
        print(f"ERROR querying RPC batch {batch_num}: {e}", file=sys.stderr)
        return None


def discover_rpc_port(container_name):
    """发现 sequencer/RPC 容器的 8123 端口映射。"""
    # 如果给的是 aggregator 容器，先尝试找同 enclave 的 rpc 容器
    candidates = [container_name]
    if "cdk-node" in container_name:
        # 例：cdk-node-1--1cf5f... -> cdk-erigon-rpc-1--...
        import re
        m = re.search(r"cdk-node-(\d+)--([a-f0-9]+)", container_name)
        if m:
            idx, suffix = m.groups()
            candidates.append(f"cdk-erigon-rpc-{idx}--{suffix}")
            candidates.append(f"cdk-erigon-sequencer-{idx}--{suffix}")
    # 兜底：任意名称包含 rpc 或 sequencer 且映射了 8123 的容器
    try:
        out = subprocess.run(
            "docker ps --format '{{.Names}}'",
            shell=True, capture_output=True, text=True, timeout=10
        )
        if out.returncode == 0:
            for name in out.stdout.splitlines():
                if "rpc" in name or "sequencer" in name:
                    candidates.append(name.strip())
    except Exception:
        pass

    for c in candidates:
        try:
            out = subprocess.run(
                f"docker port {c} 8123",
                shell=True, capture_output=True, text=True, timeout=10
            )
            if out.returncode != 0:
                continue
            line = out.stdout.strip().splitlines()[0]
            # 0.0.0.0:51712
            return f"http://{line}"
        except Exception:
            continue
    return None


def compute_smt_genesis_root(alloc_file, smt_genesis_bin):
    """运行 smt-genesis 二进制计算 allocs 的 SMT root。"""
    if not os.path.isfile(alloc_file):
        return None, f"alloc file not found: {alloc_file}"
    if not os.path.isfile(smt_genesis_bin):
        return None, f"smt-genesis binary not found: {smt_genesis_bin}"
    try:
        result = subprocess.run(
            [smt_genesis_bin, "--alloc", alloc_file],
            capture_output=True, text=True, timeout=60
        )
        if result.returncode != 0:
            return None, result.stderr.strip()
        for line in result.stdout.splitlines():
            line = line.strip()
            if re.match(r"^0x[0-9a-fA-F]{64}$", line):
                return line, None
        return None, "no valid root in smt-genesis output"
    except Exception as e:
        return None, str(e)


def get_aggregator_log_tail(container_name, lines=200):
    """读取 aggregator 容器最近的日志。"""
    try:
        result = subprocess.run(
            f"docker logs {container_name} --tail {lines}",
            shell=True, capture_output=True, text=True, timeout=30
        )
        if result.returncode != 0:
            return None, result.stderr.strip()
        return result.stdout, None
    except Exception as e:
        return None, str(e)


def scan_log_for_invalidproof(log_text):
    """扫描日志文本，汇总 InvalidProof 相关关键行。"""
    if log_text is None:
        return []
    patterns = [
        re.compile(r"InvalidProof", re.IGNORECASE),
        re.compile(r"0x09bde339"),
        re.compile(r"StateRoot mismatch", re.IGNORECASE),
        re.compile(r"failed to estimate gas", re.IGNORECASE),
        re.compile(r"L1 submission values"),
        re.compile(r"Batch 1 inputProver overridden"),
        re.compile(r"Batch proof generated"),
        re.compile(r"verif", re.IGNORECASE),
    ]
    hits = []
    for ln in log_text.splitlines():
        for pat in patterns:
            if pat.search(ln):
                hits.append(ln.strip())
                break
    return hits[-50:]


def get_publics_from_aggregator(container_name, batch_num):
    """从 aggregator 容器的数据库中提取 proof 的 publics 数组。"""
    # 先找最新的 proof
    sql = f'SELECT proof FROM proof WHERE batch_num={batch_num} ORDER BY updated_at DESC LIMIT 1;'
    cmd = f'docker exec {container_name} sqlite3 /tmp/aggregator_db.sqlite "{sql}"'
    result = subprocess.run(cmd, shell=True, capture_output=True, text=True)
    if result.returncode != 0:
        print(f"ERROR reading aggregator DB: {result.stderr}", file=sys.stderr)
        return None

    proof_json_str = result.stdout.strip()
    if not proof_json_str:
        print(f"No proof found for batch {batch_num}", file=sys.stderr)
        return None

    try:
        proof_data = json.loads(proof_json_str)
    except json.JSONDecodeError as e:
        print(f"ERROR parsing proof JSON: {e}", file=sys.stderr)
        return None

    if 'publics' not in proof_data:
        print("ERROR: proof JSON does not contain 'publics' array", file=sys.stderr)
        return None

    publics = [int(x) for x in proof_data['publics']]
    return publics


def decode_publics(publics):
    """解码 44 个 public inputs 为各个字段。"""
    if len(publics) < 44:
        raise ValueError(f"Expected at least 44 publics, got {len(publics)}")

    fields = {}
    fields['oldStateRoot'] = fea2scalar(publics[0:8])
    fields['oldAccInputHash'] = fea2scalar(publics[8:16])
    fields['oldBatchNum'] = publics[16]
    fields['chainID'] = publics[17]
    fields['forkID'] = publics[18]
    fields['newStateRoot'] = fea2scalar(publics[19:27])
    fields['newAccInputHash'] = fea2scalar(publics[27:35])
    fields['newLocalExitRoot'] = fea2scalar(publics[35:43])
    fields['newBatchNum'] = publics[43]
    return fields


def compare_fields(prover_fields, l1_data, batch_num):
    """对比 prover 和 L1 的字段，输出不匹配项。"""
    print(f"\n{'='*70}")
    print(f"Batch {batch_num} InvalidProof 对比结果")
    print(f"{'='*70}")

    mismatches = []
    checks = []

    # oldStateRoot
    prover_val = prover_fields.get('oldStateRoot', 'N/A')
    l1_val = l1_data.get('oldStateRoot', 'N/A')
    match = prover_val.lower() == l1_val.lower()
    checks.append(('oldStateRoot', prover_val, l1_val, match))
    if not match:
        mismatches.append('oldStateRoot')

    # oldAccInputHash
    prover_val = prover_fields.get('oldAccInputHash', 'N/A')
    l1_val = l1_data.get('oldAccInputHash', 'N/A')
    match = prover_val.lower() == l1_val.lower()
    checks.append(('oldAccInputHash', prover_val, l1_val, match))
    if not match:
        mismatches.append('oldAccInputHash')

    # oldBatchNum (initNumBatch)
    prover_val = f"{prover_fields.get('oldBatchNum', 'N/A')}"
    l1_val = f"{batch_num - 1}"
    match = prover_val == l1_val
    checks.append(('initNumBatch', prover_val, l1_val, match))
    if not match:
        mismatches.append('initNumBatch')

    # chainID
    prover_val = f"{prover_fields.get('chainID', 'N/A')}"
    l1_val = f"{l1_data.get('chainID', 'N/A')}"
    match = prover_val == l1_val
    checks.append(('chainID', prover_val, l1_val, match))
    if not match:
        mismatches.append('chainID')

    # forkID
    prover_val = f"{prover_fields.get('forkID', 'N/A')}"
    l1_val = f"{l1_data.get('forkID', 'N/A')}"
    match = prover_val == l1_val
    checks.append(('forkID', prover_val, l1_val, match))
    if not match:
        mismatches.append('forkID')

    # newStateRoot
    prover_val = prover_fields.get('newStateRoot', 'N/A')
    l1_val = l1_data.get('newStateRoot', 'N/A')
    match = prover_val.lower() == l1_val.lower()
    checks.append(('newStateRoot', prover_val, l1_val, match))
    if not match:
        mismatches.append('newStateRoot')

    # newAccInputHash
    prover_val = prover_fields.get('newAccInputHash', 'N/A')
    l1_val = l1_data.get('newAccInputHash', 'N/A')
    match = prover_val.lower() == l1_val.lower()
    checks.append(('newAccInputHash', prover_val, l1_val, match))
    if not match:
        mismatches.append('newAccInputHash')

    # newLocalExitRoot
    prover_val = prover_fields.get('newLocalExitRoot', 'N/A')
    l1_val = '0x0000000000000000000000000000000000000000000000000000000000000000'  # 通常为空
    match = prover_val.lower() == l1_val.lower()
    checks.append(('newLocalExitRoot', prover_val, l1_val, match))
    if not match:
        mismatches.append('newLocalExitRoot')

    # finalNewBatch
    prover_val = f"{prover_fields.get('newBatchNum', 'N/A')}"
    l1_val = f"{batch_num}"
    match = prover_val == l1_val
    checks.append(('finalNewBatch', prover_val, l1_val, match))
    if not match:
        mismatches.append('finalNewBatch')

    # 打印对比表
    print(f"\n{'Field':<20} {'Prover (circuit)':<68} {'L1 (contract)':<68} {'Status'}")
    print(f"{'-'*20} {'-'*68} {'-'*68} {'-'*10}")
    for name, pval, lval, ok in checks:
        status = "OK" if ok else "MISMATCH"
        print(f"{name:<20} {pval:<68} {lval:<68} {status}")

    print(f"\n{'='*70}")
    if mismatches:
        print(f"发现 {len(mismatches)} 个不匹配字段: {', '.join(mismatches)}")
        print("这些字段的差异会导致 inputSnark 的 sha256 结果不同，从而触发 InvalidProof (0x09bde339)。")
    else:
        print("所有字段都匹配！InvalidProof 的原因可能是：")
        print("  1. prover circuit 与 L1 verifier 合约版本不匹配")
        print("  2. inputSnark 的 sha256 计算在电路与合约之间有差异")
        print("  3. proof 本身（groth16/FFLONK 部分）有问题")
    print(f"{'='*70}\n")

    return len(mismatches) == 0


def get_l1_block_info(l1_rpc, block_num):
    """读取 L1 指定 block 的 timestamp 和 hash。"""
    ts = run_cast(f'block {block_num} --field timestamp', l1_rpc)
    bh = run_cast(f'block {block_num} --field hash', l1_rpc)
    ph = run_cast(f'block {block_num} --field parentHash', l1_rpc)
    try:
        ts_int = int(ts) if ts else None
    except ValueError:
        ts_int = None
    return {'timestamp': ts_int, 'hash': bh, 'parentHash': ph}


def get_l1_rollup_initialize_info(rollup_contract, l1_rpc):
    """读取 rollup 合约的 trustedSequencer, globalExitRootManager, lastAccInputHash。"""
    info = {}
    seq = run_cast(f'call {rollup_contract} "trustedSequencer()(address)"', l1_rpc)
    if seq:
        info['trustedSequencer'] = seq.strip()
    ger_mgr = run_cast(f'call {rollup_contract} "globalExitRootManager()(address)"', l1_rpc)
    if ger_mgr:
        info['globalExitRootManager'] = ger_mgr.strip()
    last_acc = run_cast(f'call {rollup_contract} "lastAccInputHash()(bytes32)"', l1_rpc)
    if last_acc:
        info['lastAccInputHash'] = last_acc.strip()
    return info


def get_l1_last_global_exit_root(ger_manager, l1_rpc):
    """读取 GER manager 的 lastGlobalExitRoot。"""
    out = run_cast(f'call {ger_manager} "getLastGlobalExitRoot()(bytes32)"', l1_rpc)
    return out.strip() if out else None


def decode_raw_txs_data_as_tx(raw_txs_data_hex):
    """
    raw_txs_data 可能是 batchL2Data（包含 initialize tx 的 RLP 编码）。
    这里只做简单打印，不做深度解析。
    """
    if not raw_txs_data_hex:
        return None
    return {
        'hex': '0x' + raw_txs_data_hex,
        'length_bytes': len(raw_txs_data_hex) // 2,
    }


def analyze_acc_input_hash_components(prover_fields, l1_data, input_prover, batch_num, l1_rpc, rollup_manager, rollup_id, container_name):
    """
    深入分析 newAccInputHash 的组成结构，尝试手动重算并与 L1 对比。
    数据来源：
      - prover public inputs（old/new AccInputHash）
      - aggregator_sync_db.virtual_batch / sequenced_batches（Aggregator 给 prover 的输入）
      - L1 合约（L1 实际使用的参数）
    """
    print(f"\n{'='*70}")
    print(f"accInputHash 组成结构分析 (Batch {batch_num})")
    print(f"{'='*70}")

    # 1. 从 aggregator_sync_db 读取 batch 元数据
    virtual_batch = get_virtual_batch_from_sync_db(container_name, batch_num)
    sequenced_batch = None
    if virtual_batch:
        sequenced_batch = get_sequenced_batch_from_sync_db(container_name, virtual_batch['sequence_from_batch_num'])

    print("\n[Aggregator Sync DB 中的 batch 元数据]")
    if virtual_batch:
        print(f"  virtual_batch.batch_num:        {virtual_batch['batch_num']}")
        print(f"  virtual_batch.fork_id:          {virtual_batch['fork_id']}")
        print(f"  virtual_batch.coinbase:         {virtual_batch['coinbase']}")
        print(f"  virtual_batch.sequencer_addr:   {virtual_batch['sequencer_addr']}")
        print(f"  virtual_batch.l1_info_root:     {virtual_batch['l1_info_root']}")
        print(f"  virtual_batch.batch_timestamp:  {virtual_batch['batch_timestamp']}")
        print(f"  virtual_batch.sequence_from:    {virtual_batch['sequence_from_batch_num']}")
        print(f"  virtual_batch.raw_txs_data:     0x{virtual_batch['raw_txs_data_hex'][:80]}... ({len(virtual_batch['raw_txs_data_hex'])//2} bytes)")
    else:
        print("  [WARN] 无法从 aggregator_sync_db 读取 virtual_batch")

    if sequenced_batch:
        print(f"\n  sequenced_batches.block_num:    {sequenced_batch['block_num']}")
        print(f"  sequenced_batches.from_batch:   {sequenced_batch['from_batch_num']}")
        print(f"  sequenced_batches.to_batch:     {sequenced_batch['to_batch_num']}")
        print(f"  sequenced_batches.timestamp:    {sequenced_batch['timestamp']}")
        print(f"  sequenced_batches.l1_info_root: {sequenced_batch['l1_info_root']}")
        print(f"  sequenced_batches.source:       {sequenced_batch['source']}")
    else:
        print("  [WARN] 无法从 aggregator_sync_db 读取 sequenced_batches")

    # 2. 从 input_prover 读取 aggregator 给 prover 的参数（如果数据库里有）
    if input_prover and 'publicInputs' in input_prover:
        pub = input_prover['publicInputs']
        prover_old_acc = pub.get('oldAccInputHash', '0x0')
        prover_l1_info_root = pub.get('l1InfoRoot', '0x0')
        prover_timestamp_limit = pub.get('timestampLimit', 0)
        prover_sequencer_addr = pub.get('sequencerAddr', '0x0')
        prover_forced_blockhash = pub.get('forcedBlockhashL1', '0x0')
        prover_batch_l2_data = pub.get('batchL2Data', '')
    else:
        prover_old_acc = prover_fields.get('oldAccInputHash', '0x0')
        prover_l1_info_root = virtual_batch['l1_info_root'] if virtual_batch else '0x0'
        prover_timestamp_limit = 0
        prover_sequencer_addr = virtual_batch['sequencer_addr'] if virtual_batch else '0x0'
        prover_forced_blockhash = '0x0'
        prover_batch_l2_data = '0x' + (virtual_batch['raw_txs_data_hex'] if virtual_batch else '')

    def to_hex_32(val):
        if val is None:
            return '0x' + '0' * 64
        if isinstance(val, list):
            return '0x' + ''.join(f'{b:02x}' for b in val)
        if isinstance(val, str):
            if not val:
                return '0x' + '0' * 64
            if val.startswith('0x'):
                return val.lower()
            return '0x' + val.lower()
        return '0x' + ('%064x' % int(val))

    prover_old_acc_hex = to_hex_32(prover_old_acc)
    prover_l1_info_root_hex = to_hex_32(prover_l1_info_root)
    prover_forced_blockhash_hex = to_hex_32(prover_forced_blockhash)
    prover_batch_l2_data_hex = to_hex_32(prover_batch_l2_data) if isinstance(prover_batch_l2_data, str) and prover_batch_l2_data.startswith('0x') else '0x' + bytes(prover_batch_l2_data).hex() if isinstance(prover_batch_l2_data, (bytes, list)) else '0x' + str(prover_batch_l2_data)

    print("\n[Aggregator -> Prover 输入参数]")
    print(f"  OldAccInputHash:   {prover_old_acc_hex}")
    print(f"  L1InfoRoot:        {prover_l1_info_root_hex}")
    print(f"  TimestampLimit:    {prover_timestamp_limit}")
    print(f"  SequencerAddr:     {prover_sequencer_addr}")
    print(f"  ForcedBlockhashL1: {prover_forced_blockhash_hex}")
    print(f"  BatchL2Data:       {prover_batch_l2_data_hex[:80]}...")

    # 3. 计算 batchL2DataHash
    if virtual_batch and virtual_batch['raw_txs_data_hex']:
        batch_l2_data_hash = cast_keccak('0x' + virtual_batch['raw_txs_data_hex'])
    elif prover_batch_l2_data_hex and prover_batch_l2_data_hex != '0x':
        batch_l2_data_hash = cast_keccak(prover_batch_l2_data_hex)
    else:
        batch_l2_data_hash = None

    print(f"  BatchL2DataHash:   {batch_l2_data_hash}")

    # 4. 从 L1 读取实际使用的参数
    rollup_contract = get_rollup_contract_address(rollup_manager, rollup_id, l1_rpc)
    print(f"\n[L1 合约参数]")
    print(f"  Rollup 合约地址:   {rollup_contract}")

    l1_init_info = get_l1_rollup_initialize_info(rollup_contract, l1_rpc) if rollup_contract else {}
    print(f"  trustedSequencer:  {l1_init_info.get('trustedSequencer')}")
    print(f"  gerManager:        {l1_init_info.get('globalExitRootManager')}")
    print(f"  lastAccInputHash:  {l1_init_info.get('lastAccInputHash')}")

    l1_ger = None
    if l1_init_info.get('globalExitRootManager'):
        l1_ger = get_l1_last_global_exit_root(l1_init_info['globalExitRootManager'], l1_rpc)
    print(f"  lastGlobalExitRoot: {l1_ger}")

    l1_new_acc = l1_data.get('newAccInputHash', 'N/A')
    l1_old_acc = l1_data.get('oldAccInputHash', 'N/A')
    print(f"  L1 newAccInputHash: {l1_new_acc}")
    print(f"  L1 oldAccInputHash: {l1_old_acc}")

    # 5. 计算 L1 initialize 中使用的 blockhash(block.number - 1)
    l1_block_info = None
    if sequenced_batch and sequenced_batch['block_num']:
        l1_block_info = get_l1_block_info(l1_rpc, sequenced_batch['block_num'])
        print(f"\n[L1 initialize 所在 block {sequenced_batch['block_num']}]")
        print(f"  block.timestamp:   {l1_block_info.get('timestamp')}")
        print(f"  block.hash:        {l1_block_info.get('hash')}")
        print(f"  block.parentHash:  {l1_block_info.get('parentHash')}  <-- initialize 用 blockhash(block.number-1)")

    # 6. 手动重算 accInputHash，与 L1 对比
    print(f"\n[手动重算 accInputHash]")
    if batch_l2_data_hash:
        # 对于 batch 1，L1 是在 initialize 中计算的，公式与 forced batch 类似：
        #   keccak256(oldAcc=0, batchL2DataHash, lastGlobalExitRoot, currentTimestamp, sequencer, blockhash(block.number-1))
        if batch_num == 1:
            candidates = []
            if l1_block_info and l1_block_info.get('parentHash'):
                candidates.append(('L1 parentHash (initialize)', l1_block_info['parentHash']))
            if l1_block_info and l1_block_info.get('hash'):
                candidates.append(('L1 block.hash', l1_block_info['hash']))
            candidates.extend([
                ('0x0', '0x' + '0'*64),
                ('0x1', '0x' + '0'*63 + '1'),
            ])

            ts_candidates = []
            if l1_block_info and l1_block_info.get('timestamp'):
                ts_candidates.append(('L1 block.timestamp', l1_block_info['timestamp']))
            if virtual_batch and virtual_batch['batch_timestamp']:
                # SQLite 时间戳字符串 -> unix timestamp
                import datetime
                try:
                    dt = datetime.datetime.fromisoformat(virtual_batch['batch_timestamp'].replace('Z', '+00:00'))
                    ts_candidates.append(('virtual_batch.batch_timestamp', int(dt.timestamp())))
                except Exception:
                    pass
            if sequenced_batch and sequenced_batch['timestamp']:
                import datetime
                try:
                    dt = datetime.datetime.fromisoformat(sequenced_batch['timestamp'].replace('Z', '+00:00'))
                    ts_candidates.append(('sequenced_batches.timestamp', int(dt.timestamp())))
                except Exception:
                    pass

            seq_candidates = []
            if virtual_batch and virtual_batch['sequencer_addr']:
                seq_candidates.append(('virtual_batch.sequencer_addr', virtual_batch['sequencer_addr']))
            if l1_init_info.get('trustedSequencer'):
                seq_candidates.append(('L1 trustedSequencer', l1_init_info['trustedSequencer']))

            info_root_candidates = []
            if prover_l1_info_root_hex and prover_l1_info_root_hex != '0x' + '0'*64:
                info_root_candidates.append(('prover L1InfoRoot', prover_l1_info_root_hex))
            if virtual_batch and virtual_batch['l1_info_root']:
                info_root_candidates.append(('virtual_batch.l1_info_root', virtual_batch['l1_info_root']))
            if sequenced_batch and sequenced_batch['l1_info_root']:
                info_root_candidates.append(('sequenced_batches.l1_info_root', sequenced_batch['l1_info_root']))
            if l1_ger:
                info_root_candidates.append(('L1 lastGlobalExitRoot', l1_ger))

            found_match = False
            for forced_label, forced_hash in candidates:
                for ts_label, ts_val in ts_candidates:
                    for seq_label, seq_val in seq_candidates:
                        for info_label, info_root_val in info_root_candidates:
                            calc = calculate_acc_input_hash(
                                '0x' + '0'*64,  # oldAcc
                                batch_l2_data_hash,
                                info_root_val,
                                ts_val,
                                seq_val,
                                forced_hash
                            )
                            if calc and calc.lower() == l1_new_acc.lower():
                                print(f"  MATCH! 参数组合:")
                                print(f"    infoRoot:        {info_label} = {info_root_val}")
                                print(f"    timestamp:       {ts_label} = {ts_val}")
                                print(f"    sequencer:       {seq_label} = {seq_val}")
                                print(f"    forcedBlockhash: {forced_label} = {forced_hash}")
                                print(f"    result:          {calc}")
                                found_match = True
                                break
                        if found_match:
                            break
                    if found_match:
                        break
                if found_match:
                    break

            if not found_match:
                print("  未找到能匹配 L1 newAccInputHash 的参数组合。")
                print(f"  已尝试 infoRoot 候选:    {[l for l,_ in info_root_candidates]}")
                print(f"  已尝试 timestamp 候选:   {[l for l,_ in ts_candidates]}")
                print(f"  已尝试 sequencer 候选:   {[l for l,_ in seq_candidates]}")
                print(f"  已尝试 forcedHash 候选:  {[l for l,_ in candidates]}")

                # 额外：也许 raw_txs_data 不是直接作为 batchL2DataHash 的输入
                print("\n  [NOTE] raw_txs_data 可能不是直接 keccak256 作为 batchL2DataHash。")
                print("         在 L1 initialize 中，batchL2DataHash = keccak256(transaction)，")
                print("         其中 transaction 由 generateInitializeTransaction 生成，")
                print("         不是 raw_txs_data 本身。")

        else:
            # batch > 1 的普通 batch
            calc_normal = calculate_acc_input_hash(
                l1_old_acc,
                batch_l2_data_hash,
                prover_l1_info_root_hex,
                prover_timestamp_limit,
                prover_sequencer_addr,
                '0x' + '0'*64
            )
            print(f"  普通 batch 计算: {calc_normal}")
            if calc_normal and calc_normal.lower() == l1_new_acc.lower():
                print("  => 与 L1 匹配！")
            else:
                print("  => 与 L1 不匹配。")

    # 7. 对比 prover 和 L1 的 newAccInputHash
    print(f"\n{'='*70}")
    print("关键结论")
    print(f"{'='*70}")
    prover_new_acc = prover_fields.get('newAccInputHash', 'N/A')
    if prover_new_acc.lower() != l1_new_acc.lower():
        print(f"  Prover 的 newAccInputHash: {prover_new_acc}")
        print(f"  L1 的 newAccInputHash:     {l1_new_acc}")
        print("  => newAccInputHash 不匹配！")
        print("     这意味着 prover 计算 accInputHash 时使用的某个参数与 L1 不同。")
        print("     请检查上面 [Aggregator -> Prover 输入参数] 与 [L1 合约参数] 是否一致。")
        if batch_num == 1:
            print("     对于 batch 1，特别注意：")
            print("       - L1InfoRoot 应等于 L1 initialize 时的 lastGlobalExitRoot")
            print("       - TimestampLimit 应等于 L1 initialize 时的 block.timestamp")
            print("       - ForcedBlockhashL1 应等于 L1 initialize 时的 blockhash(block.number - 1)")
            print("       - batchL2DataHash 应等于 keccak256(generateInitializeTransaction(...))")
    else:
        print("  newAccInputHash 匹配。accInputHash 不是当前分歧点。")
    print(f"{'='*70}\n")


def main():
    # ---- 自动发现环境 ----
    print("自动发现环境...")
    auto_container = find_cdk_node_container()
    auto_config = read_container_config(auto_container)
    auto_pipeline = read_pipeline_state()
    print(f"  cdk-node:      {auto_container or '未找到'}")
    print(f"  L1 RPC (auto): {auto_config.get('L1URL', 'N/A')}")
    print(f"  RollupManager: {auto_config.get('L1_polygonRollupManagerAddress', 'N/A')}")
    print()

    parser = argparse.ArgumentParser(description='对比 InvalidProof 两边数据')
    parser.add_argument('--batch', type=int, default=1, help='要对比的 batch 编号 (默认: 1)')
    parser.add_argument('--l1-rpc', default=None, help='L1 RPC URL（默认自动发现）')
    parser.add_argument('--rollup-manager', default=None, help='RollupManager 合约地址（默认自动发现）')
    parser.add_argument('--rollup-id', type=int, default=1, help='Rollup ID')
    parser.add_argument('--aggregator-container', default=None, help='Aggregator 容器名（默认自动发现）')
    parser.add_argument('--from-aggregator', action='store_true', help='从 aggregator 容器自动提取 proof')
    parser.add_argument('--offline', action='store_true', help='离线模式：使用手动提供的 publics')
    parser.add_argument('--publics', help='逗号分隔的 44 个 publics 值（离线模式用）')
    parser.add_argument('--remote-host', default=None, help='远程 prover 机器 IP')
    parser.add_argument('--remote-key', default=None, help='远程 prover 机器 SSH key')
    parser.add_argument('--rpc-url', default=None, help='Sequencer RPC URL（默认自动从容器端口发现）')
    parser.add_argument('--smt-genesis-bin', default=None, help='smt-genesis 二进制路径')
    parser.add_argument('--alloc-file', default=None, help='allocs JSON 路径（默认从 sequencer 容器复制）')
    parser.add_argument('--skip-log', action='store_true', help='跳过读取 aggregator 日志')
    parser.add_argument('--log-lines', type=int, default=500, help='扫描 aggregator 日志的最近行数')

    args = parser.parse_args()

    # ---- 填充默认值（自动发现 > 环境变量 > 硬编码） ----
    if not args.aggregator_container:
        args.aggregator_container = os.environ.get("CDK_NODE_CONTAINER") or auto_container or "cdk-node-1"
    if not args.l1_rpc:
        args.l1_rpc = os.environ.get("L1_RPC_URL") or auto_config.get("L1URL") or auto_pipeline.get("L1_RPC_URL", "http://127.0.0.1:8545")
    if not args.rollup_manager:
        args.rollup_manager = os.environ.get("ROLLUP_MANAGER") or auto_config.get("L1_polygonRollupManagerAddress", "")
    if not args.remote_host:
        args.remote_host = os.environ.get("REMOTE_PROVER_HOST", "")
    if not args.remote_key:
        args.remote_key = os.environ.get(
            "REMOTE_PROVER_SSH_KEY",
            os.path.join(os.path.dirname(os.path.abspath(__file__)), "../../dayong-op-stack.pem"),
        )
    if not args.smt_genesis_bin:
        default_bin = os.path.join(os.path.dirname(os.path.abspath(__file__)), "../../cdk-erigon/smt-genesis")
        args.smt_genesis_bin = default_bin if os.path.isfile(default_bin) else None

    if not args.rollup_manager:
        print("[ERROR] 无法发现 RollupManager 地址。请用 --rollup-manager 指定。", file=sys.stderr)
        sys.exit(1)

    print(f"使用参数:")
    print(f"  batch:              {args.batch}")
    print(f"  l1-rpc:             {args.l1_rpc}")
    print(f"  rollup-manager:     {args.rollup_manager}")
    print(f"  aggregator-container: {args.aggregator_container}")
    print()

    # 如果用户没有指定 allocs，尝试从 sequencer 容器自动复制一份到 /tmp
    if not args.alloc_file:
        auto_alloc = "/tmp/dynamic-kurtosis-allocs.json"
        # 自动发现 sequencer 容器
        seq_containers = _docker_ps("cdk-erigon-sequencer")
        seq_name = seq_containers[0] if seq_containers else None
        if seq_name:
            try:
                subprocess.run(
                    ["docker", "cp", f"{seq_name}:/etc/cdk-erigon/dynamic-kurtosis-allocs.json", auto_alloc],
                    check=True, capture_output=True, timeout=30
                )
                args.alloc_file = auto_alloc
            except Exception as e:
                print(f"[WARN] 自动复制 allocs 文件失败: {e}", file=sys.stderr)

    # 获取 publics
    if args.offline:
        if not args.publics:
            print("ERROR: --offline 模式需要提供 --publics", file=sys.stderr)
            sys.exit(1)
        publics = [int(x.strip()) for x in args.publics.split(',')]
    else:
        publics = get_publics_from_aggregator(args.aggregator_container, args.batch)
        if publics is None:
            print("无法从 aggregator 获取 publics，尝试使用 --offline --publics '...' 手动提供", file=sys.stderr)
            sys.exit(1)

    print(f"Prover publics ({len(publics)} elements):")
    print(f"  {publics}")

    # 解码 publics
    prover_fields = decode_publics(publics)
    print(f"\n解码后的 Prover 字段:")
    for k, v in prover_fields.items():
        print(f"  {k}: {v}")

    # 获取 L1 数据
    print(f"\n正在查询 L1 数据...")
    l1_data = get_l1_data(args.rollup_manager, args.rollup_id, args.batch, args.l1_rpc)
    if not l1_data:
        print("ERROR: 无法获取 L1 数据", file=sys.stderr)
        sys.exit(1)

    print(f"L1 数据:")
    for k, v in l1_data.items():
        print(f"  {k}: {v}")

    # 对比
    ok = compare_fields(prover_fields, l1_data, args.batch)

    # 进一步分析 accInputHash 组成结构
    print("\n正在提取 input_prover 以深入分析 accInputHash...")
    input_prover = get_input_prover_from_aggregator(args.aggregator_container, args.batch)
    if input_prover:
        print("成功提取 input_prover")
    else:
        print("未找到 input_prover（可能为空或数据库中不存在）")

    analyze_acc_input_hash_components(
        prover_fields, l1_data, input_prover, args.batch,
        args.l1_rpc, args.rollup_manager, args.rollup_id,
        args.aggregator_container
    )

    # 额外诊断：把 L1、RPC、prover 三方的 stateRoot 放在一起对比
    print("\n" + "=" * 70)
    print("Root 三元组对比（L1 合约 / Sequencer RPC / Prover proof）")
    print("=" * 70)

    rpc_url = args.rpc_url
    if not rpc_url:
        rpc_url = discover_rpc_port(args.aggregator_container)
        if rpc_url:
            print(f"自动发现 RPC URL: {rpc_url}")
        else:
            print("[WARN] 无法自动发现 RPC URL，跳过 RPC batch 查询（可用 --rpc-url 指定）")

    rpc_batch0 = get_rpc_batch_state_root(rpc_url, 0) if rpc_url else None
    rpc_batch_n = get_rpc_batch_state_root(rpc_url, args.batch) if rpc_url else None

    l1_old = l1_data.get('oldStateRoot', 'N/A')
    l1_new = l1_data.get('newStateRoot', 'N/A')
    prover_old = prover_fields.get('oldStateRoot', 'N/A')
    prover_new = prover_fields.get('newStateRoot', 'N/A')
    rpc_old = rpc_batch0.get('stateRoot') if rpc_batch0 else 'N/A'
    rpc_new = rpc_batch_n.get('stateRoot') if rpc_batch_n else 'N/A'

    print(f"\noldStateRoot (batch {args.batch} 开始时的状态):")
    print(f"  L1 batchNumToStateRoot[{args.batch - 1}]: {l1_old}")
    print(f"  RPC batch 0 stateRoot:                  {rpc_old}")
    print(f"  Prover proof oldStateRoot:              {prover_old}")
    if l1_old.lower() == rpc_old.lower() == prover_old.lower():
        print("  => 三方一致")
    else:
        print("  => 三方不一致！这是 InvalidProof 的直接诱因之一。")
        if l1_old.lower() != rpc_old.lower():
            print("     [L1 != RPC] L1 写入的 genesisFinal 与 sequencer 实际 block 0 stateRoot 不同。")
        if rpc_old.lower() != prover_old.lower():
            print("     [RPC != Prover] prover 从 witness 重算的 oldStateRoot 与 sequencer RPC 不同。")

    print(f"\nnewStateRoot (batch {args.batch} 结束时的状态):")
    print(f"  L1 batchNumToStateRoot[{args.batch}] (验证后): {l1_new}")
    print(f"  RPC batch {args.batch} stateRoot:                  {rpc_new}")
    print(f"  Prover proof newStateRoot:              {prover_new}")
    if l1_new == '0x' + '0' * 64:
        print("  => L1 尚未记录该 batch 的 newStateRoot（还没验证成功）。")
    if rpc_new.lower() != prover_new.lower():
        print("  => [RPC != Prover] prover 生成的新状态根与 sequencer RPC 不同。")

    # smt-genesis 计算
    if args.smt_genesis_bin and args.alloc_file:
        print("\n[smt-genesis 计算]")
        smt_root, smt_err = compute_smt_genesis_root(args.alloc_file, args.smt_genesis_bin)
        if smt_err:
            print(f"  计算失败: {smt_err}")
        else:
            print(f"  smt-genesis 输出: {smt_root}")
            print(f"  RPC batch 0 root: {rpc_old}")
            print(f"  L1 oldStateRoot:  {l1_old}")
            if smt_root.lower() == rpc_old.lower():
                print("  => smt-genesis 与 RPC batch 0 一致。若 L1 不同，说明部署时写入的 genesisFinal 不是该值。")
            else:
                print("  => smt-genesis 与 RPC batch 0 都不同，需要检查 allocs 文件是否对应当前 sequencer。")

    # aggregator 日志扫描
    if not args.skip_log:
        print("\n[Aggregator 日志扫描]")
        log_text, log_err = get_aggregator_log_tail(args.aggregator_container, args.log_lines)
        if log_err:
            print(f"  读取日志失败: {log_err}")
        else:
            hits = scan_log_for_invalidproof(log_text)
            if hits:
                print(f"  找到 {len(hits)} 条相关日志（最多显示最近 20 条）：")
                for ln in hits[-20:]:
                    print(f"    {ln}")
            else:
                print("  最近日志中没有找到 InvalidProof / 0x09bde339 / StateRoot mismatch 等关键词。")

    print("=" * 70)

    sys.exit(0 if ok else 1)


if __name__ == '__main__':
    main()
