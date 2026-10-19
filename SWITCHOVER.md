# nginx LB 流量切换方案

> 适用范围：集群外 nginx（开源版）做 L7 入口，后端是 kind/k8s 里 ingress-nginx 的 NodePort，
> `externalTrafficPolicy: Local`。生产里对应「BGP/ECMP 宣告 + 节点上的 ingress」。
>
> 本文是**方案**：要配什么、按什么顺序操作、参数怎么定、什么情况下会掉请求。
> 数据与实验过程在 [`EVIDENCE.md`](EVIDENCE.md)，踩过的坑在 [`PITFALLS.md`](PITFALLS.md)。

---

## 0. 一页结论

**摘流要分两件事，它们由不同的层负责，缺一个都不完整：**

| | 谁负责 | 解决什么 | 不做的后果 |
|---|---|---|---|
| **新请求不再进这个节点** | LB 侧（探测摘流 / 标 down）或节点侧（nat 摘流） | 停止把流量送进黑洞 | 每个新请求付一次 connect 超时 |
| **已经在飞的请求不被切** | k8s 侧 `drain`（endpoint 先摘 + 优雅终止） | 让在飞请求跑完 | 非幂等请求直接 502 |

**决定「会不会掉请求」的因素，按重要性排序：**

```
1. 节点是怎么关的        硬 crash vs cordon+drain     ← 影响最大
2. 请求有没有发出去      connect 失败可重试 / 已发出不可重试
3. 摘流有多快            fail × interval + probe_timeout
4. 超时怎么配            proxy_connect_timeout 决定单次代价上限
5. L4 还是 L7 探测        ← 影响最小，只在「端口通但数据面死」时有区别
```

**最终方案（实测 5600 请求：0 个非 200 / 0 客户端断连 / 维护期 0 次 reload）：**

- LB 侧：L7 探测 + 短超时 + **限制上游 keepalive 连接寿命**（`keepalive_time`），并支持维护期抑制（`manual_hold.list`）。
- 节点侧：计划内维护**自己摘流**（nat 改端口 → 内核回 RST），不碰 LB、不 reload。
- k8s 侧：`cordon → 摘流 → 等连接排空 → drain → reboot`，加回要慢。

---

## 1. 前提：为什么这个架构里「节点健康」等于「本节点有没有 endpoint」

整套方案只服务一个不变量：

> **LB 接流量的每一个节点，本节点必须至少有一个 Ready 的 ingress pod。**

因为 `externalTrafficPolicy: Local` 下，节点一旦没有本地 endpoint，kube-proxy 对该节点的 NodePort 是
**静默 DROP，不是 REJECT**：

```
-A KUBE-EXTERNAL-SERVICES ... --dport 31000
   -m comment "ingress-nginx/ingress-nginx-controller:http has no local endpoints" -j DROP
```

LB 看到的是「能宣告、但流量进去没声音」——SYN 超时，不是 connection refused。这一条决定了后面所有设计：

- LB 的健康检查**必须带 connect 超时**，不能靠「连不上」来判断；
- 新 infra 节点在 ingress pod Ready 之前**不能导流**；
- 计划内维护时，最好主动把「静默 DROP」变成「RST」，让 LB 的探测和真实请求都能毫秒级失败（见 §5）。

k8s 侧的调度约束（nodeAffinity / topologySpread / PDB / replicas=3×N）是在保证这个不变量的**前半段**，
见 [`README.md`](README.md) 的「k8s 侧：保证每个节点都有 endpoint」一节。本文件只管后半段：**LB 怎么摘流**。

---

## 2. 失败是怎么产生的：一条因果链

所有 502 和所有长尾，都能归到「失败发生在哪个阶段」。

| 失败发生在哪 | nginx 的判断 | 客户端最终看到 |
|---|---|---|
| **① connect 失败**<br>`refused`(RST) 或 DROP 超时 | 请求没发出去<br>⇒ GET 和 POST **都**重发 | 200，代价 = `proxy_connect_timeout`<br>实测 505–516ms |
| **② 请求已发出，连接被中途关闭**<br>`prematurely closed` / 半开连接 | 幂等 ⇒ 重放 | 200，代价 = 断连检测 + 整个请求重做<br>实测 +2.2 ~ +2.9s |
| ↑ 同上 | 非幂等 ⇒ **不重试** | **502**<br>实测 1.0%（5 并发）/ 12 个（20 并发） |
| **③ 池里没有可用成员** | 无处可重试 | 502，毫秒级快速失败<br>实测 0.001–0.003s，不伪装成慢 |

