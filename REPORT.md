# 一份报告：用 HTTP/TCP（L4/L7）健康探测时，怎么做到「优雅切换流量」

> 本报告是**唯一一份**。它合并了原来的 `SWITCHOVER.md`（方案）、`EVIDENCE.md`（实验台账 T1–T15）、
> `PITFALLS.md`（坑清单）和 `archive/` 里的两份旧报告 —— 这三份现在也在 `archive/`，只备查。
> 合并的同时，**2026-10-19 在本环境把关键场景重新跑了一遍**（场景 S1–S6，见 §2、§3），
> 新增两个此前没有覆盖的场景：**加回（恢复期）竞争**（S3）和**业务面故障**（S4）。
>
> 阅读规则：**每一条数据都标注了「哪个脚本产生的 + 什么场景」**。
> 场景编号 `S1…S6` = 本轮实测；`T1…T15` = 历史台账（§4，已压缩，结论仍有效）；`P-xx` = 坑（§8）。

生成时间：2026-10-19 09:04 UTC · 集群 `ingress-lab`（kind v0.33.0 / k8s v1.37.0 / ingress-nginx chart 4.15.1, controller v1.15.1 / nginx 1.27-alpine）

---

## 0. 一页结论

**「优雅切换」不是一件事，是三件事，分属不同的层。缺任何一层都会掉请求：**

| 要解决什么 | 谁负责 | 靠什么信号 / 手段 | 不做的后果 |
|---|---|---|---|
| ① **新请求不再进这个节点**（摘流） | LB | L7 探测（默认 `/healthz`；要挡业务面故障就用 **canary 路由**）或节点侧主动摘流 | 每个新请求付一次 `proxy_connect_timeout`，且**贯穿整个故障期** |
| ② **已经在飞的请求不被切** | k8s | `drain`（endpoint 先摘 + 优雅终止）；或节点侧摘流后**等连接排空** | 非幂等请求直接 502（本轮 S5a 实测复现） |
| ③ **加回不早于能服务** | LB | 连续 `OK_MAX` 次成功 + hold-down；canary 探测 | 流量打到「TCP 通但没 endpoint / 规则没 sync」的节点 |

**探测层（L4 vs L7）在这三件事里的真实作用范围，比想象中小：**

```
决定「会不会掉请求」的因素，按影响大小排序：
1. 节点是怎么关的        硬 crash vs cordon+drain          ← 影响最大（S5a vs S5b：1 个 502 vs 0 个）
2. 故障发生在哪一层      端口不通 / 端口通但 HTTP 死 / 只有业务路由死  ← 决定哪种探测能发现（S2、S4）
3. 摘流有多快            fail × interval + probe_timeout    ← 6–8s（S1）；节点侧 RST 摘流 3s（S5b/S6）
4. 超时怎么配            proxy_connect_timeout / read_timeout / next_upstream_timeout ← 单次代价上限（S4：10s 长尾）
5. L4 还是 L7            ← 只在「TCP 通但数据面不工作」时才有区别（S2、S4）
```

**L4 与 L7 的准确关系（本轮修正/补强）：**

- 对「节点 down / 没有本地 endpoint」这类故障，**L4 与 L7 完全等价**（S1：同时刻失败、同样 7s 摘流、都 0 掉）。
  原因：`externalTrafficPolicy: Local` 下没有本地 endpoint 的节点，kube-proxy 对 NodePort 是**静默 DROP**（P-04），
  TCP connect 本身就失败 —— 探测和真实请求以同一方式失败。
- 也正因为这条，**在 NodePort + ETP=Local 架构里，「TCP 通」隐含「本节点有本地 endpoint」**，
  所以 L4 的**加回**不会早于「有 endpoint」（S3：三轮「加回过早」窗口都是 0 个请求）。
- L4 的真差别在**「三次握手成功但数据面不工作」**：进程 hang、只做 proxy 的中间设备、conntrack 黑洞（S2），
  这时 GET 被重试掩盖、**POST 直接 502（S2 实测 6.7%）**。
- **默认 L7（探 ingress 默认 server 的 `/healthz`）也有一层盲区**：业务路由坏了 / 规则没 sync 时它照样 200。
  本轮 S4 实测：这种故障下默认 L7 摘不掉节点，**6% 的请求卡满 10s（`proxy_read_timeout`）后超时**；
  换成 **canary 探测**（带业务 Host、走真实 server→location→upstream 全链路）4s 摘除，**0 影响**。

**最终推荐（本轮 S6 实测：3020 请求 / 0 个非 200 / 0 个连接被断 / 维护期 0 次 reload）：**

1. LB 用 **L7 探测**，参数 `interval=2 fail=2 ok=2 probe_timeout=2`（摘流 ≈6s，加回 ≈+3s）；
   生产上把探测目标从默认 `/healthz` 换成 **canary 路由**（本仓库已实现：`HC_HOST` + `manifests/canary-ingress.yaml`）。
2. `proxy_connect_timeout=500ms`、`proxy_read_timeout=10s`、`proxy_next_upstream_timeout ≥ 2× 业务最长响应时间`。
3. upstream 必须限制上游连接寿命：`keepalive_time 10s; keepalive_requests 20;`（否则节点侧摘流是空操作，T12）。
4. **计划内维护在节点侧摘流**（nat DNAT → 死端口 → 内核回 RST），并写 `manual_hold.list` 抑制 LB 的自动摘流
   → **不 reload**；然后 `等连接排空 → drain → reboot`；加回要慢（S6 = 这条流程）。
5. **非计划 crash 一定会切在飞请求**，只能压小代价：保留主动摘流（8s 内摘除）+ 写接口带 `Idempotency-Key`
   + 客户端对 502/504 重试 + 增加 infra 节点数（爆炸半径 = 在飞 × 1/N）。

---

## 1. 环境：这套拓扑决定了「节点健康」等价于「本节点有没有 endpoint」

```
  Mac 宿主机   curl http://127.0.0.1:8080/
       │
       ▼
  nginx-external  (普通 docker 容器，加入 kind 网络)          ← 等价于生产里的 L4/ECMP + L7 层
    · 容器内探测循环  http://<node>:31000/healthz（或 canary）
    · 连续 2 次失败摘除 / 连续 2 次成功加回 → 改成员文件 → nginx -s reload
       │
       │  NodePort :31000 / :31001,  externalTrafficPolicy: Local
       ├──────────────────────────────┬───────────────────────────┐
       ▼                              ▼                           │
  ingress-lab-worker            ingress-lab-worker2        [infra]  ingress-nginx ×3 each
                                                        [infra]  taint infra:NoSchedule
       │                              │
       └──────────────┬───────────────┘
                      ▼  ClusterIP, internalTrafficPolicy: Local
              demo/whoami + demo/slow pods       [node]  只在 ingress-lab-worker3 / worker4
```

角色靠 label + taint（kind 不能自定义节点名，P-08b）：`node-role.kubernetes.io/infra=true` + `NoSchedule` → worker/worker2；`node-role.kubernetes.io/node=""` → worker3/worker4。

**k8s 侧保证不变量的前半段（每个节点都有 endpoint）** —— 见 `ingress-nginx-values.yaml`：

