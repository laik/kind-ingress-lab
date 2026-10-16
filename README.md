# kind + ingress-nginx(Deployment/Local) + 集群外 nginx

> 完整报告见 **`REPORT.md`**（三轮故障演练对比、坑清单、生产落地建议）
> 与 **`REPORT-l4-probe.md`**（L4 探测 vs L7 探测：关掉 infra-node 会不会掉 + infra Deployment 配置逐条理由）。
> 本文件是速查。

本机 Docker/kind 上的 5 节点 k8s。ingress-nginx 用 **Deployment**，通过
**nodeAffinity 定向到 infra-node + topologySpreadConstraints 均匀铺开**，
Service 用 **NodePort + externalTrafficPolicy: Local**（流量进哪个节点就只在该节点的 nginx 里选，绝不跨节点）。
再在 **k8s 外** 跑一个 nginx 充当 L4 LB，upstream 只包含"本节点有 ingress endpoint"的 infra 节点。

```
        Mac 宿主机  curl http://127.0.0.1:8080/
            │
   ┌────────▼──────────────────────────────────┐
   │  nginx-external (普通 docker 容器, kind 网络) │  ← 等价于你的 L4/ECMP 层
   │  容器内 L7 探测 http://<node>:31000/healthz   │     连续 2 次失败摘除 / 2 次成功加回
   │  upstream 成员动态生成 + 自动 reload          │
   └────────┬───────────────────┬───────────────┘
            │ NodePort :31000, externalTrafficPolicy: Local
   ╔════════▼════════════╗  ╔════▼════════════════════╗
   ║ ingress-lab-worker  ║  ║ ingress-lab-worker2     ║   [infra]
   ║  nginx-1 nginx-2    ║  ║  nginx-4 nginx-5        ║
   ║  nginx-3            ║  ║  nginx-6                ║
   ╚════════╤════════════╝  ╚════╤════════════════════╝
            └──────────┬─────────┘
                       ▼  K8s Services (ClusterIP)
              demo/whoami pods (只在 worker3/worker4)

   ingress-lab-worker3 / worker4  [node]          ← 业务负载
   ingress-lab-control-plane      [control-plane]
```

## 四个关键设计点（都在 `ingress-nginx-values.yaml`）

```yaml
controller:
  kind: Deployment
  replicaCount: 6                    # 每 infra-node 3 个：2节点=6, 3节点=9, 4节点=12

  # ① 只跑 infra-node（nodeAffinity 硬约束，不依赖 node name）
  affinity:
    nodeAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        nodeSelectorTerms:
          - matchExpressions:
              - key: node-role.kubernetes.io/infra
                operator: In
                values: ["true"]

  # ② 均匀铺开：3/3/3，不会 7/2/0 或 9/0/0
  topologySpreadConstraints:
    - maxSkew: 1
      topologyKey: kubernetes.io/hostname
      whenUnsatisfiable: DoNotSchedule
      labelSelector:
        matchLabels:
          app.kubernetes.io/name: ingress-nginx
          app.kubernetes.io/component: controller

  tolerations:                       # infra-node 有 NoSchedule taint
    - key: node-role.kubernetes.io/infra
      operator: Exists
      effect: NoSchedule

  service:
    type: NodePort
    externalTrafficPolicy: Local     # ③ 禁止跨 Node 转发
    nodePorts: { http: 31000, https: 31001 }

  podDisruptionBudget:
    enabled: true
  minAvailable: 50%                  # ④ PDB（注意 key 的位置，见坑#9）
```

### 为什么 infra 上的 ingress 要这么配（推理链）

全部配置只服务一个不变量：

> **上游 LB（这里是 nginx-external，生产里是 BGP/ECMP）接流量的每个 Node，本节点必须至少有一个 Ready 的 ingress pod。**

因为 `externalTrafficPolicy: Local` 下，节点没有本地 endpoint 时 kube-proxy 对 NodePort 是 **静默 DROP**
（不是 RST），LB 看到的是“能宣告、但流量进去没声音”。

- **Deployment 而不是 DaemonSet**：DaemonSet 每节点固定 1 副本 → 单 pod 挂 = 该节点 endpoint 归零
  = 整个节点 NodePort 被 DROP，**pod 故障被放大成节点故障**；也要的是滚动升级批次控制 + PDB 生效。
  3 副本/节点时单 pod 挂不影响节点可达（已实测）。
