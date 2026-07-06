# SSH 连接修复与远程 Prover 诊断报告

**日期**: 2026-06-15  
**SSH 状态**: ✅ 已修复并成功连接

---

## 一、SSH 连接问题修复

### 原始问题
- 之前尝试使用 `~/.ssh/id_rsa` 连接失败（Permission denied）
- 用户提供的路径 `/Users/xinghao/Desktop/polygon-suite/dayong-op-stack.pem` 是 Mac 本地路径，不在本机

### 解决方案
PEM 文件实际位置：
```
/home/ubuntu/workspace/ydyl-deployment-suite/dayong-op-stack.pem
```

正确 SSH 命令：
```bash
ssh -o StrictHostKeyChecking=no -i /home/ubuntu/workspace/ydyl-deployment-suite/dayong-op-stack.pem root@47.85.169.235
```

### 连接验证
- ✅ SSH 连接成功
- 远程主机名: `iZ0xi65grxqgvzrlcbfv3qZ`
- 容器名: `real-prover`（不是 `real-prover-rc16-fork12`）
- 容器状态: Up 2 hours

---

## 二、远程 Prover 关键日志发现

### 发现 1: Batch 1 的 oldStateRoot 和 newStateRoot

从 prover 日志中提取的关键数据：

**Batch 1 证明生成**（示例，时间 20260615_075644）:
```
oldStateRoot  = 3664e81342353faafcdb94216071ead78ac5900be76f3725d549b5391496c64f
newStateRoot  = 0xe6bb1f34442600d8a8afef7e56da33a92dc862afb63e72b06075fa4d2b1b4ce8
pols.SR[lastN]= e6bb1f34:442600d8:a8afef7e:56da33a9:2dc862af:b63e72b0:6075fa4d:2b1b4ce8
```

**Final Proof 输出**（多次重复，完全一致）:
```
newStateRoot      = 4085dad91ac6fc0d589d7118a9c1183c319b533ec33069379133a039e9d69f23
newAccInputHash   = b03d6233271cfefbade6d22bd19d6a1b5656928e7612f22a0f6858f102ff36e0
newLocalExitRoot  = 0
newBatchNum       = 1
```

**关键观察**:
1. **proverSR 完全一致**: `0x4085dad9...` 在所有 final proof 中相同
2. **oldStateRoot 变化**: 不同 batch 的 oldStateRoot 不同（如 `3664e813...`, `b74103fa...`, `6cc3decf...` 等）
3. **witness 大小**: 所有 witness 都是 316B，db.size=18，programs.size=0

### 发现 2: Aggregated Proof 持续失败

错误日志（反复出现）:
```
zkError: Prover::genAggregatedProof() The newStateRoot 
and the oldStateRoot are not consistent "3717309620"!="1752492191"
```

**分析**:
- 聚合证明时，batch 1 的 newStateRoot 与 batch 2 的 oldStateRoot 不匹配
- `3717309620` (hex: `DD2F2B94`) ≠ `1752492191` (hex: `6874619F`)
- **这是十进制表示**，需要转换为十六进制对比
- 这解释了为什么 batches 2-3 的聚合证明始终返回 `COMPLETED_ERROR`

### 发现 3: Witness 数据一致

所有 batch proof 的 witness 特征:
```
witness2db() calculated stateRoot=... from size=316B generating db.size=18 and programs.size=0 in ~100us
```

**关键**:
- Witness 大小固定为 **316 字节**（非常小）
- 数据库条目只有 **18 个**
- 没有程序代码（programs.size=0）
- 这表明使用的是 **trimmed witness**，且只包含少量状态

### 发现 4: 不同 Batch 的 oldStateRoot 对比

从日志中提取的多个 batch 的 oldStateRoot：
- Batch 22: `90eef11361e2942910fb8ff831aa2c5b888cc886e0965137805f88b2804c2c9c`
- Batch 23: `b74103fa8d64a18d583ad96cc499dd7f491e82505a1a880c81f4afef126b89ed`
- Batch 24: `6cc3decf52c2750365079d4dee1faf64cf07590cca89457c735f137023984dc0`
- Batch 25: `baf51a723d2b9fa8e4ded8970ba1949992a68097a6a2a6311d5c046c00fdb9f6`

