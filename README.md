# kind + ingress-nginx + 集群外 nginx：L7 摘流实验环境

本机 Docker/kind 上的 5 节点 k8s。ingress-nginx 用 **Deployment**，通过 nodeAffinity 钉在 infra 节点、
topologySpreadConstraints 均匀铺开；Service 用 **NodePort + `externalTrafficPolicy: Local`**
（流量进哪个节点就只在该节点的 nginx 里选，绝不跨节点）。再在 **k8s 外**跑一个 nginx 充当 L7 LB，
upstream 只包含「本节点有 ingress endpoint」的 infra 节点。

**这套环境是为了回答一个问题：nginx 做 LB 时，流量切换怎么做才不掉请求。**

| 文件 | 内容 |
|---|---|
| **[`SWITCHOVER.md`](SWITCHOVER.md)** | **主文档**：完整的流量切换方案 —— L4/L7 探测对比、LB 配置、计划内维护流程、参数推导、生产对应 |
| [`EVIDENCE.md`](EVIDENCE.md) | 实验台账 T1–T15：假设、方法、数据、结论，以及被后续实验推翻的结论 |
| [`PITFALLS.md`](PITFALLS.md) | 坑清单（唯一一份，按稳定 ID 引用） |
| `archive/` | 2026-10-14 / 10-15 两份原始报告（按时间追加的旧版本，保留备查） |

---

## 拓扑

```
  Mac 宿主机   curl http://127.0.0.1:8080/
       │
       ▼
  nginx-external  (普通 docker 容器，加入 kind 网络)          ← 等价于生产里的 L4/ECMP + L7 层
    · 容器内 L7 探测  http://<node>:31000/healthz              连续 2 次失败摘除 / 2 次成功加回
    · 改写 upstream 成员后 nginx -s reload
       │
       │  NodePort :31000 / :31001,  externalTrafficPolicy: Local
       ├──────────────────────────────┬───────────────────────────┐
       ▼                              ▼                           │
  ingress-lab-worker            ingress-lab-worker2        [infra]  ingress-nginx ×3 each
                                                        [infra]  taint infra:NoSchedule
       │                              │
       └──────────────┬───────────────┘
                      ▼  ClusterIP, internalTrafficPolicy: Local
              demo/whoami pods            [node]  只在 ingress-lab-worker3 / worker4

              ingress-lab-control-plane   [control-plane]
```

角色靠 label + taint，不靠节点名（kind 不能自定义节点名）：

```
node-role.kubernetes.io/infra=true + NoSchedule  → ingress-lab-worker, ingress-lab-worker2
node-role.kubernetes.io/node=""                 → ingress-lab-worker3, ingress-lab-worker4
```

版本：kind v0.33.0 · k8s v1.37.0 · ingress-nginx chart 4.15.1 / controller v1.15.1 · nginx 1.27-alpine。

---

## k8s 侧：保证每个节点都有 endpoint

摘流方案有两半。**k8s 保证「每个节点都有 endpoint」，LB 保证「没 endpoint 的节点不接流量」**
（后者见 [`SWITCHOVER.md`](SWITCHOVER.md)）。这一半的全部配置只服务一个不变量：

> **上游 LB（这里是 nginx-external，生产里是 BGP/ECMP）接流量的每一个节点，本节点必须至少有一个 Ready 的 ingress pod。**

因为 `externalTrafficPolicy: Local` 下，节点没有本地 endpoint 时 kube-proxy 对该节点的 NodePort 是
**静默 DROP，不是 RST**（`P-04`）—— LB 看到的是「能宣告，但流量进去没声音」。

```yaml
# ingress-nginx-values.yaml
controller:
  kind: Deployment
  replicaCount: 6                    # 每 infra-node 3 个：2节点=6, 3节点=9, 4节点=12

  affinity:                          # ① 只跑 infra-node（硬约束，不依赖节点名）
    nodeAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        nodeSelectorTerms:
          - matchExpressions:
              - key: node-role.kubernetes.io/infra
                operator: In
                values: ["true"]

  topologySpreadConstraints:         # ② 均匀铺开：3/3/3，不会 6/0 或 9/0/0
    - maxSkew: 1
      topologyKey: kubernetes.io/hostname
      whenUnsatisfiable: DoNotSchedule
      labelSelector:
        matchLabels: {app.kubernetes.io/name: ingress-nginx, app.kubernetes.io/component: controller}

  tolerations:                       # infra-node 有 NoSchedule taint
    - {key: node-role.kubernetes.io/infra, operator: Exists, effect: NoSchedule}

  service:
    type: NodePort
    externalTrafficPolicy: Local     # ③ 禁止跨 Node 转发
    nodePorts: {http: 31000, https: 31001}

  podDisruptionBudget:
    enabled: true
  minAvailable: 50%                  # ④ PDB（注意 key 的位置，见 P-12）
```

