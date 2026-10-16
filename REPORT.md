# 报告：kind 集群 + ingress-nginx(NodePort/Local) + 集群外 nginx 的 L7 摘流验证

| | |
|---|---|
| 日期 | 2026-10-14 |
| 环境 | macOS arm64 · Docker Desktop 29.2.1 · kind v0.33.0 · Kubernetes v1.37.0 · ingress-nginx chart 4.15.1 / controller v1.15.1 · nginx 1.27-alpine |
| 交付目录 | `~/kind-ingress-lab/` |
| 当前状态 | 5 节点全部 Ready；ingress 6 副本 3/3 分布在两个 infra 节点；`etp=Local itp=Local`；外部 nginx 双 upstream 且 L7 探测在跑；端到端 300 请求全 200、零重试 |

---

## 0. 摘要

1. 5 节点 kind 集群（1 control-plane + 2 infra + 2 worker）跑通，ingress-nginx 用 **Deployment**，
   通过 nodeAffinity 钉在 infra 节点、topologySpreadConstraints 保证 **3/3**（3 节点时自动 **3/3/3**）。
2. Service 用 **NodePort 31000 + `externalTrafficPolicy: Local` + `internalTrafficPolicy: Local`**，
   实测确认：进哪个节点就只在该节点的 nginx 里选，**零跨节点跳转**。
3. 集群外 nginx（普通 docker 容器，挂 `kind` 网络）作为 L4 入口，upstream 指向 infra 节点的 NodePort。
4. **关掉一个 infra 节点，只靠 nginx 被动健康检查时：不会报错，但 p95 从 24ms 恶化到 3006ms，
   7.1% 的请求有 3 秒长尾，且这个长尾贯穿整个故障期不会消失。**
5. 加上 **L7 主动探测（ingress `/healthz`）+ 自动摘流** 后：检测 5～7s，
   **p95 降到 15～19ms，长尾归零，全程零 502/503/504**；节点恢复后自动加回。
6. 502 只在「所有 upstream 都不可用」时出现，且是毫秒级快速失败——这是刻意设计，
   没容量就明确报 502，不伪装成慢。

> 一句话结论：**`externalTrafficPolicy: Local` 保证了不跨节点，但它把"节点没有 endpoint"变成了静默黑洞。
> 所以 LB 侧必须有主动 L7 健康检查——否则故障只表现为长尾而不是错误，从状态码上完全看不出来。**

---

## 1. 架构

```
   Mac 宿主机  curl http://127.0.0.1:8080/
       │
   ┌───▼──────────────────────────────────────────────┐
   │ nginx-external  (普通 docker 容器, kind 网络)      │  ← 等价于 L4/ECMP 层
   │  · 容器内 L7 探测 http://<node>:31000/healthz      │
   │  · 连续 2 次失败摘除 / 连续 2 次成功加回            │
   │  · 改写 upstream 成员后 nginx -s reload            │
   └───┬──────────────────────────┬───────────────────┘
       │ NodePort 31000, externalTrafficPolicy: Local
   ╔═══▼═══════════════╗    ╔════▼═══════════════╗
   ║ ingress-lab-worker║    ║ ingress-lab-worker2║   [infra]  172.18.0.2 / 172.18.0.7
   ║  nginx ×3         ║    ║  nginx ×3          ║   taint infra:NoSchedule
   ╚═══╤═══════════════╝    ╚════╤═══════════════╝   Deployment + topologySpread(maxSkew=1)
       └────────────┬────────────┘
                    ▼ ClusterIP（internalTrafficPolicy: Local）
          demo/whoami pods（仅 worker3 / worker4）

   ingress-lab-worker3 / worker4  [node]
   ingress-lab-control-plane      [control-plane]  172.18.0.6
```

角色靠 label + taint，不靠节点名：

```
node-role.kubernetes.io/infra=true  + NoSchedule   → ingress-lab-worker, ingress-lab-worker2
node-role.kubernetes.io/node=""                    → ingress-lab-worker3, ingress-lab-worker4
```

---

## 2. 关键配置

### 2.1 ingress-nginx（`ingress-nginx-values.yaml`）

