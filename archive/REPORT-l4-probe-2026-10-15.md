# 报告：L4 探测 vs L7 探测 —— 关掉 infra-node 会不会掉，以及 infra Deployment 的配置理由

日期：2026-10-15 ｜ 环境：本机 Docker/kind（`ingress-lab`，5 节点）｜ 全部数据为实测，产物在 `/tmp/failover-*`、`/tmp/l4-blindspot`

---

## 0. 摘要

| 问题 | 结论 |
|---|---|
| 用 **L4 probe**（只 TCP connect `node:31000`）时关掉一个 infra-node，会不会掉？ | **不掉**。摘流 +6s，故障期 450 个 GET / 300 个 POST **全部 200**，0 个 >1s；只有检测窗口内 5–7 个请求被 nginx 重试，代价 505–516ms（= `proxy_connect_timeout`） |
| L4 和 L7 探测有区别吗？ | 对"节点真 down"这一类故障**完全等价**（同时刻失败、同耗时摘流、同样不掉）。差别在**盲区**：见下 |
| L4 什么时候会掉？ | 把 NodePort 接到"三次握手成功但不吐 HTTP"的 sink：L4 判定健康 → **POST 6% 直接 502**（GET 靠重试掩盖，17.3% 在重试）；同一故障 L7 探测 6s 内摘流 → **0 掉** |
| **闭环并发（5 个常驻 client + 3s 慢请求）硬 crash 呢？** | **会掉**。关节点瞬间 5 个请求在飞，落在死节点上的那 2 个：**POST → 502（2/193 = 1.0%）**；GET → 不报 5xx 但被重放，代价 +2.2～2.9s。换成 `kubectl drain` → **0 掉、0 长尾**（§4B） |
| 决定"掉不掉"的真正变量 | ① **节点是怎么关的**（硬 crash vs 优雅 drain）——比探测层重要得多；② 请求是否幂等；③ 摘流速度 `fail×interval + probe_timeout`；④ `proxy_connect_timeout`；⑤ 别让 upstream 池被清空（实测踩到，见 §4） |
| infra 上的 ingress 为什么这么配 | 整套配置只服务一个不变量：**LB 接流量的每个 Node，本节点必须至少有一个 Ready 的 ingress pod**（因为 `externalTrafficPolicy: Local` 下没有本地 endpoint 的节点是静默 DROP）。逐条理由见 §5 |

---

## 1. 环境

```
kind 集群 ingress-lab，k8s v1.37.0，5 节点
  ingress-lab-control-plane  172.18.0.4   [control-plane]
  ingress-lab-worker         172.18.0.2   [infra]   ← ingress-nginx ×3
  ingress-lab-worker2        172.18.0.6   [infra]   ← ingress-nginx ×3   （被演练关闭的节点）
  ingress-lab-worker3/4      172.18.0.7/.3 [node]   ← 业务 whoami ×3
ingress-nginx: helm chart 4.15.1 / app 1.15.1，Deployment 6 副本（3/3），PDB 50%
Service: NodePort 31000/31001，externalTrafficPolicy=Local，internalTrafficPolicy=Local
集群外 LB: nginx/1.27.5 容器（nginx-external，:8080），upstream 成员由容器内探测循环动态维护
```

---

## 2. 实验设计

把探测层做成开关（`nginx/scripts/healthcheck.sh`）：

```sh
HC_MODE=l4   nc -z -w 2 <node>:31000                 # 只做 TCP connect，不看任何应用层
HC_MODE=l7   wget -T2 http://<node>:31000/healthz    # 判 HTTP 200（默认，不带业务 Host 头）
```

其余参数两轮完全一致：`interval=2s fail=2 ok=2 probe_timeout=2s`，LB 侧
`proxy_connect_timeout=500ms`、`proxy_next_upstream error timeout http_502 http_503 http_504`、
`least_conn` + `keepalive 64`。流量：`scripts/ingress-probe.py` 5 rps，每个请求带 `?probe=<id>`，
客户端观测与 nginx `$upstream_addr` 精确对齐；`METHOD=GET|POST` 用来验证非幂等请求。

- **演练 A**：`HC_MODE=l4|l7 METHOD=GET|POST ./scripts/failover-test.sh`
  A 基线 → B `docker stop ingress-lab-worker2` → C `docker start` 恢复。
- **演练 B**：`scripts/l4-blindspot-test.sh`
  在 infra 节点上插 `iptables -t nat -I PREROUTING 1 -p tcp --dport 31000 -j DNAT --to <sink>:8080`，
  sink = `alpine: nc -l -p 8080 -k -e /bin/true`（accept 之后立刻关闭，永远不吐 HTTP）。
  即"端口通、数据面死"，用来分离 L4 与 L7 的判断差异。

---

## 3. 演练 A：L4 探测 + 关掉一个 infra-node

### 3.1 数据

| 轮次 | 探测 | 方法 | 故障期请求 | 状态码 | 传输错误 | 重试 | 摘流耗时 | >1s | p50 | p95 | p99 | max |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 1 | **L4** 2s/2 | GET | 450 | **200×450** | 0 | 7 (1.6%) | **+6s** | 0 | 4ms | 10ms | 505ms | 516ms |
| 2 | **L4** 2s/2 | POST | 300 | **200×300** | 0 | 5 (1.7%) | **+6s** | 0 | 4ms | 8ms | 507ms | 508ms |
| 3 | **L4** 2s/2（修 bug 后复跑） | POST | 300 | **200×300** | 0 | 5 (1.7%) | +6s | 0 | 4ms | 8ms | 507ms | 509ms |
| 4 | **L7** 2s/2（对照） | POST | 300 | **200×300** | 0 | 5 (1.7%) | +6s | 0 | 5ms | 8ms | 507ms | 509ms |
| 参考 | L7 2s/2（上一轮，见 REPORT.md §3.3 ③） | GET | 450 | 200×450 | 0 | 14 | +6s | 0 | 5ms | 19ms | 93ms | 509ms |

### 3.2 时间线（轮次 1）

```
14:10:11  docker stop ingress-lab-worker2 (172.18.0.6)
14:10:12  [error] upstream timed out (110) while connecting to upstream
          → access log: "172.18.0.6:31000, 172.18.0.2:31000" status=200 rt=0.504
14:10:17  [hc 06:10:17] REMOVE 172.18.0.6:31000  (连续 2 次 l4 探测失败)
14:10:18  [hc] upstream 变更 -> 1 个可用节点，reload nginx      ← 之后零重试
14:12:24  [hc] ADD    172.18.0.6:31000  (连续 2 次 l4 探测成功)  ← 自动加回，恢复 2 成员
```

关联结果（`ingress-probe.py join`）：

```
172.18.0.6:31000, 172.18.0.2:31000   n=  7  p50=505ms p95=516ms max=516ms   ← 全部重试成功
172.18.0.2:31000                     n=443  p50=  4ms p95=  8ms max=238ms
```

### 3.3 为什么不掉（机制）

1. 死节点的 NodePort 是 kube-proxy 的 **静默 DROP**（`-m comment "...has no local endpoints" -j DROP`），
   不是 RST。所以 **TCP connect 本身就失败** —— L4 探测和真实请求在同一时刻、以同一方式失败。
   这就是 L4 与 L7 在"节点 down"上等价的原因。
2. 失败发生在 **connect 阶段 ⇒ 请求根本没发出去** ⇒ nginx 认为重试是安全的，
   **GET 和 POST 都会**换一台重发（nginx 的"非幂等不重试"只针对"请求已发给 upstream"之后）。
3. 代价上限 = `proxy_connect_timeout`（500ms）。把 3s 降到 500ms，长尾就从 3006ms 变成亚秒级。
4. 受影响请求数 ≈ `rate × 检测窗口` = 5rps × 6s ≈ 30 次路由机会里实际 5–7 次命中死节点
   （`least_conn` + 被动 `max_fails` 会提前把死节点置冷，所以比理论值少）。
5. `nginx -s reload` 是优雅重载：摘流那一刻没有任何请求被打断（5xx=0）。
6. k8s 侧仍然发现得慢：`docker stop` 后节点 `Ready=True` 持续到 +40s，+50s 才 `Unknown`。
   **依赖 k8s 节点/endpoint 状态的 LB 会有 40s+ 盲飞窗口**，而 LB 侧自己探测是 6s。

