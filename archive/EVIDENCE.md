# 实验台账

> ⚠ **本文已合并进 [`../REPORT.md`](../REPORT.md)（唯一一份报告），此处仅作历史存档，不再更新。**
> 本轮（2026-10-19）新增的场景 S1–S6、以及两处结论修正（加回不会过早 / 默认 L7 也有盲区）见 `../REPORT.md` §2–§3。

> 方案与结论见 [`SWITCHOVER.md`](SWITCHOVER.md)。本文件只放证据：每组实验的假设、方法、数据、结论，
> 以及**是否被后续实验推翻**。
>
> 环境：kind `ingress-lab`，k8s v1.37.0，5 节点（1 control-plane + 2 infra + 2 node），
> ingress-nginx chart 4.15.1 / controller 1.15.1，集群外 nginx/1.27.5 做 LB（`:8080`），
> NodePort 31000/31001，`etp=Local itp=Local`。产物在 `/tmp/failover-*`、`/tmp/conc-*`、`/tmp/l4-blindspot`。
>
> ⚠ **节点 IP 会随 `docker stop/start` 被 docker 重新分配**（实测 `172.18.0.4 → 172.18.0.7`）。
> 下面不同实验里的 IP 来自不同轮次，对应关系以 `kubectl get nodes -o wide` 为准，不要按 IP 认节点。

**两种压测模型**（结论差异很大，必须分清）：

| | 开环 | 闭环并发 |
|---|---|---|
| 工具 | `scripts/ingress-probe.py` | `scripts/concurrency-probe.py` |
| 连接 | 每请求新建 | 持久连接（keep-alive） |
| 在飞请求 | 关节点那一刻几乎为 0 | 始终有 N 个在飞 |
| 能回答的问题 | 新请求会不会掉、长尾多大 | **在飞请求会不会被切** |
| 慢后端 | 无（whoami，几 ms） | `manifests/slow-backend.yaml`，`/slow?sleep=Ns` |

---

## T1 · 调度约束

**假设**：ingress 只跑在 infra 节点，且每个 infra 节点都有副本。

**方法**：`scripts/bootstrap.sh` 建集群 → `scripts/scale-infra.sh add/remove/status` 改 infra 数量。

**数据**：

| 验证项 | 结果 |
|---|---|
| 副本分布（2 infra，6 副本） | `3 / 3` |
| 扩到 3 infra + 9 副本 | 自动收敛 `3 / 3 / 3` |
| 只跑 infra（硬约束） | 无 toleration 的 pod 调度失败：`0/5 nodes are available: 2 didn't match node affinity, 3 had untolerated taints` |
| 业务不污染 infra | whoami 3 副本全部落在 worker3/4 |
| 单 pod 故障 | 节点仍有 2 个 endpoint，NodePort 不失效 |
| 节点 drain | PDB 保住 50% 容量，uncordon 后自动回 3/3 |

**结论**：`nodeAffinity` 硬约束 + `topologySpread maxSkew=1 / DoNotSchedule` + `replicas=3×N` 能稳定保证不变量。
代价见 `P-06`（drain 时被驱逐 pod 会 Pending）。

---

## T2 · 流量语义：确认不跨节点

**假设**：`externalTrafficPolicy: Local` 下，进哪个节点只在该节点的 nginx 里选。

**方法**：只打 infra-1 的 `:31000`，按处理请求的 pod 统计；再从不同节点的 pod 访问 ClusterIP。

**数据**：

```
20 个请求 → pod on ingress-lab-worker: 6 / 6 / 8   pod on ingress-lab-worker2: 0 / 0 / 0

ClusterIP 10.96.150.135:80
  pod on infra 节点  -> OK
  pod on node 节点   -> 静默超时
  # node 上的规则：
  -A KUBE-SERVICES -d 10.96.150.135/32 --dport 80
     -m comment "...has no local endpoints" -j DROP
```

**结论**：ETP=Local 零跨节点，ITP=Local 让集群内路径行为一致。副作用见 `P-07`。

---

## T3 · 只有被动健康检查时，关掉一个节点

**假设**：nginx 开源版的 `max_fails` 能自动摘掉死节点。

**方法**：`failover-test.sh`，5 rps 开环，`docker stop` 一个 infra 节点，故障期 450 请求。

**数据**：

| 配置 | 摘流方式 | 检测耗时 | 状态码 | >1s 长尾 | p50 | **p95** | max |
|---|---|---|---|---|---|---|---|
| 只有被动检查 | `max_fails=3 fail_timeout=15s` | **从不摘流** | 200×450 | **32 (7.1%)** | 5ms | **3006ms** | 3034ms |