```yaml
controller:
  kind: Deployment
  replicaCount: 6                       # 每 infra-node 3 个：2节点=6 / 3=9 / 4=12

  affinity.nodeAffinity:                # ① 只跑 infra-node（硬约束）
    requiredDuringSchedulingIgnoredDuringExecution:
      nodeSelectorTerms:
        - matchExpressions:
            - {key: node-role.kubernetes.io/infra, operator: In, values: ["true"]}

  topologySpreadConstraints:            # ② 均匀铺开，不会 6/0 或 9/0/0
    - maxSkew: 1
      topologyKey: kubernetes.io/hostname
      whenUnsatisfiable: DoNotSchedule
      labelSelector:
        matchLabels: {app.kubernetes.io/name: ingress-nginx, app.kubernetes.io/component: controller}

  tolerations: [{key: node-role.kubernetes.io/infra, operator: Exists, effect: NoSchedule}]

  service:
    type: NodePort
    externalTrafficPolicy: Local        # ③ 禁止跨 Node 转发
    nodePorts: {http: 31000, https: 31001}

  podDisruptionBudget: {enabled: true}
  minAvailable: 50%                     # ④ PDB（注意 key 在 controller.minAvailable，见坑#10）
```

### 2.1.1 为什么这样配（每条对应一个不变量或一种事故）

整套配置只服务一个不变量：

> **上游 LB（本实验的 nginx-external / 生产里的 BGP+ECMP）接流量的每一个 Node，
> 本节点上必须至少有一个 Ready 的 ingress pod。**

因为 `externalTrafficPolicy: Local` 下，节点一旦没有本地 endpoint，kube-proxy 就把该节点的
NodePort **静默 DROP**（坑#4）——LB 那边看到的是“能宣告、但流量进去就没声音”，而不是 connection refused。
下面每一条都是在保证这个不变量，或者在控制它被破坏时的爆炸半径。

| 配置 | 为什么 | 不这配会怎样（实测/推演） |
|---|---|---|
| `kind: Deployment`（不用 DaemonSet） | 把“每节点几个副本”变成显式容量参数，并且需要滚动升级的批次控制（maxSurge/maxUnavailable）+ PDB 能生效 | DaemonSet 强制每节点 1 副本：单 pod 挂 → 该节点本地 endpoint 归零 → 整个节点的 NodePort 被 DROP，**pod 故障被放大成节点故障**（瞬间少 1/N 容量）。而 Deployment + 每节点 3 副本时，单 pod 挂不影响节点可达（已验证） |
| `replicaCount = 3 × N(infra)` | N-1 容量规则：挂一个节点，剩下 N-1 个节点每个还有 3 个副本，能吸收被摘节点的流量 | 固定副本（如 6）在 infra 扩到 3 节点时变 2/2/2，单节点容量下降；缩到 1 节点时又浪费 |
| `nodeAffinity` 硬约束到 `node-role.kubernetes.io/infra=true`（而不是 nodeSelector 按节点名） | 解耦“角色”和“物理节点名”：infra 增减只改 label/taint，Deployment 一行不动（kind 也不能自定义节点名，坑#10） | 按节点名写死后，换节点/重建集群就要改 values；用 `preferred` 则 ingress 会漏到业务节点，破坏不变量 |
| `tolerations` + infra 节点的 `NoSchedule` | 独占：业务不会挤进 infra（抢 CPU/连接表/带宽），ingress 也不会落到业务节点 | 没 taint 时 infra 节点会被调度到业务 pod，ingress 延迟不可控；LB 摘流时容量也不可控 |
| `topologySpreadConstraints maxSkew=1` + `DoNotSchedule` | 保证**每个** infra 节点都有 endpoint——这是 LB 能安全宣告节点的前提 | 6 副本堆到 1 个节点（6/0）时，另一个节点的 NodePort 直接 DROP，LB 按 ECMP 均匀送流量 → **一半流量进黑洞**（就是 3.3 里 3s 长尾的同类代价）。宁可 pod Pending，也不要分布不均 |
| `whenUnsatisfiable: DoNotSchedule`（硬）而不是 `ScheduleAnyway` | 分布不均 = LB 侧容量不均，是正确性问题不是偏好问题 | 代价（坑#8）：drain 一个节点时被驱逐的 pod 会 Pending，维护窗口容量减半——这由 PDB 50% 兜底，是故意的取舍 |
| `service.type: NodePort` + 固定 `nodePorts: 31000/31001` | 上游 LB/BGP 的配置变成常量，helm 重装升级不换端口 | 随机 NodePort → 每次部署都要改 LB |
| `externalTrafficPolicy: Local` | 不跨节点二跳、保留客户端真实 IP、延迟可预测；和“BGP 只宣告有本地 endpoint 的节点”是标准 ECMP 做法 | `Cluster` 下 kube-proxy 会 SNAT（后端看不到 client IP）且多一跳，infra 层的容量模型失效 |
| `internalTrafficPolicy: Local`（post-render 注入） | 集群内→ClusterIP 也只在 infra 节点服务，让集群内/集群外路径行为一致，避免业务节点“绕一圈自己的 ingress” | 不加则集群内调用会跨节点转发到 ingress，与外部路径不一致；代价见坑#11（非 infra 节点上的探测/自检会被 DROP） |
| `podDisruptionBudget` + `minAvailable: 50%` | 限制“自愿中断”（drain/升级）最多砍掉一半容量，保证维护不会把 ingress 层打到 0 | 没 PDB 时 `kubectl drain` 可以一次赶走某节点全部 3 个副本，叠加 TSC 硬约束 → 该节点直接没 endpoint。用百分比而不是固定数字，是为了 infra 节点数变化时自动跟随（`scale-infra.sh`） |
| `terminationGracePeriodSeconds: 30` | 给 nginx 自身的 drain + 在途请求留时间，滚动升级不产生 RST | 默认 30s 已够，显式写是为了和 LB 侧的摘流时间（~6s）对齐可推理 |
| `config.use-forwarded-headers` / `compute-full-forwarded-for` | 本实验前置了一个会写 XFF 的 L7 nginx，ingress 必须信任并追加，否则后端看到的源地址是 LB | 纯 L4/ECMP（没有 XFF）时这两项无感；保留是为了“前面还有一层可信 L7”的场景 |