### 3.4 参数怎么定

```
检测耗时 ≈ fail × interval + probe_timeout = 2×2 + 2 = 6s      （实测 5–6s）
单个受影响请求的代价 ≈ proxy_connect_timeout                    （实测 505–516ms）
故障期掉请求数 = 0（前提：connect 失败 + 允许重试 + 池子不为空）
```
想更快：`interval=1s fail=2 probe_timeout=1s` → 检测 ~3s，代价上限 300ms；
代价是探测流量和误摘（抖动）风险上升。**注意 busybox `nc -w` 只支持整秒**，L4 探测的超时下限是 1s。

---

## 4. 演练 B：L4 的盲区（这才是 L4/L7 的真正差别）

同一个节点，两种探测的判断：

```
L4 (nc -z)      -> 连接成功          ⇒ 判定【健康】   ← 节点继续接流量
L7 (/healthz)   -> HTTP='<无响应>'   ⇒ 判定【不可用】
```

| 探测 | 方法 | 状态码 | 重试率 | 结论 |
|---|---|---|---|---|
| L4 | GET | 200×150 | **17.3%**（26/150） | 靠 `proxy_next_upstream` 兜住，max 21ms（sink 立刻断连，不耗 connect 超时） |
| L4 | POST | **502×9 / 150（6% 真掉）** | — | 连接已建立、请求已发出 → 非幂等不重试 → 客户端拿到 502 |
| L7 | POST | 200×150 | **0%** | 节点在 +6s 被摘掉（`[hc 06:17:16] REMOVE`），坏节点根本没进流量 |

**结论**：L4 探测只在"节点/端口不可达"这类故障上等价于 L7。凡是"三次握手成功但数据面不工作"——
进程 hang、nginx 配置/规则没加载完、中间有个只做 proxy 的设备、conntrack 黑洞——L4 都会误判健康；
这时 GET 被重试掩盖，**非幂等请求直接 502**。

### 4.1 顺带发现并修复的真 bug（与探测层无关）

第一轮 POST 演练的恢复阶段出现 **10 个 502**：

```
[hc 06:20:42] upstream 变更 -> 0 个可用节点，reload nginx
[error] no live upstreams while connecting to upstream, upstream: "http://k8s_ingress_nodeport/?probe=p2"
```

根因：`failover-test.sh` 用 `kubectl ... > nginx/upstream/nodes` 刷新候选列表，重定向会**先把文件截断成 0 字节**，
容器里的 healthcheck 正好读到空 → 生成空 upstream → `no live upstreams` → 那 2s 内全量 502。

修复（已落地）：① 两处候选列表写入改成 `.nodes.tmp` + `mv`（原子）；② healthcheck 加"空列表跳过本轮"保护。
修复后复跑（轮次 3）：恢复阶段 125 个 POST **全部 200，0 个 502**。

---

## 4B. 闭环并发演练：5 个常驻 client，中途关掉一个 infra-node

§3 是**开环**压测（5 rps、每请求新建连接、请求只几毫秒）——节点被关的那一刻几乎没有在飞请求，
也没复用长连接，所以它只能回答“新请求会不会掉”。本节换成**闭环并发**：N 个常驻 client、
持久连接、始终有请求在飞。

### 4B.1 工具与参数

```
scripts/concurrency-probe.py           闭环并发：--concurrency N（连接复用）、--method GET|POST、
                                       --slow X（后端睡 X 秒，把在飞时间放大到可观测）、--stagger
scripts/concurrency-failover-test.sh   一条不间断流量跑完全程，中途 stop|kill|drain 节点，按时间窗分析
manifests/slow-backend.yaml            demo/slow：python ThreadingHTTPServer，/slow?sleep=3s
                                       （busybox nc 是串行的，不能做慢后端；whoami 不支持 sleep）
```

参数：`concurrency=5 slow=3.0s think=0.1s stagger=0.6s`；探测/超时与 §3 相同（L7 2s/2，connect 500ms）。

### 4B.2 结果

| 关闭方式 | 方法 | 总请求 | 非 200 | 连接错误 | 关节点瞬间在飞 | 落在死节点的 | 代价 |
|---|---|---|---|---|---|---|---|
| `docker stop`（半优雅） | GET | 566 | **0** | 0 | 5 | 0 | 12 个新请求 +500ms（connect 超时后重试） |
| `docker kill`（硬 crash） | GET | 566 | 0 | **1** | 5 | 0 | 12 个 +500ms |
| `docker kill`（硬 crash） | GET, slow=3s | 191 | **0** | 0 | 5 | **2** | 被中断的 2 个重放：总 5.87s / 5.25s（+2.9s / +2.2s） |
| `docker kill`（硬 crash） | POST, slow=3s | 193 | **2 × 502（1.0%）** | 0 | 5 | **2** | 直接 502（2.85s / 2.24s） |
| `kubectl cordon + drain`（维护） | POST, slow=3s | 194 | **0** | 0 | 5 | 2 | **无**（最长 3.016s，与基线一致） |
| `docker restart`（重启） | POST, slow=1s | 589 | **3 × 502（0.5%）** | — | 5 | 3 | 见 §4C |

关键日志（硬 crash + POST）：

```
07:12:19  docker kill ingress-lab-worker2          ← 此时 5 个请求在飞
[error] upstream prematurely closed connection while reading response header from upstream,
        request: "POST /slow?sleep=3.0&probe=w3-29", upstream: "http://172.18.0.6:31000/..."
access:   172.18.0.6:31000  probe=w3-29  status=502 rt=2.845   ← 请求已发出，非幂等不重试
07:12:27  [hc] REMOVE 172.18.0.6:31000            ← 摘流 8s
```

### 4B.3 为什么硬 crash 会掉、drain 不会

- **硬 crash**：请求已经写到死节点的 TCP 连接上（已发出）⇒ nginx 对非幂等方法不重试 ⇒ 502；
  幂等 GET 则重放到活节点 ⇒ 200，代价 = 断连检测（2.2～2.8s）+ 整个请求重做。
- **drain**：先把 pod 从 EndpointSlice 摘掉（新流量立刻不再进来），再优雅终止 nginx
  （`terminationGracePeriodSeconds=30` + ingress 自己的 drain）⇒ 在飞请求跑完。
  实测 5 个在飞全部 3.00s 正常返回；healthcheck 3s 内就 REMOVE 了该节点（endpoint 空 → DROP）。
- 所以：**“会不会掉”首先取决于你是怎么关节点的，然后才轮到幂等性，最后才轮到探测层。**

### 4B.4 并发模型额外推出来的四个结论

1. **`least_conn` 是 per-worker 的**。本环境 8 个 worker，5 个同步起跑的 client 会被分到不同 worker，
   每个 worker 自己看“两台都 0 连接”→ 整批 5 个全落同一个节点（实测：按批交替 .2/.6/.2/.6）。
   后果：关节点的爆炸半径是“全中或全不中”。必须 `--stagger` 错开，否则样本失真。
2. **客户端自连会被 LB 自己的 reload 打断**。两次运行各出现 1 次
   `RemoteDisconnected: Remote end closed connection without response`（0ms，nginx access log 里没有该请求），
   时间戳正好是 `[hc] … reload nginx` 那一秒。开源 nginx 的 reload 对“正在复用的 keepalive 连接”
   不是 100% 无损——摘流越频繁（探测 interval 越小），这个概率越高。
3. **硬 crash 下半开连接的代价不是 connect 超时而是 read 超时**。本次没出现 30s 长尾，
   是因为摘流 reload 后新 worker 的 keepalive 池是空的（新连接 → 500ms connect 超时）；
   如果没有主动摘流（只靠 `max_fails`），在飞/半开请求会挂到 `proxy_read_timeout`（30s）。
4. **爆炸半径 ≈ 在飞请求数 × 1/N(infra 节点数)**。5 并发/2 节点 → 2 个；4 节点 → 1 个。
   想“硬 crash 也不掉”，只能靠幂等键 + 客户端重试，或者把节点下线变成 drain。

### 4B.5 针对并发流量的建议