三个看起来矛盾的结果，其实是同一张图：

- **connect 超时只是慢，不会掉**：因为请求没发出去，nginx 认为换一台重发是安全的。
  nginx 的「非幂等不重试」只针对「请求已经发给 upstream」之后。
- **硬 crash 会真掉**：在飞请求已经写到那条 TCP 连接上，命中 ②。
- **`drain` 一个都不掉**：drain 先把 pod 从 EndpointSlice 摘掉（新流量立刻不进来），再优雅终止 ingress
  （`terminationGracePeriodSeconds` + ingress 自己的 drain），在飞请求跑完 —— 压根不进入 ①②③。

**爆炸半径公式**：`被切的在飞请求数 ≈ 在飞请求数 × 1/N(infra 节点数)`。
5 并发 / 2 节点 → 2 个；20 并发 → 10 个；100 并发 → 88 个（全部靠流程避免，见 §5）。

---

## 3. L4 探测 vs L7 探测

### 3.1 能力矩阵

| 故障类型 | L4（TCP connect `:31000`） | L7（`GET :31000/healthz`） |
|---|---|---|
| 节点 down / 网络不可达 | ✅ 能发现 | ✅ 能发现 |
| 节点没有本地 endpoint（kube-proxy DROP） | ✅ 能发现（connect 失败） | ✅ 能发现 |
| ingress pod 全挂 → endpoint 归零 | ✅ 能发现（同上） | ✅ 能发现 |
| **进程 hang、端口还 accept** | ❌ 误判健康 | ✅ 摘除 |
| **ingress 配置/规则还没加载完** | ❌ 误判健康 | ⚠️ 默认 server 的 `/healthz` 可能已经 200，业务路由却 404 |
| **中间有个只做 proxy 的设备 / conntrack 黑洞** | ❌ 误判健康 | ✅ 摘除 |
| **业务路由坏了（某条 Ingress 规则错）** | ❌ | ❌ 都不行 —— 需要 canary 路由（§3.4） |

### 3.2 实测：节点真 down 时两者完全等价（T6）

关掉一个 infra 节点，5 rps 开环流量：

| 探测 | 方法 | 摘流耗时 | 状态码 | 重试 | 重试代价 |
|---|---|---|---|---|---|
| L4 (2s/2) | GET | +6s | 200×450，0 个非 200 | 7 (1.6%) | 505–516ms |
| L4 (2s/2) | POST | +6s | 200×300，0 个非 200 | 5 (1.7%) | 506–509ms |
| L7 (2s/2) | POST | +6s | 200×300，0 个非 200 | 5 (1.7%) | 506–509ms |

原因：死节点的 NodePort 是 DROP，**TCP connect 本身就失败** ⇒ L4 探测和真实请求在同一时刻、以同一方式失败。
两者都落在因果链的 ①，所以都不掉请求，代价都等于 `proxy_connect_timeout`。

### 3.3 实测：L4 的盲区才是真差别（T7）

把 `:31000` 在节点上 DNAT 到一个「accept 之后立刻关闭」的 TCP sink —— 三次握手成功，HTTP 永远不响应：

```
L4 (nc -z)      -> 连接成功          ⇒ 判定【健康】   ← 节点继续接流量
L7 (/healthz)   -> HTTP='<无响应>'   ⇒ 判定【不可用】
```

| 探测 | 方法 | 结果 |
|---|---|---|
| L4 | GET | 200×150，但 **17.3% 在重试**（靠 `proxy_next_upstream` 兜住） |
| L4 | POST | **502×9 / 150 = 6% 真掉**（请求已发出，非幂等不重试） |
| L7 | POST | 200×150，**0 重试**（坏节点 +6s 被摘，根本没进流量） |

### 3.4 结论：用 L7，L4 只作为辅助信号

```sh
HC_MODE=l7   wget -T2 http://<node>:31000/healthz     # 默认，推荐
HC_MODE=l4   nc -z -w 2 <node>:31000                  # 只用于排障对照
```