| 配置 | 为什么 | 不这样配会怎样 |
|---|---|---|
| `kind: Deployment`（不用 DaemonSet） | 副本数变成显式容量参数；滚动升级有批次控制、PDB 生效 | DaemonSet 单 pod 挂 → 该节点 endpoint 归零 → **整个节点 NodePort 被 DROP**，pod 故障放大成节点故障 |
| `replicaCount = 3 × N(infra)` | N-1 容量规则 | 写死 6 时 infra 扩到 3 节点变 2/2/2（T1） |
| `nodeAffinity` 硬约束到角色 label + `tolerations` | 角色与节点名解耦；infra 独占 | 用 `preferred` 会让 ingress 漏到业务节点 |
| `topologySpread maxSkew=1 / DoNotSchedule` | **每个** infra 节点都有 endpoint —— LB 才敢宣告它 | 6 副本堆成 6/0 → 另一节点 NodePort 直接 DROP，ECMP 均匀送流量 → **一半流量进黑洞**（代价见 P-06） |
| `type: NodePort` + 固定 `31000/31001` | 上游 LB/BGP 配置成常量 | `healthCheckNodePort` 在 NodePort 上被 API 拒绝（P-03） |
| `externalTrafficPolicy: Local` | 不跨节点二跳、保留 client IP、和「只宣告有本地 endpoint 的节点」是标准 ECMP 做法 | `Cluster` 下 SNAT + 多一跳，容量模型失效（T2 实测 0 跨节点） |
| `internalTrafficPolicy: Local`（post-render 注入） | 集群内 → ClusterIP 也只在 infra 节点服务 | chart 没有这个 value，用 `--post-renderer scripts/post-render-itp.py`（P-07 是代价） |
| `PDB minAvailable: 50%` | 自愿中断最多砍一半容量 | 没 PDB 时 drain 能一次赶走某节点全部副本（P-12：key 的位置） |
| `terminationGracePeriodSeconds: 30` | 给 nginx drain + 在途请求留时间 | 与 LB 侧摘流时间（~6s）对齐，可推理 |

**LB 侧保证后半段（没 endpoint 的节点不接流量）** —— 就是本报告的主题。

关键机制（P-04）：某节点没有本地 endpoint 时，kube-proxy 对该节点的 NodePort 是

```
-A KUBE-EXTERNAL-SERVICES ... --dport 31000
   -m comment "ingress-nginx/ingress-nginx-controller:http has no local endpoints" -j DROP
```

**静默 DROP，不是 RST。** 这一条决定了后面所有设计：探测必须带 connect 超时；不能靠「连不上」判断；
计划内维护值得主动把黑洞变成 RST（§6.2）。

---

## 2. 场景 × 脚本对照表（本轮 2026-10-19 全部实测）

| # | 场景 | 故障/动作注入 | 用的脚本 | 探测层 | 结果（一句话） |
|---|---|---|---|---|---|
| **S1** | 非计划：infra 节点整机 down（黑洞） | `docker stop <infra>`，开环 5rps POST | `scripts/failover-test.sh`（`HC_MODE=l4` / `l7`） | **L4 vs L7 对照** | **两者等价**：都是 +7s 摘流，0 个非 200，代价 = 6–7 个请求各付 ~507ms |
| **S2** | 非计划：端口通、HTTP 死（L4 盲区） | 节点上 `iptables -t nat -I PREROUTING 1 --dport 31000 -j DNAT → accept 即关的 sink` | `scripts/l4-blindspot-test.sh` | **L4 vs L7 对照** | L4：GET **16.4% 在重试**（贯穿故障期）、POST **6.7% 直接 502**；L7：+2s 摘除，**0 重试 0 掉** |
| **S3** | 恢复期：LB 什么时候把它**加回**才安全 | `docker restart <infra>`，全程开环流量 + 独立采样 tcp/healthz/canary | `scripts/addback-race-test.sh`（**本轮新增**） | **L4(快) vs L7(默认) vs L7(canary)** | 三轮「加回过早」窗口都是 **0 个请求**；加回开销 = `ok×interval`（L4 快配 ~0s，L7/canary ~3s）；代价全在**摘流前 0–4s 窗口**（6–7 个请求，其中 1 个 502） |
| **S4** | 非计划：业务面故障（TCP 通、`/healthz` 200，但业务路由服务不了） | 节点上 `iptables -I FORWARD -s <本节点 pod 网段> -d <其它 pod 网段> -j DROP` | `scripts/business-blindspot-test.sh`（**本轮新增**） | **L7 默认 vs L7 canary** | 默认 L7 **看不见**：6% 请求卡满 10s 后超时/504，p95=10002ms；**canary 4s 摘除：0 影响，p95=13ms** |
| **S5** | 在飞请求：硬 crash vs `drain`（同样的流量、同样的 L7 探测） | 20 并发…（S5）5 个常驻 client + 3s 慢后端，中途 `docker kill` / `kubectl drain` | `scripts/concurrency-failover-test.sh`（`KILL_MODE=kill` / `drain`） | L7（固定） | **kill：1 个 502 + 1 个连接被 reload 打断**；**drain：0 个非 200，5 个在飞全部 200 且延迟与基线一致** |
| **S6** | 计划内维护（推荐流程） | 20 并发 + 1s 慢后端持续打，中途执行 8 步流程 | `scripts/graceful-reboot-infra.sh`（经 `concurrency-failover-test.sh KILL_MODE=reboot` 驱动） | L7 + `manual_hold` 抑制 | **3020 请求 / 0 个非 200 / 0 个连接被断 / 维护期 0 次 reload**；节点侧摘流后连接 5s 归零 |

产物目录：`/tmp/camp/S1-l4`、`/tmp/camp/S1-l7`、`/tmp/camp/S2-blindspot`、`/tmp/addback-race/{A-l4-fast,B-l7-rec,C-l7-canary}`、`/tmp/business-blindspot`、`/tmp/camp/S5a-kill`、`/tmp/camp/S5b-drain`、`/tmp/camp/S6-reboot`。

---

## 3. 场景详解（本轮数据）

### S1 · 节点整机 down：L4 与 L7 等价

**脚本**：`HC_MODE=l4|l7 METHOD=POST PHASE_A=20 PHASE_B=60 PHASE_C=30 ./scripts/failover-test.sh`
**场景**：稳态 20s → `docker stop ingress-lab-worker2` → 观察 60s → `docker start` → 观察 30s；开环 5rps，POST（非幂等）。

| 轮次 | 探测 | 摘流耗时（`docker stop` → `[hc] REMOVE`） | 状态码 | 故障期重试 | 重试代价 | p95 / p99 / max（全程） |
|---|---|---|---|---|---|---|
| S1-l4 | L4 `nc -z -w2 :31000` | **+7s**（stop 08:26:41 → REMOVE 08:26:48） | 全程 550 请求 **0 个非 200** | 7 / 402（1.7%） | 505–517ms | 23 / 507 / 517ms |
| S1-l7 | L7 `GET :31000/healthz` | **+7s**（stop 08:32:20 → REMOVE 08:32:27） | 全程 550 请求 **0 个非 200** | 6 / 402（1.5%） | 503–512ms | 13 / 505 / 512ms |

时间线（S1-l7）：

```
08:32:20  docker stop ingress-lab-worker2
08:32:2x  6 个请求 upstream=172.18.0.6:31000, 172.18.0.2:31000  status=200 rt≈507ms   ← connect 超时后换一台
08:32:27  [hc] REMOVE 172.18.0.6:31000 (连续 2 次 l7 探测失败) → reload
          之后零重试
08:34:03  [hc] ADD    172.18.0.6:31000 (连续 2 次成功) → reload
```

**结论**：假设「L4 比 L7 弱」在**这类故障上不成立**。机制：死节点的 NodePort 是 DROP ⇒ TCP connect 本身就失败
⇒ 探测和真实请求同时、以同一方式失败；失败发生在 **connect 阶段 ⇒ 请求没发出去 ⇒ GET 和 POST 都会换一台重发**，
代价上限 = `proxy_connect_timeout`（500ms）。
**所以「不掉」是重试语义给的，不是探测层给的。**

### S2 · L4 的盲区：TCP 通、HTTP 死

**脚本**：`./scripts/l4-blindspot-test.sh ingress-lab-worker2`（`DUR=30 RATE=5`）
**场景**：把 `:31000` 在节点上 DNAT 到一个「accept 之后立刻关闭」的 TCP sink（`alpine: nc -l -p 8080 -k -e /bin/true`）。
三次握手成功，HTTP 永远不响应。

```
L4 (nc -z)      -> 连接成功          ⇒ 判定【健康】   ← 节点继续接流量
L7 (/healthz)   -> HTTP='<无响应>'   ⇒ 判定【不可用】
```

| 探测 | 方法 | 状态码 | 重试率 | 摘流 |
|---|---|---|---|---|
| L4 | GET | 200×150 | **16.4%（25/150）**，且**贯穿整个 30s 故障期**（10s 分桶：1/10/10/4） | 不摘 |
| L4 | POST | **502×10 / 150 = 6.7% 真掉** | 8.4% | 不摘 |
| L7 | POST | 200×150 | **0%** | **+2s 摘除**（08:37:31 起 → 08:37:33 REMOVE） |