| 措施 | 效果 |
|---|---|
| 节点下线一律走 `cordon + drain`（给足 grace period），不用 `docker stop`/kill | 在飞请求 0 掉（实测） |
| 写接口带 Idempotency-Key，客户端对 502/504 重试 | 把硬 crash 的 1% 掉变成可重试 |
| `proxy_next_upstream` 加 `non_idempotent` | 能吞掉，但可能重复执行（有副作用时慎用） |
| 降低 `proxy_read_timeout`（按业务 P99 定，而不是默认 30s） | 把半开连接的 30s 卡死变成秒级失败 |
| 控制摘流频率，或改用不 reload 的 LB（HAProxy/Envoy 动态后端） | 避开 keepalive 连接被 reload 打断 |

---

## 4C. 重启（restart）一台 infra —— 为什么 nginx 会出 502

`CONC=5 METHOD=POST KILL_MODE=restart SLOW=1.0 ./scripts/concurrency-failover-test.sh`
（`docker restart ingress-lab-worker2`，589 个请求）

| 探测层 | 总请求 | 502 | 摘流 | 加回 |
|---|---|---|---|---|
| L7 (2s/2) | 589 | **3（0.5%）** | +4s | +24s |
| L4 (2s/2) | 589 | **3（0.5%）** | +4s | +25s |

error_log 里的三种信号（同一个 4s 窗口）：

```
 3 × upstream prematurely closed connection while reading response header   ← 就是这 3 个变成 502
 9 × connect() failed (111: Connection refused) while connecting to upstream ← 快速失败，已重试→ 200
 1 × upstream timed out (110) while connecting to upstream                  ← 同上，200
```

### 结论：restart 时的 502 只来自一个机制

**请求已经写到那台节点的 TCP 连接上（已发出），连接被中途关闭** ⇒
nginx 对非幂等请求不重试 ⇒ 502。数量 ≈ 在飞请求数 × 1/N（5 并发 / 2 节点 → 实测 3）。

connect 阶段的失败（refused / timeout）**不会**造成 502，因为请求没发出去，nginx 会换一台重发。

restart 与 stop/kill 的区别：restart 期间节点 IP 还在网络上但 kube-proxy 规则已撤，
所以得到的是 **RST（connection refused，毫秒级）**而不是静默 DROP——反而更容易被重试掉。

### 怎么消除

| 做法 | 效果（实测/预期） |
|---|---|
| 重启前先 `kubectl cordon + drain`（给足 grace period） | **0 掉**（§4B 实测：194 请求 0 个非 200） |
| 只重启 ingress pod（`rollout restart`）而不是整台节点 | 0 掉（endpoint 先摘，nginx 自己 drain） |
| 客户端对 502 重试 + 写接口带 Idempotency-Key | 把 0.5% 掉变成可重试 |
| `proxy_next_upstream ... non_idempotent` | 能吞掉，但可能重复执行 |
| 提高 infra 节点数 / 加快摘流 / 降低 `proxy_read_timeout` | 缩小爆炸半径与卡死时间 |

---

## 4D. 怎么避免：把“重启”改成“先摘流 → 等排空 → 再重启”

脚本：`scripts/graceful-restart-infra.sh <node> [pre-drain-seconds]`（已实测）

```
[1/7] kubectl cordon $NODE                       防止新 pod 调上来
[2/7] LB 预摘流：把该节点从 upstream 候选里去掉      生产里 = 撤 BGP 宣告 / LB 摘节点
[3/7] 等 PRE_DRAIN 秒（必须 > 业务最长请求时间）      ← 在飞请求排空
[4/7] kubectl drain --grace-period=60              endpoint 先摘，nginx 优雅终止
[5/7] docker restart / reboot                      真正重启（此时已经没有在飞请求了）
[6/7] 等节点 Ready
[7/7] uncordon + 加回候选                        探测连续 OK_MAX 次通过后才真正接流量
```

实测对比（同样 5 个常驻 client、后端 1s、POST）：

| 方式 | 请求 | 非 200 | 连接错误 | 最长请求 |
|---|---|---|---|---|
| `docker restart`（直接重启） | 589 | **3 × 502（0.5%）** | 0 | 1.50s |
| `graceful-restart-infra.sh`（cordon→摘流→等15s→drain→restart） | 723 | **0** | **0** | 1.017s（与基线一致） |

要点：

1. **顺序不能错**。必须在“没有任何在飞请求指向该节点”之后才去关它——第 2/3 步是第 4/5 步的前提。
2. `PRE_DRAIN` 要 **大于业务最长请求时间**（不是固定 15s）；长连接/WebSocket/大文件需要单独的排空策略。
3. 加回也要慢：等 pod Ready + 探测连续 OK_MAX 次通过（本实验 2 次×2s），否则“刚回来就被打满”会变成 404/503。
4. 本实验的“预摘流”靠改 upstream 成员 + `nginx -s reload`，reload 自身有极小概率打断客户端 keepalive
   （上一轮实测 1/725 次 `RemoteDisconnected`）。生产里用 **BGP withdrawal / LB 动态摘节点**没有这个代价。
5. 如果实在做不到优雅下线（比如节点必须硬重启），就只能在应用层兜：
   **写接口带 Idempotency-Key + 客户端对 502/504 重试**，或 `proxy_next_upstream ... non_idempotent`（有重复执行风险）。

---

## 4E. NodePort 与 ingress-nginx 之间的 GAP（实测时间线）

工具：`scripts/nodeport-vs-ingress-gap.sh <node> [restart|stop|drain]`。
对同一个节点每秒采样四条**互相独立**的信号：

```
A tcp      nc -z <node>:31000                    ← kube-proxy 的 NodePort 路径（LB 的 L4 探测）
B healthz  GET :31000/healthz（不带业务 Host）     ← ingress 默认 server（LB 的 L7 探测）
C biz      GET :31000/  Host: demo.local          ← 业务路由真的能服务吗
D k8s      该节点上 Ready 的 ingress pod 数 / EndpointSlice 里该节点的本地 endpoint 数
```

`docker restart ingress-lab-worker2` 的实测时间线：

```
08:21:29  TCP-OK  healthz=200 biz=200   nodeReady=True podsReadyOnNode=3 localEndpoints=3
08:21:34  --      ---       ---         nodeReady=True podsReadyOnNode=3 localEndpoints=3   ← 重启！数据面已死
08:21:42  --      ---       ---         nodeReady=True podsReadyOnNode=0 localEndpoints=0   ← 控制面 08:21:39 才跟上
08:22:16  --      200       200         nodeReady=True podsReadyOnNode=0 localEndpoints=0   ← 数据面已可用！
08:22:17  TCP-OK  200       200         nodeReady=True podsReadyOnNode=1 localEndpoints=1
08:22:21  TCP-OK  200       200         nodeReady=True podsReadyOnNode=3 localEndpoints=3
```

量出来的两个 GAP：

| GAP | 方向 | 实测时长 | 具体表现 | 后果 |
|---|---|---|---|---|
| **GAP-1** | 下线 | **≈5s**（08:21:34 → 08:21:39） | NodePort 已经全黑，但 API 里还是 `podsReadyOnNode=3 / localEndpoints=3` | 依赖 k8s endpoint / node 状态导流的 LB（或基于 node 的 BGP 宣告）会**持续往黑洞里送流量** 5s |
| **GAP-2** | 上线 | **≈5s**（08:22:16 → 08:22:21） | ingress-nginx 已经 `healthz=200 / biz=200`，但 API 里 `localEndpoints=0` | 按 endpoint 加回的 LB 会晚 5s（浪费容量）；按探测加回的 LB 在 08:22:16 就加回了（此时确实能服务） |
| 数据面黑窗 | — | **42s**（08:21:34 → 08:22:16） | 整个节点 NodePort 不可达 | 这 42s 里所有被分到该节点的请求全部靠重试兑救；**在飞请求直接变 502** |

为什么会脱节：

- kube-proxy 的转发规则是**异步收敛**的，而且会残留（stale DNAT 仍然能工作）——
  所以“数据面可用”和“控制面 Ready”可以互相先后可后，两个方向都会脱节。