选 L7 的三个实现细节（都是实测出来的）：

1. **不能带业务 Host 头**。带 `Host: demo.local` 时 `/healthz` 会被 ingress 规则匹配走，
   拿到的是业务 pod 的响应，探测就失去意义。
2. **只能判 HTTP 状态码**。默认 server 里是 `location /healthz { return 200; }`，**body 是空的**。
3. **这个信号为什么可信**：ingress-nginx 的 readinessProbe 打 `:10254/healthz`，pod 不健康会被摘出
   EndpointSlice；某节点本地 endpoint 全空时 kube-proxy 对该节点 NodePort 直接 DROP。
   所以一次 `/healthz` 200 同时覆盖了「节点可达 + 有本地 endpoint + nginx 默认 server 活着」。

**要挡住「ingress 规则没加载完」，L7 还不够**：在 ingress 上配一条 canary 路由（带业务 Host、
返回固定 200），探测它。这是本实验没做但生产建议做的一步。

**更好的信号（生产）**：`type: LoadBalancer` + Antrea BGP 宣告时，用 `healthCheckNodePort` ——
它给明确的 200（有本地 endpoint）/ 403（没有），是**控制面事件驱动**而不是超时探测，
把「NodePort 已黑但 API 还说有 endpoint」的 5s GAP 降到亚秒级。见 §8。

---

## 4. LB 侧配置（nginx 开源版）

开源 nginx 没有主动健康检查（`max_fails` 是被动且 **per-worker**），也没有运行时改后端的 API
（Plus 才有 `PUT /api/http/upstreams/...`）。所以方案是：**外挂一个探测循环 + 改成员文件 + reload**。

### 4.1 `nginx.conf`

```nginx
upstream k8s_ingress_nodeport {
    least_conn;
    include /etc/nginx/upstream/nodeports.conf;   # 成员文件原子替换，永不为空
    keepalive          64;
    keepalive_time     10s;   # ← 关键：不限制上游连接寿命，节点侧摘流就是空操作
    keepalive_requests 20;
}

server {
    location / {
        proxy_pass http://k8s_ingress_nodeport;
        proxy_http_version 1.1;
        proxy_set_header Connection "";           # 上游 keepalive 必须
        proxy_set_header Host       $ingress_host; # 必须透传业务 Host，否则 ingress 一律 404

        proxy_connect_timeout       500ms;   # 3s → p95 3006ms；500ms → p99 507ms
        proxy_send_timeout          5s;
        proxy_read_timeout          10s;     # 默认 30s 会让半开连接卡满 30s
        proxy_next_upstream         error timeout http_502 http_503 http_504;
        proxy_next_upstream_tries   2;       # 限制故障时的流量放大
        proxy_next_upstream_timeout 5s;      # ⚠ 必须 > 业务最长正常响应时间（建议 ≥2×），
                                             #   否则重试会被这个预算掉，反而制造 502
    }
}
```

`keepalive_time` 为什么是必需的（T12）：实测在静态池里插节点侧摘流规则，**conntrack 计数 70s 都不降** ——
LB 一直复用已有的上游连接，而这些连接不空闲、永远不会被回收。加上这两行后 12s 归零。
没有它，「等连接排空」这一步永远等不到，drain 必然切在飞请求。

`max_fails`：已经有主动摘流时建议 `max_fails=0` 关掉它，只当兜底。
它是 per-worker 的（本环境 8 个 worker），留着会造成持续不断的重复探测噪声
（实测 33 次重试均匀分布在 90s 里）。

### 4.2 探测循环与三个名单

`nginx/scripts/healthcheck.sh` 在容器内循环：探测 → 防抖 → 改写成员文件 → `nginx -s reload`。

| 名单 | 语义 | 谁写 |
|---|---|---|
| `manual_down.list` | 人工下线：成员行保留但标 `down`，且**不计入可用节点数**（自动摘流不会悄悄加回来） | `scripts/lb-mark.sh` |
| `manual_hold.list` | 维护中：**不探测、不摘、不加**，保持现状 | `scripts/graceful-reboot-infra.sh` |
| `force_all_down` | 保险开关：人工下线导致可用节点为 0 时，默认**拒绝应用**（要清空入口必须显式 touch） | 人工 |