**结论**：这才是 L4/L7 的真差别。同一个故障，GET 被重试掩盖（但持续付代价、p95 抖动），
**非幂等请求直接 502** —— 因为请求已经写到那条 TCP 连接上了（因果链 ②，§5）。

### S3 · 加回竞争：什么时候把它放回池子才优雅（本轮新场景）

**脚本**：`./scripts/addback-race-test.sh ingress-lab-worker2`（新增）
**场景**：`docker restart` 一台 infra 节点，全程开环 POST 5rps；同时用独立容器每秒采样该节点的
`tcp(nc -z)` / `healthz(默认 server /healthz)` / `canary(Host: canary.demo.local /healthz)` 三个信号，
与 LB 的 `[hc] ADD` 时刻对齐。三轮只换「加回信号」：

| 轮次 | 加回信号 | LB REMOVE | LB ADD | 该节点首次能服务（canary=200） | **加回比「能服务」晚** | **W1 摘流前送到死节点的请求** | **W2 加回过早送到的请求** | reload |
|---|---|---|---|---|---|---|---|---|
| A-l4-fast | L4，`ok=1 interval=1` | +3s | **+20s** | +19s | **+1s** | 7 个（**1 个 502**） | **0** | 3 |
| B-l7-rec | L7 默认 `/healthz`，`ok=2 interval=2` | +3s | **+42s** | +39s | **+3s** | 7 个（0 个非 200，1 个 503ms 重试） | **0** | 3 |
| C-l7-canary | L7 canary（业务路由），`ok=2 interval=2` | +4s | **+48s** | +45s | **+3s** | 6 个（**1 个 502**） | **0** | 3 |

（三轮总请求各 727 个，非 200 分别 1 / 0 / 1 个。）

**结论（三条，都是之前没有量化过的）：**

1. **在 NodePort + ETP=Local 架构里，L4 的加回不会「早到没有 endpoint」**：节点没本地 endpoint 时 NodePort 被 DROP，
   TCP 连不上 ⇒ L4 也判不可用。所以「TCP 通」隐含「有本地 endpoint」。三轮 W2 都是 0 个请求，就是这个机制。
2. **加回的额外延迟只由防抖参数决定**：`ok × interval`（A：+1s，B/C：+3s）。**3 秒换「不会把流量打到不能服务的节点」，
   是极便宜的保险** —— 而 L4 换不来这条保证（S2/S4 就是反例）。
3. **真正的代价窗口在「摘流之前」**：restart 后 0–4s 内 LB 还会往这个节点送 6–7 个请求，
   其中**已经写到连接上的那个 POST 直接变 502**（因果链 ②）。
   想消掉它：要么把摘流做在节点侧（S6：0 个），要么把 `fail×interval` 调小（A 轮 `interval=1` → REMOVE +3s）。

### S4 · 业务面故障：默认 L7 也看不见（本轮新场景）

**脚本**：`./scripts/business-blindspot-test.sh ingress-lab-worker2`（新增）
**场景**：在目标节点上 `iptables -I FORWARD 1 -s <本节点 pod 网段> -d <其它 pod 网段> -j DROP`
—— 只丢「ingress pod → 业务 pod」的包。NodePort 入向包不受影响，所以：

```
L4  TCP :31000          -> 握手成功    ⇒ 判定【健康】
L7  /healthz 默认 server -> HTTP='200'  ⇒ 判定【健康】      ← 默认 L7 也看不见
L7  canary 业务路由      -> HTTP='超时' ⇒ 判定【不可用】
```

| 探测 | 摘流 | 150 个请求的结果 | p95 / max |
|---|---|---|---|
| L7 默认（`/healthz`，不带业务 Host） | **不摘** | 9 个打到坏节点 → **8 个客户端 10s 超时（nginx 记 499）+ 1 个 504**，**0 次重试** | **10002ms / 10005ms** |
| L7 canary（`HC_HOST=canary.demo.local`） | **+4s 摘除** | 150×200，**0 失败 0 重试** | **13ms / 23ms** |

**结论（两条）：**

1. **探测目标决定你能摘掉什么故障**：探「进程活着」只能摘「进程死了」；要摘「这条业务路由坏了」必须探业务路由。
   这就是 canary 路由的价值，也是 `SWITCHOVER` 旧版里「生产建议做的一步」，本轮已实现并实测：
   `manifests/canary-ingress.yaml` + `healthcheck.sh` 的 `HC_HOST` 支持。
2. **`proxy_next_upstream_timeout` 必须 > 业务最长响应时间**：这里 read 超时 10s > 重试预算 5s ⇒
   **重试被预算掉，直接 504/499**（P-?，见 P-23 附注与 §6.1）。故障形态从「慢但能成」变成「慢且失败」。

### S5 · 在飞请求：硬 crash vs drain（同样的流量、同样的 L7 探测）

**脚本**：`CONC=5 METHOD=POST SLOW=3.0 KILL_MODE=kill|drain ./scripts/concurrency-failover-test.sh ingress-lab-worker2`
**场景**：5 个常驻 client（持久连接）打 3s 慢后端（`manifests/slow-backend.yaml`），t=+20s 时关节点。
关节点那一刻**确实有 5 个请求在飞**。

| 轮次 | 关闭方式 | 总请求 | 非 200 | 连接被断 | 关节点在飞 5 个的下场 | LB 摘流 |
|---|---|---|---|---|---|---|
| S5a-kill | `docker kill`（硬 crash） | 196 | **1（502）** | 1 | 4 个 200（3.0s，基线）+ **1 个 502（2.49s）** | +8s（08:54:21→08:54:29） |
| S5b-drain | `kubectl cordon + drain` | 197 | **0** | 1（加回 reload 时） | **5 个全部 200，最长 3019ms = 基线** | **+3s**（08:57:06→08:57:09） |

S5a 的关键证据（客户端 ↔ nginx 日志按 `probe=<id>` 对齐）：

```
w4-30   起 08:54:19  2494ms  status=502          ← 请求已写到死节点的连接上 ⇒ 非幂等不重试
w2-38   upstream=[172.18.0.6:31000, 172.18.0.2:31000] urt=0.502, 3.020  status=200
        ↑ 摘流窗口内的新请求：connect 超时 500ms + 换一台重做 = 3.5s（慢，但没掉）
w0-46   08:54:29  2ms  status=0                  ← 就是 [hc] REMOVE + reload 那一秒，空闲 keepalive 被关（P-24）
```

**结论**：**「会不会掉」首先取决于你是怎么关节点的，然后才轮到幂等性，最后才轮到探测层。**
drain 先把 pod 摘出 EndpointSlice（新流量立刻不进来，NodePort 回 RST ⇒ 探测 3s 就摘，比 crash 快），
再优雅终止 ingress，在飞请求跑完 —— 压根不进入失败因果链。

### S6 · 计划内维护：推荐流程在 20 并发下（0 掉 / 0 断连 / 0 reload）

**脚本**：`CONC=20 METHOD=POST SLOW=1.0 KILL_MODE=reboot ./scripts/concurrency-failover-test.sh ingress-lab-worker2`
（内部调用 `scripts/graceful-reboot-infra.sh`，8 步流程见 §6.2）

```
[2/8] 写 manual_hold + 节点侧 nat 摘流      当前连接数: 13
[3/8] t=+0s conns=13  →  t=+5s conns=0     ← conntrack -D 强制关闭，下一个包重新走 nat ⇒ RST
[4/8] drain   [5/8] reboot   [6/8] Ready=True   [7/8] uncordon   [8/8] 探测连续 2 次通过 → 解除 hold
```