- **replicas = 3×N**：N-1 容量规则，挂一个节点时剩下的节点能吸收流量；infra 增减时由 `scale-infra.sh` 重算。
- **nodeAffinity 硬约束（不按节点名）+ toleration/taint**：角色与物理节点解耦，infra 增减只改 label；
  独占保证 ingress 不和业务抢 CPU/连接表。
- **topologySpread maxSkew=1 + DoNotSchedule**：这是 Local 的硬前提。6 副本堆到 1 个节点（6/0）
  时，另一个节点的 NodePort 直接 DROP，ECMP 均匀送流量 → **一半流量进黑洞**。
  宁可 Pending 也不要不均（代价见坑#8）。
- **ETP=Local**：不跨节点二跳 + 保留 client IP；副作用就是上面的“节点健康 = 本节点有没有 endpoint”，
  所以上四条都是在为它兼底。
- **PDB 50%**：drain/升级不会把某节点（或整个池）归零；用百分比而不是固定数字，infra 扩容时自动跟随。

完整逐条对照（含“不这样配会怎样”）在 `REPORT.md` §2.1.1。

### Service 的两个 traffic policy（互相独立，都要设）

`internalTrafficPolicy` chart 4.15.1 **没有对应 value**（`grep -rn internalTrafficPolicy templates/` 无结果），
用 helm post-renderer 注入，`helm upgrade` 可幂等重放：

```bash
helm upgrade ... --post-renderer ./scripts/post-render-itp.py
```

| 字段 | 作于哪条路径 | 本集群效果 |
|---|---|---|
| `externalTrafficPolicy: Local` | 集群外 → `NodePort` | 流量进哪个 infra-node，只在该节点的 nginx 里选 |
| `internalTrafficPolicy: Local` | 集群内 → `ClusterIP` | 只有 infra-node 上的 pod 能访问 ingress Service；其它节点上直接 DROP |

当前生效值：

```
NAME                      TYPE      ETP     ITP     NODEPORTS
ingress-nginx-controller  NodePort  Local   Local   31000, 31001
```

实测（从不同节点的 pod 访问 ClusterIP `10.96.150.135:80`）：

```
pod on ingress-lab-worker   (infra) -> OK
pod on ingress-lab-worker3  (node)  -> 超时/失败
# worker3 上的规则：
-A KUBE-SERVICES -d 10.96.150.135/32 --dport 80
   -m comment "ingress-nginx/ingress-nginx-controller:http has no local endpoints" -j DROP
```

标签用显式值 `node-role.kubernetes.io/infra=true`，infra-node 增减不影响 Deployment 配置。

## 快速开始

```bash
cd ~/kind-ingress-lab
./scripts/bootstrap.sh                              # 建集群 + 装 ingress + 起外部 nginx
./scripts/scale-infra.sh add    ingress-lab-worker3 # 扩 infra：自动把 replicas 改成 3×N 并等新 endpoint 就绪
./scripts/scale-infra.sh remove ingress-lab-worker3 # 缩 infra：drain + 摘标签 + 重算 replicas
./scripts/scale-infra.sh status                     # 看 infra 节点和 pod 分布
./scripts/external-nginx.sh                         # 重新探测节点健康并重建 upstream
./scripts/teardown.sh
```

## 实测结果

| 验证项 | 结果 |
|---|---|
| 副本分布（2 infra） | `3 / 3` ✅ |
| 扩到 3 infra + 9 副本 | 自动收敛 `3 / 3 / 3` ✅ |
| 跨节点转发 | 打 infra-1 的 20 个请求，全部由该节点 3 个 pod 处理（6/8/6），另一节点 **0** ✅ |
| 无本地 endpoint 的节点 | `172.18.0.5/172.18.0.3/172.18.0.6:31000` 全部不可达（kube-proxy DROP）✅ |
| `internalTrafficPolicy: Local` | infra 节点上的 pod 访问 ClusterIP 通；worker 节点上的 pod 超时（规则为 DROP）✅ |
| 单 pod 故障 | 节点仍有 2 个 endpoint，NodePort 不通告失效 ✅ |
| 节点 drain | PDB 保住 50% 容量，uncordon 后自动回到 3/3 ✅ |

## 故障演练：关掉一个 infra-node

```bash
./scripts/failover-test.sh        # A 基线30s → B 停节点90s（自动摘流）→ C 恢复60s（自动加回）
./scripts/ingress-probe.py analyze --logfile /tmp/failover-l7/B.nginx.log
./scripts/ingress-probe.py join  --csvfile /tmp/failover-l7/B.csv --logfile /tmp/failover-l7/B.nginx.log
```

