# 坑清单

全部实测复现过。按稳定 ID 引用（`P-xx`），不随插入错位 —— 正文里写 `P-04` 就永远指这一条。

| 组 | ID |
|---|---|
| K8s / kind | P-01 … P-08, P-12 |
| 节点侧摘流（iptables / conntrack） | P-09, P-10, P-25 |
| nginx LB 语义 | P-11, P-13, P-14, P-16, P-19, P-23, P-24, P-26 |
| 环境与工具 | P-15, P-17 … P-22, P-27, P-28 |

---

## K8s / kind

### P-01 kind 配置里的 `labels:` 不能打 `node-role.kubernetes.io/*`

它会注入 kubelet 的 `--node-labels`，而 kubelet 对 `kubernetes.io` 命名空间有白名单 → kubelet 直接退出，
`kind create cluster` 卡在 `kubelet-wait-bootstrap`。真实日志：

```
failed to validate kubelet flags: unknown 'kubernetes.io' labels specified with --node-labels
```

报错还很误导人（`required cgroups disabled`）。→ 集群起来后用 `kubectl label`。

### P-02 `kubectl taint ... --overwrite` 是「加」不是「删」

删 taint 用 `kubectl taint node X key:NoSchedule-`（尾部减号）。

### P-03 `healthCheckNodePort` 在 `type: NodePort` 上不可用

API 直接拒绝：

```
may only be set when type is 'LoadBalancer' and externalTrafficPolicy is 'Local'
```

→ NodePort 方案里 LB 只能自己探测 NodePort。生产上更干净的做法是 `type: LoadBalancer` + BGP 宣告。

### P-04 无本地 endpoint 的节点是 `-j DROP`，不是 REJECT ★

```
-A KUBE-EXTERNAL-SERVICES ... --dport 31000
   -m comment "ingress-nginx/ingress-nginx-controller:http has no local endpoints" -j DROP
```

客户端只看到 SYN 超时，收不到 connection refused。后果贯穿整个方案：

- LB 的健康检查**必须带 connect 超时**，不能靠「连不上」判断；
- 故障时表现为「不报错但很慢」（每次付一个 connect 超时），而不是明确失败；
- 计划内维护值得主动把它变成 RST（见 P-09）。

### P-05 `externalTrafficPolicy: Local` 会让 `127.0.0.1:31000` 失效

kind 的 `extraPortMappings` 只能绑 control-plane，而 control-plane 上没有本地 ingress endpoint → 连接超时。
宿主机访问必须走集群外 nginx（`:8080`），或直连 infra 节点 IP。

### P-06 `whenUnsatisfiable: DoNotSchedule` 与 drain 互卡

2 个 infra 节点、6 副本时 drain 其中一个，被驱逐的 3 个 pod 会一直 **Pending** ——
放到另一个节点就变成 6/0，skew=6 > maxSkew=1。

实测：drain 本身能完成，PDB 保住 3 个可用（50%），uncordon 后自动恢复 3/3。
这是**刻意的取舍**（宁可维护窗口容量减半，也不要分布不均）。想维护期保持满副本就改 `ScheduleAnyway`，
代价是分布不均 = LB 侧容量不均。

### P-07 `internalTrafficPolicy: Local` 会打断集群内 hairpin 调用

任何从非 infra 节点发出的、访问 ingress Service ClusterIP / DNS 名的流量都会被 DROP（静默超时，不是 RST）。
常见踩坑：集群内应用「绕一圈自己的 ingress」、集群内监控/脚本探测 ingress。

需要这些路径：给探测任务加 `nodeSelector` 到 infra 节点，或单独建一个 `internalTrafficPolicy: Cluster` 的 Service。
（ingress-nginx 的 admission webhook 和 metrics 是另外的 Service，没动，不受影响。）

### P-08 节点重启后 IP 会变

实测 `docker stop/start ingress-lab-worker2` 后 `172.18.0.4 → 172.18.0.7`（docker 重新分配）。
静态写的 upstream 会失效，**LB 必须能重新枚举节点**（`scripts/external-nginx.sh`）。

> 这也是为什么 `EVIDENCE.md` 里不同实验的节点 IP 不一致：它们来自不同轮次。
> 对应关系以 `kubectl get nodes -o wide` 为准，不要按 IP 认节点。

### P-12 chart 4.15.1 的 PDB 阈值取 `controller.minAvailable`

写在 `controller.podDisruptionBudget.minAvailable` 下会被**静默忽略**（渲染成默认值 1）。
`podDisruptionBudget.enabled` 只负责开关。

