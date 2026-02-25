# K8s NOC PoC

Kubernetes クラスタ上に **Unbound DNS resolver** と **Kea DHCPv4 サーバー**をデプロイする PoC (Proof of Concept) プロジェクト。

## 構成

```
┌────────────────────────────────────────────────────────────────────┐
│  Kubernetes Cluster                                                │
│                                                                    │
│  noc-poc namespace                                                 │
│                                                                    │
│  Client ──► MetalLB LB ──► ┌──────────────────┐                   │
│         (plain :53 / DoT :853)│  dnsdist Pod     │                   │
│                             │  (DNS LB :53)    │                   │
│                             │  (DoT    :853)   │                   │
│                             │  metrics :8083   │                   │
│                             └────────┬─────────┘                   │
│                    Pod IP 直接分散     │ (headless Service)          │
│                 ┌─────────────────────┼──────────────┐             │
│                 ▼                     ▼              ▼             │
│  ┌────────────────────┐  ┌──────────────────────┐  ...            │
│  │ Unbound Pod        │  │ Unbound Pod          │                 │
│  │ ┌────────────────┐ │  │ ┌──────────────────┐ │                 │
│  │ │ unbound        │ │  │ │ unbound          │ │                 │
│  │ │ (DNS resolver) │ │  │ │ (DNS resolver)   │ │                 │
│  │ ├────────────────┤ │  │ ├──────────────────┤ │                 │
│  │ │ unbound-       │ │  │ │ unbound-         │ │                 │
│  │ │ exporter :9167 │ │  │ │ exporter :9167   │ │                 │
│  │ └────────────────┘ │  │ └──────────────────┘ │                 │
│  └─────────┬──────────┘  └──────────┬───────────┘                 │
│            └────────────┬───────────┘                              │
│                 ┌───────▼───────┐                                  │
│                 │    Redis      │  cachedb backend                 │
│                 │  (standalone) │                                  │
│                 └───────────────┘                                  │
│                                                                    │
│  ┌────────────────────┐                                            │
│  │ Kea DHCP Pod       │                                            │
│  │ ┌────────────────┐ │                                            │
│  │ │ kea-dhcp       │ │  DHCPv4 server                             │
│  │ ├────────────────┤ │                                            │
│  │ │ kea-exporter   │ │  Prometheus exporter :9547                 │
│  │ └────────────────┘ │                                            │
│  └────────────────────┘                                            │
│                                                                    │
│  monitoring namespace                                              │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────────┐         │
│  │ Prometheus   │  │   Grafana    │  │  Alertmanager    │         │
│  │   :9090      │  │   :3000      │  │   :9093          │         │
│  │              │◄─┤  (12.3.3)    │  │                  │         │
│  │  ServiceMonitor / PrometheusRule  │                  │         │
│  └──────┬───────┘  └──────────────┘  └──────────────────┘         │
│         │  scrape                                                  │
│         ▼                                                          │
│   dnsdist / unbound-exporter / kea-exporter (cross-namespace)      │
│                                                                    │
│  MetalLB ─── LoadBalancer IP for DNS (dnsdist) / DHCP / Grafana    │
└────────────────────────────────────────────────────────────────────┘
```

### コンポーネント

| コンポーネント | イメージ | 役割 |
|---|---|---|
| dnsdist | `powerdns/dnsdist-19:latest` | DNS ロードバランサ (Unbound 前段、Pod IP 直接分散、動的バックエンド同期、DoT :853 対応) |
| Unbound | `klutchell/unbound:latest` | DNS キャッシュリゾルバ (cachedb + Redis、フルリカーシブ) |
| Unbound Exporter | `rsprta/unbound_exporter:latest` | Unbound Prometheus メトリクス (サイドカー) |
| Redis | `redis:7-alpine` | Unbound の共有キャッシュバックエンド |
| Kea DHCP | `ghcr.io/mglants/kea-dhcp:2.5.8` | DHCPv4 サーバー |
| Kea Exporter | `ghcr.io/mweinelt/kea-exporter:latest` | Kea Prometheus メトリクス (サイドカー) |
| MetalLB | Helm chart v0.14.9 | L2モードの LoadBalancer 実装 |
| Prometheus | kube-prometheus-stack v72.6.2 | メトリクス収集・アラート評価 |
| Grafana | `grafana:12.3.3` | ダッシュボード・可視化 |
| Alertmanager | kube-prometheus-stack 同梱 | アラート通知管理 |