三条必须有的保护（每一条都是一次事故）：

1. **单一写入者**：维护脚本只写名单，落盘和 reload 由健康检查做。两个写入者会互相覆盖，
   实测多两次 reload；顺序反了还会把两个节点全标 down，入口直接 502。
2. **候选列表原子替换**：`kubectl ... > nodes` 会先把文件截断成 0 字节 → 空 upstream →
   `no live upstreams` → 全量 502（实测 10 个）。必须 tmp + `mv`，并加「空列表跳过本轮」保护。
3. **「不能摘掉最后一个可用节点」的检查必须在写名单之前**。

### 4.3 参数怎么定

```
检测耗时（摘流）   ≈ fail × interval + probe_timeout
                  = 2 × 2 + 2 = 6s（实测 4–6s）

单个受影响请求代价 ≈ proxy_connect_timeout（500ms 封顶）

加回耗时           ≈ ok × interval = 4s，另加 hold-down ≥ 30s
```

想更快：`interval=1s fail=2 probe_timeout=1s` → 检测 ~3s，代价上限 300ms；
代价是探测流量和误摘（抖动）风险上升。注意 busybox `nc -w` 只支持整秒，L4 探测超时下限 1s。

**摘流要快，加回要慢**：加回需要连续 `OK_MAX` 次成功 + 最小 hold-down，
最好叠加「该节点上 ingress pod 已 Ready」。加回太快会把流量打到还没有本地 endpoint 的节点（黑洞）。

---

## 5. 计划内维护：完整流程（推荐）

**思路：计划内维护在节点侧摘流，不碰 LB、不 reload；主动摘流只留给非计划故障，并在维护期间抑制它。**

```bash
./scripts/graceful-reboot-infra.sh <node> [wait-conn-seconds]
```

```
[1/8] cordon                                  防止新 pod 调上来
[2/8] 写 manual_hold + 节点侧 nat 摘流         告诉 LB「这台在维护别摘」；把黑洞变成 RST
[3/8] 等 conntrack 连接数 = 0                 在飞请求排空
[4/8] drain --grace-period=60                 endpoint 先摘，在飞请求跑完
[5/8] reboot                                  此时已经没有在飞请求指向该节点
[6/8] 等节点 Ready
[7/8] 先 uncordon                             cordon 状态下 pod 永远 Pending，等不到 Ready
[8/8] 等 /healthz 连续 2 次通过 → 解除 hold    加回要慢
```

节点侧摘流的正确写法（**放在 nat PREROUTING 最前面**，抢在 kube-proxy 的 jump 之前）：

```bash
iptables -t nat -I PREROUTING 1 -p tcp --dport 31000 -j DNAT --to-destination <nodeIP>:1
iptables -t nat -I PREROUTING 1 -p tcp --dport 31001 -j DNAT --to-destination <nodeIP>:1
# 计数用 conntrack，不能用 ss：NodePort 是 DNAT，节点上没有 :31000 的本地 socket
conntrack -L -p tcp --dport 31000 | grep -c ESTABLISHED
conntrack -D -p tcp --dport 31000        # 强制关闭：下一个包重新走 nat 规则 ⇒ RST
```

两个踩过的坑：

- `iptables -j REJECT` 放 **filter INPUT 上是空操作**：kube-proxy 的 DNAT 在更早的 nat PREROUTING，
  只要节点还有本地 endpoint，包到 INPUT 时 dport 已经是 `podIP:80`，`--dport 31000` 根本匹配不上。
  REJECT 放 mangle PREROUTING 又被内核拒（`Invalid argument`）。
- **不要在 reboot 前删掉 nat 规则**：规则随 netns 消失，提前删会留下一个 kube-proxy DROP 的黑洞窗口
  （实测造成 17 次 500ms connect 超时）。

### 方案横评（T10 / T11 / T13 / T14；CONC=20、POST、后端 1s、约 5600 请求，同一集群同一拓扑）