关联数据：`172.18.0.7:31000, 172.18.0.2:31000` n=33 p50=3006ms；单跳 `172.18.0.2:31000` n=417 p50=5ms。
33 次重试**均匀分布在 90s 里**，相邻间隔中位数 3s（= connect 超时）。

**结论**：假设不成立。`max_fails` 是 **per-worker** 的（本环境 8 个 worker），每个 worker 各自把死节点
置冷 15s 再探一次 ⇒ 聚合起来是持续不断的探测，**长尾贯穿整个故障期，不会消失**。
故障形态是「不报错但很慢」，从状态码上完全看不出来。

---

## T4 · 加主动 L7 探测，参数三档对比

**方法**：同 T3，外挂 `nginx/scripts/healthcheck.sh` 探测循环，只改参数。

**数据**：

| 配置 | 检测耗时 | 状态码 | >1s 长尾 | p50 | **p95** | max |
|---|---|---|---|---|---|---|
| ① 只有被动检查（= T3） | 从不摘流 | 200×450 | 32 (7.1%) | 5ms | **3006ms** | 3034ms |
| ② L7 探测 5s/3，connect 3s | 18s | 200×450 | 8 (1.8%) | 5ms | **39ms** | 3034ms |
| ③ L7 探测 2s/2，connect 500ms | ~5s | 200×450 | **0** | 5ms | **19ms** | 509ms |

**结论**：p95 从 3006ms 降到 19ms（**158×**），长尾归零，全程零 5xx。
两个独立变量：主动摘流（消除「贯穿故障期」）+ `proxy_connect_timeout`（缩小单次代价上限）。
参数推导：`检测耗时 ≈ fail × interval + probe_timeout`。

---

## T5 · 502/503 专项：切换瞬间会不会出 5xx

**方法**：`switchover-check.sh`，20 rps，故障期 1200 请求；再测两个 infra 全关的边界。

**数据**：

```
nginx access log 全量:  200 = 1602      5xx = 0
客户端（故障期 1200）:   200 = 1200      5xx = 0   传输错误 = 0

error_log 事件:
  no live upstreams              0     ← 唯一会产生 502 的事件
  upstream timed out            18     ← 打到死节点，已重试到活节点，客户端仍 200
  server temporarily disabled    2     ← 被动检查标记，不影响状态码
  connect() failed               0

边界：两个 infra 节点全关
  [hc] REMOVE 172.18.0.2 / REMOVE 172.18.0.7 → upstream 只剩 server 127.0.0.1:1 down;
  客户端: 502 (0.003s)  502 (0.001s)  502 (0.002s)
```

**结论**：切换过程不产生 5xx。502 只在「所有 upstream 都不可用」时出现，且是**毫秒级快速失败**
（healthcheck 在零健康节点时写 `server 127.0.0.1:1 down;` 占位）—— 没容量就明确报 502，不伪装成慢。
`nginx -s reload` 是优雅重载：摘流那一刻没有请求被打断。

---

## T6 · L4 vs L7：真的关掉一个节点

**假设**：L4 探测（只 TCP connect）比 L7 弱。

**方法**：`HC_MODE=l4|l7 METHOD=GET|POST ./scripts/failover-test.sh`，其余参数完全一致。

**数据**：

| 轮次 | 探测 | 方法 | 故障期请求 | 状态码 | 重试 | 摘流耗时 | >1s | p95 | p99 | max |
|---|---|---|---|---|---|---|---|---|---|---|
| 1 | L4 2s/2 | GET | 450 | 200×450 | 7 (1.6%) | +6s | 0 | 10ms | 505ms | 516ms |
| 2 | L4 2s/2 | POST | 300 | 200×300 | 5 (1.7%) | +6s | 0 | 8ms | 507ms | 508ms |
| 3 | L4 2s/2（修 bug 后复跑） | POST | 300 | 200×300 | 5 (1.7%) | +6s | 0 | 8ms | 507ms | 509ms |
| 4 | L7 2s/2（对照） | POST | 300 | 200×300 | 5 (1.7%) | +6s | 0 | 8ms | 507ms | 509ms |

时间线（轮次 1）：

```
14:10:11  docker stop ingress-lab-worker2
14:10:12  upstream timed out (110) while connecting to upstream → 重试到活节点，status=200 rt=0.504
14:10:17  [hc] REMOVE 172.18.0.6:31000  (连续 2 次 l4 探测失败)
14:10:18  [hc] upstream 变更 -> 1 个可用节点，reload nginx      ← 之后零重试
14:12:24  [hc] ADD    172.18.0.6:31000  (连续 2 次成功)
```

