#!/usr/bin/env python3
"""
自动检查 zkEVM batch 的证明状态。

功能：
1. 自动发现本机 Docker 容器（cdk-node、cdk-erigon 等）
2. 从容器配置中读取 RollupManager、L1 RPC 等参数
3. 查询 L1 RollupManager 合约，确认 batch 的 stateRoot、accInputHash、lastVerifiedBatch
4. 读取 cdk-node aggregator 的 SQLite 数据库中的 proof 状态
5. 读取本地 cdk-node 容器的日志

所有参数均可通过环境变量覆盖。
"""

import argparse
import json
import os
import re
import sqlite3
import subprocess
import sys
from pathlib import Path

# ---------------- 自动发现辅助函数 ----------------

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
    # 兜底：尝试更宽泛的搜索
    names = _docker_ps("cdk")
    for n in names:
        if "node" in n and "erigon" not in n:
            return n
    return None


def find_erigon_containers():
    """查找 cdk-erigon 容器（sequencer / rpc）。"""
    result = {"sequencer": None, "rpc": None}
    for name in _docker_ps("cdk-erigon"):
        if "sequencer" in name:
            result["sequencer"] = name
        elif "rpc" in name:
            result["rpc"] = name
    return result


def read_container_config(container_name):
    """
    从 cdk-node 容器的 /etc/cdk/cdk-node-config.toml 提取关键配置。
    返回 dict: l1_rpc, rollup_manager, rollup_contract, l2_rpc, rpc_url, ...
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
    # 简单 TOML key=value 解析
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("#") or line.startswith("["):
            continue
        m = re.match(r'^(\w+)\s*=\s*"([^"]*)"', line)
        if m:
            config[m.group(1)] = m.group(2)

    # 也提取 [L1Config] section
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
    # 尝试多个可能路径
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


def discover_prover_from_config(config):
    """从 cdk-node 配置中尝试发现 prover 地址。"""
    # aggregator 日志中通常有 prover 地址
    return None


def copy_db_from_container(container_name, local_path):
    """从容器中复制 SQLite 数据库到本地。"""
    if not container_name:
        return False
    r = subprocess.run(
        ["docker", "cp", f"{container_name}:/tmp/aggregator_db.sqlite", local_path],
        capture_output=True, text=True,
    )
    return r.returncode == 0


# ---------------- 主逻辑 ----------------

def parse_args():
    parser = argparse.ArgumentParser(description="检查 zkEVM batch 证明状态")
    parser.add_argument("--l1-rpc", default=None, help="L1 RPC URL（默认自动从容器配置读取）")
    parser.add_argument("--rollup-manager", default=None, help="RollupManager 合约地址（默认自动从容器配置读取）")
    parser.add_argument("--rollup-id", type=int, default=None, help="Rollup ID（默认 1）")
    parser.add_argument("--cdk-node", default=None, help="cdk-node 容器名（默认自动发现）")
    parser.add_argument("--agg-db", default=None, help="Aggregator SQLite 数据库本地路径")
    parser.add_argument("--skip-prover", action="store_true", help="跳过远程 prover 日志查询")
    parser.add_argument("--prover-host", default=None, help="远程 prover 主机 IP")
    parser.add_argument("--prover-key", default=None, help="远程 prover SSH key 路径")
    parser.add_argument("--prover-container", default=None, help="远程 prover 容器名")
    return parser.parse_args()


def main():
    args = parse_args()

    # ---- 自动发现 ----
    print("自动发现环境...")

    cdk_node = args.cdk_node or os.environ.get("CDK_NODE_CONTAINER") or find_cdk_node_container()
    print(f"  cdk-node 容器: {cdk_node or '未找到'}")

    erigon = find_erigon_containers()
    print(f"  erigon sequencer: {erigon['sequencer'] or '未找到'}")
    print(f"  erigon rpc:       {erigon['rpc'] or '未找到'}")

    config = read_container_config(cdk_node) if cdk_node else {}
    pipeline = read_pipeline_state()

    l1_rpc = args.l1_rpc or os.environ.get("L1_RPC_URL") or config.get("L1URL") or pipeline.get("L1_RPC_URL", "http://127.0.0.1:8545")
    rollup_manager = args.rollup_manager or os.environ.get("ROLLUP_MANAGER") or config.get("L1_polygonRollupManagerAddress", "")
    rollup_id = args.rollup_id or int(os.environ.get("ROLLUP_ID", "1"))
    agg_db_path = args.agg_db or os.environ.get("LOCAL_AGG_DB", "/tmp/aggregator_db.sqlite")

    print(f"  L1 RPC:          {l1_rpc}")
    print(f"  RollupManager:   {rollup_manager}")
    print(f"  Rollup ID:       {rollup_id}")
    print()

    if not rollup_manager:
        print("[ERROR] 无法发现 RollupManager 地址。请用 --rollup-manager 指定或设置 ROLLUP_MANAGER 环境变量。")
        sys.exit(1)

    # ---- L1 合约状态 ----
    def run_cast(cmd):
        full = ["cast", "call", rollup_manager] + cmd + ["--rpc-url", l1_rpc]
        r = subprocess.run(full, capture_output=True, text=True)
        if r.returncode != 0:
            return f"ERROR: {r.stderr.strip()}"
        return r.stdout.strip()

    print("=" * 70)
    print("L1 合约状态")
    print("=" * 70)

    out = run_cast(["rollupTypeMap(uint32)(address,address,uint64,uint8,bool,bytes32,bytes32)", str(rollup_id)])
    print(f"  rollupTypeMap({rollup_id}): {out}")

    out = run_cast(["getRollupBatchNumToStateRoot(uint32,uint64)(bytes32)", str(rollup_id), "0"])
    print(f"  batchNumToStateRoot[{rollup_id}][0]: {out}")

    out = run_cast(["getRollupBatchNumToStateRoot(uint32,uint64)(bytes32)", str(rollup_id), "1"])
    print(f"  batchNumToStateRoot[{rollup_id}][1]: {out}")

    out = run_cast(["getRollupSequencedBatches(uint32,uint64)((bytes32,uint64,uint64))", str(rollup_id), "1"])
    print(f"  sequencedBatches[{rollup_id}][1]: {out}")

    out = run_cast([
        "rollupIDToRollupData(uint32)(address,uint64,address,uint64,bytes32,uint64,uint64,uint64,uint64,uint64,uint64,uint8)",
        str(rollup_id),
    ])
    print(f"  rollupIDToRollupData({rollup_id}): {out}")

    # ---- Aggregator DB ----
    print()
    print("=" * 70)
    print("Aggregator SQLite 数据库状态")
    print("=" * 70)

    db_path = Path(agg_db_path)
    if not db_path.exists():
        print(f"  数据库不存在: {agg_db_path}，尝试从容器复制...")
        if not copy_db_from_container(cdk_node, agg_db_path):
            print(f"  [ERROR] 无法从容器 {cdk_node} 复制数据库")
            return

    if not db_path.exists():
        print("  [ERROR] 无法获取数据库文件")
        return

    try:
        conn = sqlite3.connect(agg_db_path)
        cur = conn.cursor()
        cur.execute("SELECT name FROM sqlite_master WHERE type='table' AND name='proof';")
        if not cur.fetchone():
            print("  [WARN] 数据库中没有 proof 表")
            tables = [r[0] for r in cur.execute("SELECT name FROM sqlite_master WHERE type='table';")]
            print(f"  现有表: {tables}")
            conn.close()
            return

        cur.execute(
            "SELECT batch_num, batch_num_final, proof_id, prover, prover_id, "
            "created_at, updated_at, generating_since, input_prover, proof "
            "FROM proof ORDER BY batch_num;"
        )
        rows = cur.fetchall()
        if not rows:
            print("  [INFO] proof 表为空")
        for row in rows:
            bn, bnf, pid, prover, pvid, created, updated, gen_since, inp, proof = row
            print(
                f"  batch_num={bn} batch_num_final={bnf} "
                f"proof_id={pid} prover={prover} prover_id={pvid} "
                f"created={created} updated={updated} generating_since={gen_since}"
            )
            print(f"    proof length={len(proof) if proof else 0}")
            print(f"    input_prover length={len(inp) if inp else 0}")
            if inp:
                try:
                    ip = json.loads(inp)
                    pub = ip.get("publicInputs", {})
                    print(
                        f"    input_prover: oldStateRoot={pub.get('oldStateRoot')} "
                        f"newStateRoot={pub.get('newStateRoot')} "
                        f"newAccInputHash={pub.get('newAccInputHash')}"
                    )
                except Exception as e:
                    print(f"    [WARN] 无法解析 input_prover: {e}")
            if proof:
                try:
                    p = json.loads(proof)
                    pub = p.get("publics") or p.get("public", {})
                    # publics 可能是数组
                    if isinstance(pub, list):
                        print(f"    proof publics: (array, length={len(pub)})")
                    else:
                        print(
                            f"    proof publics: newStateRoot={pub.get('newStateRoot')} "
                            f"newAccInputHash={pub.get('newAccInputHash')} "
                            f"batchNum={pub.get('batchNum')}"
                        )
                except Exception as e:
                    print(f"    [WARN] 无法解析 proof: {e}")
        conn.close()
    except Exception as e:
        print(f"  [ERROR] 读取数据库失败: {e}")

    # ---- 远程 prover 日志 ----
    if not args.skip_prover:
        prover_host = args.prover_host or os.environ.get("REMOTE_PROVER_HOST")
        prover_key = args.prover_key or os.environ.get(
            "REMOTE_PROVER_SSH_KEY",
            os.path.join(os.path.dirname(__file__), "../../dayong-op-stack.pem"),
        )
        prover_container = args.prover_container or os.environ.get("REMOTE_PROVER_CONTAINER", "real-prover")

        print()
        print("=" * 70)
        print("远程 prover 最近日志")
        print("=" * 70)

        if prover_host:
            ssh_cmd = [
                "ssh", "-o", "StrictHostKeyChecking=no",
                "-i", prover_key, f"root@{prover_host}",
                f"docker logs --tail 40 {prover_container}",
            ]
            r = subprocess.run(ssh_cmd, capture_output=True, text=True, timeout=15)
            if r.returncode != 0:
                print(f"  [ERROR] 无法读取远程日志: {r.stderr.strip()}")
            else:
                key_pats = [
                    re.compile(r"Prover::genFinalProof.*newStateRoot"),
                    re.compile(r"aggregatorClientThread.*response sent"),
                    re.compile(r"FFLONK PROVER FINISHED"),
                    re.compile(r"ERROR|error|Failed|failed"),
                ]
                for line in r.stdout.splitlines():
                    if any(p.search(line) for p in key_pats):
                        print(f"  {line}")
        else:
            print("  [SKIP] 未配置 REMOTE_PROVER_HOST，跳过远程 prover 日志")

    # ---- cdk-node 容器日志 ----
    print()
    print("=" * 70)
    print("本地 cdk-node 容器日志")
    print("=" * 70)

    if cdk_node:
        r = subprocess.run(["docker", "logs", "--tail", "100", cdk_node], capture_output=True, text=True)
        if r.returncode != 0:
            print(f"  [ERROR] 无法读取日志: {r.stderr.strip()}")
        else:
            lines = r.stdout.splitlines() + r.stderr.splitlines()
            if not lines:
                print("  [INFO] 日志为空")
            else:
                key_pats = [
                    re.compile(r"InvalidProof|0x09bde339|execution reverted"),
                    re.compile(r"verifyBatches|VerifyBatches|settlement", re.I),
                    re.compile(r"Batch 1 inputProver overridden"),
                    re.compile(r"batch1 initialize"),
                    re.compile(r"final proof roots"),
                    re.compile(r"L1 submission values"),
                    re.compile(r"Batch proof generated"),
                    re.compile(r"ERROR.*aggregator", re.I),
                ]
                hits = [ln for ln in lines if any(p.search(ln) for p in key_pats)]
                if hits:
                    for ln in hits[-30:]:
                        print(f"  {ln.strip()}")
                else:
                    print("  最近日志中没有关键匹配项")
    else:
        print("  [SKIP] 未找到 cdk-node 容器")


if __name__ == "__main__":
    main()
#!/usr/bin/env python3
"""
自动检查 zkEVM batch 1 的证明状态。