### P-08b kind 不能自定义节点名

infra 节点物理名是 `ingress-lab-worker` / `worker2`，角色只靠 label/taint 区分。
（这也是 P-01 存在的原因。）

---

## 节点侧摘流

### P-09 `iptables -j REJECT` 放 filter INPUT 上是空操作 ★

kube-proxy 的 NodePort DROP 在 **filter INPUT**（`-A INPUT --ctstate NEW -j KUBE-EXTERNAL-SERVICES`），
但 **DNAT 发生在更早的 nat PREROUTING** ⇒ 只要该节点还有本地 endpoint，包到 INPUT 时 dport 已经是
`podIP:80`，`--dport 31000` 的 REJECT **根本匹配不上**。

实测：插了规则后 `wget :31000/healthz` 仍然 200。REJECT 放 mangle PREROUTING 又被内核拒
（`RULE_INSERT failed (Invalid argument)`，发 RST 需要路由决策）。

✅ 可用形式：在 **nat PREROUTING 最前面**（抢在 kube-proxy 的 jump 之前）改到一个没人监听的本地端口，让内核自己回 RST：

```bash
iptables -t nat -I PREROUTING 1 -p tcp --dport 31000 -j DNAT --to-destination <nodeIP>:1
iptables -t nat -I PREROUTING 1 -p tcp --dport 31001 -j DNAT --to-destination <nodeIP>:1
```

实测：无论有没有本地 endpoint，新连接都是 **0s 拒绝**（而不是 3s 超时黑洞）。

### P-10 连接数用 conntrack 看，不能用 `ss`

NodePort 是 DNAT，节点上没有 `:31000` 的本地 socket —— `ss state established sport = :31000` 永远是 0。
conntrack 的原始元组里 dport 仍是 31000：

```bash
conntrack -L -p tcp --dport 31000 | grep -c ESTABLISHED   # 计数
conntrack -D -p tcp --dport 31000                        # 强制关闭：下一个包会重新走 nat 规则 ⇒ RST
```

### P-25 不要在 reboot 前删掉节点侧 nat 规则

规则会随 netns 消失，提前删会留下一个 **kube-proxy DROP 的黑洞窗口**（实测造成 17 次 500ms connect 超时）。

---

## nginx LB 语义

### P-11 `least_conn` 是 per-worker 的 ★

8 个 worker + 5 个同步起跑的 client ⇒ 每个 worker 自己看「两台都 0 连接」，
整批请求全落同一个 upstream（实测按批交替 `.2/.6/.2`）。

后果：「关节点会切到几个在飞请求」只会得到 0 或 N，测不出真实爆炸半径。
并发压测必须 `--stagger` 错开起跑。

### P-13 候选节点列表不能非原子重写 ★

`kubectl ... > nodes` 会先把文件**截断成 0 字节**，容器里的 healthcheck 正好读到空 →
生成空 upstream → `no live upstreams` → 全量 502（实测 10 个）。

必须 `>.nodes.tmp && mv`，并在 healthcheck 里加「空列表跳过本轮」的保护。

### P-14 维护脚本（标 down/up）必须有的 5 个保护

每一条都是一次事故：

1. **保护检查必须在写「人工下线名单」之前**。实测事故：先把 IP 追写到 `manual_down.list`，
   再做「不能把最后一个可用节点标 down」的检查；而容器内的健康检查每 2s 就按名单重写 upstream
   ⇒ 两个节点全 down ⇒ **入口直接 502**。
2. **两个写入者必须合并**（单一写入者）。维护脚本改的 `down` 会被健康检查下一轮覆盖回去。
   做法：健康检查读 `manual_down.list`，命中就输出 `server ... down;` 且不计入可用数；
   同时健康检查自己也要有保险：**可用节点为 0 且是人工下线造成的 → 拒绝应用**（除非 `touch force_all_down`）。
   实测未合并时一次维护发生 4 次 reload（脚本 1 次 + 健康检查重写 1 次 × 2），合并后 down/up 各 1 次。
3. **区分「LB 不可达」和「配置语法错」**。`docker exec nginx -t` 在容器刚重启时会失败，
   当成语法错就会把一份本来正常的配置回滚掉（实测误报过）。要重试 + 看输出区分，不可达时不做变更。
4. **标 up 要处理「成员行已被健康检查删掉」**。重启期间 hc 会把整行删掉，这时「去掉 down」会找不到行；
   正确做法是只从名单里移除，等 hc 探测通过自己 ADD。