**结论**：假设不成立 —— 对「节点真 down」这一类故障，**L4 与 L7 完全等价**（同时刻失败、同耗时摘流、同样不掉）。
机制：死节点的 NodePort 是静默 DROP ⇒ TCP connect 本身就失败 ⇒ 探测和真实请求以同一方式失败；
失败在 connect 阶段 ⇒ 请求没发出去 ⇒ **GET 和 POST 都会**换一台重发，代价上限 = `proxy_connect_timeout`。

顺带修掉一个真 bug（与探测层无关）：见 `P-13`，轮次 2 恢复阶段的 10 个 502。

---

## T7 · L4 的盲区（这才是 L4/L7 的真差别）

**方法**：`l4-blindspot-test.sh`。在 infra 节点上插
`iptables -t nat -I PREROUTING 1 -p tcp --dport 31000 -j DNAT --to <sink>:8080`，
sink = `alpine: nc -l -p 8080 -k -e /bin/true`（accept 后立刻关闭，永远不吐 HTTP）。
即「端口通、数据面死」，用来分离两种探测的判断。

**数据**：

```
L4 (nc -z)      -> 连接成功          ⇒ 判定【健康】   ← 节点继续接流量
L7 (/healthz)   -> HTTP='<无响应>'   ⇒ 判定【不可用】
```

| 探测 | 方法 | 状态码 | 重试率 | 说明 |
|---|---|---|---|---|
| L4 | GET | 200×150 | **17.3%**（26/150） | 靠 `proxy_next_upstream` 兜住，max 21ms（sink 立刻断连，不耗 connect 超时） |
| L4 | POST | **502×9 / 150（6% 真掉）** | — | 连接已建立、请求已发出 → 非幂等不重试 |
| L7 | POST | 200×150 | **0%** | 节点 +6s 被摘，坏节点根本没进流量 |

**结论**：L4 只在「节点/端口不可达」上等价于 L7。凡是「三次握手成功但数据面不工作」
（进程 hang、规则没加载完、中间只做 proxy 的设备、conntrack 黑洞），L4 都误判健康；
这时 GET 被重试掩盖，**非幂等请求直接 502**。→ 用 L7。

---

## T8 · 闭环并发：5 个常驻 client，中途关节点

**假设**：开环（T3–T7）关节点那一刻几乎没有在飞请求，也没复用长连接，所以只能回答「新请求会不会掉」。

**方法**：`concurrency-failover-test.sh` + `concurrency-probe.py`（`--concurrency 5 --slow 3.0 --stagger 0.6`）
+ `manifests/slow-backend.yaml`。一条不间断流量跑完全程，中途 `stop` / `kill` / `drain` / `restart` 节点，按时间窗分析。

**数据**：

| 关闭方式 | 方法 | 总请求 | 非 200 | 连接错误 | 关节点瞬间在飞 | 落在死节点的 | 代价 |
|---|---|---|---|---|---|---|---|
| `docker stop`（半优雅） | GET | 566 | **0** | 0 | 5 | 0 | 12 个新请求 +500ms |
| `docker kill`（硬 crash） | GET | 566 | 0 | **1** | 5 | 0 | 12 个 +500ms |
| `docker kill` | GET, slow=3s | 191 | **0** | 0 | 5 | **2** | 被重放：总 5.87s / 5.25s |
| `docker kill` | POST, slow=3s | 193 | **2 × 502（1.0%）** | 0 | 5 | **2** | 直接 502（2.85s / 2.24s） |
| `cordon + drain` | POST, slow=3s | 194 | **0** | 0 | 5 | 2 | **无**（最长 3.016s，与基线一致） |
| `docker restart` | POST, slow=1s | 589 | **3 × 502（0.5%）** | — | 5 | 3 | 见 T8b |

关键日志（硬 crash + POST）：

```
07:12:19  docker kill ingress-lab-worker2          ← 此时 5 个请求在飞
[error] upstream prematurely closed connection while reading response header from upstream,
        request: "POST /slow?sleep=3.0&probe=w3-29"
access:   172.18.0.6:31000  probe=w3-29  status=502 rt=2.845   ← 请求已发出，非幂等不重试
07:12:27  [hc] REMOVE 172.18.0.6:31000            ← 摘流 8s
```