一句话总结各层职责：
**nodeAffinity+taint 决定“在哪”，replicas=3×N+TSC 决定“每个都有且均匀”，
ETP/ITP=Local 决定“不跳出去”，PDB 决定“维护时不归零”**；
LB 侧的主动探测（第 2.3 / 3.5 节）是同一件事的另一半：
**k8s 保证“每个节点都有 endpoint”，LB 保证“没 endpoint 的节点不接流量”。**

### 2.2 `internalTrafficPolicy: Local`

chart 4.15.1 **没有这个 value**（`grep -rn internalTrafficPolicy templates/` 无结果）。
用 helm post-renderer 注入，`helm upgrade` 可幂等重放：

```bash
helm upgrade ... --post-renderer ./scripts/post-render-itp.py
```

只作用于 `ingress-nginx-controller`；admission webhook 和 metrics 是独立 Service，不受影响。

当前生效值：

```
NAME                      TYPE      ETP     ITP     NODEPORTS
ingress-nginx-controller  NodePort  Local   Local   31000, 31001
```

两个字段职责独立，缺一不可：

| 字段 | 作用路径 | 效果 |
|---|---|---|
| `externalTrafficPolicy: Local` | 集群外 → NodePort | 进哪个 infra-node 只在该节点的 nginx 里选 |
| `internalTrafficPolicy: Local` | 集群内 → ClusterIP | 只有 infra-node 上的 pod 能访问 ingress Service，其它节点 DROP |

### 2.3 集群外 nginx 的 L7 摘流

```
nginx/conf/nginx.conf.tmpl    upstream 里 include /etc/nginx/upstream/nodeports.conf
nginx/scripts/healthcheck.sh  容器内循环：L7 探测 → 防抖 → 改写成员 → nginx -s reload
nginx/scripts/entrypoint.sh   后台 healthcheck + 前台 nginx
scripts/external-nginx.sh     用 kubectl 生成候选节点列表 + 启动前一次性预热探测
```

探测实现里两个必须注意的点（都是实测出来的）：

- **不能带业务 Host 头**。带 `Host: demo.local` 时 `/healthz` 会被 ingress 规则匹配走，
  拿到的是业务 pod 的响应（422 字节），探测就失去意义。
- **只能判 HTTP 状态码**。默认 server 里是 `location /healthz { return 200; }`，**body 是空的**。

为什么这个信号可信：ingress-nginx 的 readinessProbe 打的是 `:10254/healthz`，pod 不健康会被摘出
EndpointSlice；某节点本地 endpoint 全空时 kube-proxy 对该节点 NodePort 直接 DROP。
所以一次 `/healthz` 200 同时覆盖了「节点可达 + 有本地 endpoint + nginx 默认 server 活着」。