| 方案 | 计划内 502 | 客户端断连 | reload | 非计划 crash |
|---|---:|---:|---:|---|
| A 直接 `docker restart` | **12** | 3 | 2 | — |
| B cordon → drain → restart | 0 | 3 | 2 | — |
| C cordon → LB 预摘流 → drain → restart | 0 | **8** | 2 | — |
| D cordon → 节点侧摘流 → 等排空 → drain → reboot | 0 | 7 | 2 | ~10 个，4s 摘除 |
| E LB 标 down → 等排空 → 节点侧兜底 → … | 0 | 6 | 3 | — |
| F 静态池（无主动摘流）+ `keepalive_time` + 节点侧摘流 | 0 | 0 | 0 | 8 个 + **96 次 500ms 长尾，贯穿故障期** |
| **G 推荐：F 的配置 + 保留主动摘流，维护期抑制** | **0** | **0** | **0** | ~10 个，8s 摘除，长尾短 |

F 在计划内维护上做到了极致，代价全在非计划故障：静态池里没有主动摘流，crash 后 LB 会一直重试这个节点。
G 就是「F 的配置 + 用 `manual_hold` 只在维护期抑制主动摘流」。

**为什么「LB 预摘流」（C）在这里是净成本**：NodePort + ETP=Local 下 `drain` 会让 NodePort 立刻回 RST，
LB 探测 3s 内自己就摘了；预摘流只是多两次 reload，客户端断连从 3 涨到 8。
**救回在飞请求的是 drain，不是 LB 摘流。**

**仍然需要 LB 预摘流的三种场景**（命中任一条就保留完整的预摘流步骤）：

1. 不能 drain（必须硬关机 / 重启操作系统）；
2. 摘流信号是静默 DROP 而不是 RST（没 drain，或 Service 不是 Local）—— 被动探测要等 connect 超时；
3. LB 的动态摘除成本高（BGP 撤销慢、reload 慢、或探测间隔大）。

### 维护窗口必须用 LB 标 down 时（`scripts/maintenance-restart.sh`）

`down` 是 upstream 里的**静态参数**，开源 nginx 没有任何运行时 API，所以「标 down」必然 = 改文件 + reload。
好处是 reload 之后 nginx **立刻**不再往这个 server 派新请求，且动作可审计（`nginx -T` 里能看出是谁摘的）。

```
1) LB 标 down（reload #1）          ← 先于 cordon，否则留下「已 cordon 但流量还在进」的窗口
2) 等 LB 到该节点的连接排空          ← down+reload 会顺手关掉旧 worker 的上游连接，实测立刻为 0
3) 节点侧兜底摘流                   ← 兜住 LB 之外的客户端：监控探测 / 直连 NodePort / 第二个 LB
4) cordon + drain → 5) reboot → 6) 等 Ready → 7) 先 uncordon
8) 等该节点 ingress pod Ready → LB 标 up（reload #2）   ← 先标 up 再等 pod 会把流量打到没有 endpoint 的节点
```

实测 5607 请求：0 个 502、0 个 upstream 错误，6 个客户端连接被 reload 打断。
**生产建议两个都做**：LB 标 down 保证新请求立刻停、可审计；节点侧兜底保证 LB 之外的客户端不掉进黑洞。

---

## 6. 非计划故障：crash 会掉，以及怎么把代价压到最小

硬 crash 时，落在死节点的在飞请求已经发出去了（因果链 ②），非幂等请求必然 502。
**这不是 LB 配置能消除的，只能靠下面三条**：

| 措施 | 效果 |
|---|---|
| 保留主动摘流（L7，2s/2） | 8s 内摘除，把长尾限制在几秒而不是整个故障期 |
| 写接口带 `Idempotency-Key` + 客户端对 502/504 重试 | 把 ~1% 的掉变成可重试，这是唯一能真正归零的办法 |
| 提高 infra 节点数 | 爆炸半径 = 在飞 × 1/N，节点越多切得越少 |

`proxy_next_upstream ... non_idempotent` 能吞掉，但**可能重复执行**（有副作用时慎用）。

实测对照（T8；5 个常驻 client + 3s 慢请求，关节点瞬间 5 个在飞）：

| 关闭方式 | 方法 | 非 200 | 落在死节点的 | 代价 |
|---|---|---|---|---|
| `docker stop`（半优雅） | GET | 0 | 0 | 12 个新请求 +500ms |
| `docker kill`（硬 crash） | GET | 0 | 2 | 被重放：总 5.87s / 5.25s |
| `docker kill` | POST | **2 × 502（1.0%）** | 2 | 直接 502 |
| `kubectl cordon + drain` | POST | **0** | 2 | 无（最长 3.016s，与基线一致） |