**结论**：**「会不会掉」首先取决于你是怎么关节点的，然后才轮到幂等性，最后才轮到探测层。**
drain 先把 pod 从 EndpointSlice 摘掉（新流量立刻不进来），再优雅终止 ingress，在飞请求跑完。

### T8 顺带得到的四个结论

1. **`least_conn` 是 per-worker 的**：8 个 worker、5 个同步起跑的 client 会被分到不同 worker，
   每个 worker 自己看「两台都 0 连接」→ 整批 5 个全落同一个节点（实测按批交替 .2/.6/.2/.6）。
   爆炸半径变成「全中或全不中」，必须 `--stagger` 错开，否则样本失真。见 `P-11`。
2. **客户端自连会被 LB 自己的 reload 打断**：两次运行各 1 次 `RemoteDisconnected`（0ms，access log 里没有该请求），
   时间戳正好是 `[hc] … reload nginx` 那一秒。→ 这条在 T14 里被统计、在 T15 里被量化。
3. **硬 crash 下半开连接的代价不是 connect 超时而是 read 超时**：本次没出现 30s 长尾，
   是因为摘流 reload 后新 worker 的 keepalive 池是空的；如果没有主动摘流（只靠 `max_fails`），
   在飞/半开请求会挂到 `proxy_read_timeout`（默认 30s）。
4. **爆炸半径 ≈ 在飞请求数 × 1/N(infra 节点数)**。

---

## T8b · restart 一台 infra 为什么出 502

**数据**（`CONC=5 METHOD=POST KILL_MODE=restart SLOW=1.0`，589 请求）：

| 探测层 | 总请求 | 502 | 摘流 | 加回 |
|---|---|---|---|---|
| L7 (2s/2) | 589 | **3（0.5%）** | +4s | +24s |
| L4 (2s/2) | 589 | **3（0.5%）** | +4s | +25s |

error_log 三种信号（同一个 4s 窗口）：

```
 3 × upstream prematurely closed connection while reading response header   ← 就是这 3 个变成 502
 9 × connect() failed (111: Connection refused) while connecting to upstream ← 快速失败，已重试 → 200
 1 × upstream timed out (110) while connecting to upstream                  ← 同上，200
```

**结论**：restart 的 502 只来自一个机制 —— 请求已写到那台节点的 TCP 连接上，连接被中途关闭。
**connect 阶段的失败（refused / timeout）不会造成 502**，因为请求没发出去，会换一台重发。
restart 与 stop/kill 的区别：restart 期间节点 IP 还在网络上但 kube-proxy 规则已撤，
得到的是 RST（毫秒级）而不是静默 DROP —— 反而更容易被重试掉。

---

## T9 · NodePort 与 ingress-nginx 之间的 GAP

**方法**：`nodeport-vs-ingress-gap.sh <node> restart`，对同一节点每秒采样四条**互相独立**的信号：

```
A tcp      nc -z <node>:31000                ← kube-proxy 的 NodePort 路径（LB 的 L4 探测）
B healthz  GET :31000/healthz（不带业务 Host） ← ingress 默认 server（LB 的 L7 探测）
C biz      GET :31000/  Host: demo.local     ← 业务路由真的能服务吗
D k8s      该节点 Ready 的 ingress pod 数 / EndpointSlice 里该节点的本地 endpoint 数
```

**数据**（`docker restart` 一个 infra 节点）：

```
08:21:29  TCP-OK  healthz=200 biz=200   nodeReady=True podsReadyOnNode=3 localEndpoints=3
08:21:34  --      ---       ---         nodeReady=True podsReadyOnNode=3 localEndpoints=3   ← 重启！数据面已死
08:21:42  --      ---       ---         nodeReady=True podsReadyOnNode=0 localEndpoints=0   ← 控制面 08:21:39 才跟上
08:22:16  --      200       200         nodeReady=True podsReadyOnNode=0 localEndpoints=0   ← 数据面已可用！
08:22:17  TCP-OK  200       200         nodeReady=True podsReadyOnNode=1 localEndpoints=1
08:22:21  TCP-OK  200       200         nodeReady=True podsReadyOnNode=3 localEndpoints=3
```

| GAP | 方向 | 实测 | 后果 |
|---|---|---|---|
| GAP-1 | 下线 | **≈5s** | NodePort 已全黑，API 里还是 `localEndpoints=3` ⇒ 按 k8s endpoint/node 状态导流的 LB 持续往黑洞送流量 |
| GAP-2 | 上线 | **≈5s** | ingress 已能服务，API 里 `localEndpoints=0` ⇒ 按 endpoint 加回的 LB 晚 5s（浪费容量） |
| 数据面黑窗 | — | **42s** | 这期间被分到该节点的请求全靠重试兜救；在飞请求直接变 502 |