5. **变量名紧跟中文必须用 `${}`**（`$msg，` 会被 bash 当成变量名 `msg，`，`set -u` 下直接炸，
   而且是在最关键的检查那一行炸）。

### P-16 必须透传 Host 头

`proxy_set_header Host $ingress_host;`，否则 ingress 匹配不到 rule，一律 404。
（本实验还用 `map` 把空 Host / `localhost` 兜底成 `demo.local`，这样才能验证「未匹配 host 返 404」。）

### P-19 upstream 里放 IPv6 需要 `[::1]:port` 语法

dual-stack 集群下把 InternalIP 全塞进去会让 `nginx -s reload` 连续失败 20+ 次。只取 IPv4。

### P-23 L4 探测分不清「端口通」和「数据面通」★

实测把 NodePort DNAT 到一个 accept 即关的 sink：L4 判定健康、GET 有 17% 在重试、**POST 直接 6% 502**；
L7 探测 6s 内摘流，0 掉。

同时注意 nginx 的**重试语义**（这是同一个故障下 GET 不掉、POST 掉的根因）：

- **connect 失败**（请求没发出去）⇒ GET 和 POST **都会**重试；
- **请求已发出**之后 ⇒ 只有幂等方法重试。

### P-24 `nginx -s reload` 对客户端 keepalive 不是 100% 无损 ★

reload 时旧 worker 退出会关闭它持有的**空闲**客户端连接。实测在摘流/加回 reload 那一秒各出现 1 次
`RemoteDisconnected: Remote end closed connection without response`（0ms，access log 里没有这个请求）。

代价与连接池大小成正比（见 `EVIDENCE.md` T15）：2000 条连接时一次维护的两次 reload 打断 12.1% 的请求。
开源 nginx 没有不 reload 的后端池；摘流越频繁风险越高。要彻底避开就得用 HAProxy/Envoy 这类动态后端。

### P-26 `max_fails` 是被动且 per-worker 的

- 只有 `max_fails` 时，8 个 worker 各自把死节点置冷 15s 再探一次 → 聚合起来是**持续不断**的探测：
  实测 33 次重试均匀分布在 90s 里，**长尾贯穿整个故障期**（见 T3）。
- 已经有主动摘流时建议 `max_fails=0` 关掉它，只当兜底。
- 它还影响「等连接排空」的快慢：`max_fails=1 fail_timeout=5s` 下 conns 10→0 用 10s；
  `max_fails=3 fail_timeout=15s` 要 20s。想要维护窗口快就调小。

---

## 环境与工具

### P-15 `172.18.0.x` 从 Mac 宿主机不可达

Docker Desktop 的 Linux VM 内部地址。所以集群外 nginx 必须是**容器并加入 `kind` 网络**。
若用 brew 装的原生 nginx，upstream 只能写 `127.0.0.1:31000`（且受 P-05 限制）。

### P-17 解析 nginx access log：`$upstream_addr` 在重试时是 `A, B`（含空格）

用 `\S+` 会把重试请求整条日志漏掉 —— 第一版工具因此得出「重试 0 次」的错误结论。

### P-18 集群外 nginx 被重建（`docker rm -f`）时，故障期的日志会一起消失

→ 演练必须每阶段快照日志。

### P-20 busybox 的工具限制

`timeout` 是 `timeout SECS CMD`（不支持 `-t`）；`date +%N` 不可用；`nc -w` 只支持整秒
（⇒ L4 探测的超时下限是 1s）。

### P-21 shell 函数参数错位会静默毁掉整个实验

`setcnt() { echo "$2" > ... }` 应为 `$3`，把字面量 `fails` 写进计数文件，导致 `-ge 3` 恒假、
**摘流逻辑完全没生效**，第一轮演练白跑。→ 必须端到端验证，不能只看代码。

### P-22 慢后端不能用 busybox `nc -k`

它是串行处理的，延迟会叠加；whoami 也不支持 sleep。
用 `python:3.12-alpine` + ThreadingHTTPServer（`manifests/slow-backend.yaml`）。

### P-27 probe id 会跨轮次重名

id 形如 `w17-1420`，两轮会重复。用 `kubectl logs --since=15m` 查会命中上一轮的请求，
差点把「后端已处理」误判为成立。→ 必须按时间戳过滤。

### P-28 观测要看 p99 和重试次数，不是只看状态码

本实验的故障模式错误率是 0，但 p95 从 8ms 恶化到 3006ms（158×）。
只看 5xx 会完全漏掉 P-26 描述的那类故障。