---

## 7. 开源 nginx 做 LB 的固有代价：reload

每次改后端成员都要 `nginx -s reload`，而 reload 会关闭旧 worker 持有的**空闲客户端 keepalive 连接**。
客户端恰好在那一瞬间往这条连接上写请求 ⇒ `RemoteDisconnected`（0ms，access log 里没有这个请求）。

**代价模型**（T14 统计、T15 修正）：

```
一次 reload 杀掉的客户端连接数 ≈ 当时的空闲 keepalive 连接数
                              = 总连接数 × 空闲比例
                              = 总连接数 × (1 − 1/连接池大小)
```

- 每 client 1 条连接：空闲比例 ≈ think/(slow+think) ≈ 9% ⇒ 只打断几个（实测 3–8 / 5600 请求）；
- 每 client 20 条连接（2000 连接）：任意时刻 19/20 空闲 ⇒ **几乎整个连接池被杀**，
  实测 3808 个请求失败 = **12.1%**，100/100 个 client 各约 38 次。

这些失败全部是「请求未到达 LB」（在 LB access log 和 ingress 日志里都查不到对应请求），
所以**客户端重试一次是安全的**：实测 3825 次重试全部成功，代价 +50ms，失败率 12.1% → 0。

**把 reload 次数压到 0 的办法就是 §5 的方案 G**：计划内维护不碰 LB。

| 你拥有什么 | 结果 | 前提 |
|---|---|---|
| 只能改 nginx LB（开源） | membership 变更必然 reload ⇒ 2000 连接下 12% 请求命中被杀连接 | 必须依赖客户端重试 |
| 能改节点（本实验） | 摘流下移到节点侧，不碰 LB、不 reload ⇒ 0 失败 | 自己维护 §5 那套脚本 |
| 动态后端 LB（Plus API / HAProxy runtime / Envoy xDS） | 改后端不杀连接 | 成本 |

> 开源能做对，但「做对」需要你同时掌握节点侧和客户端两个前提。
> 商业 / 动态后端产品卖的是**把这两个前提拿掉**。

---

## 8. 生产对应：BGP/ECMP + Antrea

| 本实验 | 生产对应物 | 说明 |
|---|---|---|
| `nginx-external` 容器 + 探测式 upstream | BGP/ECMP 宣告 + 健康检查 | 摘流语义相同 |
| 外挂 L7 探测循环 | `healthCheckNodePort`（需 `type: LoadBalancer`） | **控制面事件驱动**，不用超时探测 |
| 节点侧 nat 摘流 | 撤 BGP 宣告 / 节点侧摘流 | 同一个目的：让流量毫秒级失败而不是进黑洞 |
| `manual_hold.list` | 维护窗口抑制自动摘流 | 避免维护触发无谓的宣告抖动 |
| `nginx -s reload` | BGP 宣告变更 | 没有「杀客户端连接」的代价 |

生产上更干净的做法：把 ingress Service 做成 `type: LoadBalancer` + Antrea BGP 宣告。
这样 `healthCheckNodePort` 可用（它在 `type: NodePort` 上被 API 直接拒绝），LB 拿到明确的 200/403，
而不是靠超时猜。同时 GAP-1（见下）从 5s 降到亚秒级。

### 必须知道的两个 GAP

对同一个节点每秒采样四条独立信号（T9，`scripts/nodeport-vs-ingress-gap.sh`）：

| GAP | 方向 | 实测 | 后果 |
|---|---|---|---|
| NodePort 已黑，API 里还是 `localEndpoints=3` | 下线 | **≈5s** | 按 k8s endpoint / node 状态导流的 LB（或基于 node 的 BGP 宣告）持续往黑洞送流量 |
| ingress 已 `healthz=200 / biz=200`，API 里 `localEndpoints=0` | 上线 | **≈5s** | 按 endpoint 加回的 LB 会晚 5s（浪费容量）；按探测加回当时确实能服务 |
| 数据面黑窗 | — | **42s** | 这期间所有被分到该节点的请求靠重试兜；在飞请求直接变 502 |