**结论**：数据面和控制面两个方向都会脱节。原因：kube-proxy 规则异步收敛且会残留（stale DNAT 仍工作）；
节点对象更慢（`Ready=True` 全程不变，40s+ 才 Unknown）；
readinessProbe 只证明进程健康，不证明业务路由已 sync。
→ **LB 探测直接探 NodePort 本身**；加回要慢（`OK_MAX` + hold-down ≥30s + pod Ready）。
→ 生产上换成 `type: LoadBalancer` + BGP 宣告 + `healthCheckNodePort`，把「靠超时探测」变成「靠控制面事件」，GAP-1 降到亚秒级。

---

## T10 · 放大到 20 并发：去掉「LB 预摘流」会怎样

**假设**（来自 T8b 的推导）：维护要先从 LB 摘流，再 drain。

**方法**：`CONC=20 METHOD=POST SLOW=1.0`，每轮 ~4000 请求，关节点瞬间 **19 个在飞**。

**数据**：

| 做法 | 总请求 | **502** | 客户端连接被断 | reload | `prematurely closed` | `refused`（可重试） |
|---|---|---|---|---|---|---|
| A. 直接 `docker restart` | 3447 | **12** | 3 | 3 | 10 | 10 |
| B. cordon → 等15s → drain → restart（**不做 LB 预摘流**） | 3982 | **0** | 3 | 3 | **0** | 11 |
| C. cordon → **LB 预摘流** → 等15s → drain → restart | 3981 | **0** | **8** | **5** | 0 | 12（+6 connect 超时） |

**结论（与 T8b 相反）**：

1. **救回在飞请求的是 k8s 侧的 drain，不是 LB 摘流。** B 完全没动 LB，502 仍为 0。
2. B 里 LB 靠被动探测摘流要 ≈22s（cordon 后），但这 22s 中新请求得到的是 **RST ⇒ 毫秒级失败 ⇒ 自动重发**，
   客户端无感（11 次）。这个「便宜」的前提是 **drain 让 NodePort 回 RST**。
   如果是 `docker stop`/`kill`（静默 DROP），同样的窗口就变成每次 500ms connect 超时 + 在飞被切 ⇒ 就是 A 里的 12 个 502。
3. 在这个实现里 **LB 预摘流是净成本**：多两次 reload，客户端断连从 3 涨到 8。
4. 预摘流仍然有价值的三种场景见 [`SWITCHOVER.md` §5](SWITCHOVER.md)。

> ⚠ A 组的 reload 数在旧报告里有两种写法（`archive/REPORT-l4-probe-2026-10-15.md` §4F 写 3、§4J 写 2），
> 属于不同轮次，未复核。引用时以本表为准。

---

## T11 · 节点侧自己摘流（LB 不可控时）

**方法**：`graceful-reboot-infra.sh <node> [wait-conn]`：
`cordon → 节点侧 nat 摘流 → 等 conntrack 排空 → drain → reboot → uncordon`。

**数据**（`CONC=20`，POST，后端 1s，5611 请求）：

```
[2/7] 节点侧摘流（nat DNAT → :1）      当前连接数: 13
[3/7] t=+0s conns=13   →   t=+5s conns=0        # conntrack -D 强制关闭生效
[4/7] drain   [5/7] reboot   [6/7] Ready=True   [7/7] uncordon

LB 侧：09:06:32 cordon+插规则 → 09:06:36 [hc] REMOVE（**4s**）→ 09:07:14 ADD
客户端：5611 请求，**0 个 502**，**0 个 upstream 错误**
唯一代价：7 个客户端连接被 LB 自己的 reload 打断
```

**与其他做法对比**（都是 CONC=20、POST、~4000–5600 请求）：

| 做法 | 502 | upstream 错误 | **LB 摘流耗时** | 客户端连接被断 |
|---|---|---|---|---|
| A. 直接 `docker restart` | **12** | 20 | 4s | 3 |
| B. cordon→drain→restart（不做任何摘流） | 0 | 11 refused（可重试） | **≈22s** | 3 |
| C. cordon→**LB 预摘流**→drain→restart | 0 | 18 | 0s（需要 LB 配合） | 8 |
| **D. cordon→节点侧 nat 摘流→等排空→drain→reboot** | **0** | **0** | **4s**（LB 自己就摘了） | 7 |