| 指标 | 结果 |
|---|---|
| 总请求 | **3020** |
| 非 200 / 502 / 504 | **0** |
| 客户端连接被断 | **0** |
| **维护期 LB 摘流/加回事件、reload 次数** | **0 / 0**（整场只有测试开始时 LB 重建的 1 次 reload） |
| 关节点瞬间在飞的 19 个请求 | **全部 200**，最长 1010ms（基线 p50=1005ms） |
| p50 / p95 / p99（故障窗口） | 1005 / 1011 / 1045ms（基线 1005 / 1011 / 1021ms） |
| LB 内部重试（客户端无感） | 25 个请求 `172.18.0.6 → 172.18.0.2`，p50 1006ms（≈基线），max 1511ms |

**结论**：把「摘流」下移到节点侧（黑洞 → RST）+ 用 `manual_hold` 抑制 LB 自动摘流（**不 reload**）+
**等连接排空再 drain** —— 三件事同时做到 0 掉、0 断连、0 reload。
LB 侧唯一必须有的配套是 `keepalive_time`（T12）：否则「等连接排空」这一步永远等不到。

---

## 4. 历史台账 T1–T15（压缩版，结论仍有效）

> 这些是 2026-10-14 ~ 10-16 的实验，原始记录在 `archive/`。本轮 S1–S6 复核了其中
> T6(=S1)、T7(=S2)、T8(=S5a)、T10/T11(=S5b/S6) 的结论，**全部成立**；
> 并新增了 T16(=S3)、T17(=S4)。

**两种压测模型（结论差异很大，必须分清）：**

| | 开环 | 闭环并发 |
|---|---|---|
| 工具 | `scripts/ingress-probe.py` | `scripts/concurrency-probe.py` |
| 连接 | 每请求新建 | 持久连接（keep-alive） |
| 在飞请求 | 关节点那一刻几乎为 0 | 始终有 N 个在飞 |
| 能回答的问题 | 新请求会不会掉、长尾多大 | **在飞请求会不会被切** |
| 慢后端 | 无（whoami，几 ms） | `manifests/slow-backend.yaml`，`/slow?sleep=Ns` |

| # | 假设 / 问题 | 脚本 | 数据 | 结论 |
|---|---|---|---|---|
| **T1** | ingress 只跑 infra 且每节点都有副本 | `bootstrap.sh`、`scale-infra.sh add/remove/status` | 2 infra→`3/3`；扩到 3 infra→自动 `3/3/3`；无 toleration 调度失败；单 pod 挂节点仍可达 | `nodeAffinity` + `TSC maxSkew=1/DoNotSchedule` + `replicas=3×N` 能稳定保证不变量（代价 P-06） |
| **T2** | ETP=Local 不跨节点 | 直连各节点 NodePort + 从各节点 pod 访问 ClusterIP | 20 请求全在本节点 pod；node 节点访问 ClusterIP **静默超时** | ETP/ITP=Local 零跨节点（副作用 P-07） |
| **T3** | 只有被动 `max_fails` 能不能自动摘流 | `failover-test.sh` | **从不摘流**；33 次重试均匀分布在 90s；p95 **3006ms** | 不成立。`max_fails` 是 **per-worker** 的，长尾贯穿整个故障期（P-26） |
| **T4** | 主动 L7 探测 + 参数三档 | `failover-test.sh` | 无主动摘流 p95 3006ms → 5s/3 档 39ms → **2s/2 + connect 500ms 档：0 长尾，p95 19ms** | p95 降 **158×**。两个独立变量：主动摘流 + `proxy_connect_timeout` |
| **T5** | 切换瞬间会不会出 5xx | `switchover-check.sh`（20rps，1200 请求） | access log 200=1602，**5xx=0**；`no live upstreams`=0；两个 infra 全关 → **502 且 0.001–0.003s** | 切换不产生 5xx；502 只在「池里没可用成员」时出现，且是**毫秒级快速失败**，不伪装成慢 |
| **T6** | L4 比 L7 弱？ | `HC_MODE=l4\|l7 failover-test.sh` | 摘流 +6s、0 掉、重试代价 505–516ms —— **两档完全相同** | 对「节点真 down」**等价**（=S1 复核） |
| **T7** | L4 盲区 | `l4-blindspot-test.sh` | L4 GET 17.3% 重试 / L4 POST **6% 502** / L7 0 | 真差别在这里（=S2 复核） |
| **T8** | 闭环并发下关节点 | `concurrency-failover-test.sh` | `docker stop` 0 掉；`docker kill` GET 0 掉但重放 2 个；`docker kill` POST **2×502（1.0%）**；`cordon+drain` **0** | 掉不掉首先取决于**怎么关节点**（=S5 复核） |
| **T8b** | restart 为什么出 3 个 502 | `KILL_MODE=restart` | 3× `upstream prematurely closed`；9× `connect() failed (111)`（已重试→200） | **只有「请求已发出后连接被中途关闭」会掉**；connect 阶段失败不会 |
| **T9** | NodePort 与 ingress 实际可用之间的 GAP | `nodeport-vs-ingress-gap.sh <node> restart` | GAP-1（下线）**≈5s**：NodePort 已黑但 API 还 `localEndpoints=3`；GAP-2（上线）**≈5s**：已能服务但 API 说 0；数据面黑窗 **42s** | **LB 探测直接探 NodePort 本身**，不要依赖 k8s endpoint/node 状态；加回要慢 |
| **T10** | 20 并发下「LB 预摘流」是不是必需 | `CONC=20 KILL_MODE=graceful PRE_DRAIN_LB=0/1` | A 直接 restart **12 个 502**；B 只 cordon→drain→restart **0**；C 加 LB 预摘流 **0 但断连 3→8、reload 3→5** | **救回在飞请求的是 drain，不是 LB 摘流**；这个实现里预摘流是净成本（例外见 §6.3） |
| **T11** | LB 不可控时节点侧自己摘流 | `graceful-reboot-infra.sh` | 摘流 22s → **4s**；5611 请求 **0 个 502 / 0 个 upstream 错误** | 把黑洞变 RST 是最优解（=S6 复核） |
| **T12** | `keepalive_time` 是节点侧摘流的前提 | `HC_ENABLED=0 external-nginx.sh`（静态池） | 不加：插了摘流规则 **conntrack 70s 都是 8，排不空**；加两行：**12s 归零**，1440 请求 0 掉、0 reload | 静态池 + `keepalive_time/requests` 也能 0 掉；但非计划故障没有主动摘流（长尾贯穿） |
| **T13** | 维护窗口用 LB 标 `down` | `lb-mark.sh`、`maintenance-restart.sh` | 5607 请求 0 个 502、0 个 upstream 错误，6 个连接被 reload 打断 | 能做，但 `down` 必然 = 改文件 + reload（开源 nginx 无运行时 API）；好处是立刻生效 + 可审计 |
| **T14** | 客户端到底有没有业务问题 | `maintenance-restart.sh` + `concurrency-probe.py` | CONC=20：5600 请求 0 个 502/504、0 个 >3s、6 个连接被断；CONC=100：28017 请求 0 个 5xx、**88 个在飞全部 200**、12 个（0.043%）断连 | 断连全部是「请求未到达 LB」（三边求交验证）⇒ **重试安全**；并发越高影响率反而越低 |
| **T15** | 2000 条连接时 reload 的代价 | `CONNS=20`（100×20） | LB 动态 down/up（2 次 reload）：**3808 个失败 = 12.1%**，100/100 个 client 各 ≈38 次；**节点侧摘流（0 reload）：0**；**客户端重试一次：0 失败，代价 +50ms** | 代价模型：`一次 reload 杀掉的连接 ≈ 空闲 keepalive 连接数 = 总连接数 × (1 − 1/连接池大小)` |
| **T16**（=S3） | 加回会不会过早 | `addback-race-test.sh` | 见 §3-S3 | NodePort+Local 下 L4 加回不早；加回开销 = `ok×interval`；真正代价窗口在摘流前 |
| **T17**（=S4） | 默认 L7 能不能看见业务面故障 | `business-blindspot-test.sh` | 见 §3-S4 | 不能；canary 探测能，且把 10s 长尾变成 0 影响 |

### 被推翻 / 修正过的结论（保留，避免再犯）