默认参数：`HC_INTERVAL=2 HC_FAIL=2 HC_OK=2 HC_CONNECT_TIMEOUT=500ms`（均可用环境变量覆盖）。

---

## 3. 验证结果

### 3.1 调度约束

| 验证项 | 结果 |
|---|---|
| 副本分布（2 infra） | `3 / 3` ✅ |
| 扩到 3 infra + 9 副本 | 自动收敛 `3 / 3 / 3` ✅ |
| 只跑 infra（硬约束） | 无 toleration 的 pod 调度失败：`0/5 nodes are available: 2 didn't match node affinity, 3 had untolerated taints` ✅ |
| 业务不污染 infra | whoami 3 副本全部落在 worker3/4 ✅ |
| 节点 drain | PDB 保住 50% 容量，uncordon 后自动回 3/3 ✅（但见坑#6） |

### 3.2 流量语义：确认不跨节点

只打 infra-1（172.18.0.2:31000）的 20 个请求，按处理它的 ingress pod 统计：

```
pod=10.244.4.5   node=ingress-lab-worker    handled=6
pod=10.244.4.4   node=ingress-lab-worker    handled=6
pod=10.244.4.3   node=ingress-lab-worker    handled=8
pod=10.244.1.3   node=ingress-lab-worker2   handled=0
pod=10.244.1.4   node=ingress-lab-worker2   handled=0
pod=10.244.1.5   node=ingress-lab-worker2   handled=0
```

`internalTrafficPolicy: Local` 实测（访问 ClusterIP `10.96.150.135:80`）：

```
pod on ingress-lab-worker   (infra) -> OK
pod on ingress-lab-worker4  (node)  -> 静默超时
# worker4 上的规则：
-A KUBE-SERVICES -d 10.96.150.135/32 --dport 80
   -m comment "ingress-nginx/ingress-nginx-controller:http has no local endpoints" -j DROP
```

### 3.3 故障演练三轮对比

工具：`scripts/ingress-probe.py`（probe / analyze / join）。每个请求带唯一标记 `?probe=<id>`，
客户端观测能和 nginx 的 `$upstream_addr` 精确对齐（重试时它是 `A, B` 逗号分隔）。
场景：5 rps，关掉 `ingress-lab-worker2`，故障期 450 请求。

| 配置 | 摘流方式 | 检测耗时 | 状态码 | >1s 长尾 | p50 | **p95** | max |
|---|---|---|---|---|---|---|---|
| ① 只有 nginx 被动健康检查 | `max_fails=3 fail_timeout=15s` | **从不摘流** | 200×450 | **32 (7.1%)** | 5ms | **3006ms** | 3034ms |
| ② + L7 探测 (5s/3)，connect 3s | 主动摘 | 18s | 200×450 | 8 (1.8%) | 5ms | **39ms** | 3034ms |
| ③ + L7 探测 (2s/2)，connect 500ms | 主动摘 | ~5s | 200×450 | **0** | 5ms | **19ms** | 509ms |

**p95 从 3006ms 降到 19ms（158×），长尾从 7.1% 降到 0。**

① 的根因分析：

- 死节点的 NodePort 是 **静默 DROP**（不是 RST）：
  ```
  -A KUBE-EXTERNAL-SERVICES --dport 31000
     -m comment "ingress-nginx/...:http has no local endpoints" -j DROP
  ```
  nginx 必须耗满 `proxy_connect_timeout 3s` 才失败，再靠 `proxy_next_upstream` 重试 →
  客户端拿到 200，代价 3 秒。关联数据：`172.18.0.7:31000, 172.18.0.2:31000` n=33 p50=3006ms；
  单跳 `172.18.0.2:31000` n=417 p50=5ms。
- **nginx 开源版的被动健康检查是 per-worker 的**。本环境 8 个 worker 进程各自把死节点置冷 15s 后再探一次
  → 聚合起来是**持续不断**的探测：33 次重试均匀分布在 90s 里，相邻间隔中位数 3s（= connect 超时）。
  所以长尾不会在"节点被标记不可用"后消失，而是贯穿整个故障期。
- **k8s 自己发现得慢**：`docker stop` 后节点 `Ready=True` 持续到 +40s，+50s 才变 `Unknown`
  （kubelet lease 未过期）。依赖 k8s 节点/endpoint 状态的 LB 有 40s+ 盲飞窗口。

### 3.4 502/503 专项验证