**结论**：D 是 LB 不可控时的最优选择 —— 把「黑洞」变成「RST」，让 LB 探测从「等 connect 超时」变成
「立刻失败」，摘流从 22s 降到 4s，且不需要动 LB 一行配置。
两个必须改的地方见 `P-09`（nat 位置）与 `P-10`（conntrack 计数）。

---

## T12 · LB 侧配置：`keepalive_time` 是节点侧摘流生效的前提

**发现**：一个反直觉的现象 —— **静态池下，节点侧的摘流规则完全不起作用**。
LB 一直复用已有的 keepalive 连接（这些连接不空闲，永远不会被回收），
插了 nat 摘流规则后 conntrack 计数 **70s 都是 8，根本排不空**；这时去 drain/reboot，必然切在飞请求。

**方法**：给 upstream 加两行，然后**关掉主动摘流**（`HC_ENABLED=0`，纯静态池）重测。

```nginx
keepalive_time     10s;   # 连接最长活 10s（nginx ≥1.15.3）
keepalive_requests 20;    # 每条连接最多服务 20 个请求就重连
```

**数据**：

```
节点侧插摘流规则 → 到该节点的连接 12s 内归零（之前 70s 不降）
1440 个请求：全部 200，0 个失败
49 × connect() failed (111) → 全部立即重试（RST，代价 ~20ms）
reload 次数：0      客户端连接被断：0
```

**结论**：这是性价比最高的一组配置 —— 不需要主动健康检查、不需要 reload，
只靠「节点侧摘流 + LB 快速重建连接」就能做到 0 掉。已写进 `nginx/conf/nginx.conf.tmpl`。

**其他配置项的实测结论**：

| 项 | 结论 |
|---|---|
| `proxy_connect_timeout` | 3s → p95 3006ms；500ms → p99 507ms。线性决定「① connect 失败」的代价上限 |
| `proxy_read_timeout` | 默认 30s 会让半开连接卡满 30s，按业务 P99 定（本实验 10s） |
| `proxy_next_upstream_timeout` | ⚠ 必须 > 业务最长正常响应时间（建议 ≥2×），否则重试被这个预算掉，**反而制造 502** |
| `max_fails` | per-worker，已有主动摘流时设 0。另外它影响「等连接排空」的快慢：`max_fails=1 fail_timeout=5s` 下 conns 10→0 用 10s；`max_fails=3 fail_timeout=15s` 要 20s |
| `worker_shutdown_timeout 30s` | 避免旧 worker 长期挂不退 |

---

## T13 · 维护窗口用 LB 标 upstream down

**方法**：`lb-mark.sh`（标 down/up/回滚，带备份、语法校验、自动回滚、不为空保护）+ `maintenance-restart.sh`（完整流程）。

**数据**（CONC=20、POST、5607 请求）：**0 个 502、0 个 upstream 错误**，6 个客户端连接被 reload 打断。

**结论**：能做，但 `down` 必然伴随 reload —— `down` 是 upstream 里的**静态参数**，
开源 nginx 没有任何运行时 API（Plus 才有 `PUT /api/http/upstreams/<name>/servers/<id>/down`）。
好处：reload 之后 nginx **立刻**不再往这个 server 派新请求（不用等探测失败），且动作可审计。
意外收获：reload 时旧 worker 退出会**顺手关掉它到该节点的上游 keepalive 连接**，实测标 down 后 `conns` 直接 0。

写这个脚本必须有的 5 个保护见 `P-14`。

---

## T14 · 完整维护流程下，客户端到底有没有业务问题

**方法**：`maintenance-restart.sh`（带绝对时间戳），CONC=20、POST、后端 1s、~5600 请求。
**判定标准不是只看 502**：

| 指标 | 为什么重要 |
|---|---|
| 非 200（502/504） | 直接失败 |
| 连接被断（status=0） | 写请求最危险：可能「后端已处理但客户端不知道」⇒ 重试会重复写 |
| 耗时 >3s | 趋于超时/重试风暴 |
| 关节点瞬间在飞的请求结局 | 真正会丢数据的那一批 |

**归因方法**：每个请求带唯一 `probe=<id>`，三方对齐 —— 客户端 CSV → LB access log → ingress 控制器日志。
只有「三边都查不到」才能判定「请求未发出 ⇒ 重试安全」。

**数据**（两轮）：