- 节点对象更慢：`nodeReady=True` 全程不变（lease 未过期），40s+ 才会变 Unknown。
- ingress-nginx 的 readinessProbe（:10254/healthz）只能证明“进程健康”，**不能证明业务路由已 sync**；
  所以“endpoint 出现了”也不等于“biz 一定 200”。

针对 NodePort 架构的做法（按优先级）：

1. **LB 健康检查直接探 NodePort 本身**（TCP + L7 `/healthz`），不要依赖 k8s endpoint / node 状态——
   实测两条时间线互相偏差 5s+。探测参数：`interval 2s / fail 2 / probe_timeout ≤1s` → 摘流 4–6s。
2. **摘流要快，加回要慢**：加回需要“连续 OK_MAX 次成功 + 最小 hold-down（建议 ≥ 30s）”，
   并最好叠加“该节点上 ingress pod 已 Ready”这个条件，避免 GAP-2 变成 404/503 突发。
3. **把重启变成 graceful（§4D）**：GAP-1 的 5s 黑洞和 42s 黑窗里的在飞 502，靠探测都只能缓解不能消除。
4. **生产上更干净的做法：`type: LoadBalancer` + Antrea BGP 宣告 + `healthCheckNodePort`**：
   摘流由**控制面事件驱动**（endpoint 变化 → 立即撤宣告），而不是靠 LB 超时探测，
   GAP-1 从 5s 降到亚秒级；`healthCheckNodePort` 给出明确的 200/403，不用靠超时猜。
5. 节点侧：适当调低 `--node-monitor-grace-period`、给 ingress-nginx 配 `startupProbe` +
   `preStop sleep`（先摘 endpoint、再退进程），把两个方向的 GAP 都拉小。

---

## 4F. 放大规模（20 并发）对照：**没有 LB 预摘流**会怎样

`CONC=20 METHOD=POST SLOW=1.0`，每轮 ~4000 请求，关节点瞬间有 **19 个请求在飞**。

| 做法 | 总请求 | **502** | 客户端连接被断 | nginx reload | `prematurely closed` | `refused`（可重试） |
|---|---|---|---|---|---|---|
| A. 直接 `docker restart` | 3447 | **12** | 3 | 3 | 10 | 10 |
| B. cordon → 等15s → drain → restart（**不做 LB 预摘流**） | 3982 | **0** | 3 | 3 | **0** | 11 |
| C. cordon → **LB 预摘流** → 等15s → drain → restart | 3981 | **0** | **8** | **5** | 0 | 12（+6 connect 超时） |

### 结论（和小规模时不同）

1. **救回在飞请求的是 k8s 侧的 drain，不是 LB 摘流**。B 没动 LB，502 仍为 0；
   因为 `drain` 会先把 pod 从 EndpointSlice 摘掉、再优雅终止 nginx（在飞请求跑完）。
2. B 里 LB 靠被动探测摘流（cordon 后 ≈22s，drain 后 ≈3s）。这 22s 中新请求得的是
   **RST（connection refused）⇒ 毫秒级失败 ⇒ nginx 自动换一台重发**，客户端无感（11 次）。
   → 这个“便宜”的前提是 **drain 让 NodePort 回 RST**。如果是 `docker stop`/`kill`（静默 DROP），
   同样的窗口就变成每次 500ms connect 超时 + 在飞被切 ⇒ 就是 A 里的 12 个 502。
3. 在这个具体实现里，**LB 预摘流是净成本**：多两次 reload（预摘 1 + 被动摘 1 + 加回 1 = 5 次），
   客户端连接被断从 3 涨到 8。因为 NodePort + ETP=Local 下 drain 会让 NodePort 立刻 RST，
   LB 探测 3s 内就能摘掉，预摘流没有额外收益。
4. **预摘流仍然有价值的三种场景**（你们生产如果命中任一条，就保留 §4D 的完整 7 步）：
   - 不能 drain（必须硬关机/重启操作系统）；
   - 摘流信号是静默 DROP 而不是 RST（没 drain、或 Service 不是 Local）——被动探测要等 connect 超时；
   - LB 的动态摘除成本高（BGP 撑销慢、reload 慢、或探测间隔大）。

### 摇结论

> 在 **NodePort + externalTrafficPolicy: Local + 开源 nginx 做 LB** 这套组合下，
> 重启 infra 的最小安全动作是 **`cordon` → `drain` → 重启 → 加回**；
> LB 预摘流可省（省了反而少两次 reload）。但一旦去掉 drain，19 个在飞里就有 ~10 个变 502。

---

## 4G. 节点侧自己摘流（LB 不可控时）：cordon → 节点侧摘流 → 等连接排空 → drain → reboot

脚本：`scripts/graceful-reboot-infra.sh <node> [wait-conn-seconds]`（已实测）

### 两个必须改的地方

1. **顺序：摘流必须在 drain 之前**。`cordon` 本身不会停流量，“等排空”在插规则之前不可能发生。
   正确顺序：`cordon → 节点侧摘流 → 等连接排空 → drain → reboot`。
2. **`iptables ... -j REJECT --reject-with tcp-reset` 放在 filter INPUT/PREROUTING 上是错的**：
   - kube-proxy 的 NodePort DROP 在 **filter INPUT**（`-A INPUT --ctstate NEW -j KUBE-EXTERNAL-SERVICES`），
     而 **DNAT 发生在更早的 nat PREROUTING** ⇒ 只要该节点还有本地 endpoint，包到 INPUT 时 dport 已经是 podIP:80，
     `--dport 31000` 的 REJECT **根本匹配不上**（实测：插了规则后 `wget :31000/healthz` 仍 200/0s）。
   - REJECT 放在 mangle PREROUTING 被内核拒（`RULE_INSERT failed (Invalid argument)`，发 RST 需要路由决策）。
   - ✅ 可用形式：在 **nat PREROUTING 最前面**（抢在 kube-proxy 的 jump 之前）把 :31000 改到一个没人监听的本地端口，
     让内核自己回 RST：
     ```bash
     iptables -t nat -I PREROUTING 1 -p tcp --dport 31000 -j DNAT --to-destination <nodeIP>:1
     iptables -t nat -I PREROUTING 1 -p tcp --dport 31001 -j DNAT --to-destination <nodeIP>:1
     ```
     实测：无论有没有本地 endpoint，新连接都是 **0s 拒绝**（而不是 3s 超时黑洞）。
3. **连接数用 conntrack 看，不能用 `ss`**：NodePort 是 DNAT，节点上没有 :31000 的本地 socket
   （`ss state established sport = :31000` 永远是 0）。conntrack 的原始元组里 dport 仍是 31000：
   ```bash
   conntrack -L -p tcp --dport 31000 | grep -c ESTABLISHED     # 计数
   conntrack -D -p tcp --dport 31000                          # 强制关闭：下一个包会重新走 nat 规则 ⇒ RST
   ```

### 实测（CONC=20，POST，后端 1s，5611 请求）

```
[2/7] 节点侧摘流（nat DNAT → :1）      当前连接数: 13
[3/7] t=+0s conns=13   →   t=+5s conns=0        # 强制关闭生效
[4/7] drain   [5/7] reboot   [6/7] Ready=True   [7/7] uncordon

LB 侧：09:06:32 cordon+插规则 → 09:06:36 [hc] REMOVE（**4s**）→ 09:07:14 ADD
客户端：5611 请求，**0 个 502**，**0 个 upstream 错误**（无 refused / 无 timeout / 无 prematurely closed）
唯一代价：7 个客户端连接被 LB 自己的 reload 打断（09:06:36 ×3、09:07:15 ×4）
```

### 与其他做法对比（都是 CONC=20、POST、~4000-5600 请求）

| 做法 | 502 | upstream 错误 | **LB 摘流耗时** | 客户端连接被断 |
|---|---|---|---|---|
| A. 直接 `docker restart` | **12** | 20 | 4s | 3 |
| B. cordon→drain→restart（不做任何摘流） | 0 | 11 refused（可重试） | **≈22s** | 3 |
| C. cordon→**LB 预摘流**→drain→restart | 0 | 18 | 0s（但需要 LB 配合） | 8 |
| **D. cordon→节点侧 nat 摘流→等排空→drain→reboot** | **0** | **0** | **4s**（LB 自己就摘了） | 7 |