脚本：`scripts/switchover-check.sh`（20 rps，故障期 1200 请求）。**结论：不会触发 5xx。**

```
nginx access log 全量状态码:  200 = 1602      5xx = 0
客户端侧（故障期 1200 请求）:  200 = 1200      5xx = 0   传输错误 = 0

error_log 事件统计:
  no live upstreams              0     ← 唯一会产生 502 的事件
  upstream timed out            18     ← 打到死节点，已重试到活节点，客户端仍 200
  server temporarily disabled    2     ← 被动健康检查标记，不影响状态码
  connect() failed               0
```

切换时间线（客户端无感知）：

```
16:25:50  docker stop ingress-lab-worker2
16:25:57  [hc] REMOVE 172.18.0.7:31000 (连续 2 次 /healthz 非 200)   ← 检测 7s
16:25:57  [hc] upstream 变更 -> 1 个可用节点，reload nginx
16:27:35  [hc] ADD    172.18.0.7:31000 (连续 2 次 /healthz 200)      ← 节点回来后自动加回
```

- 18 个受影响请求全部集中在宕机后的 **7s 检测窗口内**（重试时间线只有一个 `+0s` 桶），之后零重试。
- **`nginx -s reload` 是优雅重载**：摘流那一刻没有任何请求被掉，5xx 时间点统计 = 0。
- 故障期 p95=15ms / p99=505ms / max=518ms，全部 200。

边界测试——把两个 infra 节点全关掉：

```
16:28:14  docker stop 两个 infra 节点
16:28:18  [hc] REMOVE 172.18.0.2
16:28:20  [hc] REMOVE 172.18.0.7   → upstream 只剩 server 127.0.0.1:1 down;
客户端:   502 (0.003s)  502 (0.001s)  502 (0.002s)
error_log: no live upstreams while connecting to upstream
```

即 502 只在「所有 upstream 都不可用」时出现，且是**毫秒级快速失败**（不是等超时）。
这是刻意设计：healthcheck 在零健康节点时写入 `server 127.0.0.1:1 down;` 占位，既保证 upstream
语法合法（空 upstream 会让 reload 失败），也让客户端拿到明确的 502 而不是挂在死成员上耗 connect 超时。
节点恢复后自动 ADD，立刻回到 200。

### 3.5 L4 探测 vs L7 探测（`HC_MODE=l4|l7`）

> 完整数据与参数推导见 **`REPORT-l4-probe.md`**（含“关掉 infra-node 会不会掉”的实测与
> infra Deployment 逐条配置理由）。本节是摘要。

`nginx/scripts/healthcheck.sh` 支持两种探测层：

```sh
HC_MODE=l4   nc -z -w 2 <node>:31000                    # 只做 TCP connect
HC_MODE=l7   wget -T2 http://<node>:31000/healthz       # 判 HTTP 200（默认）
```

**演练 A：真的关掉一个 infra-node**（`HC_MODE=l4 METHOD=GET|POST ./scripts/failover-test.sh`）

| 探测 | 方法 | 摘流耗时 | 状态码 | 重试 | 重试请求代价 |
|---|---|---|---|---|---|
| L4 (2s/2) | GET | +6s | 200×450，**0 个非 200** | 7/450 (1.6%) | 505–516ms |
| L4 (2s/2) | POST | +6s | 200×300，**0 个非 200** | 5/300 (1.7%) | 506–509ms |
| L7 (2s/2) | POST | +6s | 200×300，**0 个非 200** | 5/300 | 506–509ms |

结论：**节点真 down 时 L4 和 L7 完全等价，都不掉请求**。原因：

- 死节点的 NodePort 是静默 DROP（坑#4），**TCP connect 本身就失败**，
  所以 L4 探测和真实请求在同一时刻失败，检测耗时都是 `fail×interval + probe_timeout ≈ 6s`。
- 失败发生在 **connect 阶段** ⇒ 请求根本没发出去 ⇒ nginx 对 GET **和 POST** 都会重试到活节点。
  （nginx 的“非幂等不重试”只针对“请求已经发给 upstream”的情况，见演练 B。）
- 代价由 `proxy_connect_timeout` 决定：500ms 封顶，全程 0 个 >1s、0 个 5xx。

**演练 B：L4 的盲区**（`scripts/l4-blindspot-test.sh`）

在 infra 节点上插一条 nat PREROUTING DNAT，把 :31000 劫持到一个“accept 之后立刻关闭”的 TCP sink
（`alpine: nc -l -p 8080 -k -e /bin/true`）——三次握手成功，HTTP 永远没响应：