| 曾经的说法 | 修正后 | 证据 |
|---|---|---|
| 维护必须先做 LB 预摘流 | 救回在飞请求的是 k8s 侧的 drain；NodePort+ETP=Local 下 drain 让 NodePort 回 RST，LB 探测 3s 内自己就摘了 | T10、S5b |
| 每次 reload 固定打断约 3 个客户端连接 | ≈ 空闲 keepalive 连接数，与连接池大小成正比 | T15 |
| 节点侧插摘流规则就够了 | 静态池下完全无效，必须配 `keepalive_time` / `keepalive_requests` | T12 |
| `iptables -j REJECT` 放 filter INPUT 就能摘流 | 空操作，必须放 **nat PREROUTING** | T11、P-09 |
| L4 探测比 L7 弱 / 或两者等价 | 只在「节点/端口不可达」上等价；「端口通但数据面死」时 L4 误判健康 | T6+T7、S1+S2 |
| **L7 探测足够（探 `/healthz` 就行）** | **默认 `/healthz` 只覆盖「进程活着」**；业务路由故障/规则没 sync 时它仍 200 ⇒ 生产要探 canary | **S4（新）** |
| **加回是比摘流更危险的方向（会过早）** | 在 NodePort+ETP=Local 下不会过早（没 endpoint 时 TCP 也连不上）；加回的额外延迟只有 `ok×interval` | **S3（新）** |
| 并发越高，故障影响率越高 | 反了：0.11%（CONC=20）→ 0.043%（CONC=100） | T14 |
| 只有被动 `max_fails` 就够 | per-worker，长尾贯穿整个故障期 | T3 |

---

## 5. 失败是怎么产生的：一条因果链（所有 5xx 和所有长尾都能归到这里）

| 失败发生在哪 | nginx 的判断 | 客户端最终看到 | 本轮证据 |
|---|---|---|---|
| **① connect 失败**（RST 或 DROP 超时） | 请求没发出去 ⇒ GET 和 POST **都**重发 | 200，代价 = `proxy_connect_timeout`（实测 503–517ms） | S1、S5a 的 `urt=0.502, 3.020` |
| **② 请求已发出，连接被中途关闭** | 幂等 ⇒ 重放；**非幂等 ⇒ 不重试** | 幂等：200 但 +2.2~2.9s；**非幂等：502** | S5a（1 个 502）、S2（10 个 502）、S3 W1（1 个 502） |
| **③ 池里没有可用成员** | 无处可重试 | 502，**毫秒级快速失败**（0.001–0.003s），不伪装成慢 | T5 |
| **④ 请求已发出、后端不回**（新增） | read 超时；若 `proxy_next_upstream_timeout` < 业务响应时间 ⇒ **重试被掉** | **504 / 客户端超时，10s** | **S4** |

**爆炸半径公式**：`被切的在飞请求数 ≈ 在飞请求数 × 1/N(infra 节点数)`。
5 并发 / 2 节点 → 2 个（T8）；20 并发 → 10 个；100 并发 → 88 个（S6 里 19 个在飞全部靠流程避免）。

---

## 6. 优雅切换的完整配方

### 6.1 LB 侧：探测层、参数、超时

**探测层怎么选（能力矩阵，本轮补 canary 列）**

| 故障类型 | L4（TCP connect `:31000`） | L7 默认（`/healthz`，无业务 Host） | L7 canary（业务 Host + 真实路由） |
|---|---|---|---|
| 节点 down / 网络不可达 | ✅ | ✅ | ✅ |
| 节点没有本地 endpoint（kube-proxy DROP） | ✅（TCP 连不上） | ✅ | ✅ |
| ingress pod 全挂 → endpoint 归零 | ✅ | ✅ | ✅ |
| 进程 hang、端口还 accept | ❌ 误判健康 | ✅ | ✅ |
| 中间有个只做 proxy 的设备 / conntrack 黑洞 | ❌ | ✅ | ✅ |
| **ingress 规则没加载完 / 业务路由坏了** | ❌ | ❌ **也看不见**（S4） | ✅（S4） |

```sh
HC_MODE=l7 HC_HOST=                      # 默认：探默认 server 的 /healthz
HC_MODE=l7 HC_HOST=canary.demo.local    # 推荐（生产）：探一条 canary 业务路由
HC_MODE=l4                              # 只用于排障对照
```

实现细节（都是实测出来的）：
1. 不带业务 Host 时命中的是默认 server 的 `location /healthz { return 200; }`，**body 是空的 ⇒ 只能判状态码**。
2. 这个信号为什么可信：ingress 的 readinessProbe 打 `:10254/healthz`，pod 不健康会被摘出 EndpointSlice；
   节点本地 endpoint 全空时 NodePort 被 DROP ⇒ 一次 200 同时覆盖「节点可达 + 有本地 endpoint + 默认 server 活着」。
3. **要挡住「业务规则没 sync」必须探 canary**：`manifests/canary-ingress.yaml`（host `canary.demo.local`，path `/healthz`）
   + `HC_HOST` 环境变量（本轮新增到 `nginx/scripts/healthcheck.sh` / `scripts/external-nginx.sh`）。
4. canary 的代价：探测本身会打到业务后端（多几 rps），并且把「后端故障」也当成节点不可用 ——
   生产上 should 用一条**专用的、无副作用的** canary（固定 200），不要用真实业务接口。

**参数怎么定**

```
检测耗时（摘流）   ≈ fail × interval + probe_timeout = 2×2+2 = 6s      实测 S1/S2：+7s / +2s / +4s
加回耗时           ≈ 数据面恢复时刻 + ok × interval                    实测 S3：+1s（ok=1,int=1）/ +3s（ok=2,int=2）
单个受影响请求代价 ≈ proxy_connect_timeout（500ms 封顶）                实测 S1：503–517ms
```

想更快：`interval=1s fail=2 probe_timeout=1s` → 检测 ~3s（S3-A 轮 `interval=1` 实测 REMOVE +3s），代价上限 300ms；
代价是探测流量和误摘（抖动）风险上升。busybox `nc -w` 只支持整秒 ⇒ L4 探测超时下限 1s（P-20）。

**nginx 配置（开源版）**

```nginx
upstream k8s_ingress_nodeport {
    least_conn;
    include /etc/nginx/upstream/nodeports.conf;   # 成员文件原子替换，永不为空（P-13）
    keepalive          64;
    keepalive_time     10s;   # ← 必需：不限制上游连接寿命，节点侧摘流就是空操作（T12）
    keepalive_requests 20;
}
server {
  location / {
    proxy_pass http://k8s_ingress_nodeport;
    proxy_http_version 1.1;
    proxy_set_header Connection "";            # 上游 keepalive 必须
    proxy_set_header Host       $ingress_host; # 必须透传业务 Host，否则 ingress 一律 404（P-16）

    proxy_connect_timeout       500ms;   # 3s → p95 3006ms；500ms → p99 507ms（T4）
    proxy_send_timeout          5s;
    proxy_read_timeout          10s;     # 默认 30s 会让半开连接卡满 30s
    proxy_next_upstream         error timeout http_502 http_503 http_504;
    proxy_next_upstream_tries   2;       # 限制故障时的流量放大
    proxy_next_upstream_timeout 5s;      # ⚠ 必须 > 业务最长正常响应时间（建议 ≥2×），
                                         #   否则重试被这个预算掉，反而制造 502/499（S4 实测）
  }
}
```

`max_fails`：已有主动摘流时设 0（它是被动且 **per-worker** 的，留着会造成持续探测噪声，P-26）；
它还影响「等连接排空」的快慢（`max_fails=1 fail_timeout=5s` → conns 10→0 用 10s；`3/15s` → 20s）。
另加 `worker_shutdown_timeout 30s;` 避免旧 worker 长期挂不退。

**探测循环与三个名单**（`nginx/scripts/healthcheck.sh`，容器内循环：探测 → 防抖 → 改成员文件 → reload）

| 名单 | 语义 | 谁写 |
|---|---|---|
| `manual_down.list` | 人工下线：成员行保留但标 `down`，且**不计入可用节点数**（自动摘流不会悄悄加回来） | `scripts/lb-mark.sh` |
| `manual_hold.list` | 维护中：**不探测、不摘、不加**，保持现状 | `scripts/graceful-reboot-infra.sh` |
| `force_all_down` | 保险：人工下线导致可用节点为 0 时默认**拒绝应用**（要清空入口必须显式 touch） | 人工 |