## 前提条件

- Kubernetes クラスタ (動作確認: OrbStack K8s)
- `kubectl`
- `kustomize` (Helm 対応: `--enable-helm`)
- `dig` (DNS テスト用)
- `kdig` (DoT テスト用、オプション - `knot-dnsutils` パッケージ)

## クイックスタート

```bash
# デプロイ (MetalLB + TLS証明書 + 全リソース)
make deploy

# 状態確認
make status

# テスト実行
make test

# スケールテスト (Unbound 3台)
make test-scale

# Grafana (http://localhost:3000, admin/admin)
make grafana-forward

# Prometheus (http://localhost:9090)
make prometheus-forward

# 全削除
make clean
```

または `scripts/deploy.sh` で対話的にデプロイ:

```bash
./scripts/deploy.sh
```

## ディレクトリ構成

```
k8s-noc-poc/
├── Makefile                    # 操作一括管理
├── CLAUDE.md                   # Claude Code 向けプロジェクト情報
├── base/
│   ├── namespace/              # noc-poc namespace
│   ├── metallb/                # MetalLB Helm chart
│   │   ├── namespace.yaml      # metallb-system namespace
│   │   ├── kustomization.yaml  # helmCharts
│   │   └── config/             # IPAddressPool, L2Advertisement
│   ├── redis/                  # Redis (configMapGenerator)
│   │   ├── deployment.yaml
│   │   ├── service.yaml
│   │   └── configs/redis.conf
│   ├── dnsdist/                # dnsdist DNS LB
│   │   ├── deployment.yaml
│   │   ├── service.yaml         # LoadBalancer (外部公開)
│   │   ├── service-metrics.yaml # ClusterIP (Prometheus)
│   │   └── configs/
│   │       ├── entrypoint.sh    # 初期 Pod 待機 + dnsdist 起動
│   │       └── dnsdist.conf     # Lua 設定 (maintenance() で動的同期)
│   ├── unbound/                # Unbound (configMapGenerator)
│   │   ├── deployment.yaml
│   │   ├── service.yaml         # ClusterIP (内部)
│   │   ├── service-headless.yaml # headless (dnsdist → Pod IP)
│   │   └── configs/
│   │       ├── unbound.conf
│   │       ├── forward-zones.conf
│   │       └── cachedb.conf
│   ├── kea-dhcp/               # Kea DHCP (helmCharts)
│   │   ├── kustomization.yaml
│   │   └── values.yaml
│   └── monitoring/             # kube-prometheus-stack
│       ├── kustomization.yaml  # helmCharts + resources
│       ├── namespace.yaml      # monitoring namespace
│       ├── values.yaml         # Helm values
│       ├── servicemonitors/    # dnsdist / Unbound / Kea DHCP ServiceMonitor
│       └── prometheusrules/    # Unbound アラートルール
├── overlays/
│   └── poc/                    # PoC 環境 overlay
│       ├── kustomization.yaml
│       └── patches/
├── test/
│   ├── scripts/                # テストスクリプト
│   └── manifests/              # テスト用 Pod
└── scripts/
    ├── deploy.sh               # デプロイスクリプト
    └── teardown.sh             # クリーンアップ
```

## 設定のカスタマイズ

### MetalLB IP レンジ

`base/metallb/config/ip-address-pool.yaml` でネットワーク環境に合わせた IP レンジを設定:

```yaml
spec:
  addresses:
    - 192.168.139.50-192.168.139.70   # 環境に合わせて変更
```

### DNS 解決モード

デフォルトはフルリカーシブモード（ルートサーバーから自力解決）。`*.local.jaws-ug.jp` のみ Route 53 Resolver Inbound Endpoint に転送:

```
forward-zone:
    name: ""
    forward-addr: 10.0.0.2      # Route 53 Resolver Inbound EP — replace with actual IP
    forward-addr: 10.0.0.3      # Route 53 Resolver Inbound EP — replace with actual IP
```

Route 53 Resolver の IP は AWS 側で Inbound Endpoint 作成後に確定。`base/unbound/configs/forward-zones.conf` を更新すること。

