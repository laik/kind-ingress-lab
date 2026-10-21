# 最优方案：G（静态成员池 + L7 canary 主动摘流，维护期节点侧摘流并抑制 LB）

> 从 `REPORT.md` 提炼的唯一推荐方案。实测（S6）：3020 请求 / 0 个非 200 / 0 个连接被断 / 维护期 0 次 reload。
>
> 适用前提：ingress 为 `NodePort` + `externalTrafficPolicy: Local`，上游 LB 自行探测 NodePort（非 k8s endpoint 驱动）。

---

## 0. 三层分工

| 层 | 职责 | 手段 |
|---|---|---|
| LB | 新请求不再进这个节点 | L7 canary 主动探测 + 防抖摘流 |
| k8s | 已经在飞的请求不被切 | drain + 优雅终止 |
| 节点 | 计划内维护时把黑洞变成 RST | nat PREROUTING 开头 DNAT 到死端口 |

缺任何一层都会掉请求。

---

## 1. LB 探测与参数

**探测用 L7 canary，不要用 L4，也不要用默认 `/healthz`。**

默认 `/healthz` 只证明「节点可达 + 有本地 endpoint + nginx 进程活着」，不证明业务规则已 sync；业务路由坏掉时它照样 200。canary 走真实 server → location → upstream 链路，能当场发现这类故障。

```sh
HC_MODE=l7 \
HC_HOST=canary.demo.local \
HC_PATH=/healthz \
HC_INTERVAL=2 HC_FAIL=2 HC_OK=2 HC_TIMEOUT=2 \
HC_CONNECT_TIMEOUT=500ms \
./scripts/external-nginx.sh

kubectl apply -f manifests/canary-ingress.yaml   # 探测目标
```

- canary 必须是**专用、无副作用、固定 200** 的路由，不要用真实业务接口，否则后端故障会被误判为节点故障。
- L4 探测（`HC_MODE=l4`）只保留做排障对照，不用于生产决策。

推导：

```
摘流耗时 ≈ fail × interval + probe_timeout = 2×2+2 = 6s
加回耗时 ≈ 恢复时刻 + ok × interval          = +3s
单请求最大代价 ≈ proxy_connect_timeout        = 500ms
```

想更快：`interval=1 fail=2 probe_timeout=1` → 约 3s 摘流、300ms 代价上限，但探测流量和误摘风险上升（L4 若用 busybox `nc`，超时下限为 1s）。

---

## 2. nginx LB 配置

```nginx
upstream k8s_ingress_nodeport {
    least_conn;
    include /etc/nginx/upstream/nodeports.conf;  # 原子替换，永不为空
    keepalive 64;
    keepalive_time     10s;   # 必需：不限制上游连接寿命，节点侧摘流就是空操作
    keepalive_requests 20;
}

server {
    location / {
        proxy_pass http://k8s_ingress_nodeport;
        proxy_http_version 1.1;
        proxy_set_header Connection "";
        proxy_set_header Host $ingress_host;     # 必须透传，否则一律 404

        proxy_connect_timeout        500ms;
        proxy_send_timeout           5s;
        proxy_read_timeout           10s;
        proxy_next_upstream          error timeout http_502 http_503 http_504;
        proxy_next_upstream_tries    2;          # 限制故障期流量放大
        proxy_next_upstream_timeout  5s;         # 必须 ≥ 2× 业务最长正常响应时间
    }
}

worker_shutdown_timeout 30s;
```

- `max_fails` 设为 **0**：它是被动且 per-worker 的，和主动摘流叠加只会制造持续探测噪声。
- 成员列表必须 **tmp + `mv` 原子替换**；禁止 `kubectl ... > nodes`（先截断成 0 字节 → 空 upstream → 全量 502）。
- 单一写入者：维护脚本只写名单，落盘 + reload 只由健康检查做。
- 安全阀：`manual_down.list`（人工下线）、`manual_hold.list`（维护中冻结）、`force_all_down`（允许清空入口的显式开关）；「不能摘掉最后一个可用节点」的检查必须在写名单**之前**。

---

## 3. k8s 侧不变量

| 配置 | 值 | 目的 |
|---|---|---|
| workload | `Deployment` | 副本数可控、PDB 生效；单 pod 故障不放大成节点故障 |
| `replicaCount` | `3 × N(infra)` | N-1 容量 |
| 调度 | `nodeAffinity` 硬约束 infra label + `NoSchedule` toleration | 角色与节点名解耦，infra 独占 |
| 拓扑 | `topologySpreadConstraints` `maxSkew=1` / `DoNotSchedule` | 每个 infra 节点都有 endpoint，否则该节点 NodePort 被 DROP |
| Service | `NodePort` 31000/31001 + `externalTrafficPolicy: Local` | 不跨节点二跳、保留真实 IP |
| 内部流量 | `internalTrafficPolicy: Local`（post-renderer 注入） | 集群内也只由 infra 节点服务 |
| PDB | `controller.minAvailable: 50%` | 写错位置会被静默忽略 |
| 优雅终止 | `terminationGracePeriodSeconds: 30` | 与 LB 摘流时间（~6s）对齐 |

---

## 4. 计划内维护（唯一推荐流程）