探测层 / 请求方法可切换：

```bash
HC_MODE=l4 ./scripts/failover-test.sh    # 把探测换成纯 TCP connect（默认 l7）
METHOD=POST ./scripts/failover-test.sh   # 非幂等请求会不会真的掉
./scripts/l4-blindspot-test.sh           # L4 盲区：TCP 通、HTTP 死
```

`ingress-probe.py` 给每个请求带唯一标记 `?probe=<id>`，所以客户端观测能和 nginx 的
`$upstream_addr` 精确对齐（发生重试时它是 `A, B` 逗号分隔）。

三轮对比（5 rps，故障期 450 请求，关 `ingress-lab-worker2`）：

| 配置 | 摘流方式 | 检测耗时 | 状态码 | >1s 长尾 | p50 | **p95** | max |
|---|---|---|---|---|---|---|---|
| ① 只有 nginx 被动健康检查 | `max_fails=3` | **从不摘流** | 200×450 | **32 (7.1%)** | 5ms | **3006ms** | 3034ms |
| ② + L7 探测 (5s/3)，connect 3s | 主动摘 | 18s | 200×450 | 8 (1.8%) | 5ms | **39ms** | 3034ms |
| ③ + L7 探测 (2s/2)，connect 500ms | 主动摘 | ~5s | 200×450 | **0** | 5ms | **19ms** | 509ms |

**p95 从 3006ms 降到 19ms（158×）**，全程零 5xx、零连接失败。

结论：**不会报错，但会有 3 秒长尾**。机制：

1. 死节点的 NodePort 是静默 DROP（坑#4），nginx 必须耗满 `proxy_connect_timeout 3s` 才能失败，
   然后 `proxy_next_upstream` 重试到健康节点 → 客户端拿到 200，但耗时 3006ms。
   关联结果很干净：`172.18.0.7:31000, 172.18.0.2:31000` 链路 n=33 p50=3006ms；
   单跳 `172.18.0.2:31000` n=417 p50=5ms。
2. **nginx 开源版只有被动健康检查，而且是 per-worker 的**。本环境 8 个 worker 进程，
   每个 worker 各自把死节点置冷 15s（`fail_timeout`）后再探一次 → 聚合起来是
   **持续不断**的探测：33 次重试均匀分布在 90s 里，相邻间隔中位数 3s（= connect 超时）。
   所以长尾不会在“节点被标记不可用”后消失，而是贯穿整个故障期。
3. **k8s 侧发现得慢**：`docker stop` 后节点 `Ready=True` 一直持续到 +40s，到 +50s 才变 `Unknown`
   （kubelet lease 未过期）。依赖 k8s 节点/endpoint 状态的 LB 会有 40s+ 盲飞窗口。
4. **L7 主动探测（已实现，`nginx/scripts/healthcheck.sh`）**：容器内循环探测
   `http://<node>:31000/healthz`，判 HTTP 200，连续失败摘除 / 连续成功加回，改写
   `/etc/nginx/upstream/nodeports.conf` 后 `nginx -s reload`。实测时间线：
   ```
   [hc 08:11:37] REMOVE 172.18.0.7:31000  (连续 3 次 /healthz 非 200)
   [hc 08:13:37] ADD    172.18.0.7:31000  (连续 2 次 /healthz 200)
   ```
   两个必须注意的细节：探测**不能带业务 Host 头**（否则被 ingress 规则抢走，拿到的是业务响应）；
   默认 server 里是 `location /healthz { return 200; }`，**body 为空**，只能判状态码。
5. **节点重启后 IP 会变**（172.18.0.4 → 172.18.0.7，docker 重新分配）。
   静态写的 upstream 会失效，LB 必须能重新枚举节点。

对应到生产（BGP/ECMP）：
- `proxy_connect_timeout` 从 3s 降到 300～500ms，长尾代价立刻从 3s 变成亚秒级；
- 用主动健康检查（keepalived / HAProxy / nginx Plus / Envoy outlier detection）而不是 `max_fails`；
- 探测目标用 `healthCheckNodePort`（需 `type: LoadBalancer`）或 NodePort TCP 探测；
- BGP 只宣告“有本地 endpoint 的节点”，且要等 nginx pod Ready 后再宣告。

## L4 探测 vs L7 探测（实测）

**问：用 L4 probe（只 TCP connect `node:31000`）时关掉一个 infra-node，会不会掉**？

答：**不掉**，和 L7 探测完全一致（摘流 +6s，0 个非 200）：