→ **D 是 LB 不可控时的最优选择**：它把“黑洞”变成“RST”，让 LB 的探测从“等 connect 超时”变成
“立刻失败”，摘流时间从 22s 降到 4s，而且不需要动 LB 一行配置。
→ 客户端连接被断（3～8 次）是 **nginx 开源版做 LB 的固有代价**（每次改后端都要 reload），
与节点侧动作无关；要彻底消除只能换 HAProxy/Envoy 这类动态后端，或降低摘流频率。

---

## 4H. nginx LB 侧加哪些配置能减少这类问题（全部实测）

### ① 最关键：限制上游 keepalive 连接的寿命

实测发现一个反直觉的现象：**静态池下，节点侧的摘流规则完全不起作用**——
LB 一直复用已有的 keepalive 连接（这些连接不空闲，永远不会被回收），
插了 nat 摘流规则后 conntrack 计数 **70s 都是 8，根排不空**；
这时去 drain/reboot，必然切在飞请求。

```nginx
upstream k8s_ingress_nodeport {
    least_conn;
    include /etc/nginx/upstream/nodeports.conf;
    keepalive         64;
    keepalive_time     10s;   # ← 连接最长活 10s（nginx ≥1.15.3）
    keepalive_requests 20;    # ← 每条连接最多服务 20 个请求就重连
}
```

加上这两行后重测（**关掉主动摘流**，`HC_ENABLED=0`，纯静态池）：

```
节点侧插摘流规则 → 到该节点的连接 12s 内归零（之前 70s 不降）
1440 个请求：全部 200，0 个失败
49 × connect() failed (111) → 全部立即重试（RST，代价 ~20ms）
reload 次数：0      客户端连接被断：0
```

→ **这是性价比最高的一组配置**：不需要主动健康检查、不需要 reload，只靠
“节点侧摘流 + LB 快速重建连接”就能做到 0 掉。已写进本实验的 `nginx/conf/nginx.conf.tmpl`。

### ② 超时与重试边界（控制长尾）

```nginx
proxy_connect_timeout   500ms;   # 实测：3s → p95=3006ms；500ms → p99=507ms
proxy_send_timeout      5s;
proxy_read_timeout      10s;     # 不要留默认 30s：半开连接会卡 30s
proxy_next_upstream     error timeout http_502 http_503 http_504;
proxy_next_upstream_tries    2;  # 限制重试次数，避免故隙时放大流量
proxy_next_upstream_timeout  5s;   # ⚠ 必须 > 业务最长正常响应时间（建议 ≥2×），否则重试会被掉，反而制造 502
```

（写接口多可考虑加 `non_idempotent`，但有重复执行风险；更推荐应用幂等键 + 客户端重试。）

### ③ 如果用主动摘流，把 reload 频率压下去

开源 nginx 改 upstream 必须 reload，而每次 reload 会打断极少量客户端 keepalive 连接
（实测 3～8 / 4000-5600）。所以：

- 滞回：连续 **2 次失败才摘**、连续 **2-3 次成功才加**，加回前再加 hold-down ≥ 30s；
- 保护：**永远不要把 upstream 写成空**（实测过 10 个 502 的 `no live upstreams`）；
- 候选列表/成员文件必须**原子替换**（tmp + `mv`）；
- `worker_shutdown_timeout 30s;` 避免旧 worker 长期挂不退。

### ④ 被动健康检查参数（`max_fails`）

`max_fails=3 fail_timeout=15s` 是 **per-worker** 的，会造成持续不断的重复探测噪声
（实测 33 次重试均匀分布在 90s 里）。如果已经有主动摘流，建议 `max_fails=0` 关掉它，
只当兼底；否则把 `fail_timeout` 调小（5s）并配合短超时。

### 配置组合建议（按你能控制什么）

| 你能控制的 | 推荐组合 |
|---|---|
| 只能改 nginx LB | ①+②+④（`keepalive_time` + 短超时 + 关 `max_fails`），再考虑外挂探测循环 |
| 能改节点（本实验的情况） | **①+② + 节点侧 nat 摘流**（§4G）→ 实测 0 掉、0 reload |
| 能换 LB 实现 | HAProxy `option httpchk` + `default-server observe` / Envoy outlier detection，动态后端不 reload，可去掉①的代价 |

---

## 4I. 维护窗口用 LB 标记 upstream down，再重启节点

脚本：`scripts/lb-mark.sh`（标记/恢复/回滚） + `scripts/maintenance-restart.sh`（完整流程）

### 先说结论：能做，但 `down` 必然伴随 reload

`down` 是 upstream 里的**静态参数**，开源 nginx **没有任何运行时 API**（Plus 才有
`PUT /api/http/upstreams/<name>/servers/<id>/down`）。所以“标记 down”= 改文件 + `nginx -s reload`。
好处是 reload 之后 nginx **立刻**不再往这个 server 派新请求（不用等探测失败），而且动作可审计。

意外收获：reload 时旧 worker 退出会**顺手关掉它到该节点的上游 keepalive 连接**，
实测标 down 后 `conns` 直接 0（不需要等 `keepalive_time`）。

### 正确顺序（实测）

```
1) LB 标 down（reload #1）        ← 先于 cordon，否则留下“已 cordon 但流量还在进”的窗口
2) 等 LB 到该节点的连接排空        ← conntrack 计数；down+reload 后实测立刻为 0
3) 节点侧兜底摘流（nat DNAT → :1） ← 兜住 LB 之外的客户端：监控探测 / 直连 NodePort / 第二个 LB
4) cordon + drain
5) reboot
6) 等节点 Ready
7) uncordon                      ← 必须在这里！cordon 状态下 pod 永远 Pending，等不到 Ready
8) 等该节点 ingress pod Ready → LB 标 up（reload #2） ← 先标 up 再等 pod 会把流量打到一个
                                                          还没有本地 endpoint 的节点（NodePort 黑洞）
```

实测（CONC=20、POST、5607 请求）：**0 个 502、0 个 upstream 错误**，
6 个客户端连接被 reload 打断（本次共 3 次 reload：脚本 down + hc REMOVE + hc ADD）。

### 写这个脚本必须有的 5 个保护（每一条都是一次事故）

1. **保护检查必须在写“人工下线名单”之前**。实测事故：先把 IP 追写到 `manual_down.list`，
   再做“不能把最后一个可用节点标 down”的检查；而容器内的健康检查每 2s 就会按名单重写 upstream
   ⇒ 两个节点全 down ⇒ **入口直接 502**。
2. **两个写入者必须合并**。维护脚本改的 `down` 会被健康检查下一轮覆盖回去。做法：
   健康检查读 `manual_down.list`，命中就输出 `server ... down;` 且不计入可用数；
   同时健康检查自己也要有保险：**可用节点为 0 且是人工下线造成的 → 拒绍应用**（除非 touch `force_all_down`）。
3. **区分“LB 不可达”和“配置语法错”**。`docker exec nginx -t` 在容器刚重启时会失败，
   当成语法错就会把一份本来正常的配置回滚掉（实测误报过）。要重试 + 看输出区分，不可达时不做变更。
4. **标 up 要处理“成员行已被健康检查删掉”**。重启期间 hc 会把整行删掉，这时“去掉 down”会找不到行；
   正确做法是只从名单里移除，等 hc 探测通过自己 ADD。
5. **变量名紧跟中文必须用 `${}`**（`$msg，` 会被 bash 当成变量名 `msg，`，`set -u` 下直接炸，
   而且是在最关键的检查那一行炸）。

### 三种方案对比（都是 CONC=20、POST、~5600 请求）

| 方案 | 502 | upstream 错误 | 新请求停住 | reload | 客户端连接被断 |
|---|---|---|---|---|---|
| §4G 纯节点侧（不碰 LB） | 0 | 0 | 4s（等 hc 探测失败） | 2（hc 自己） | 7 |
| **§4I LB 标 down + 节点侧兜底** | **0** | **0** | **立刻** | 3（脚本 1 + hc 2） | 6 |
| §4F C 组：只靠 LB 预摘流 | 0 | 18 | 立刻 | 2 | 8 |

→ 生产建议：**两个都做**（`maintenance-restart.sh` 就是这么写的）。LB 标 down 保证新请求立刻停、
动作可审计；节点侧兜底保证“LB 之外的客户端”不会掉进黑洞。两者都不依赖业务改造。