| 配置 | 为什么 | 不这样配会怎样 |
|---|---|---|
| `kind: Deployment`（不用 DaemonSet） | 把「每节点几个副本」变成显式容量参数；需要滚动升级批次控制 + PDB 生效 | DaemonSet 每节点固定 1 副本：单 pod 挂 → 该节点 endpoint 归零 → **整个节点 NodePort 被 DROP，pod 故障放大成节点故障**。Deployment + 每节点 3 副本时单 pod 挂不影响节点可达（已实测） |
| `replicaCount = 3 × N(infra)` | N-1 容量规则：挂一个节点，剩下的节点每个还有 3 副本，能吸收流量 | 副本写死（如 6）时 infra 扩到 3 节点变 2/2/2，单节点容量下降；缩到 1 节点又浪费。`scale-infra.sh` 按 3×N 重算 |
| `nodeAffinity` 硬约束到角色 label | 角色与物理节点名解耦：infra 增减只改 label/taint，Deployment 一行不动 | 按节点名写死后换节点/重建集群就要改 values；用 `preferred` 则 ingress 会漏到业务节点，破坏不变量 |
| `tolerations` + infra 的 `NoSchedule` | 独占：业务不挤进 infra（抢 CPU/连接表/带宽），ingress 不落业务节点 | 没 taint 时容量和延迟都不可控 |
| `topologySpread maxSkew=1` + `DoNotSchedule` | 保证**每个** infra 节点都有 endpoint —— 这是 LB 能安全宣告节点的前提 | 6 副本堆成 6/0 时另一节点 NodePort 直接 DROP，ECMP 均匀送流量 → **一半流量进黑洞**。宁可 Pending 也不要不均（代价见 `P-06`） |
| `type: NodePort` + 固定 `31000/31001` | 上游 LB/BGP 配置成常量，helm 重装不换端口 | 随机 NodePort → 每次部署都要改 LB。`healthCheckNodePort` 在 NodePort 上被 API 拒绝（`P-03`） |
| `externalTrafficPolicy: Local` | 不跨节点二跳、保留客户端真实 IP、延迟可预测；和「BGP 只宣告有本地 endpoint 的节点」是标准 ECMP 做法 | `Cluster` 下 kube-proxy SNAT（后端看不到 client IP）且多一跳，infra 层容量模型失效 |
| `internalTrafficPolicy: Local`（post-render 注入） | 集群内 → ClusterIP 也只在 infra 节点服务，集群内外路径行为一致 | 不加则集群内调用会跨节点转发到 ingress；代价见 `P-07` |
| `PDB minAvailable: 50%` | 自愿中断（drain/升级）最多砍一半容量 | 没 PDB 时 `drain` 能一次赶走某节点全部 3 副本，叠加 TSC 硬约束 → 该节点直接没 endpoint。用百分比而非固定数字，infra 扩容自动跟随 |
| `terminationGracePeriodSeconds: 30` | 给 nginx 自身 drain + 在途请求留时间，升级不产生 RST | 与 LB 侧摘流时间（~6s）对齐，可推理 |

职责一句话：**nodeAffinity + taint 决定「在哪」，replicas=3×N + TSC 决定「每个都有且均匀」，
ETP/ITP=Local 决定「不跳出去」，PDB 决定「维护时不归零」。**

### 两个 traffic policy 互相独立，都要设

chart 4.15.1 **没有 `internalTrafficPolicy` 这个 value**（`grep -rn internalTrafficPolicy templates/` 无结果），
用 helm post-renderer 注入，`helm upgrade` 可幂等重放：

```bash
helm upgrade ... --post-renderer ./scripts/post-render-itp.py
```

| 字段 | 作用路径 | 效果 |
|---|---|---|
| `externalTrafficPolicy: Local` | 集群外 → `NodePort` | 进哪个 infra-node 只在该节点的 nginx 里选 |
| `internalTrafficPolicy: Local` | 集群内 → `ClusterIP` | 只有 infra-node 上的 pod 能访问 ingress Service，其它节点 DROP |

当前生效值：

```
NAME                      TYPE      ETP     ITP     NODEPORTS
ingress-nginx-controller  NodePort  Local   Local   31000, 31001
```

---

## 快速开始