**观察**: 每个 batch 的 oldStateRoot 都不同，且都是 64 字符（32 字节，256-bit）

---

## 三、核心问题确认

### 问题 A: Prover SR 不匹配

**对比数据**:
- **Prover 计算**: `0x4085dad91ac6fc0d589d7118a9c1183c319b533ec33069379133a039e9d69f23`
- **L2 链 RPC**: `0xc24c756faaf1a59f7a84dddc261dbd0dd07b79c7a4d3c8141e96ebc1a25d2b99`
- **差异**: 完全不同的值

**数据流确认**:
```
1. witness2db() 从 witness (316B) 提取 oldStateRoot
   示例: oldStateRoot = 3664e813... (batch 1)

2. executor.executeBatch(oldStateRoot, db, batchL2Data)
   计算: newStateRoot = e6bb1f34... (polynomials 输出)

3. genFinalProof() 从 recursive proof 的 publics[19..26] 提取
   输出: newStateRoot = 4085dad9... (最终证明中的值)

4. Aggregator 对比:
   proverSR (4085dad9...) ≠ rpcSR (c24c756f...)
```

### 问题 B: 为什么 newStateRoot 从 executor 到 final proof 发生变化？

**重要发现**:
- Executor 输出: `newStateRoot = 0xe6bb1f34442600d8a8afef7e56da33a92dc862afb63e72b06075fa4d2b1b4ce8`
- Final Proof 输出: `newStateRoot = 0x4085dad91ac6fc0d589d7118a9c1183c319b533ec33069379133a039e9d69f23`

**分析**:
- 这两个值**不同**！
- 说明 batch proof → aggregated proof → final proof 的转换过程中，newStateRoot 被改变了
- 可能原因：
  1. Aggregated proof 聚合了多个 batch，newStateRoot 是最后一个 batch 的
  2. Recursive proof 的 publics 提取逻辑有问题
  3. joinzkin 函数在聚合时 newStateRoot 来自 zkin2，但 zkin2 的 publics[19..26] 不同

---

## 四、待办事项更新

### 已完成
- [x] SSH 连接修复
- [x] 获取远程 prover 日志
- [x] 确认 proverSR 确定性（每次都相同）
- [x] 确认 witness 类型和大小（trimmed, 316B）
- [x] 发现 aggregated proof 的 newStateRoot 不一致错误

### 需要进一步调查
- [ ] **Task 1**: 检查 batch 1 的 input.json 文件（如果还存在）
  - 目的：确认 witness 中的 oldStateRoot 值
  - 命令：查找 `*.1.gen_batch_proof_input.json` 文件

- [ ] **Task 2**: 对比 oldStateRoot 与 L2 链的 genesis state root
  - 使用 RPC 查询 batch 0 的 state root
  - 对比 witness2db 提取的 oldStateRoot

- [ ] **Task 3**: 调查为什么 executor 输出的 newStateRoot 与 final proof 不同
  - executor: `e6bb1f34...`
  - final proof: `4085dad9...`
  - 需要检查 aggregated proof 的聚合逻辑

- [ ] **Task 4**: 重建 CDK Docker 镜像
  - 包含最新的 `compareFinalProofRootsWithRPC` 逻辑
  - 阻止在 roots 不匹配时发送 settlement

- [ ] **Task 5**: 尝试切换到 full witness
  - 修改配置: `UseFullWitness = true`
  - 测试是否能解决 newStateRoot 不匹配

---

## 五、关键代码位置更新

### 远程 Prover 文件位置
- 输出目录: `/usr/src/app/output/`
- 配置文件: `/usr/src/app/config.json`
- Fork 配置: `/usr/src/app/config/`（挂载自 `/root/polygon-suite/zkevm-prover/v8.0.0-rc.9-fork.12/config`）

### 需要检查的文件
```bash
# Batch 1 的输入文件（如果存在）
docker exec real-prover ls /usr/src/app/output/ | grep '\.1\.gen_batch'

# 最新的 aggregator 请求/响应
docker exec real-prover cat /usr/src/app/output/*.aggregator_request.txt | tail -5
docker exec real-prover cat /usr/src/app/output/*.aggregator_response.txt | tail -5
```

---

**报告生成时间**: 2026-06-15  
**诊断人员**: AI Assistant  
**SSH 状态**: ✅ 可用