| 探测 | 方法 | 摘流 | 状态码 | 重试 | 重试代价 |
|---|---|---|---|---|---|
| L4 (2s/2) | GET | +6s | 200×450 | 7 (1.6%) | 505–516ms |
| L4 (2s/2) | POST | +6s | 200×300 | 5 (1.7%) | 506–509ms |
| L7 (2s/2) | POST | +6s | 200×300 | 5 (1.7%) | 506–509ms |

原因：死节点的 NodePort 是静默 DROP，**TCP connect 本身就失败** ⇒ 请求根本没发出去 ⇒
nginx 对 GET **和 POST** 都会重试到活节点；代价上限 = `proxy_connect_timeout`（500ms）。

**但 L4 有盲区**（`scripts/l4-blindspot-test.sh`：把 :31000 DNAT 到一个 accept 即关的 TCP sink）：

```
L4 (nc -z)    -> 连接成功       ⇒ 判定【健康】
L7 (/healthz) -> HTTP='<无响应>' ⇒ 判定【不可用】
```

| 探测 | 方法 | 结果 |
|---|---|---|
| L4 | GET | 200×150，但 17.3% 在重试 |
| L4 | POST | **502×9/150（6% 真掉）** —— 请求已发出，非幂等不重试 |
| L7 | POST | 200×150，0 重试（坏节点 6s 内被摘） |

所以 **L4 只能当“最后一道”信号**（节点/端口不可达）。要挡住“三次握手成功但数据面不工作”
（进程 hang、配置/规则没加载完、中间设备只做 proxy、conntrack 黑洞），
至少 L7 探默认 server 的 `/healthz`（不带业务 Host），更好的是探一个带业务 Host 的 canary 路由。

> 同时挖到一个真 bug：候选列表 `kubectl ... > nodes` 非原子重写 → healthcheck 读到空
> → upstream 清空 → `no live upstreams` → 10 个 502。已改成 tmp + `mv` + 空列表保护（坑#16）。

## 闭环并发实测：5 个常驻 client，中途关掉 infra-node

上面是**开环**（5 rps、每请求新建连接、请求几毫秒）——关节点那一刻几乎没有在飞请求。
换成**闭环并发**（`scripts/concurrency-failover-test.sh` + `manifests/slow-backend.yaml`，
5 个常驻 client、持久连接、后端 3s、错开起跑），结论变了：

| 关节点方式 | 方法 | 总请求 | 非 200 | 在飞（5个）中落在死节点的 | 代价 |
|---|---|---|---|---|---|
| `docker stop` | GET | 566 | **0** | 0 | 12 个新请求 +500ms |
| `docker kill`（硬 crash） | GET | 191 | **0** | 2 | 被中断的 2 个重放：总 5.87s / 5.25s |
| `docker kill`（硬 crash） | POST | 193 | **2 × 502（1.0%）** | 2 | 直接 502（2.85s / 2.24s） |
| `kubectl cordon + drain` | POST | 194 | **0** | 2 | **无**（最长 3.016s，与基线一致） |

所以：

1. **会不会掉，首先取决于“怎么关节点”**：硬 crash 会在飞的请求真掉（非幂等 → 502）；
   drain 则一个都不掉（endpoint 先摘、在飞请求优雅跑完）。
2. **幂等性决定第事项**：同一个被切断的在飞请求，GET 被重放（+2.2～2.9s），POST 直接 502。
3. **`least_conn` 是 per-worker 的**：5 个同步起跑的 client 会被整批送到同一个节点（实测按批交替 .2/.6），
   爆炸半径“全中或全不中”——必须 `--stagger` 错开，否则测不准（坑#18）。
4. **摘流 reload 自会打断极少量客户端 keepalive**：两次运行各 1 次 `RemoteDisconnected`（0ms，
   服务端无日志），时间戳正好是 `[hc] … reload nginx`（坑#19）。

```bash
CONC=5 METHOD=POST KILL_MODE=kill  SLOW=3.0 ./scripts/concurrency-failover-test.sh
CONC=5 METHOD=POST KILL_MODE=drain SLOW=3.0 ./scripts/concurrency-failover-test.sh
CONC=5 METHOD=POST KILL_MODE=restart SLOW=1.0 ./scripts/concurrency-failover-test.sh  # 重启→ 502
```