```
L4 (nc -z)      -> 连接成功        ⇒ 判定【健康】   ← 节点继续接流量
L7 (/healthz)   -> HTTP='<无响应>'  ⇒ 判定【不可用】
```

| 探测 | 方法 | 状态码 | 重试率 | 说明 |
|---|---|---|---|---|
| L4 | GET | 200×150 | 17.3% | 靠 `proxy_next_upstream` 兜住，max 21ms（sink 立刻断连，不耗 connect 超时） |
| L4 | POST | **502×9 / 150（6% 真掉）** | — | 连接已建立、请求已发出 → 非幂等不重试 → 客户端拿到 502 |
| L7 | POST | 200×150 | **0%** | 节点在 +6s 被摘掉，坏节点根本没进流量 |

结论：L4 探测只在“节点/端口不可达”这类故障上等价于 L7。
凡是“三次握手成功但数据面不工作”（进程 hang、nginx 配置/规则没加载完、
中间有个只做 proxy 的设备、conntrack 黑洞），L4 都会误判为健康；
这时 GET 被重试掩盖，**非幂等请求直接 502**。

**演练中发现的一个真 bug（和探测层无关）**：候选列表用 `kubectl ... > nodes` 重写会先截断文件，
容器里的 healthcheck 正好读到空 → upstream 被清空 → `no live upstreams` → **10 个请求 502**。
已修：写临时文件 + `mv`（原子），并在 healthcheck 里加“空列表跳过本轮”的保护。

### 3.6 闭环并发：5 个常驻 client，中途关掉 infra-node

> 完整数据见 **`REPORT-l4-probe.md` §4B**。工具：`scripts/concurrency-failover-test.sh`（stop/kill/drain）
> + `scripts/concurrency-probe.py`（连接复用、`--slow` 造在飞请求）+ `manifests/slow-backend.yaml`。

| 关节点方式 | 方法 | 非 200 | 在飞 5 个中落在死节点的 | 代价 |
|---|---|---|---|---|
| `docker stop` | GET | 0 | 0 | 12 个新请求 +500ms |
| `docker kill` | GET (slow=3s) | 0 | 2 | 重放，总 5.87s / 5.25s |
| `docker kill` | POST (slow=3s) | **2 × 502（1.0%）** | 2 | 直接 502 |
| `kubectl cordon + drain` | POST (slow=3s) | **0** | 2 | 无 |

**决定的优先级：怎么关节点 ＞ 请求幂等性 ＞ 摘流速度 ＞ 探测层（L4/L7）。**

---

## 4. 坑清单（全部实测复现）

### K8s / kind

1. **kind 配置里的 `labels:` 不能打 `node-role.kubernetes.io/*`**。它会注入 kubelet `--node-labels`，
   而 kubelet 对 `kubernetes.io` 命名空间有白名单 → kubelet 直接退出，`kind create cluster` 卡在
   `kubelet-wait-bootstrap`，报错还很误导人（"required cgroups disabled"）。真实日志：
   `failed to validate kubelet flags: unknown 'kubernetes.io' labels specified with --node-labels`。
   → 集群起来后用 `kubectl label`。
2. **`kubectl taint ... --overwrite` 是"加"不是"删"**；删 taint 用 `kubectl taint node X key:NoSchedule-`。
3. **`healthCheckNodePort` 在 `type: NodePort` 上不可用**，API 直接拒绝：
   `may only be set when type is 'LoadBalancer' and externalTrafficPolicy is 'Local'`。
4. **无本地 endpoint 的节点是 `-j DROP` 而不是 REJECT** → 客户端只看到 SYN 超时，收不到 RST。
   LB 的健康检查必须带 connect 超时。
5. **`externalTrafficPolicy: Local` 会让 `127.0.0.1:31000` 失效**：kind 的 `extraPortMappings` 只能绑
   control-plane，那里没有本地 ingress endpoint。宿主机访问必须走集群外 nginx 或直连 infra 节点 IP。
6. **`whenUnsatisfiable: DoNotSchedule` 与 drain 互卡**：2 节点 6 副本时 drain 一个节点，被驱逐的 pod
   会长期 Pending（放另一节点就是 6/0，skew=6>1）。drain 本身能完成，PDB 保住 50%，uncordon 后自动恢复。
   想维护期保持满副本就改 `ScheduleAnyway`（软约束），代价是分布不均。