三条必须有的保护（每条都是一次事故，P-14）：**单一写入者**（维护脚本只写名单，落盘+reload 由健康检查做）；
**候选列表原子替换**（`> nodes` 会先截断成 0 字节 → 空 upstream → 全量 502，实测 10 个）；
**「不能摘掉最后一个可用节点」的检查必须在写名单之前**。

### 6.2 计划内维护：推荐流程（S6 就是它）

```bash
./scripts/graceful-reboot-infra.sh <node> [wait-conn-seconds]
```

```
[1/8] cordon                              防止新 pod 调上来
[2/8] 写 manual_hold + 节点侧 nat 摘流     告诉 LB「这台在维护别摘」；把黑洞变成 RST
[3/8] 等 conntrack 连接数 = 0             在飞请求排空（S6：13 → 0 用 5s）
[4/8] drain --grace-period=60             endpoint 先摘，在飞请求跑完
[5/8] reboot                              此时已经没有在飞请求指向该节点
[6/8] 等节点 Ready
[7/8] 先 uncordon                         cordon 状态下 pod 永远 Pending，等不到 Ready
[8/8] 等 /healthz（或 canary）连续 2 次通过 → 解除 hold     加回要慢
```

节点侧摘流的正确写法（**放在 nat PREROUTING 最前面**，抢在 kube-proxy 的 jump 之前，P-09）：

```bash
iptables -t nat -I PREROUTING 1 -p tcp --dport 31000 -j DNAT --to-destination <nodeIP>:1
iptables -t nat -I PREROUTING 1 -p tcp --dport 31001 -j DNAT --to-destination <nodeIP>:1
# 计数用 conntrack，不能用 ss：NodePort 是 DNAT，节点上没有 :31000 的本地 socket（P-10）
conntrack -L -p tcp --dport 31000 | grep -c ESTABLISHED
conntrack -D -p tcp --dport 31000        # 强制关闭：下一个包重新走 nat 规则 ⇒ RST
```

两个必须记住的点：**不要在 reboot 前删掉 nat 规则**（规则随 netns 消失，提前删会留下 kube-proxy DROP 的黑洞窗口，
实测造成 17 次 500ms connect 超时，P-25）；**REJECT 放 filter INPUT / mangle PREROUTING 都不行**（P-09）。

**方案横评（T10/T11/T13/T14 + 本轮 S6；CONC=20、POST、后端 1s、约 5600 请求，同一集群同一拓扑）**

| 方案 | 计划内 502 | 客户端断连 | reload | 非计划 crash |
|---|---:|---:|---:|---|
| A 直接 `docker restart` | **12** | 3 | 2 | — |
| B cordon → drain → restart | 0 | 3 | 2 | — |
| C cordon → LB 预摘流 → drain → restart | 0 | **8** | 2 | — |
| D cordon → 节点侧摘流 → 等排空 → drain → reboot | 0 | 7 | 2 | ~10 个，4s 摘除 |
| E LB 标 down → 等排空 → 节点侧兜底 → … | 0 | 6 | 3 | — |
| F 静态池（无主动摘流）+ `keepalive_time` + 节点侧摘流 | 0 | 0 | 0 | 8 个 + **96 次 500ms 长尾，贯穿故障期** |
| **G 推荐：F 的配置 + 保留主动摘流，维护期抑制** | **0**（S6 复核：3020 请求 0 个） | **0** | **0** | ~10 个，8s 摘除（S5a 复核），长尾短 |

**为什么「LB 预摘流」（C）在这里是净成本**：NodePort+ETP=Local 下 `drain` 让 NodePort 立刻回 RST，
LB 探测 3s 内自己就摘了（S5b 实测 +3s）；预摘流只是多两次 reload，客户端断连从 3 涨到 8。

**仍然需要 LB 预摘流的三种场景**（命中任一条就保留完整预摘流步骤）：
1. 不能 drain（必须硬关机 / 重启操作系统）；
2. 摘流信号是静默 DROP 而不是 RST（没 drain，或 Service 不是 Local）—— 被动探测要等 connect 超时；
3. LB 的动态摘除成本高（BGP 撤销慢、reload 慢、或探测间隔大）。

**维护窗口必须用 LB 标 down 时**（`scripts/maintenance-restart.sh` + `scripts/lb-mark.sh`）：
`down` 是 upstream 里的**静态参数**，开源 nginx 没有任何运行时 API（Plus 才有 `PUT /api/http/upstreams/...`），
所以「标 down」必然 = 改文件 + reload。好处：reload 后 nginx **立刻**不再往这个 server 派新请求，且动作可审计
（`nginx -T` 里能看出是谁摘的）；意外收获：reload 时旧 worker 退出会顺手关掉它到该节点的上游 keepalive 连接（实测标 down 后 conns 直接 0）。
实测 5607 请求：0 个 502、0 个 upstream 错误，6 个客户端连接被 reload 打断。
**生产建议两个都做**：LB 标 down（新请求立刻停、可审计）+ 节点侧兜底（兜住 LB 之外的客户端：监控探测 / 直连 NodePort / 第二个 LB）。

### 6.3 非计划故障：crash 会掉，只能压到最小

| 措施 | 效果 | 证据 |
|---|---|---|
| 保留主动摘流（L7/canary，2s/2） | 8s 内摘除，把长尾限制在几秒而不是整个故障期 | S5a（+8s）、T3（不摘则贯穿） |
| 写接口带 `Idempotency-Key` + 客户端对 502/504 重试 | 把 ~1% 的掉变成可重试，**这是唯一能真正归零的办法** | T15（重试一次：12.1% → 0，代价 +50ms） |
| 提高 infra 节点数 | 爆炸半径 = 在飞 × 1/N | T8 |
| `proxy_next_upstream ... non_idempotent` | 能吞掉，但**可能重复执行**（有副作用时慎用） | — |

### 6.4 开源 nginx 的固有代价：reload

每次改后端成员都要 `nginx -s reload`，reload 会关闭旧 worker 持有的**空闲客户端 keepalive 连接**
（正在处理请求的连接会等请求跑完）。客户端恰在那一瞬间往这条连接写请求 ⇒ `RemoteDisconnected`（0ms，access log 里没有这个请求）。

```
一次 reload 杀掉的客户端连接数 ≈ 当时的空闲 keepalive 连接数
                              = 总连接数 × (1 − 1/连接池大小)
```

- 每 client 1 条连接：空闲比例 ≈ think/(slow+think) ≈ 9% ⇒ 只打断几个（S5a/S5b 各 1 个，时间戳正好是 reload 那一秒）；
- 每 client 20 条连接（2000 连接）：任意时刻 19/20 空闲 ⇒ **几乎整个连接池被杀** = **12.1%**（T15）。
- 这些失败全部是「请求未到达 LB」（三边求交验证）⇒ **客户端重试一次是安全的**：3825 次重试全部成功，+50ms，12.1% → 0。
- **相位效应**（T14）：闭环负载下各 client 准同步，「空闲窗口」是一条每 (slow+think) 重复一次的窄带 ⇒
  有时打断 12 个、有时 0 个。

| 你拥有什么 | 结果 | 前提 |
|---|---|---|
| 只能改 nginx LB（开源） | membership 变更必然 reload ⇒ 2000 连接下 12% 请求命中被杀连接 | 必须依赖客户端重试 |
| 能改节点（本实验） | 摘流下移到节点侧，不碰 LB、不 reload ⇒ 0 失败 | 自己维护 §6.2 那套脚本 |
| 动态后端 LB（Plus API / HAProxy runtime / Envoy xDS） | 改后端不杀连接 | 成本 |

> 开源能做对，但「做对」需要你同时掌握**节点侧**和**客户端**两个前提。
> 商业 / 动态后端产品卖的是**把这两个前提拿掉**。

---

## 7. 观测与验收

**盯这三个，不是只看状态码：**