**重启（restart）一台 infra 为什么 nginx 会 502**（实测 589 请求中 3 个 502，L4/L7 探测结果相同）：
error_log 里只有 `upstream prematurely closed connection while reading response header` 这一类会变成 502
——请求**已经发到那台节点**，连接被中途关掉，非幂等请求 nginx 不重试。数量 ≈ 在飞请求数 × 1/N。
而 `connect() failed (111: Connection refused)`（restart 时 kube-proxy 规则已撤但 IP 还在→RST）和
`upstream timed out while connecting` 都**不会**造成 502，因为请求没发出去，会换一台重发。
→ 要消除：重启前先 `cordon + drain`（实测 0 掉），或者客户端带幂等键对 502 重试。

**避免它的正确顺序**（`scripts/graceful-restart-infra.sh <node> [pre-drain]`，已实测）：

```bash
# cordon → 从 LB/BGP 摘掉这个节点 → 等 PRE_DRAIN（> 业务最长请求时间）→ drain → restart → 加回
CONC=5 METHOD=POST KILL_MODE=graceful SLOW=1.0 PRE_DRAIN=15 ./scripts/concurrency-failover-test.sh
```

| 方式 | 请求 | 非 200 |
|---|---|---|
| `docker restart` | 589 | **3 × 502（0.5%）** |
| `graceful-restart-infra.sh` | 723 | **0**（最长请求 1.017s，与基线一致） |

核心只有一句：**在“没有任何在飞请求指向该节点”之后，才去关它**。

### NodePort 与 ingress-nginx 的 GAP（实测）

`./scripts/nodeport-vs-ingress-gap.sh ingress-lab-worker2 restart` —— 每秒同时采样
tcp / `healthz` / 业务路由 / k8s endpoint，四条时间线确实对不上：

```
08:21:34  --      ---   ---      podsReadyOnNode=3 localEndpoints=3   ← 数据面已死，控制面还说有 endpoint（GAP-1 ≈5s）
08:21:42  --      ---   ---      podsReadyOnNode=0 localEndpoints=0
08:22:16  --      200   200      podsReadyOnNode=0 localEndpoints=0   ← 数据面已可用，控制面还没 Ready（GAP-2 ≈5s）
08:22:21  TCP-OK  200   200      podsReadyOnNode=3 localEndpoints=3
```

| GAP | 实测 | 后果 |
|---|---|---|
| 下线：NodePort 已黑，endpoint 还在 | ≈5s | 按 k8s endpoint/node 状态导流的 LB 往黑洞送 5s 流量 |
| 上线：ingress 已能服务，endpoint 还没出 | ≈5s | 按 endpoint 加回会晚 5s；按探测加回更快且当时确实可用 |
| 数据面黑窗 | **42s** | 靠探测只能缓解；在飞请求仍会变 502 |

应对：① LB 探测**直接探 NodePort**（不信 k8s 状态）；② 摘流快、加回慢（OK_MAX + hold-down，叠加 pod Ready）；
③ 重启走 graceful；④ 生产上换成 `type: LoadBalancer` + BGP 宣告 + `healthCheckNodePort`，
把“靠超时探测”变成“靠控制面事件”，GAP-1 从 5s 降到亚秒级。

### 20 并发放大：去掉“LB 预摘流”会怎样？

`CONC=20 METHOD=POST SLOW=1.0`，每轮 ~4000 请求，关节点瞬间 19 个在飞：

| 做法 | 总请求 | **502** | 客户端连接被断 | reload |
|---|---|---|---|---|
| 直接 `docker restart` | 3447 | **12** | 3 | 3 |
| cordon→等15s→drain→restart（**不做 LB 预摘流**） | 3982 | **0** | 3 | 3 |
| cordon→LB 预摘流→等15s→drain→restart | 3981 | **0** | **8** | **5** |

→ **救回在飞请求的是 drain，不是 LB 摘流**。没预摘流时 LB 被动摘流要 22s，但 drain 让 NodePort 回的是
**RST（connection refused）**⇒ 毫秒级失败 + 自动重发，客户端无感。反而预摘流多两次 reload，
客户端连接被断从 3 涨到 8。
→ 但一旦没有 drain（硬 restart），NodePort 是静默 DROP，19 个在飞里就有 ~10 个变 502。
→ 预摘流仍然需要的场景：不能 drain / 摘流信号是 DROP 而不是 RST / LB 动态摘除成本高（BGP 撑销慢）。

### LB 不可控时：在节点侧自己摘流（实测最优）

`./scripts/graceful-reboot-infra.sh <node> [wait-conn-seconds]`

```
cordon → 节点侧摘流(nat DNAT 到死端口 ⇒ RST) → 等 conntrack 连接数=0 → drain → reboot → uncordon
```