功能：
1. 查询 L1 RollupManager 合约，确认 batch 0/1 的 stateRoot、accInputHash、lastVerifiedBatch。
2. 读取本地 cdk-node aggregator 的 SQLite 数据库（/tmp/aggregator_db.sqlite）中的 proof 状态。
3. 读取远程 prover 的最近日志，确认证明生成结果。
4. 读取本地 cdk-node 容器的日志（通过 docker logs）。
"""

import json
import os
import re
import sqlite3
import subprocess
import sys
from pathlib import Path

# ---------------- 配置 ----------------
L1_RPC_URL = os.environ.get("L1_RPC_URL", "http://184.32.182.132/espace")
ROLLUP_MANAGER = os.environ.get("ROLLUP_MANAGER", "0xB53AC99b723Fb6D96D527c53FC85df40C07C153c")
ROLLUP_ID = int(os.environ.get("ROLLUP_ID", "1"))
REMOTE_PROVER_HOST = os.environ.get("REMOTE_PROVER_HOST", "47.85.169.235")
REMOTE_PROVER_SSH_KEY = os.environ.get(
    "REMOTE_PROVER_SSH_KEY",
    "/home/ubuntu/workspace/ydyl-deployment-suite/dayong-op-stack.pem",
)
REMOTE_PROVER_CONTAINER = os.environ.get("REMOTE_PROVER_CONTAINER", "real-prover")
LOCAL_AGG_DB = os.environ.get("LOCAL_AGG_DB", "/tmp/aggregator_db.sqlite")
CDK_NODE_CONTAINER = os.environ.get("CDK_NODE_CONTAINER", "cdk-node-1")


def run_cast(cmd: list[str]) -> str:
    """执行 cast 命令并返回 stdout。"""
    full = ["cast", "call", ROLLUP_MANAGER] + cmd + ["--rpc-url", L1_RPC_URL]
    result = subprocess.run(full, capture_output=True, text=True)
    if result.returncode != 0:
        return f"ERROR: {result.stderr.strip()}"
    return result.stdout.strip()


def query_l1_state():
    print("=" * 70)
    print("L1 合约状态")
    print("=" * 70)

    # rollupTypeMap(1).genesis
    out = run_cast(
        ["rollupTypeMap(uint32)(address,address,uint64,uint8,bool,bytes32,bytes32)", str(ROLLUP_ID)]
    )
    print(f"  rollupTypeMap({ROLLUP_ID}): {out}")

    # batchNumToStateRoot[0]
    out = run_cast(["getRollupBatchNumToStateRoot(uint32,uint64)(bytes32)", str(ROLLUP_ID), "0"])
    print(f"  batchNumToStateRoot[{ROLLUP_ID}][0]: {out}")

    # batchNumToStateRoot[1]
    out = run_cast(["getRollupBatchNumToStateRoot(uint32,uint64)(bytes32)", str(ROLLUP_ID), "1"])
    print(f"  batchNumToStateRoot[{ROLLUP_ID}][1]: {out}")

    # sequencedBatches[1].accInputHash
    out = run_cast(["getRollupSequencedBatches(uint32,uint64)((bytes32,uint64,uint64))", str(ROLLUP_ID), "1"])
    print(f"  sequencedBatches[{ROLLUP_ID}][1]: {out}")

    # rollupIDToRollupData
    out = run_cast(
        [
            "rollupIDToRollupData(uint32)(address,uint64,address,uint64,bytes32,uint64,uint64,uint64,uint64,uint64,uint64,uint8)",
            str(ROLLUP_ID),
        ]
    )
    print(f"  rollupIDToRollupData({ROLLUP_ID}): {out}")


def query_aggregator_db():
    print()
    print("=" * 70)
    print("Aggregator SQLite 数据库状态")
    print("=" * 70)

    db_path = Path(LOCAL_AGG_DB)
    if not db_path.exists():
        print(f"  [WARN] 数据库文件不存在: {LOCAL_AGG_DB}")
        print("  尝试从 cdk-node 容器复制...")
        cp = subprocess.run(
            [
                "docker",
                "cp",
                f"{CDK_NODE_CONTAINER}--1cf5f97ee5d34193a094ff56f514f436:/tmp/aggregator_db.sqlite",
                LOCAL_AGG_DB,
            ],
            capture_output=True,
            text=True,
        )
        # 容器名可能变化，尝试用 docker ps 查找
        if cp.returncode != 0:
            result = subprocess.run(
                ["docker", "ps", "-q", "-f", f"name={CDK_NODE_CONTAINER}"],
                capture_output=True,
                text=True,
            )
            cid = result.stdout.strip().splitlines()[0] if result.stdout.strip() else None
            if cid:
                subprocess.run(
                    ["docker", "cp", f"{cid}:/tmp/aggregator_db.sqlite", LOCAL_AGG_DB],
                    capture_output=True,
                    text=True,
                )

    if not db_path.exists():
        print(f"  [ERROR] 无法获取数据库文件")
        return

    try:
        conn = sqlite3.connect(LOCAL_AGG_DB)
        cur = conn.cursor()

        # proof 表
        cur.execute("SELECT name FROM sqlite_master WHERE type='table' AND name='proof';")
        if not cur.fetchone():
            print("  [WARN] 数据库中没有 proof 表")
            tables = [row[0] for row in cur.execute("SELECT name FROM sqlite_master WHERE type='table';")]
            print(f"  现有表: {tables}")
            conn.close()
            return

        cur.execute(
            "SELECT batch_num, batch_num_final, proof_id, prover, prover_id, created_at, updated_at, generating_since, input_prover, proof FROM proof ORDER BY batch_num;"
        )
        rows = cur.fetchall()
        if not rows:
            print("  [INFO] proof 表为空")
        for row in rows:
            (batch_num, batch_num_final, proof_id, prover, prover_id,
             created_at, updated_at, generating_since, input_prover, proof) = row
            print(
                f"  batch_num={batch_num} batch_num_final={batch_num_final} "
                f"proof_id={proof_id} prover={prover} prover_id={prover_id} "
                f"created={created_at} updated={updated_at} generating_since={generating_since}"
            )
            print(f"    proof length={len(proof) if proof else 0}")
            print(f"    input_prover length={len(input_prover) if input_prover else 0}")
            if input_prover:
                try:
                    ip = json.loads(input_prover)
                    pub = ip.get("publicInputs", {})
                    print(
                        f"    input_prover publics: oldStateRoot={pub.get('oldStateRoot')} "
                        f"newStateRoot={pub.get('newStateRoot')} "
                        f"newAccInputHash={pub.get('newAccInputHash')} "
                        f"newLocalExitRoot={pub.get('newLocalExitRoot')}"
                    )
                except Exception as e:
                    print(f"    [WARN] 无法解析 input_prover: {e}")
            if proof:
                try:
                    p = json.loads(proof)
                    pub = p.get("public", {})
                    print(
                        f"    proof publics: newStateRoot={pub.get('newStateRoot')} "
                        f"newAccInputHash={pub.get('newAccInputHash')} "
                        f"newLocalExitRoot={pub.get('newLocalExitRoot')} "
                        f"batchNum={pub.get('batchNum')}"
                    )
                except Exception as e:
                    print(f"    [WARN] 无法解析 proof: {e}")

        conn.close()
    except Exception as e:
        print(f"  [ERROR] 读取数据库失败: {e}")


def query_remote_prover_log():
    print()
    print("=" * 70)
    print("远程 prover 最近日志")
    print("=" * 70)

    ssh_cmd = [
        "ssh",
        "-o",
        "StrictHostKeyChecking=no",
        "-i",
        REMOTE_PROVER_SSH_KEY,
        f"root@{REMOTE_PROVER_HOST}",
        f"docker logs --tail 40 {REMOTE_PROVER_CONTAINER}",
    ]
    result = subprocess.run(ssh_cmd, capture_output=True, text=True)
    if result.returncode != 0:
        print(f"  [ERROR] 无法读取远程日志: {result.stderr.strip()}")
        return

    lines = result.stdout.splitlines()
    # 只显示关键行
    key_patterns = [
        re.compile(r"Prover::genFinalProof.*newStateRoot"),
        re.compile(r"aggregatorClientThread.*response sent"),
        re.compile(r"FFLONK PROVER FINISHED"),
        re.compile(r"ERROR|error|Failed|failed"),
    ]
    for line in lines:
        if any(p.search(line) for p in key_patterns):
            print(f"  {line}")


def query_local_cdk_node_log():
    print()
    print("=" * 70)
    print("本地 cdk-node 容器日志")
    print("=" * 70)

    result = subprocess.run(
        ["docker", "logs", "--tail", "50", CDK_NODE_CONTAINER],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        # 尝试用 docker ps 查找完整容器名
        result2 = subprocess.run(
            ["docker", "ps", "-q", "-f", f"name={CDK_NODE_CONTAINER}"],
            capture_output=True,
            text=True,
        )
        cid = result2.stdout.strip().splitlines()[0] if result2.stdout.strip() else None
        if cid:
            result = subprocess.run(
                ["docker", "logs", "--tail", "50", cid],
                capture_output=True,
                text=True,
            )

    if result.returncode != 0:
        print(f"  [ERROR] 无法读取本地日志: {result.stderr.strip()}")
        return

    lines = result.stdout.splitlines()
    if not lines:
        print("  [INFO] 本地 cdk-node 日志为空（可能输出到 stderr 或被重定向）")
        return

    key_patterns = [
        re.compile(r"InvalidProof|0x09bde339|execution reverted"),
        re.compile(r"verifyBatches|VerifyBatches|settlement|Settlement"),
        re.compile(r"proof.*verified|verified.*proof|settled", re.I),
        re.compile(r"ERROR|error|Failed|failed"),
    ]
    for line in lines:
        if any(p.search(line) for p in key_patterns):
            print(f"  {line}")


if __name__ == "__main__":
    query_l1_state()
    query_aggregator_db()
    query_remote_prover_log()
    query_local_cdk_node_log()