```bash
cd ~/kind-ingress-lab
./scripts/bootstrap.sh                              # 建集群 + 装 ingress + 起外部 nginx
./scripts/scale-infra.sh add    ingress-lab-worker3 # 扩 infra：replicas 自动改成 3×N 并等新 endpoint
./scripts/scale-infra.sh remove ingress-lab-worker3 # 缩 infra：drain + 摘标签 + 重算 replicas
./scripts/scale-infra.sh status                     # 看 infra 节点和 pod 分布
./scripts/external-nginx.sh                         # 重新探测节点健康并重建 upstream
./scripts/teardown.sh
```

跑一遍摘流验证（细节与参数见 [`SWITCHOVER.md` §10](SWITCHOVER.md)）：

```bash
./scripts/switchover-check.sh                       # 502/503 专项：切换会不会出 5xx
./scripts/failover-test.sh                          # 开环：摘流与长尾（HC_MODE=l4|l7, METHOD=GET|POST）
./scripts/graceful-reboot-infra.sh ingress-lab-worker2   # 计划内维护（推荐方案，实测 0 掉）
```

---

## 文件结构

```
├── SWITCHOVER.md            主文档：流量切换方案
├── EVIDENCE.md              实验台账 T1–T15
├── PITFALLS.md              坑清单
├── archive/                 旧版报告（按时间追加）
├── kind-config.yaml         5 节点拓扑 + 31000/31001 宿主机端口映射
├── ingress-nginx-values.yaml  Deployment + nodeAffinity + TSC + Local + PDB
├── manifests/
│   ├── demo-app.yaml        demo 业务（钉在 node）+ 2 条 Ingress 规则
│   └── slow-backend.yaml    /slow?sleep=Ns 慢后端（闭环并发用，制造在飞请求）
├── nginx/                   集群外 LB
│   ├── conf/nginx.conf.tmpl upstream 用 include，成员动态生成
│   ├── scripts/healthcheck.sh  L4/L7 探测 + 防抖摘流/加回 + 三个名单 + reload
│   ├── scripts/entrypoint.sh   后台 healthcheck + 前台 nginx
│   └── upstream/               nodes（候选）/ nodeports.conf（生效成员）/
│                             manual_down.list / manual_hold.list / history/
└── scripts/
    ├── bootstrap.sh  teardown.sh  external-nginx.sh  post-render-itp.py  scale-infra.sh
    ├── ingress-probe.py             开环压测 / nginx 日志分析 / 客户端-上游关联
    ├── concurrency-probe.py         闭环并发压测（持久连接、--slow/--stagger/--method）
    ├── summarize-runs.py            多轮演练结果汇总成一张表
    ├── failover-test.sh             开环故障演练（基线 / 停节点 / 恢复）
    ├── l4-blindspot-test.sh         L4 盲区（TCP 通、HTTP 死）
    ├── concurrency-failover-test.sh 闭环模型下 stop / kill / drain / restart 对比
    ├── switchover-check.sh          502/503 专项验证
    ├── nodeport-vs-ingress-gap.sh   量 NodePort 与 ingress 实际可用之间的 GAP
    ├── graceful-restart-infra.sh    cordon → LB 摘流 → 等排空 → drain → restart
    ├── graceful-reboot-infra.sh     推荐方案：节点侧摘流 + 等排空 + drain + reboot
    └── lb-mark.sh  maintenance-restart.sh   维护窗口标 upstream down（必须 reload 时）
```

---

## 与 Antrea + BGP/ECMP 方案的对应

| 本实验里的东西 | 生产环境里的对应物 |
|---|---|
| `nginx-external` 容器 + 探测式 upstream | BGP/ECMP 宣告 + 健康检查 |
| 外挂 L7 探测循环（`healthcheck.sh`） | `healthCheckNodePort`（需 `type: LoadBalancer`）—— 控制面事件驱动，不用超时探测 |
| 节点侧 nat 摘流（DNAT 到死端口 → RST） | 撤 BGP 宣告 / 节点侧摘流 |
| `manual_hold.list`（维护期抑制摘流） | 维护窗口抑制宣告抖动 |
| `nginx -s reload` | BGP 宣告变更（没有「杀客户端连接」的代价） |

真实环境里更干净的做法：把 ingress Service 做成 `type: LoadBalancer` + Antrea BGP 宣告，
这样 `healthCheckNodePort` 可用，LB 拿到明确的 200/403 而不是靠超时判断。
完整对照见 [`SWITCHOVER.md` §8](SWITCHOVER.md)。