两个坑（实测踩过）：
1. **摘流必须在 drain 之前**；`cordon` 本身不停流量，先“等排空”是等不到的。
2. **REJECT 规则放在 filter INPUT 上是空操作**：kube-proxy 的 DNAT 在更早的 nat PREROUTING，
   只要节点还有本地 endpoint，包到 INPUT 时 dport 已变成 podIP:80。REJECT 放 mangle PREROUTING
   又被内核拒。可用形式：
   ```bash
   iptables -t nat -I PREROUTING 1 -p tcp --dport 31000 -j DNAT --to-destination <nodeIP>:1
   ```
   计数用 `conntrack -L -p tcp --dport 31000 | grep -c ESTABLISHED`（`ss` 不行，NodePort 没本地 socket）。

实测（CONC=20、POST、5611 请求）：**0 个 502、0 个 upstream 错误**，LB 摘流从 22s 降到 **4s**；
代价只有 7 个客户端连接被 LB 自己的 reload 打断（开源 nginx 做 LB 的固有代价，与节点侧无关）。

### nginx LB 侧加什么配置能减少这类问题

**① 最关键：限制上游 keepalive 连接的寿命**（已写进本实验的 `nginx.conf.tmpl`）

```nginx
upstream k8s_ingress_nodeport {
    least_conn;
    include /etc/nginx/upstream/nodeports.conf;
    keepalive          64;
    keepalive_time     10s;   # ← 连接最长活 10s（nginx ≥1.15.3）
    keepalive_requests 20;    # ← 每条连接最多 20 个请求就重连
}
```

为什么：实测发现**静态池下节点侧摘流根本无效** —— LB 一直复用旧连接，
插了摘流规则后 conntrack 计数 **70s 不降**；加上这两行后 **12s 归零**。
关掉主动摘流（`HC_ENABLED=0`）重测：1440 请求全 200，49 次 refused 全部秒级重试（代价 ~20ms），
**0 次 reload、0 个客户端连接被断**。

**② 超时与重试边界**

```nginx
proxy_connect_timeout  500ms;   # 3s → p95=3006ms；500ms → p99=507ms
proxy_read_timeout     10s;     # 不要留默认 30s（半开连接会卡 30s）
proxy_next_upstream    error timeout http_502 http_503 http_504;
proxy_next_upstream_tries   2;
proxy_next_upstream_timeout 5s; # ⚠ 必须 > 业务最长正常响应时间（建议 ≥2×），否则重试会被这个预算掉，反而把可重试的失败变成 502
```

**③ 如果用主动摘流**：滞回（2 次失败才摘 / 2-3 次成功才加 + hold-down ≥30s）、
池子永不为空、成员文件原子替换、`worker_shutdown_timeout 30s` —— 因为每次 reload
都会打断 3～8/5000 个客户端 keepalive 连接。

**④ `max_fails` 是 per-worker 的**：已有主动摘流就 `max_fails=0` 关掉它（否则会有持续探测噪声）。

### 维护窗口：在 LB 里把 upstream 标 down 再重启节点

```bash
./scripts/lb-mark.sh <node-ip> down|up|status|rollback [备份文件]   # 带备份/语法校验/自动回滚
./scripts/maintenance-restart.sh <node> [wait-conn-seconds]        # 完整流程
```

关键事实：`down` 是**静态参数**，开源 nginx 没有运行时 API（Plus 才有），所以标 down 必然 = 改文件 + reload。
正确顺序（实测 0 个 502 / 5607 请求）：

```
LB 标 down → 等连接排空 → 节点侧兜底摘流 → cordon+drain → reboot
→ 等 Ready → 先 uncordon → 等 pod Ready → LB 标 up
```

两个最容易出事故的地方（都实测踩过）：
1. **“不能把最后一个可用节点标 down”的检查，必须在写人工下线名单之前**。
   顺序反了 → 健康检查按名单把两个节点全标 down → **入口直接 502**。
2. **两个写入者要合并**：维护脚本写的 `down` 会被容器内健康检查下一轮覆盖。
   做法：健康检查读 `manual_down.list` 并输出 `down`；且当可用节点为 0 且由人工下线造成时
   **拒绍应用**（除非 `touch force_all_down`）。

## 最终推荐方案（§4J，实测 0 掉 / 0 客户端断连 / 0 reload）

思路：**计划内维护在节点侧摘流（不碰 LB、不 reload）；主动摘流只留给非计划故障，
并在维护期间用 `manual_hold.list` 抑制它**。