---

## 4J. 方案横评与最终推荐（本轮实测）

所有行都是 **CONC=20、POST、后端 1s、~5600 请求**，同一集群同一拓扑，只换流程/LB 配置。

| 方案 | 计划内重启：502 | 客户端断连 | reload | 非计划 crash：502 | 非计划的长尾 |
|---|---|---|---|---|---|
| A. 直接 `docker restart` | 12 | 3 | 2 | — | — |
| B. cordon→drain→restart | 0 | 3 | 2 | — | — |
| C. cordon→LB 预摘流→drain→restart | 0 | 8 | 2 | — | — |
| D. cordon→节点侧 nat 摘流→等排空→drain→reboot（§4G） | 0 | 7 | 2 | ~10 | 短（4s 摘除） |
| E. LB 标 down→等排空→节点侧兜底→…（§4I） | 0 | 6 | 3 | — | — |
| F. 静态池（无主动摘流）+ `keepalive_time` + 节点侧摘流 | **0** | **0** | **0** | 8 | **长**：96 次 500ms 重试，持续整个故障期 |
| **G. F 的配置 + 保留主动摘流，但维护期抑制（推荐）** | **0** | **0** | **0** | ~10 | 短（8s 摘除） |

### 为什么是 G

F 在计划内维护上做到了极致（**0 掉、0 reload、0 客户端断连**，5585 请求），代价在非计划故障：
静态池里没有主动摘流，crash 后 LB 会一直重试这个节点 ⇒ 整个故障期间持续产 500ms 长尾（96 次）。

G 的做法：保留主动摘流（非计划故障仍然 8s 内摘除），但给健康检查加一个
**`manual_hold.list`（“这台在维护，不要摘”）**：

- 计划内维护：节点侧已经把自己摘干净了（新连接 RST），健康检查再去 REMOVE/ADD 只会白白多两次 reload
  ⇒ 写 hold ⇒ **维护期间 0 次 reload**；
- 非计划故障：hold 不存在 ⇒ 摘流照旧生效 ⇒ 长尾被限制在几秒。

实测（G，计划内）：5600 请求，**0 非200 / 0 客户端断连 / 维护期间 0 reload**；
LB 内部 27 次 refused + 6 次超时全部被重试掉，客户端无感（最慢的一个 1506ms）。

### 两个调优发现

1. **`max_fails` 影响“等连接排空”的快慢**：`max_fails=1 fail_timeout=5s` 下 conns 10→0 用 10s；
   `max_fails=3 fail_timeout=15s` 下要 20s。想要维护窗口快，就调小。
2. **不要在 reboot 前删掉节点侧 nat 规则**：规则会随 netns 消失，提前删会留下一个
   kube-proxy DROP 的黑洞窗口（实测造成 17 次 500ms connect 超时）。

### 最终配置（两部分，都不需要业务改造）

**LB（nginx 开源版）**
```nginx
upstream k8s_ingress_nodeport {
    least_conn;
    include /etc/nginx/upstream/nodeports.conf;   # 成员文件原子替换，永不为空
    keepalive          64;
    keepalive_time     10s;                        # ← 关键：让节点侧摘流能生效
    keepalive_requests 20;
}
proxy_connect_timeout  500ms;
proxy_read_timeout     10s;
proxy_next_upstream    error timeout http_502 http_503 http_504;
proxy_next_upstream_tries   2;
proxy_next_upstream_timeout 5s; # ⚠ 必须 > 业务最长正常响应时间（建议 ≥2×），否则重试会被这个预算掉，反而把可重试的失败变成 502
```
外加一个外挂探测循环（interval 2s / fail 2 / ok 2），并且支持：
`manual_down.list`（人工下线）、`manual_hold.list`（维护中不摘）、可用节点为 0 时拒绍应用。

**节点（计划内维护）**：`scripts/graceful-reboot-infra.sh <node> [wait-conn]`
```
cordon → 写 manual_hold + 节点侧 nat 摘流(RST) → 等 conntrack=0 → drain
→ reboot → 等 Ready → 先 uncordon → 等 /healthz 连续 2 次通过 → 解除 hold
```

---

## 4K. 实验：LB 动态 down upstream + 完整节点维护流程 → 客户端到底有没有业务问题

脚本：`scripts/maintenance-restart.sh <node> [wait-conn]`（带绝对时间戳）
负载：CONC=20 闭环并发、持久连接、**POST（非幂等写）**、后端 1s、~300s、~5600 请求
流程：LB 标 down → 等连接排空 → 节点侧兜底 → cordon+drain → reboot → Ready → uncordon → 探测通过 → 标 up

### 判定标准（不是只看 502）

| 指标 | 为什么重要 |
|---|---|
| 非 200（502/504） | 直接失败 |
| 连接被断（status=0） | 写请求最危险：可能“后端已处理但客户端不知道” ⇒ 重试会重复写 |
| 耗时 >3s | 习于超时/重试风暴 |
| 关节点瞬间在飞的请求结局 | 真正会丢数据的那一批 |

### 归因方法（关键）

每个请求带唯一 `probe=<id>` 查询参数，三方对齐：
**客户端 CSV** → **LB access log**（有没有被转发）→ **ingress 控制器日志**（后端有没有真的处理）。
只有“三边都查不到”才能判定为“请求未发出 ⇒ 重试安全”。

### 结果（两轮）

| | 第一轮 | 第=轮（修正后） |
|---|---|---|
| 总请求 | 5606 | 5600 |
| 502 / 504 | **0** | **0** |
| 耗时 >3s | **0** | **0** |
| p50 / p99（故障窗口） | 1004 / 1043ms（基线 1004/1044） | 1004 / 1045ms（基线 1005/1014） |
| 关节点在飞 20 个请求 | **全部 200** | 全部 200 |
| 连接被断 | 6 | 6 |
| 其中“后端已处理但客户端不知道” | **0** | **0** |
| reload 次数 | 4 | **2** |

被断的 12 个请求（两轮合计）全部是 `RemoteDisconnected`、耗时 0.1～0.3ms，
**在 LB access log 和 ingress 日志里都查不到对应 probe id** ⇒ 请求从未被转发、后端从未收到
⇒ 属于“幂等安全”的失败，客户端直接重试不会重复写。

⚠ 一个容易误判的地方：用 `kubectl logs --since=15m` 查 probe id 会跟上一轮实验重名
（id 形如 `w17-1420`，两轮会重复），必须按时间戳过滤。本轮差点因此把“后端已处理”误判为成立。

### 这 6 个断连是怎么来的

全部落在 reload 的那一秒（03:14:57 标 down、03:15:44 标 up）。机制：reload 时旧 worker 退出，
会立即关闭它持有的**空闲客户端 keepalive 连接**；客户端恰好在这个瞬间往这条连接上写请求 ⇒ 连接已关。

实测：**每次 reload 固定打断 ~3 个客户端连接**（与请求速率无关，5600 请求里 0.05%）；
把 4 次 reload 降到 2 次，并不能把 6 降到 3——因为成对的 reload 只隔 1s，打断的是同一批“幸运”连接。

### 顺便修掉的一个设计问题（单一写入者）

第一轮实际发生了 4 次 reload：维护脚本写一次，容器内的健康检查下一轮按自己的注释重写⇒ 又 reload 一次。
修正：`lb-mark.sh` 检测到健康检查在跑时**只写 `manual_down.list`**，由健康检查唯一落盘（`wait_hc` 等待生效）。
验证：down/up 各 **1 次** reload。配置抹平、归因也干净了。

### 结论

- **业务层面：0 个失败请求、0 个“结果未知的写”、0 个长尾、在飞请求全部完成。**
- 客户端能感知到的只有一件事：**0.11% 的请求遇到“连接被关、请求未发出”**。
  对 HTTP 客户端这是标准的安全重试条件（请求未到达服务端），但**必须真的去重试**；
  不重试的客户端会把它当成一次失败。
- 要连这 0.11% 都不要：走 §4J 的方案 G（计划内维护不碰 LB、不 reload），或者换成支持动态后端的 LB。

### 加大到 CONC=100 的复测（确认结论不依赖并发）