原因：kube-proxy 的转发规则是异步收敛的，而且会残留（stale DNAT 仍然能工作）；
节点对象更慢（`Ready=True` 全程不变，40s+ 才 Unknown）；
ingress-nginx 的 readinessProbe 只证明「进程健康」，**不证明业务路由已 sync**。

**所以：LB 探测直接探 NodePort 本身，不要依赖 k8s endpoint / node 状态。**

---

## 9. 观测与验收

**盯这三个，不是只看状态码**：

| 指标 | 为什么 |
|---|---|
| p99 / >1s 请求占比 | 本实验的故障模式错误率是 0，但 p95 从 8ms 恶化到 3006ms（158×） |
| upstream 重试次数（`$upstream_addr` 含逗号） | 重试是「没掉但付了代价」的唯一可见信号 |
| 客户端连接被断（status=0 / `RemoteDisconnected`） | 写请求最危险：可能「后端已处理但客户端不知道」⇒ 重试会重复写 |

**判定一个请求是否「重试安全」的方法**（每个请求带唯一 `probe=<id>`，三方对齐）：

```
客户端 CSV → LB access log（有没有被转发）→ ingress 控制器日志（后端有没有真的处理）
只有「三边都查不到」才能判定为「请求未发出 ⇒ 重试安全」
```

⚠ 用 `kubectl logs --since=15m` 查 probe id 会和上一轮实验重名（id 形如 `w17-1420`），必须按时间戳过滤。

**验收基线**（T14，推荐流程 G，CONC=100、28017 请求）：0 个 502/504、0 个 >2s、
关节点在飞 88 个请求全部 200、p99 与基线一致；12 个（0.043%）连接被断，全部「请求未到达后端」。

---

## 10. 复现

```bash
cd ~/kind-ingress-lab
./scripts/bootstrap.sh                                   # 建集群 + 装 ingress + 起外部 nginx

# 探测层 / 方法可切换
HC_MODE=l4 METHOD=POST ./scripts/failover-test.sh       # 开环：摘流与长尾
./scripts/l4-blindspot-test.sh                          # L4 盲区（TCP 通、HTTP 死）
./scripts/switchover-check.sh                           # 502/503 专项

# 闭环并发：N 个常驻 client + 慢后端，中途关节点
CONC=5 METHOD=POST KILL_MODE=kill  SLOW=3.0 ./scripts/concurrency-failover-test.sh
CONC=5 METHOD=POST KILL_MODE=drain SLOW=3.0 ./scripts/concurrency-failover-test.sh

# 计划内维护（推荐方案）
./scripts/graceful-reboot-infra.sh ingress-lab-worker2  # §5，0 掉 / 0 断连 / 0 reload
./scripts/maintenance-restart.sh   ingress-lab-worker2  # 必须用 LB 标 down 时的完整流程
./scripts/nodeport-vs-ingress-gap.sh ingress-lab-worker2 restart   # 量 GAP

# 分析
python3 scripts/summarize-runs.py /tmp/failover-l4 /tmp/failover-l7-post /tmp/l4-blindspot
python3 scripts/ingress-probe.py join --csvfile /tmp/failover-l4/B.csv --logfile /tmp/failover-l4/B.nginx.log
```

调优参数（`external-nginx.sh` 会传进容器）：

```bash
HC_MODE=l7 HC_INTERVAL=2 HC_FAIL=2 HC_OK=2 HC_TIMEOUT=2 HC_CONNECT_TIMEOUT=500ms ./scripts/external-nginx.sh
```

---

## 文档索引

| 文件 | 内容 |
|---|---|
| **`SWITCHOVER.md`** | 本文：流量切换方案、L4/L7 对比、配置、维护流程、参数推导 |
| [`EVIDENCE.md`](EVIDENCE.md) | 实验台账 T1–T15：假设、方法、数据、结论，以及被后续实验推翻的结论 |
| [`PITFALLS.md`](PITFALLS.md) | 坑清单（唯一一份，按稳定 ID 引用） |
| [`README.md`](README.md) | 环境、拓扑、k8s 侧调度配置（不变量的前半段） |
| `archive/` | 2026-10-14 / 10-15 两份原始报告，按时间追加的旧版本 |