| | 第一轮 | 第二轮（修正后） |
|---|---|---|
| 总请求 | 5606 | 5600 |
| 502 / 504 | **0** | **0** |
| 耗时 >3s | **0** | **0** |
| p50 / p99（故障窗口） | 1004 / 1043ms（基线 1004/1044） | 1004 / 1045ms（基线 1005/1014） |
| 关节点在飞 20 个请求 | **全部 200** | 全部 200 |
| 连接被断 | 6 | 6 |
| 其中「后端已处理但客户端不知道」 | **0** | **0** |
| reload 次数 | 4 | **2** |

被断的 12 个请求（两轮合计）全部是 `RemoteDisconnected`、耗时 0.1–0.3ms，
**在 LB access log 和 ingress 日志里都查不到对应 probe id** ⇒ 请求从未被转发、后端从未收到 ⇒ 重试安全。

⚠ 差点误判：用 `kubectl logs --since=15m` 查 probe id 会和上一轮重名（id 形如 `w17-1420`），必须按时间戳过滤。

**顺便修掉的设计问题（单一写入者）**：第一轮实际发生 4 次 reload —— 维护脚本写一次，
容器内健康检查下一轮按自己的注释重写 ⇒ 又 reload 一次。
修正：`lb-mark.sh` 检测到健康检查在跑时**只写 `manual_down.list`**，由健康检查唯一落盘。
验证：down/up 各 **1 次** reload。

**结论**：业务层面 0 个失败请求、0 个「结果未知的写」、0 个长尾、在飞请求全部完成。
客户端能感知的只有 0.11% 的「连接被关、请求未发出」—— 对 HTTP 客户端这是标准的安全重试条件，
**但必须真的去重试**；不重试的客户端会把它当成一次失败。

### 加大到 CONC=100 的复测

先确认容量：CONC=60 / CONC=100 空跑基线都是 p50=1004 / p99=1045 / 0 错误（未饱和）。

| 指标 | CONC=20 | **CONC=100** |
|---|---|---|
| 总请求 | 5600 | **28017** |
| 502 / 504 | 0 | **0** |
| 耗时 >2s | 0 | **0**（维护窗口内 4359 请求，只有 1 个 >1.1s） |
| 关节点在飞请求 | 20 → 全 200 | **88 → 全 200**（最长 1049ms） |
| p50/p99（故障窗口） | 1004/1045 | 1004/1044（基线 1004/1046） |
| 连接被断 | 6（0.11%） | **12（0.043%）** |
| 其中「后端已处理但客户端不知道」 | 0 | **0**（12/12 三边求交，不是抽样） |

**结论**：并发提高 5 倍，业务影响率反而从 0.11% 降到 0.043% —— 因为断连数取决于
「reload 瞬间有多少空闲客户端连接」，而不是请求速率。

### 为什么有时打断 12 个、有时 0 个：相位

CONC=100 这一轮，12 个断连全在标 down 那一秒，而标 up 的 reload **一个也没打断**。按相位对齐后：

```
被断的 12 个请求：上一个请求都恰好在 reload 前 100.9～102.3ms 结束 ⇒ 全在 100ms 空闲窗口内
标 up 的 reload（03:26:54）：±0.3s 内有 71 个请求开始 ⇒ 落在忙碌相位 ⇒ 0 个打断
```

机制：reload 时旧 worker 只关闭**空闲**的客户端 keepalive 连接；正在处理请求的连接会等请求跑完。
闭环负载下各 client 准同步（周期 = 后端 1.0s + think 0.1s），所以「空闲窗口」是一条每 1.1s 重复一次的窄带。

> ⚠ 本节的「每次 reload 固定打断 ~3 个」已被 **T15 推翻**：那是低连接数下的抽样。

---

## T15 · 把连接数拉到 2000：T14 的断连结论被推翻了一半

**方法**：100 并发 × 每并发 20 条持久连接 = **2000 条连接**（LB 侧 `:80` accepted 实测 2001），同一个维护流程。

**数据**：

| | LB 动态 down/up（2 次 reload） | 节点侧摘流（0 次 reload，推荐方案） |
|---|---|---|
| 总请求 | 31408 | 28000 |
| **失败请求** | **3808 = 12.1%** | **0 = 0.000%** |
| 失败时刻 | 04:12:19-21、04:13:01-04（就是两次 reload） | — |
| 受影响的 client | **100/100**，每个 ≈38 次（= 整个连接池） | 0 |
| 错误类型 | 全 `RemoteDisconnected`，97.6% 耗时 <1ms | — |
| 其中「已转发到后端」 | **0 / 3808**（全量集合求交，不是抽样） | — |
| 502 / 504 | 0 | 0 |
| p99（故障窗口） | 1045ms（与基线一致） | 1045ms |
| LB 内部重试（客户端无感） | — | 54 refused + 8 timeout |