先确认容量：CONC=60 / CONC=100 空跑基线都是 p50=1004 / p99=1045 / 0 错误（未饱和）。
然后 CONC=100（~90 rps，28017 请求）跑同一流程：

| 指标 | CONC=20 | **CONC=100** |
|---|---|---|
| 总请求 | 5600 | **28017** |
| 502 / 504 | 0 | **0** |
| 耗时 >2s | 0 | **0**（维护窗口内 4359 请求，只有 1 个 >1.1s） |
| 关节点在飞请求 | 20 → 全 200 | **88 → 全 200**（最长 1049ms） |
| p50/p99（故障窗口） | 1004/1045 | 1004/1044（基线 1004/1046） |
| 连接被断 | 6（0.11%） | **12（0.043%）** |
| 其中“后端已处理但客户端不知道” | 0 | **0**（12/12 在 LB 和 ingress 日志里都查不到） |

→ **并发提高 5 倍，业务影响率反而从 0.11% 降到 0.043%**：因为断连数取决于
“reload 瞬间有多少空闲客户端连接”，而不是请求速率。

### 为什么有时打断 12 个、有时 0 个：相位

CONC=100 这一轮，12 个断连全部在标 down 那一秒，而标 up 的 reload **一个也没打断**。
把客户端 CSV 按相位对齐后真相很直接：闭环负载下各 client 是准同步的（周期 = 后端 1.0s + think 0.1s），
所以“空闲窗口”是一条每 1.1s 重复一次的窄带：

```
被断的 12 个请求：上一个请求都恰好在 reload 前 100.9～102.3ms 结束 ⇒ 全在 100ms 空闲窗口内
标 up 的 reload（03:26:54）：±0.3s 内有 71 个请求开始 ⇒ 落在忙碌相位 ⇒ 0 个打断
```

机制：reload 时旧 worker 只关闭**空闲**的客户端 keepalive 连接；正在处理请求的连接会等请求跑完。
所以这个代价不是“每次 reload 固定 N 个”，而是
**≈ 客户端连接数 × 空闲占比**，与流量相位相关，真实（非同步）流量下就是后者。
（→ 本段“固定 ~3 个”的说法已被 §4L 推翻：那是低连接数下的抽样。）

---

## 4L. 把连接数拉到 2000：之前的结论被推翻了一半（重要）

上一节的“每次 reload 打断 ~3 个连接”是**低连接数下得到的错误结论**。
把负载改成 **100 并发 × 每并发 20 条持久连接 = 2000 条连接**（LB 侧 `:80` accepted 实测 2001），
同一个维护流程，结果完全不同：

| | LB 动态 down/up（2 次 reload） | 节点侧摘流（0 次 reload，§4J 方案 G） |
|---|---|---|
| 总请求 | 31408 | 28000 |
| **失败请求** | **3808 = 12.1%** | **0 = 0.000%** |
| 失败时刻 | 04:12:19-21、04:13:01-04（就是两次 reload） | — |
| 受影响的 client | **100/100**，每个 ≈38 次（= 整个连接池） | 0 |
| 错误类型 | 全 `RemoteDisconnected`，97.6% 耗时 <1ms | — |
| 其中“已转发到后端” | **0 / 3808**（全量集合求交，不是抽样） | — |
| 502 / 504 | 0 | 0 |
| p99（故障窗口） | 1045ms（与基线一致） | 1045ms |
| LB 内部重试（客户端无感） | — | 54 refused + 8 timeout |

### 代价模型（修正版）

```
一次 reload 杀掉的客户端连接数 ≈ 当时的空闲 keepalive 连接数
                                     = 总连接数 × 空闲比例
                                     = 总连接数 × (1 - 1/连接池大小)
```

- 每 client 1 条连接（之前的测试）：空闲比例 ≈ think/(slow+think) ≈ 9% ⇒ 只打断几个；
- 每 client 20 条连接（本轮）：任意时刻 19/20 是空闲的 ⇒ **几乎整个连接池被杀**，
  客户端下一个请求正好撞上下一条已关闭的连接 ⇒ 连续 3 秒、每 client ≈38 次失败。

### 客户端重试一次能不能抹平？——能（实测）

同样的 2000 连接、同样的 LB 动态 down/up，只给客户端加“连接级失败重试一次”：

| | 不重试 | **重试一次** | 节点侧摘流（不 reload） |
|---|---|---|---|
| 失败请求 | 3808 = **12.1%** | **0 = 0.000%** | **0 = 0.000%** |
| 触发重试 / 重试成功 | — | 3825 / **3825 全成功** | — |
| 重试请求耗时 | — | ≈1055ms（基线 1005ms，**+50ms**） | — |
| 故障窗口 p99 | 1045ms | 1082ms（基线 1046） | 1045ms |

因为这 3808 个请求 0 个到达过 LB，所以“重试一次”是安定的（不会重复写），
而且代价只是 +50ms。注意：这是**事后才知道安全**的——客户端当时无法知道请求有没有被处理。

### 所以“凭什么买商业 LB”的量化回答

| 你拥有什么 | 结果 | 代价 |
|---|---|---|
| 只能改 nginx LB（开源） | 能做，但 membership 变更必然 reload ⇒ 2000 连接下 **12% 请求命中被杀连接** | 必须依赖客户端重试；或者忍受 12% |
| 能改节点（本实验） | 摘流下移到节点侧（nat 改端口），**不碰 LB、不 reload** ⇒ 0 失败 | 自己写并维护这套流程（就是上面那些脚本） |
| 商业/动态后端 LB（Plus API / HAProxy runtime / Envoy xDS） | 改后端**不杀连接** ⇒ 不需要节点侧 hack，也不需要客户端重试 | 成本 |

→ 开源能做对，但“做对”需要你同时掌握节点侧和客户端；商业产品卖的是
**把这两个前提拿掉**。

（另注：12.1% 的失败全部是“请求未发出”，不是丢数据；但 12% 的重试风暴、
以及任何不做重试的客户端，都是真实故障。）

---

## 5. infra 上的 ingress Deployment 为什么这样配

整套配置只服务一个不变量：

> **上游 LB（这里是 nginx-external，生产里是 BGP/ECMP）接流量的每一个 Node，本节点上必须至少有一个 Ready 的 ingress pod。**

因为 `externalTrafficPolicy: Local` 下，节点一旦没有本地 endpoint，kube-proxy 就把该节点的 NodePort **静默 DROP**——
LB 看到的是"能宣告、但流量进去没声音"，而不是 connection refused。