### DHCP サブネット

`base/kea-dhcp/values.yaml` でサブネット、プール、オプションを設定:

```yaml
kea:
  dhcp4:
    subnets:
      - subnet: "192.168.1.0/24"
        pools:
          - pool: "192.168.1.100-192.168.1.200"
```

## スケーリング

Unbound は Deployment として動作し、Redis を共有キャッシュバックエンドとして利用するため、水平スケールが可能:

```bash
# 3 レプリカにスケール
kubectl -n noc-poc scale deployment/unbound --replicas=3

# または
make test-scale REPLICAS=3
```

全レプリカが同じ Redis キャッシュを共有するため、どの Pod にルーティングされても一貫したキャッシュヒット率を得られる。

> **Note**: dnsdist は `maintenance()` Lua コールバックで 10秒ごとに headless Service を再解決し、Unbound Pod の追加/削除を自動検出する。Unbound レプリカ変更後に dnsdist の再起動は不要。

## テスト

| テスト | コマンド | 内容 |
|---|---|---|
| DNS 全般 | `make test-dns` | 再帰解決、NXDOMAIN、TCP、Redis cache |
| DHCP | `make test-dhcp` | Pod 起動、Service 存在、設定読み込み |
| スケール | `make test-scale` | 3台スケール + クエリ負荷テスト |
| 全テスト | `make test` | DNS + DHCP |
| ベンチマーク | `make bench-scale` | dnsperf によるレプリカ別 QPS 比較 |

### パフォーマンスベンチマーク

`dnsperf` を使ったレプリカ別スループット計測（OrbStack K8s, ホスト 12コア/24GB）:

```bash
# デフォルト (1, 2, 3 レプリカ)
make bench-scale

# カスタムレプリカ数
REPLICAS_LIST="1 2 3 5" make bench-scale
```

**計測条件**: `dnsperf -c 10 -T 10 -l 30` (10クライアント, 10スレッド, 30秒間)

#### 計測結果 (2026-02-24, OrbStack K8s single node, dnsdist 導入前)

| Replicas | QPS | Avg Latency | Min Latency | Max Latency | Lost | スケール効率 |
|----------|-----|-------------|-------------|-------------|------|-------------|
| 1 | 50,527 | 1.819ms | 0.230ms | 40.0ms | 0/1.5M | baseline |
| 2 | 83,012 | 1.102ms | 0.052ms | 105.3ms | 74/2.5M | +64% |
| 3 | 87,241 | 0.858ms | 0.047ms | 165.8ms | 180/2.6M | +5% (頭打ち) |

#### ボトルネック分析

- 1→2 レプリカで QPS +64% と良好にスケール
- 2→3 レプリカでは +5% と頭打ち
- Redis CPU上限を 200m→1000m に引き上げても変化なし → Redis はボトルネックではない
- dnsperf クライアント側を `-c 20 -T 20` に増やしても QPS 変化なし → クライアント側でもない
- **推定ボトルネック**: OrbStack/k3s の klipper-lb (svclb) による LoadBalancer トラフィック処理
  - 全 DNS パケットが `svclb-unbound` Pod 経由でiptables DNAT される
  - シングルノード環境でこの経路が飽和していると推定

#### 対策: dnsdist 導入

iptables ボトルネックを回避するため、dnsdist を Unbound の前段に配置:
- Client → MetalLB → dnsdist → Unbound Pod IP (直接分散)
- klipper-lb が分散する先が dnsdist 1台のみになり、iptables DNAT のターゲット数が削減
- dnsdist は headless Service で Unbound Pod IP を直接解決し、leastOutstanding ポリシーで分散
- `maintenance()` Lua コールバック (毎秒実行、10秒間隔でチェック) により Unbound Pod の増減を自動検出・同期

#### その他の改善候補

| 対策 | 期待効果 | 備考 |
|------|---------|------|
| kube-proxy を IPVS モードに変更 | 大 | iptables → ハッシュテーブル O(1) 分散 |
| Keepalived + LVS (DSR) | 大 | カーネルレベル LB、戻りパケットが LB を迂回 |
| kube-vip 導入 | 中 | K8s ネイティブな Keepalived 代替 |
| Unbound `so-reuseport: yes` + `num-threads: 4` | 中 | Pod 単体性能の向上 |