7. **`internalTrafficPolicy: Local` 会打断集群内 hairpin 调用**：非 infra 节点访问 ingress Service
   ClusterIP 一律 DROP。常见踩坑：集群内应用绕自己的 ingress、集群内监控探测 ingress。
   需要这些路径就给探测任务加 `nodeSelector` 到 infra 节点，或单独建一个 `internalTrafficPolicy: Cluster` 的 Service。
8. **节点重启后 IP 会变**：实测 `docker stop/start ingress-lab-worker2` 后 172.18.0.4 → 172.18.0.7
   （docker 重新分配）。静态 upstream 会失效，LB 必须能重新枚举节点。
9. kind 不能自定义节点名，角色只能靠 label/taint。
10. **chart 4.15.1 的 PDB 阈值取 `controller.minAvailable`**，写在
    `controller.podDisruptionBudget.minAvailable` 下会被静默忽略（渲染成默认值 1）。

### nginx / 工具

11. 解析 nginx access log 时 `$upstream_addr` 在重试时是 `A, B`（含空格），用 `\S+` 会把重试请求
    整条日志漏掉 —— 第一版工具因此得出"重试 0 次"的错误结论。
12. 集群外 nginx 被重建（`docker rm -f`）时，故障期的日志会一起消失 → 演练必须每阶段快照日志。
13. upstream 里放 IPv6 需要 `[::1]:port` 语法。dual-stack 下把 InternalIP 全塞进去会让
    `nginx -s reload` 连续失败 20+ 次。
14. busybox `timeout` 是 `timeout SECS CMD`（不支持 `-t`）；`date +%N` 在 busybox 下不可用。
15. shell 函数参数错位（`setcnt() { echo "$2" > ... }` 应为 `$3`）把字面量 `fails` 写进计数文件，
    导致 `-ge 3` 恒假、**摘流逻辑完全没生效**，第一轮演练白跑 —— 必须端到端验证，不能只看代码。
16. **候选节点列表不能非原子重写**：`kubectl ... > nodes` 会先把文件截断成 0 字节，
    容器里的 healthcheck 正好读到空 → 生成空 upstream → `no live upstreams` → 全量 502（实测 10 个）。
    必须 `>.nodes.tmp && mv`，并在 healthcheck 里加“空列表跳过本轮”的保护。
17. **L4 探测（TCP connect）分不清“端口通”和“数据面通”**：实测把 NodePort DNAT 到一个
    accept 即关的 sink，L4 判定健康、GET 有 17% 在重试、POST 直接 6% 502；L7 探测 6s 内摘流，0 掉。
    另外注意 nginx 的重试语义：**connect 失败**（请求没发出去）GET/POST 都会重试；
    **请求已发出**后只有幂等方法才重试 —— 这就是同一个故障下 GET 不掉、POST 掉的原因。
18. **`least_conn` 是 per-worker 的**：8 worker + 5 个同步 client ⇒ 每个 worker 自己看“两台都 0 连接”，
    整批请求全落同一个 upstream（实测按批交替 .2/.6/.2）。闭环并发压测必须错开起跑（`--stagger`），
    否则“关节点切到几个在飞请求”只会得到 0 或 N。
19. **`nginx -s reload` 对客户端 keepalive 不是 100% 无损**：摘流/加回 reload 那一秒各出现 1 次
    `RemoteDisconnected`（0ms，access log 无该请求）。开源 nginx 只能靠 reload 改后端池，
    摘流越频繁风险越高。
20. **慢后端不能用 busybox `nc -k`**（串行处理，延迟会叠加）；whoami 也不支持 sleep。
    用 `python:3.12-alpine` + ThreadingHTTPServer（`manifests/slow-backend.yaml`）。

---

## 5. 生产落地建议（对应 BGP/ECMP + Antrea）

| 层次 | 职责 | 做法 |
|---|---|---|
| L3/L4 | 哪个 Node | BGP 只宣告"有本地 ingress endpoint 的节点"，且等 nginx pod Ready 后再宣告 |
| L4 | Node 内哪个 nginx | `externalTrafficPolicy: Local`（已验证零跨节点） |
| LB 健康检查 | 摘流 | **必须主动**：优先 `healthCheckNodePort`（需 `type: LoadBalancer`），否则 TCP connect + 短超时 + L7 `/healthz` |
| 超时 | 控制长尾 | connect 超时 500ms 而不是 3s；探测 interval 2s / fail 2 → 检测 ~5s |
| 容量 | 单点故障 | 每节点 ≥2 个 nginx pod + PDB 50% |
| 拓扑 | 均匀分布 | `topologySpreadConstraints maxSkew=1`，infra 增减时 replicas 按 3×N 重算 |