**代价模型（修正版）**：

```
一次 reload 杀掉的客户端连接数 ≈ 当时的空闲 keepalive 连接数
                              = 总连接数 × 空闲比例
                              = 总连接数 × (1 − 1/连接池大小)
```

**客户端重试一次能不能抹平？—— 能（实测）**：同样 2000 连接、同样 LB 动态 down/up，只加「连接级失败重试一次」：

| | 不重试 | **重试一次** | 节点侧摘流（不 reload） |
|---|---|---|---|
| 失败请求 | 3808 = **12.1%** | **0 = 0.000%** | **0 = 0.000%** |
| 触发重试 / 成功 | — | 3825 / **3825 全成功** | — |
| 重试请求耗时 | — | ≈1055ms（基线 1005ms，**+50ms**） | — |
| 故障窗口 p99 | 1045ms | 1082ms（基线 1046） | 1045ms |

因为这 3808 个请求 0 个到达过 LB，所以「重试一次」是安全的（不会重复写），代价只是 +50ms。
注意：这是**事后才知道安全**的 —— 客户端当时无法知道请求有没有被处理。

**结论**：「凭什么买商业 LB」的量化回答见 [`SWITCHOVER.md` §7](SWITCHOVER.md)。
12.1% 的失败全部是「请求未发出」，不是丢数据；但 12% 的重试风暴、以及任何不做重试的客户端，都是真实故障。

---

## 被推翻的结论（汇总）

| 曾经的说法 | 修正后 | 证据 |
|---|---|---|
| 维护必须先做 LB 预摘流 | 救回在飞请求的是 k8s 侧的 drain；NodePort + ETP=Local 下 drain 让 NodePort 回 RST，LB 探测 3s 内自己就摘了 | T10 |
| 每次 reload 固定打断约 3 个客户端连接 | ≈ 空闲 keepalive 连接数，与连接池大小成正比 | T15 |
| 节点侧插摘流规则就够了 | 静态池下完全无效，必须配 `keepalive_time` / `keepalive_requests` | T12 |
| `iptables -j REJECT` 放 filter INPUT 就能摘流 | 空操作，必须放 nat PREROUTING | T11 |
| L4 探测比 L7 弱 / 或两者等价 | 只在「节点/端口不可达」上等价；「端口通但数据面死」时 L4 误判健康 | T6 + T7 |
| 并发越高，故障影响率越高 | 反了：0.11%（CONC=20）→ 0.043%（CONC=100） | T14 |
| 只有被动 `max_fails` 就够（会「自动摘流」） | per-worker，长尾贯穿整个故障期 | T3 |

---

## 复现

```bash
cd ~/kind-ingress-lab
HC_MODE=l4 METHOD=POST ./scripts/failover-test.sh        # T6（默认 HC_MODE=l7、METHOD=GET）
./scripts/l4-blindspot-test.sh                           # T7
CONC=5 METHOD=POST KILL_MODE=kill  SLOW=3.0 ./scripts/concurrency-failover-test.sh   # T8
CONC=5 METHOD=POST KILL_MODE=drain SLOW=3.0 ./scripts/concurrency-failover-test.sh
CONC=5 METHOD=POST KILL_MODE=restart SLOW=1.0 ./scripts/concurrency-failover-test.sh # T8b
./scripts/nodeport-vs-ingress-gap.sh ingress-lab-worker2 restart                     # T9
CONC=20 METHOD=POST SLOW=1.0 KILL_MODE=graceful PRE_DRAIN_LB=0 ./scripts/concurrency-failover-test.sh  # T10 B 组
./scripts/graceful-reboot-infra.sh ingress-lab-worker2                               # T11 / 推荐方案
HC_ENABLED=0 ./scripts/external-nginx.sh                                            # T12 静态池
./scripts/maintenance-restart.sh ingress-lab-worker2                                # T13 / T14

python3 scripts/summarize-runs.py /tmp/failover-l4 /tmp/failover-l4-post2 /tmp/failover-l7-post /tmp/l4-blindspot
python3 scripts/concurrency-probe.py join --csvfile /tmp/conc-POST-kill/all-POST.csv --logfile /tmp/conc-POST-kill/nginx.log
python3 scripts/ingress-probe.py join --csvfile /tmp/failover-l4/B.csv --logfile /tmp/failover-l4/B.nginx.log
```