| 配置 | 为什么 | 不这样配会怎样（实测/推演） |
|---|---|---|
| `kind: Deployment`（不用 DaemonSet） | 把"每节点几个副本"变成显式容量参数；需要滚动升级批次控制（maxSurge/maxUnavailable）和 PDB 生效 | DaemonSet 每节点固定 1 副本：单 pod 挂 → 该节点 endpoint 归零 → **整个节点 NodePort 被 DROP，pod 故障放大成节点故障**（瞬间少 1/N 容量）。Deployment + 每节点 3 副本时单 pod 挂不影响节点可达（已验证） |
| `replicaCount = 3 × N(infra)` | N-1 容量规则：挂一个节点，剩下 N-1 个节点每个还有 3 副本，能吸收被摘节点的流量 | 副本写死（如 6）时，infra 扩到 3 节点变 2/2/2，单节点容量下降；缩到 1 节点又浪费。`scale-infra.sh` 会按 3×N 重算 |
| `nodeAffinity` 硬约束 `node-role.kubernetes.io/infra=true`（不按节点名） | 角色与物理节点名解耦：infra 增减只改 label/taint，Deployment 一行不动（kind 也不能自定义节点名） | 按节点名写死后换节点/重建集群就要改 values；用 `preferred` 则 ingress 会漏到业务节点，破坏不变量 |
| `tolerations` + infra 的 `NoSchedule` | 独占：业务不挤进 infra（抢 CPU/连接表/带宽），ingress 不落业务节点 | 没 taint 时容量和延迟都不可控 |
| `topologySpreadConstraints maxSkew=1` + `DoNotSchedule` | 保证**每个** infra 节点都有 endpoint——这是 LB 能安全宣告节点的前提 | 6 副本堆成 6/0 时，另一节点 NodePort 直接 DROP，ECMP 均匀送流量 → **一半流量进黑洞**（就是 §3.3 里 3s 长尾的同类代价）。宁可 Pending 也不要不均 |
| 硬约束而不是 `ScheduleAnyway` | 分布不均 = LB 侧容量不均，是正确性问题不是偏好 | 代价：drain 一个节点时被驱逐 pod 会 Pending，维护窗口容量减半——由 PDB 50% 兜底，是刻意取舍 |
| `type: NodePort` + 固定 `31000/31001` | 上游 LB/BGP 配置成常量，helm 重装不换端口 | 随机 NodePort → 每次部署都要改 LB。（`healthCheckNodePort` 在 NodePort 上被 API 拒绝，所以生产更干净的是 `type: LoadBalancer` + Antrea BGP 宣告） |
| `externalTrafficPolicy: Local` | 不跨节点二跳、保留客户端真实 IP、延迟可预测；和"BGP 只宣告有本地 endpoint 的节点"是标准 ECMP 做法 | `Cluster` 下 kube-proxy SNAT（后端看不到 client IP）且多一跳，infra 层容量模型失效 |
| `internalTrafficPolicy: Local`（post-render 注入） | 集群内→ClusterIP 也只在 infra 节点服务，集群内外路径行为一致 | 不加则集群内调用会跨节点转发到 ingress；代价是坑#11（非 infra 节点上的自检/监控探测会被 DROP） |
| `podDisruptionBudget` + `minAvailable: 50%` | 自愿中断（drain/升级）最多砍一半容量 | 没 PDB 时 `drain` 能一次赶走某节点全部 3 副本，叠加 TSC 硬约束 → 该节点直接没 endpoint。用百分比而非固定数字，infra 扩容自动跟随 |
| `terminationGracePeriodSeconds: 30` | 给 nginx 自身 drain + 在途请求留时间，升级不产生 RST | 与 LB 侧摘流时间（~6s）对齐，可推理 |
| `config.use-forwarded-headers` / `compute-full-forwarded-for` | 前置有可信 L7（本实验的 nginx-external 写 XFF）时必须信任并追加，否则后端看到的源地址是 LB | 纯 L4/ECMP（无 XFF）时这两项无感，靠的是 Local 保留 client IP |

职责一句话：**nodeAffinity+taint 决定"在哪"，replicas=3×N + TSC 决定"每个都有且均匀"，
ETP/ITP=Local 决定"不跳出去"，PDB 决定"维护时不归零"**；
LB 侧的主动探测是同一件事的另一半——**k8s 保证"每个节点都有 endpoint"，LB 保证"没 endpoint 的节点不接流量"**。

---

## 6. 生产落地建议（对应 BGP/ECMP + Antrea）

| 层次 | 做法 |
|---|---|
| 探测层 | **L4 TCP connect 只能当最后一道信号**（节点/端口不可达）。至少 L7 探默认 server 的 `/healthz`（不带业务 Host 头，否则被业务规则抢走）；更好的是探一条带业务 Host 的 **canary 路由**，这样连"ingress 规则没加载完"都能挡住 |
| 探测参数 | `interval 2s / fail 2 / probe_timeout ≤1s` → 检测 ~3–5s；加防抖（连续 N 次才摘/加），避免抖动导致反复 reload |
| 超时 | `proxy_connect_timeout` 300–500ms，不是 3s |
| 池子保护 | **永远不要把 upstream 写成空**；候选列表/成员文件必须原子替换（tmp + mv），并考虑"不摘掉最后一个健康节点"的策略 |
| 宣告 | BGP 只宣告"有本地 endpoint 的节点"，且等 nginx pod Ready 后再宣告；节点重启后 IP 会变，LB 必须能重新枚举 |
| 容量 | 每节点 ≥2（建议 3）个 nginx pod + PDB 50% + TSC maxSkew=1 |
| 可观测 | 盯 **p99 和 upstream 重试次数**，不是只看状态码——本次故障模式错误率 0，但 p99 从 8ms 涨到 507ms |

---

## 7. 复现

```bash
cd ~/kind-ingress-lab
HC_MODE=l4 METHOD=POST ./scripts/failover-test.sh        # 开环：摘流/长尾（默认 HC_MODE=l7、METHOD=GET）
./scripts/l4-blindspot-test.sh                           # L4 盲区（TCP 通、HTTP 死）

# 闭环并发（§4B）：5 个常驻 client + 3s 慢请求，中途关节点
CONC=5 METHOD=POST KILL_MODE=kill  SLOW=3.0 ./scripts/concurrency-failover-test.sh
CONC=5 METHOD=POST KILL_MODE=drain SLOW=3.0 ./scripts/concurrency-failover-test.sh
CONC=5 METHOD=GET  KILL_MODE=kill  SLOW=3.0 ./scripts/concurrency-failover-test.sh
python3 scripts/concurrency-probe.py join --csvfile /tmp/conc-POST-kill/all-POST.csv \
        --logfile /tmp/conc-POST-kill/nginx.log

python3 scripts/summarize-runs.py /tmp/failover-l4 /tmp/failover-l4-post2 /tmp/failover-l7-post /tmp/l4-blindspot
./scripts/ingress-probe.py join --csvfile /tmp/failover-l4/B.csv --logfile /tmp/failover-l4/B.nginx.log
```

本次改动：

```
nginx/scripts/healthcheck.sh    + HC_MODE=l4|l7（probe_l4 = nc -z -w）；空候选列表保护
nginx/scripts/entrypoint.sh     日志带上 mode/timeout
scripts/external-nginx.sh       预热探测按 HC_MODE 分支；把 HC_MODE/HC_TIMEOUT 传进容器；nodes 文件原子写
scripts/failover-test.sh        HC_MODE / METHOD / PHASE_A|B|C 可配；nodes 文件原子写
scripts/ingress-probe.py        probe 支持 --method GET|POST
scripts/l4-blindspot-test.sh    新增：TCP 通、HTTP 死的故障注入 + L4/L7 对照
scripts/concurrency-probe.py    新增：闭环并发压测（持久连接、--slow/--stagger/--method）+ 日志关联
scripts/concurrency-failover-test.sh  新增：并发模型下 stop / kill / drain 三种关节点方式
scripts/graceful-restart-infra.sh   新增：cordon→LB摘流→等排空→drain→restart→加回（实测 0 掉）
scripts/nodeport-vs-ingress-gap.sh  新增：每秒采样 tcp/healthz/biz/endpoint，量 NodePort 与 ingress 的 GAP
graceful-restart-infra.sh 可用 PRE_DRAIN_LB=0 跳过“LB 预摘流”这一步（§4F 的 B 组）
scripts/graceful-reboot-infra.sh    新增：节点侧 nat 摘流 + 等 conntrack 排空 + drain + reboot（§4G，LB 不可控时用）
nginx/conf/nginx.conf.tmpl         改动：upstream 加 keepalive_time 10s / keepalive_requests 20（§4H ①，实测关键）
scripts/lb-mark.sh                 新增：维护窗口标 upstream down/up（带备份/语法校验/自动回滚/不为空保护，§4I）
scripts/maintenance-restart.sh     新增：LB 标 down → 等排空 → 节点侧兜底 → drain → reboot → 标 up（§4I/§4K，带时间戳）
scripts/lb-mark.sh                 新增：单一写入者模式（有健康检查时只写名单）—— 避免多一次 reload（§4K）
nginx/scripts/healthcheck.sh       改动：合并 manual_down.list；可用节点为 0 且是人工下线造成时拒绍应用
nginx/scripts/healthcheck.sh       再加：manual_hold.list（维护中的节点不探测、不摘除）—— §4J 方案 G 的关键
scripts/graceful-reboot-infra.sh   重写：hold + nat 摘流 + 等排空 + drain + reboot + 先 uncordon + 探测通过再解除（§4J 推荐）
manifests/slow-backend.yaml     新增：/slow?sleep=Ns 慢后端（制造在飞请求）
scripts/summarize-runs.py       新增：多轮演练结果汇总
README.md / REPORT.md           新增 L4 vs L7 章节、坑#16/#17、REPORT §2.1.1（配置理由）、§3.5
```