```bash
# 计划内维护（唯一需要记的命令）
./scripts/graceful-reboot-infra.sh <node> [wait-conn-seconds]
# cordon → 写 manual_hold + 节点侧 nat 摘流(RST) → 等 conntrack=0 → drain
# → reboot → 等 Ready → 先 uncordon → 等 /healthz 连续 2 次通过 → 解除 hold
```

实测对比（CONC=20、POST、后端 1s、~5600 请求）：

| 方案 | 计划内 502 | 客户端断连 | reload | 非计划 502 | 非计划长尾 |
|---|---|---|---|---|---|
| 直接 restart | 12 | 3 | 2 | — | — |
| cordon+drain | 0 | 3 | 2 | — | — |
| LB 预摘流 | 0 | 8 | 2 | — | — |
| 纯节点侧（LB 自动摘） | 0 | 7 | 2 | ~10 | 短 |
| LB 标 down | 0 | 6 | 3 | — | — |
| 静态池 + keepalive_time + 节点侧摘流 | 0 | 0 | 0 | 8 | **长**（96 次 500ms） |
| **推荐：上面 + 保留主动摘流、维护期抑制** | **0** | **0** | **0** | ~10 | 短（8s 摘除） |

调优发现：`max_fails=1 fail_timeout=5s` 下“等连接排空”10s，`max_fails=3 fail_timeout=15s` 要 20s；
**不要在 reboot 前删节点侧规则**（会留下 kube-proxy DROP 黑洞窗口）。

> 以上结论在 **CONC=100（~90 rps、28017 请求）** 上复测成立：0 个 502、0 个 >2s、
> 关节点在飞的 88 个请求全部 200；LB 标 down/up 只造成 12 个（0.043%）客户端连接被断，
> 且全部“请求未到达后端”⇒ 重试安全。详见 `REPORT-l4-probe.md §4K`。


## 坑（重要，都是实测出来的）

1. **kind 配置里的 `labels:` 不能打 `node-role.kubernetes.io/*`** —— 它会注入 kubelet `--node-labels`，
   kubelet 对 `kubernetes.io` 命名空间有白名单，结果 kubelet 直接退出，`kind create cluster` 卡在
   `kubelet-wait-bootstrap`，报错还很误导人（"required cgroups disabled"）。→ 集群起来后用 `kubectl label`。
2. **`kubectl taint ... --overwrite` 是"加"不是"删"**；删 taint 用 `kubectl taint node X key:NoSchedule-`。
3. **`healthCheckNodePort` 在 `type: NodePort` 上不可用**，API 直接拒绝：
   `may only be set when type is 'LoadBalancer' and externalTrafficPolicy is 'Local'`。
   → NodePort 方案里，LB 只能自己探测 NodePort（见下一条）。
4. **无本地 endpoint 的节点是 `-j DROP`，不是 REJECT**：
   ```
   -A KUBE-EXTERNAL-SERVICES ... --dport 31000
      -m comment "ingress-nginx/...:http has no local endpoints" -j DROP
   ```
   客户端只会看到 SYN 超时（不是 connection refused）。所以上游 LB/BGP 的健康检查必须是
   **带 connect 超时的探测**，且新 infra-node 在 nginx pod Ready 之前不能导流。
   `nginx/scripts/healthcheck.sh` 就是按这个规则做 L7 探测 + 自动摘流的。
5. **`externalTrafficPolicy: Local` 会让 `127.0.0.1:31000` 失效**：kind 的 `extraPortMappings` 只能绑
   control-plane，而 control-plane 上没有本地 ingress endpoint → 连接超时。
   宿主机访问必须走集群外 nginx（:8080），或直连 infra 节点 IP。
6. **`172.18.0.x` 从 Mac 宿主机不可达**（Docker Desktop 的 Linux VM 内部）。所以集群外 nginx 必须是
   **容器并加入 `kind` 网络**。若用 brew 装的原生 nginx，upstream 只能写 `127.0.0.1:31000`（且受坑#5 限制）。
7. **必须透传 Host 头**（`proxy_set_header Host $ingress_host`），否则 ingress 匹配不到 rule，一律 404。
8. **`whenUnsatisfiable: DoNotSchedule` 与 drain 的相互作用**：2 个 infra-node、6 副本时 drain 其中一个节点，
   被驱逐的 3 个 pod 会一直 **Pending** —— 因为放到另一个节点会变成 6/0，skew=6 > maxSkew=1。
   实测：drain 本身能完成，PDB 保住 3 个可用（50%），uncordon 后自动恢复 3/3。
   如果希望维护期间保持满副本，把 `whenUnsatisfiable` 改成 `ScheduleAnyway`（软约束），
   代价是维护窗口内分布不均。