## リース保存

Kea DHCP はデフォルトで **memfile バックエンド**（CSV ファイル）を使用:
- 保存先: `/data/dhcp4.leases` (PVC で永続化)
- MySQL/PostgreSQL バックエンドへの変更も Helm values で可能

## モニタリング

[kube-prometheus-stack](https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack) (Helm v72.6.2) ベースの監視スタックを `monitoring` namespace にデプロイ。

### 構成

| コンポーネント | アクセス | 説明 |
|---|---|---|
| Prometheus | `make prometheus-forward` → http://localhost:9090 | メトリクス収集・アラート評価 |
| Grafana | LoadBalancer IP or `make grafana-forward` → http://localhost:3000 | ダッシュボード (admin/admin) |
| Alertmanager | クラスタ内 :9093 | アラート通知管理 |

### メトリクス収集

Unbound / Kea DHCP のサイドカー Exporter および dnsdist から ServiceMonitor 経由で cross-namespace scrape:

| Exporter | ポート | メトリクス例 |
|---|---|---|
| dnsdist | 8083 | QPS, レイテンシ, バックエンドヘルスチェック |
| unbound_exporter | 9167 | QPS, キャッシュヒット率, クエリタイプ別統計 |
| kea-exporter | 9547 | リース数, サブネット統計, パケット統計 |

### アラートルール (PrometheusRule)

Unbound 用のアラートを `base/monitoring/prometheusrules/unbound-alerts.yaml` で定義:

| アラート名 | 条件 | Severity | 発火待ち |
|---|---|---|---|
| UnboundDown | `up{job="unbound"} == 0` | critical | 1m |
| UnboundHighSERVFAILRate | SERVFAIL > 5% | warning | 5m |
| UnboundSlowRecursion | 再帰解決の平均 > 2s | warning | 5m |
| UnboundRequestListOverflow | リクエストリスト溢れ | critical | 2m |
| UnboundLowCacheHitRate | キャッシュヒット率 < 50% | warning | 10m |
| UnboundNoQueries | クエリゼロ | warning | 5m |

### Grafana Git Sync (experimental)

`values.yaml` で Grafana の feature toggle (`provisioning`, `kubernetesDashboards`) を有効化済み。ダッシュボード定義の Git 管理に対応。

### デプロイ

```bash
# monitoring stack のみデプロイ (2段階 apply: CRD → CR)
make monitoring

# 状態確認
make monitoring-status

# 削除
make monitoring-clean
```

> **Note**: CRD (PrometheusRule 等の CustomResourceDefinition) が `Established` になるまで CR を apply できないため、`make monitoring` は自動的に2段階で apply する。

## 技術ノート

- **dnsdist** (`powerdns/dnsdist-19`)
  - `newServer()` は IP アドレスのみ受付（ホスト名不可）→ `getent ahostsv4` で headless Service を解決
  - `entrypoint.sh` で Unbound Pod の起動を待機してから `dnsdist.conf` (Lua) で起動
  - `maintenance()` Lua コールバックは dnsdist が毎秒呼び出し、10秒間隔で `getent` → `newServer()` / `rmServer()` でバックエンド自動同期
  - webserver (:8083) は起動するが HTTP GET でEOF を返す場合あり → readiness probe は `tcpSocket:53` を使用
- **Unbound** (`klutchell/unbound`) はミニマルイメージ (`sh`, `cat`, `ls` 等なし)
  - Health probe は `tcpSocket:53` を使用
  - Config は `/config/` にマウント、`-d -c /config/unbound.conf` で起動
  - `chroot: ""` で chroot 無効化が必要
- Kustomize の `namespace` トランスフォーマーは Helm レンダリングリソースに効かないため、overlay で JSON パッチにて強制注入
- MetalLB は CRD → Controller → Speaker → CR の順序でデプロイが必要
- **DoT (DNS over TLS)**: クライアント向け DoT (:853) は dnsdist が自己署名証明書で提供。`make tls-cert` で Secret 生成（`make deploy` に含まれる）
- **フルリカーシブ**: Unbound はルートサーバーから自力で名前解決。`*.local.jaws-ug.jp` のみ Route 53 Resolver Inbound Endpoint に転送