| 指标 | 为什么 |
|---|---|
| p99 / >1s 请求占比 | S1 的错误率是 0，但 p99 从 8ms 变成 505ms；T3 里 p95 从 8ms 变成 3006ms（158×） |
| upstream 重试次数（`$upstream_addr` 含逗号） | 重试是「没掉但付了代价」的唯一可见信号（S5a 的 `urt=0.502, 3.020`） |
| 客户端连接被断（status=0 / `RemoteDisconnected`） | 写请求最危险：可能「后端已处理但客户端不知道」⇒ 重试会重复写 |

**判定一个请求是否「重试安全」**（每个请求带唯一 `probe=<id>`，三方对齐）：

```
客户端 CSV → LB access log（有没有被转发）→ ingress 控制器日志（后端有没有真的处理）
只有「三边都查不到」才能判定为「请求未发出 ⇒ 重试安全」
```

⚠ probe id 会跨轮次重名（形如 `w17-1420`），用 `kubectl logs --since=15m` 会命中上一轮，必须按时间戳过滤（P-27）。

**验收基线**（本轮 S6 + T14 CONC=100 复测）：0 个 502/504、0 个 >2s、
关节点在飞请求（19 / 88 个）全部 200、p99 与基线一致；连接被断 ≤ 0.05% 且全部「请求未到达后端」。

---

## 8. 坑清单（全部实测复现过，按稳定 ID 引用）

### K8s / kind

- **P-01 kind 配置里的 `labels:` 不能打 `node-role.kubernetes.io/*`** —— 会注入 kubelet `--node-labels`，
  kubelet 对 `kubernetes.io` 命名空间有白名单 → 直接退出，`kind create cluster` 卡在 `kubelet-wait-bootstrap`；
  报错还误导人（`required cgroups disabled`）。→ 集群起来后用 `kubectl label`。
- **P-02 `kubectl taint ... --overwrite` 是「加」不是「删」** —— 删用尾部减号 `key:NoSchedule-`。
- **P-03 `healthCheckNodePort` 在 `type: NodePort` 上不可用** —— API 直接拒绝
  （`may only be set when type is 'LoadBalancer' and externalTrafficPolicy is 'Local'`）。
- **P-04 无本地 endpoint 的节点是 `-j DROP`，不是 REJECT ★** —— 客户端只看到 SYN 超时。后果：
  健康检查必须带 connect 超时；故障表现为「不报错但很慢」；计划内维护值得主动把它变成 RST。
- **P-05 `externalTrafficPolicy: Local` 会让 `127.0.0.1:31000` 失效** —— kind 的 `extraPortMappings` 只能绑
  control-plane，而它没有本地 endpoint → 连接超时。宿主机访问必须走集群外 nginx（`:8080`）或直连 infra 节点 IP。
- **P-06 `whenUnsatisfiable: DoNotSchedule` 与 drain 互卡** —— 2 infra/6 副本时 drain 一个，被驱逐的 3 个 pod 会
  **Pending**（放到另一个节点就是 6/0，skew>maxSkew）。drain 本身能完成，PDB 保住 50%。这是刻意取舍。
- **P-07 `internalTrafficPolicy: Local` 会打断集群内 hairpin 调用** —— 非 infra 节点发出的、访问 ingress
  ClusterIP/DNS 的流量都被静默 DROP。需要这些路径：探测任务加 `nodeSelector` 到 infra，或单独建一个
  `internalTrafficPolicy: Cluster` 的 Service。
- **P-08 节点重启后 IP 会变**（`docker stop/start` 实测 `172.18.0.4 → 172.18.0.7`）⇒ LB 必须能重新枚举节点。
  不同实验里的 IP 来自不同轮次，以 `kubectl get nodes -o wide` 为准。
- **P-08b kind 不能自定义节点名** —— 角色只靠 label/taint（这也是 P-01 存在的原因）。
- **P-12 chart 4.15.1 的 PDB 阈值取 `controller.minAvailable`** —— 写在
  `controller.podDisruptionBudget.minAvailable` 下会被**静默忽略**（渲染成默认值 1）。

### 节点侧摘流

- **P-09 `iptables -j REJECT` 放 filter INPUT 上是空操作 ★** —— DNAT 发生在更早的 nat PREROUTING，
  只要节点还有本地 endpoint，包到 INPUT 时 dport 已是 `podIP:80`，`--dport 31000` 根本匹配不上；
  REJECT 放 mangle PREROUTING 被内核拒（`RULE_INSERT failed (Invalid argument)`）。
  ✅ 可用形式：nat PREROUTING 最前面 DNAT 到没人监听的端口，让内核回 RST（实测 0s 拒绝）。
- **P-10 连接数用 conntrack 看，不能用 `ss`** —— NodePort 是 DNAT，节点上没有 `:31000` 的本地 socket。
- **P-25 不要在 reboot 前删掉节点侧 nat 规则** —— 会留下 kube-proxy DROP 的黑洞窗口（实测 17 次 500ms 超时）。
- **（本轮新增）做「业务面故障」注入时，DROP 规则的目的网段只能是 pod 网段（10.x）** ——
  若把 `172.18.0.0/24`（kind 的 docker 网络，LB 在里面）也 DROP，会把**响应包**干掉，
  连 TCP 握手都成不了，故障形态从「业务面死」变成「整机死」，实验直接失真（`scripts/business-blindspot-test.sh` 第一版踩过）。

### nginx LB 语义

- **P-11 `least_conn` 是 per-worker 的 ★** —— 8 worker + 5 个同步起跑的 client ⇒ 整批请求全落同一个 upstream。
  并发压测必须 `--stagger` 错开，否则「关节点会切到几个在飞」只会得到 0 或 N。
- **P-13 候选节点列表不能非原子重写 ★** —— `kubectl ... > nodes` 先截断成 0 字节 → 空 upstream →
  `no live upstreams` → 全量 502（实测 10 个）。必须 tmp + `mv`，并在 healthcheck 里加「空列表跳过本轮」。
- **P-14 维护脚本必须有的 5 个保护** —— ①「不能把最后一个可用节点标 down」的检查必须在写名单**之前**；
  ②**单一写入者**（否则一次维护 4 次 reload）；③区分「LB 不可达」和「配置语法错」（`docker exec nginx -t` 在容器刚重启时会失败）；
  ④标 up 要处理「成员行已被健康检查删掉」；⑤**变量名紧跟中文必须用 `${}`**（`$DURs`、`$msg，` 这类错误会在最关键的那行炸）。
- **P-16 必须透传 Host 头** —— 否则 ingress 匹配不到 rule，一律 404（还用 `map` 把空 Host/`localhost` 兜底成 `demo.local`）。
- **P-19 upstream 里放 IPv6 需要 `[::1]:port`** —— dual-stack 下把 InternalIP 全塞进去会让 reload 连续失败 20+ 次。只取 IPv4。
- **P-23 L4 探测分不清「端口通」和「数据面通」★** —— 同时注意 nginx 的重试语义：
  **connect 失败（请求没发出去）⇒ GET 和 POST 都会重试；请求已发出之后 ⇒ 只有幂等方法重试。**
  （本轮补充：**默认 L7 的 `/healthz` 也分不清「进程活着」和「业务能服务」**，见 S4。）
- **P-24 `nginx -s reload` 对客户端 keepalive 不是 100% 无损 ★** —— 关的是**空闲**连接；
  代价与连接池大小成正比（T15：2000 连接时 12.1%）。
- **P-26 `max_fails` 是被动且 per-worker 的** —— 只有它时 8 个 worker 各自把死节点置冷 15s 再探一次 ⇒
  聚合起来持续不断（实测 33 次重试均匀分布在 90s）；已有主动摘流时设 0；它还影响「等连接排空」的快慢。

### 环境与工具

- **P-15 `172.18.0.x` 从 Mac 宿主机不可达** —— 集群外 nginx 必须是**容器并加入 `kind` 网络**。
- **P-17 解析 access log：`$upstream_addr` 在重试时是 `A, B`（含空格）** —— 用 `\S+` 会漏掉所有重试请求，
  第一版工具因此得出「重试 0 次」的错误结论。
