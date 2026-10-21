# 流量优雅切换方案

| 项目 | 内容 |
|---|---|
| 版本 | 1.0 |
| 日期 | 2026-10-21 |
| 适用环境 | Kubernetes + ingress-nginx（NodePort，externalTrafficPolicy: Local） |
| 上游负载均衡 | 自建 nginx（L7 探测）；生产为 Antrea + BGP/ECMP 时见第 7 章 |

---

## 1. 方案概述

### 1.1 目标

节点下线、重启或故障时，满足：

- 新请求不进入不可用节点；
- 已建立的在飞请求不被中断；
- 节点恢复后，不早于其具备服务能力时加回流量。

### 1.2 分层职责

| 层次 | 职责 | 实现 |
|---|---|---|
| 负载均衡层 | 新请求不再进入故障节点 | L7 canary 主动探测、防抖摘流 |
| Kubernetes 层 | 在飞请求不被切断 | cordon、drain、优雅终止 |
| 节点层 | 计划内维护时将静默丢包转为 RST | nat PREROUTING DNAT 至无效端口 |

三层须同时具备，缺任一层均会产生请求失败。

### 1.3 核心原则

1. 探测对象为 NodePort 本身，不以 Kubernetes Endpoint 或 Node 状态作为摘流依据。
2. 计划内维护在节点侧摘流，维护期间冻结负载均衡自动摘流，避免 reload。
3. 非计划故障无法消除在飞请求损失，仅能压缩影响范围与单次代价。

---

## 2. 健康探测

### 2.1 探测方式

采用 L7 canary 探测。探测请求携带业务 Host，经真实 server、location、upstream 链路返回。

| 探测方式 | 能力范围 |
|---|---|
| L4 TCP | 仅能发现节点不可达、无本地 endpoint；无法发现进程假死及数据面故障 |
| L7 默认 `/healthz` | 可发现节点与进程故障；无法发现业务规则未同步、业务路由故障 |
| L7 canary | 覆盖上述全部故障类型，为生产采用方式 |

L4 探测仅用于排障对照，不参与生产摘流决策。

### 2.2 探测配置

```sh
HC_MODE=l7 \
HC_HOST=canary.demo.local \
HC_PATH=/healthz \
HC_INTERVAL=2 HC_FAIL=2 HC_OK=2 HC_TIMEOUT=2 \
HC_CONNECT_TIMEOUT=500ms \
./scripts/external-nginx.sh
```

探测目标：

```bash
kubectl apply -f manifests/canary-ingress.yaml
```

canary 路由须为专用、无副作用、固定返回 200 的接口，不得使用真实业务接口。

### 2.3 时序参数

| 参数 | 取值 | 含义 |
|---|---|---|
| interval | 2s | 探测间隔 |
| fail | 2 | 连续失败次数达此值摘流 |
| ok | 2 | 连续成功次数达此值加回 |
| probe_timeout | 2s | 单次探测超时 |
| connect_timeout | 500ms | 单个请求连接超时上限 |

推导：

```
摘流耗时 = fail × interval + probe_timeout = 6s
加回耗时 = 恢复时刻 + ok × interval = +3s
单请求最大代价 = proxy_connect_timeout = 500ms
```

---

## 3. 负载均衡配置

### 3.1 upstream

```nginx
upstream k8s_ingress_nodeport {
    least_conn;
    include /etc/nginx/upstream/nodeports.conf;
    keepalive 64;
    keepalive_time 10s;
    keepalive_requests 20;
}
```

`keepalive_time` 与 `keepalive_requests` 为节点侧摘流生效的前提，不得省略。

### 3.2 代理参数

```nginx
server {
    location / {
        proxy_pass http://k8s_ingress_nodeport;
        proxy_http_version 1.1;
        proxy_set_header Connection "";
        proxy_set_header Host $ingress_host;

        proxy_connect_timeout        500ms;
        proxy_send_timeout           5s;
        proxy_read_timeout           10s;
        proxy_next_upstream          error timeout http_502 http_503 http_504;
        proxy_next_upstream_tries    2;
        proxy_next_upstream_timeout  5s;
    }
}

worker_shutdown_timeout 30s;
```

约束：

1. `Host` 必须透传，否则 ingress 无法匹配规则。
2. `proxy_next_upstream_timeout` 须不小于业务最长正常响应时间的 2 倍。
3. `max_fails` 设为 0，避免与主动摘流叠加产生持续探测噪声。
4. `worker_shutdown_timeout` 设为 30s，防止旧 worker 长期驻留。

### 3.3 成员管理

| 约束 | 要求 |
|---|---|
| 写入 | 单一写入者；维护脚本仅写名单，落盘与 reload 由健康检查统一执行 |
| 替换 | 临时文件写入后 `mv` 原子替换；禁止直接重定向覆盖 |
| 保护 | 摘除前校验剩余可用节点数，不得摘除最后一个可用节点 |
| 名单 | `manual_down.list` 人工下线；`manual_hold.list` 维护期冻结；`force_all_down` 显式清空开关 |

---

## 4. Kubernetes 配置