9. **chart 4.15.1 的 PDB 阈值取 `controller.minAvailable`**，写在 `controller.podDisruptionBudget.minAvailable`
   下会被静默忽略（渲染成默认值 1）。`podDisruptionBudget.enabled` 只负责开关。
10. kind 不能自定义节点名，infra 节点物理名是 `ingress-lab-worker`/`worker2`，角色只靠 label/taint 区分。
11. **`internalTrafficPolicy: Local` 会掉断集群内的 hairpin 调用**：任何从非 infra 节点发出的、
    访问 ingress Service ClusterIP / DNS 名的流量都会被 DROP（不是 RST，是静默超时）。
    常见踩坑：集群内应用“绕一圈自己的 ingress”、集群内监控/脚本探测 ingress、
    或把 ingress 当集群内东西向入口。需要这些路径的话，要么给探测任务加 `nodeSelector` 到 infra 节点，
    要么单独建一个 `internalTrafficPolicy: Cluster` 的 Service。
    （ingress-nginx 的 admission webhook 和 metrics 是另外的 Service，没动，不受影响。）
12. **节点重启后 IP 会变**：实测 `docker stop/start ingress-lab-worker2` 后 172.18.0.4 → 172.18.0.7
    （docker 重新分配）。静态写的 upstream 会失效，LB 必须能重新枚举节点（`scripts/external-nginx.sh`）。
13. **解析 nginx access log 时 `$upstream_addr` 在重试时是 `A, B`（含空格）**，用 `\S+` 会把重试请求
    整条日志漏掉 —— 第一版工具因此得出“重试 0 次”的错误结论。
14. **集群外 nginx 被重建（`docker rm -f`）时，故障期的日志会一起消失** → 演练必须每阶段快照日志。
15. **upstream 里放 IPv6 需要 `[::1]:port` 语法**。dual-stack 集群下把 InternalIP 全塞进去会让
    `nginx -s reload` 一直失败（只取 IPv4）。
16. **候选节点列表不能 `kubectl ... > nodes` 直接覆写**：重定向会先把文件截断成 0 字节，
    容器里的 healthcheck 读到空 → 生成空 upstream → `no live upstreams` → 全量 502（实测 10 个）。
    必须 `>.nodes.tmp && mv`（已修），healthcheck 也加了“空列表跳过本轮”的保护。
17. **L4 探测分不清“端口通”和“数据面通”**（见上面“L4 探测 vs L7 探测”）。
    同时注意 nginx 重试语义：**connect 失败**（请求没发出去）GET/POST 都会重试；
    **请求已发出**后只有幂等方法重试 —— 这就是同一故障下 GET 不掉、POST 掉 502 的原因。
18. **`least_conn` 是 per-worker 的**：8 个 worker + 5 个同步 client ⇒ 每个 worker 都看到“两台都 0 连接”，
    整批请求全落同一个 upstream（实测按批交替 .2/.6/.2）。并发压测必须 `--stagger` 错开起跑，
    否则“关节点会切到几个在飞请求”完全是 0 或 N，测不出真实爆炸半径。
19. **`nginx -s reload` 不是对客户端 100% 无损**：实测在摘流/加回 reload 那一秒各出现 1 次
    `RemoteDisconnected: Remote end closed connection without response`（0ms，access log 里没这个请求）。
    开源 nginx 没有不 reload 的后端池；摘流越频繁这个概率越高。要彻底避开就得用
    HAProxy/Envoy 这类动态后端。

## 与你的 Antrea + BGP/ECMP 方案的对应关系

| 本实验里的东西 | 你生产环境里的对应物 |
|---|---|
| `nginx-external` 容器 + 探测式 upstream | BGP/ECMP 宣告 + 健康检查 |
| `nc -z -w2 <node>:31000` 探测 | 应换成对 NodePort 的 TCP connect 超时探测，或 `healthCheckNodePort`（需 LB 类型）|
| `topologySpreadConstraints` | 同样适用，保证每个 infra-node 都有 nginx |
| `externalTrafficPolicy: Local` | 同样适用，禁止跨节点跳转、保留客户端 IP |

真实环境里更干净的做法：把 ingress Service 做成 `type: LoadBalancer` + Antrea BGP 宣告，
这样 `healthCheckNodePort` 可用，LB 能拿到明确的 200/403 而不是靠超时判断。