补充判断：

- 真实环境建议把 ingress Service 做成 `type: LoadBalancer` + Antrea BGP 宣告，这样 `healthCheckNodePort`
  可用，LB 拿到明确的 200/403，不用靠超时猜。
- nginx 开源版做不了主动健康检查（`max_fails` 是被动且 per-worker）。要在这个位置用 nginx，
  就得像本实验一样外挂一个探测循环；否则直接换 HAProxy / Envoy / nginx Plus 的 active health check。
- 监控上必须盯 **p99 和 upstream 重试次数**，而不是只看状态码——本次故障模式下错误率是 0，
  但 p95 恶化了 158 倍。

---

## 6. 交付物

```
~/kind-ingress-lab/
├── REPORT.md                        本报告
├── REPORT-l4-probe.md               L4 探测 vs L7 探测 + infra Deployment 配置理由
├── README.md                        速查 + 架构图
├── kind-config.yaml                 5 节点拓扑 + 31000/31001 宿主机端口映射
├── ingress-nginx-values.yaml        Deployment + nodeAffinity + TSC + Local + PDB
├── manifests/demo-app.yaml          demo 业务（钉在 worker）+ 2 条 Ingress 规则
├── manifests/slow-backend.yaml      /slow?sleep=Ns 慢后端（闭环并发用，制造在飞请求）
├── nginx/
│   ├── conf/nginx.conf.tmpl         upstream 用 include，成员动态生成
│   ├── scripts/healthcheck.sh       L4/L7 探测（HC_MODE）+ 防抖摘流/加回 + reload
│   ├── scripts/entrypoint.sh        后台 healthcheck + 前台 nginx
│   └── upstream/{nodes,nodeports.conf}  候选节点 / 当前生效成员
└── scripts/
    ├── bootstrap.sh                 一键重建整套环境
    ├── external-nginx.sh            生成候选列表 + 预热探测 + 起外部 nginx
    ├── post-render-itp.py           helm post-renderer（注入 internalTrafficPolicy）
    ├── scale-infra.sh               infra 节点增删 + replicas 按 3×N 重算 + 等新 endpoint
    ├── ingress-probe.py             压测 / nginx 日志分析 / 客户端-上游关联（支持 GET/POST）
    ├── summarize-runs.py            多轮演练结果汇总成一张表
    ├── failover-test.sh             故障演练（基线 / 停节点 / 恢复），HC_MODE + METHOD 可选
    ├── l4-blindspot-test.sh         L4 探测盲区实验（TCP 通、HTTP 死 → POST 502）
    ├── concurrency-probe.py         闭环并发压测（持久连接、--slow/--stagger/--method）
    ├── concurrency-failover-test.sh 并发模型下 stop / kill / drain 对比
    ├── switchover-check.sh          502/503 专项验证
    └── teardown.sh                  拆除
```

### 复现命令

```bash
cd ~/kind-ingress-lab
./scripts/bootstrap.sh                    # 建集群 + 装 ingress + 起外部 nginx
./scripts/switchover-check.sh            # 502/503 专项验证（最有说服力的一条）
./scripts/failover-test.sh               # 三轮故障演练
HC_MODE=l4 METHOD=POST ./scripts/failover-test.sh   # 把探测换成纯 TCP connect
./scripts/l4-blindspot-test.sh            # L4 盲区：TCP 通、HTTP 死 → POST 502
python3 scripts/summarize-runs.py /tmp/failover-l4 /tmp/failover-l4-post2 /tmp/failover-l7-post
./scripts/scale-infra.sh add ingress-lab-worker3    # infra 扩到 3，replicas 自动 9，验证 3/3/3
./scripts/ingress-probe.py analyze --logfile /tmp/switchover/all.log
./scripts/ingress-probe.py join --csvfile /tmp/switchover/out.csv --logfile /tmp/switchover/all.log
./scripts/teardown.sh
```

调优参数：

```bash
HC_INTERVAL=2 HC_FAIL=2 HC_OK=2 HC_CONNECT_TIMEOUT=500ms ./scripts/external-nginx.sh
```