| 配置项 | 取值 | 说明 |
|---|---|---|
| 工作负载 | Deployment | 副本数可控，支持 PDB 与分批滚动 |
| 副本数 | 3 × infra 节点数 | 满足 N-1 容量 |
| 调度 | nodeAffinity 硬约束 infra 标签 + NoSchedule toleration | infra 独占，角色与节点名解耦 |
| 拓扑约束 | maxSkew=1，DoNotSchedule | 每个 infra 节点均有本地 endpoint |
| Service 类型 | NodePort 31000/31001 | 上游 LB 使用固定端口 |
| externalTrafficPolicy | Local | 不跨节点转发，保留客户端 IP |
| internalTrafficPolicy | Local（post-renderer 注入） | 集群内流量同样仅由 infra 节点服务 |
| PDB | controller.minAvailable: 50% | 自愿中断保留半数容量 |
| 优雅终止 | terminationGracePeriodSeconds: 30 | 覆盖 LB 摘流时长 |

配置依据：externalTrafficPolicy 为 Local 时，无本地 endpoint 的节点对 NodePort 静默丢包。上述约束确保节点健康状态与本地 endpoint 存在性一致。

---

## 5. 计划内维护流程

### 5.1 流程

执行：

```bash
./scripts/graceful-reboot-infra.sh <node> [wait-conn-seconds]
```

| 步骤 | 操作 | 目的 |
|---|---|---|
| 1 | cordon | 阻止新 Pod 调度至该节点 |
| 2 | 写入 manual_hold.list；节点侧 nat 摘流 | 冻结 LB 自动摘流；将丢包转为 RST |
| 3 | 等待 conntrack 连接数为 0 | 在飞请求排空 |
| 4 | drain --grace-period=60 | 摘除 endpoint，等待在飞请求完成 |
| 5 | reboot | 此时无在飞请求指向该节点 |
| 6 | 等待节点 Ready | — |
| 7 | uncordon | cordon 状态下 Pod 无法就绪 |
| 8 | canary 连续 2 次通过后解除 hold | 延迟加回 |

### 5.2 节点侧摘流

```bash
iptables -t nat -I PREROUTING 1 -p tcp --dport 31000 -j DNAT --to-destination <nodeIP>:1
iptables -t nat -I PREROUTING 1 -p tcp --dport 31001 -j DNAT --to-destination <nodeIP>:1

conntrack -L -p tcp --dport 31000 | grep -c ESTABLISHED
conntrack -D -p tcp --dport 31000
```

规则须插入 nat PREROUTING 首条，优先于 kube-proxy 规则。连接数统计使用 conntrack，不使用 `ss`。

### 5.3 约束

1. 不得使用 REJECT 实现摘流。REJECT 置于 filter INPUT 不生效，置于 mangle PREROUTING 被内核拒绝。
2. reboot 前不得删除 nat 规则。规则随 netns 消失；提前删除将产生 kube-proxy 丢包窗口。
3. 本拓扑下计划内维护不执行 LB 预摘流。drain 后 NodePort 立即返回 RST，预摘流仅增加 reload 与连接中断。
4. 存在以下情形时保留 LB 预摘流：无法 drain；摘流信号为静默丢包；LB 动态摘除成本过高。

---

## 6. 非计划故障处置

| 措施 | 作用 |
|---|---|
| 主动摘流（L7 canary，2s/2） | 8s 内摘除，限制影响时长 |
| 写接口携带 Idempotency-Key | 支持客户端安全重试 |
| 客户端对 502/504 重试 | 消除可重试失败 |
| 增加 infra 节点数 | 降低爆炸半径（在飞请求数 × 1/N） |

不得在未评估副作用的情况下对非幂等请求启用自动重试。

---

## 7. 生产环境映射

| 本方案组件 | 生产对应 |
|---|---|
| nginx 探测式 upstream | BGP/ECMP 宣告 + 健康检查 |
| L7 canary 探测 | 节点级健康检查；healthCheckNodePort 仅适用于 LoadBalancer |
| 节点侧 nat 摘流 | 撤销 BGP 宣告 |
| manual_hold | 维护窗口抑制宣告抖动 |
| nginx reload | BGP 宣告变更（无连接中断代价） |

生产实施须满足：

1. 探测 NodePort 本身，不以 Endpoint 或 Node 状态作为宣告依据。
2. 加回判断以 canary 连续成功为准。
3. 节点维护期间抑制宣告变更，恢复后延迟加回。

---

## 8. 验收标准

| 指标 | 标准 |
|---|---|
| 502/504 数量 | 0 |
| 超过 2s 的请求数 | 0 |
| 关节点时在飞请求 | 全部返回 200，延迟与基线一致 |
| 客户端连接中断比例 | ≤ 0.05%，且均为请求未到达后端 |
| p99 | 与基线一致 |

观测项：

| 指标 | 用途 |
|---|---|
| p99 及超 1s 请求占比 | 识别未产生错误码的性能劣化 |
| upstream 重试次数（`$upstream_addr` 含逗号） | 识别未失败但产生额外代价的请求 |
| 客户端连接中断数（status=0 / RemoteDisconnected） | 识别写请求风险 |

重试安全判定：客户端记录、LB access log、ingress 日志三方比对，三者均无记录方视为请求未发出。比对时须按时间戳过滤，避免跨轮次 probe id 重名。