- **P-18 集群外 nginx 被 `docker rm -f` 重建时，故障期的日志会一起消失** → 演练必须每阶段快照日志。
- **P-20 busybox 工具限制** —— `timeout SECS CMD`（不支持 `-t`）；`date +%N` 不可用；`nc -w` 只支持整秒。
  （本轮补充：busybox ash **没有数组**，`healthcheck.sh` 里拼 `--header` 只能写两个分支。）
- **P-21 shell 函数参数错位会静默毁掉整个实验** —— `setcnt() { echo "$2" > ... }` 应为 `$3`，
  导致 `-ge 3` 恒假、摘流逻辑完全没生效，第一轮演练白跑。→ 必须端到端验证。
- **P-22 慢后端不能用 busybox `nc -k`** —— 串行处理，延迟会叠加。用 `python:3.12-alpine` + ThreadingHTTPServer。
- **P-27 probe id 会跨轮次重名** —— 必须按时间戳过滤。
- **P-28 观测要看 p99 和重试次数，不是只看状态码** —— 只看 5xx 会完全漏掉 P-26 那类故障。

---

## 9. 复现

```bash
cd ~/kind-ingress-lab
./scripts/bootstrap.sh                                    # 建集群 + 装 ingress + 起外部 nginx
kubectl apply -f manifests/canary-ingress.yaml            # canary 探测目标（S4 / 生产推荐）

# ── 本轮场景（S1–S6）───────────────────────────────────────────────
HC_MODE=l4 METHOD=POST PHASE_A=20 PHASE_B=60 PHASE_C=30 OUT=/tmp/camp/S1-l4 \
  ./scripts/failover-test.sh                              # S1 场景：节点 down，L4 探测
HC_MODE=l7 METHOD=POST PHASE_A=20 PHASE_B=60 PHASE_C=30 OUT=/tmp/camp/S1-l7 \
  ./scripts/failover-test.sh                              # S1 场景：同，L7 探测
OUT=/tmp/camp/S2-blindspot ./scripts/l4-blindspot-test.sh # S2 场景：TCP 通、HTTP 死
./scripts/addback-race-test.sh        ingress-lab-worker2 # S3 场景：加回竞争（L4/L7/canary）
./scripts/business-blindspot-test.sh  ingress-lab-worker2 # S4 场景：业务面故障（默认 L7 vs canary）
CONC=5 METHOD=POST SLOW=3.0 KILL_MODE=kill  OUT=/tmp/camp/S5a-kill  ./scripts/concurrency-failover-test.sh  # S5a
CONC=5 METHOD=POST SLOW=3.0 KILL_MODE=drain OUT=/tmp/camp/S5b-drain ./scripts/concurrency-failover-test.sh  # S5b
CONC=20 METHOD=POST SLOW=1.0 KILL_MODE=reboot PHASE_B=90 OUT=/tmp/camp/S6-reboot \
  ./scripts/concurrency-failover-test.sh                  # S6：推荐维护流程（0 掉 / 0 reload）

# ── 其它场景 ───────────────────────────────────────────────────────
./scripts/switchover-check.sh                             # 502/503 专项（T5）
./scripts/nodeport-vs-ingress-gap.sh ingress-lab-worker2 restart   # 四信号 GAP（T9）
./scripts/graceful-reboot-infra.sh  ingress-lab-worker2   # 计划内维护（不带流量）
./scripts/maintenance-restart.sh    ingress-lab-worker2   # 必须用 LB 标 down 时的完整流程（T13/T14）
HC_ENABLED=0 ./scripts/external-nginx.sh                  # 静态池（T12）
CONC=100 CONNS=20 RETRY=1 ./scripts/concurrency-failover-test.sh   # reload 代价 + 客户端重试抹平（T15）

# ── 分析 ───────────────────────────────────────────────────────────
python3 scripts/summarize-runs.py /tmp/camp/S1-l4 /tmp/camp/S1-l7 /tmp/camp/S2-blindspot
python3 scripts/ingress-probe.py join --csvfile /tmp/camp/S1-l7/B-POST.csv --logfile /tmp/camp/S1-l7/B.nginx.log
python3 scripts/concurrency-probe.py join --csvfile /tmp/camp/S5a-kill/all-POST.csv --logfile /tmp/camp/S5a-kill/nginx.log

# ── 切换探测层 / 参数（含 canary）──────────────────────────────────
HC_MODE=l7 HC_HOST=canary.demo.local HC_INTERVAL=2 HC_FAIL=2 HC_OK=2 HC_TIMEOUT=2 \
  HC_CONNECT_TIMEOUT=500ms ./scripts/external-nginx.sh
```

---

## 10. 与 Antrea + BGP/ECMP 生产的对应

| 本实验里的东西 | 生产对应物 | 说明 |
|---|---|---|
| `nginx-external` 容器 + 探测式 upstream | BGP/ECMP 宣告 + 健康检查 | 摘流语义相同 |
| 外挂 L7/canary 探测循环 | `healthCheckNodePort`（需 `type: LoadBalancer`） | **控制面事件驱动**，明确 200（有本地 endpoint）/ 403（没有），不用超时探测 |
| 节点侧 nat 摘流（DNAT → 死端口 → RST） | 撤 BGP 宣告 / 节点侧摘流 | 同一个目的：让流量毫秒级失败而不是进黑洞 |
| `manual_hold.list` | 维护窗口抑制宣告抖动 | 避免维护触发无谓的宣告变更 |
| `nginx -s reload` | BGP 宣告变更 | **没有「杀客户端连接」的代价** |

**必须知道的两个 GAP**（T9，`scripts/nodeport-vs-ingress-gap.sh`）：

| GAP | 方向 | 实测 | 后果 |
|---|---|---|---|
| NodePort 已黑，API 里还是 `localEndpoints=3` | 下线 | **≈5s** | 按 k8s endpoint / node 状态导流的 LB（或基于 node 的 BGP 宣告）持续往黑洞送流量 |
| ingress 已 `healthz=200 / biz=200`，API 里 `localEndpoints=0` | 上线 | **≈5s** | 按 endpoint 加回的 LB 会晚 5s（浪费容量） |
| 数据面黑窗 | — | **42s** | 被分到该节点的请求全靠重试兜；在飞请求直接变 502 |

原因：kube-proxy 转发规则异步收敛且会残留（stale DNAT 仍工作）；节点对象更慢（`Ready=True` 全程不变，40s+ 才 Unknown）；
readinessProbe 只证明进程健康，**不证明业务路由已 sync**。
**所以：LB 探测直接探 NodePort 本身，不要依赖 k8s endpoint / node 状态**；要覆盖「规则没 sync」就探 canary。

---

## 11. 本轮（2026-10-19）为这些场景新增/改动的东西

| 文件 | 内容 | 为哪个场景 |
|---|---|---|
| **`scripts/addback-race-test.sh`**（新） | 加回竞争：同一故障注入跑三轮，只换加回信号（L4 快配 / L7 默认 / L7 canary），对齐 `[hc] ADD` 与「该节点真能服务」的时刻，分开统计「摘流前窗口 W1」和「加回过早窗口 W2」 | **S3** |
| **`scripts/business-blindspot-test.sh`**（新） | 业务面故障：节点上 DROP「ingress pod → 业务 pod」的 FORWARD 包，对照默认 L7 探测与 canary 探测 | **S4** |
| **`manifests/canary-ingress.yaml`**（新） | canary 路由 `canary.demo.local/healthz`，走真实 server/location/upstream 全链路 | **S3、S4** |
| `nginx/scripts/healthcheck.sh` | 新增 `HC_HOST`：L7 探测可带业务 Host 头（canary）；busybox ash 无数组，故分两个分支 | S3、S4 |
| `scripts/external-nginx.sh` | 透传 `HC_HOST`；预热探测同样带 Host | S3、S4 |
| `scripts/l4-blindspot-test.sh` | 修掉「第二轮仍打印 l4」的标签错误（切到 L7 后没更新 `HC_MODE`） | S2 |
| `README.md` / `archive/` | 报告合并为本文一份 | — |