```bash
./scripts/graceful-reboot-infra.sh <node> [wait-conn-seconds]
```

```
[1] cordon                              防止新 pod 调上来
[2] 写 manual_hold.list                 告诉 LB：维护中，不探测、不摘、不加
    节点侧 nat 摘流（把黑洞变 RST）
[3] 等 conntrack 连接数 = 0             在飞请求排空
[4] drain --grace-period=60             endpoint 先摘，在飞请求跑完
[5] reboot                              此时已无在飞请求指向该节点
[6] 等节点 Ready
[7] 先 uncordon                         cordon 状态下 pod 永远 Pending
[8] canary 连续 2 次通过 → 解除 hold     加回要慢
```

节点侧摘流（**必须插在 nat PREROUTING 第 1 条**，抢在 kube-proxy 的 jump 之前）：

```bash
iptables -t nat -I PREROUTING 1 -p tcp --dport 31000 -j DNAT --to-destination <nodeIP>:1
iptables -t nat -I PREROUTING 1 -p tcp --dport 31001 -j DNAT --to-destination <nodeIP>:1

conntrack -L -p tcp --dport 31000 | grep -c ESTABLISHED   # 数连接：不能用 ss（NodePort 是 DNAT，节点上没有 :31000 本地 socket）
conntrack -D -p tcp --dport 31000                          # 强制关闭：下一个包重走 nat 规则 ⇒ RST
```

三个必须记住的约束：

1. **不要用 `REJECT`**：放 filter INPUT 是空操作（DNAT 已经发生），放 mangle PREROUTING 会被内核拒绝。唯一可用形式是 DNAT 到没人监听的端口。
2. **不要在 reboot 前删 nat 规则**：规则随 netns 消失；提前删会留下 kube-proxy DROP 的黑洞窗口。
3. **不要在这套拓扑里做 LB 预摘流**：drain 会让 NodePort 立刻回 RST，LB 3s 内自己就摘了。预摘流只是多两次 reload，客户端断连从 3 涨到 8。

仅当命中以下任一条时，才保留完整 LB 预摘流步骤：

- 不能 drain（必须硬关机 / 重启操作系统）；
- 摘流信号是静默 DROP 而不是 RST（没 drain，或 Service 不是 Local）；
- LB 动态摘除成本高（BGP 撤销慢、reload 慢、探测间隔大）。

---

## 5. 非计划 crash

crash 一定会切在飞请求，只能压小代价：

| 措施 | 作用 |
|---|---|
| 保留主动摘流（L7 canary，2s/2） | 8s 内摘除，影响限制在几秒而不是整个故障期 |
| 写接口带 `Idempotency-Key` | 让「后端已处理但客户端不知道」可安全重试 |
| 客户端对 502/504 重试 | 唯一能真正归零的办法 |
| 增加 infra 节点数 | 爆炸半径 = 在飞请求数 × 1/N |

不要无脑加 `proxy_next_upstream ... non_idempotent`：能吞掉错误，但可能重复执行。

---

## 6. 生产映射（Antrea + BGP/ECMP）

- **探测 NodePort 本身，不要依赖 k8s endpoint / node 状态**：实测两个方向各约 5s GAP，数据面黑窗 42s。
- `healthCheckNodePort` 仅在 `type: LoadBalancer` 可用；NodePort 方案下 LB 必须自己探测。
- 节点侧 nat 摘流对应「撤 BGP 宣告」，目的相同：让流量毫秒级失败而不是进黑洞。
- BGP 宣告变更没有「杀客户端连接」的代价；开源 nginx 的 reload 有这个代价，所以才需要第 4 节的流程。

---

## 7. 验收标准

| 指标 | 通过线 |
|---|---|
| 502/504 | 0 |
| >2s 请求 | 0 |
| 关节点时在飞请求 | 全部 200，延迟与基线一致 |
| 客户端连接被断 | ≤ 0.05%，且全部「请求未到达后端」 |
| p99 | 与基线一致 |

只看状态码不够：必须同时看**重试次数**（`$upstream_addr` 含逗号）和**连接被断数**（status=0 / `RemoteDisconnected`）。重试是「没掉但付了代价」的唯一可见信号。

判定一个请求是否「重试安全」：客户端 CSV → LB access log → ingress 控制器日志，三边对齐；只有三边都查不到，才是「请求未发出 ⇒ 重试安全」。注意 probe id 会跨轮次重名，必须按时间戳过滤。

---

## 8. 不要做的事

| 做法 | 后果 |
|---|---|
| 用 L4 TCP 探测做生产决策 | 「TCP 通、数据面死」时完全失明，POST 直接 502 |
| 只探默认 `/healthz` | 业务路由坏掉 / 规则没 sync 时看不见，请求卡满 read timeout |
| 依赖 k8s endpoint / node 状态摘流 | 两端各约 5s GAP，期间持续往黑洞送流量 |
| LB 预摘流（本拓扑的计划内维护） | 净成本：多 reload、断连更多 |
| reboot 前删节点侧 nat 规则 | 留下 DROP 黑洞窗口 |
| 非原子重写成员列表 | 空 upstream → 全量 502 |
| 只看 5xx 做验收 | 漏掉「0 错误但 p99 暴涨 / 大量重试」 |
