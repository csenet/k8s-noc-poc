# K8s NOC PoC

K8sクラスタ上にUnbound DNS resolver + Kea DHCPv4サーバーをデプロイするPoC。

## アーキテクチャ

- **Unbound DNS**: `klutchell/unbound` イメージ、cachedbモジュールでRedisバックエンド
  - chroot無効、`/config/` にConfigMapマウント、`-d -c /config/unbound.conf` で起動
  - イメージはミニマル（sh/cat/ls 等なし）、probe は tcpSocket:53
  - スケールアウト対応: 複数レプリカがRedisキャッシュを共有
  - **Unbound Exporter** (`rsprta/unbound_exporter`) サイドカーでPrometheusメトリクス公開 (:9167)
    - Unixソケット (`/var/run/unbound/unbound.ctl`) 経由で統計取得、`remote-control` 有効化済み
- **Redis**: Unboundのキャッシュ用standalone Redis (redis:7-alpine)
- **Kea DHCP**: `mglants/kea-dhcp` Helmチャート (v0.7.1) 経由、StatefulSet
  - **Kea Exporter** (`ghcr.io/mweinelt/kea-exporter`) サイドカーでPrometheusメトリクス公開 (:9547)
    - `/run/kea/kea-dhcp4-ctrl.sock` Unixソケット共有でKea control socketにアクセス
- **MetalLB**: Helm (v0.14.9) でインストール、LoadBalancerタイプServiceで外部公開
- **Monitoring**: kube-prometheus-stack (Helm v72.6.2) で Prometheus + Grafana + Alertmanager を `monitoring` namespace にデプロイ
  - `serviceMonitorSelectorNilUsesHelmValues: false` で全namespace の ServiceMonitor を自動検出
  - `ruleSelectorNilUsesHelmValues: false` で全namespace の PrometheusRule を自動検出
  - Unbound Exporter / Kea Exporter を ServiceMonitor 経由で cross-namespace 収集
  - **PrometheusRule**: Unbound 用アラート6件 (Down, HighSERVFAIL, SlowRecursion, RequestListOverflow, LowCacheHitRate, NoQueries)
  - **Grafana** 12.3.3 は LoadBalancer で外部公開 (admin/admin)、Git Sync (experimental feature toggle)
  - **Alertmanager** 有効
  - kubeProxy / kubeEtcd / kubeScheduler / kubeControllerManager は無効 (OrbStack非対応)

## ディレクトリ構成

```
base/
  namespace/      # noc-poc namespace
  metallb/        # MetalLB Helm chart + config/ (IPAddressPool, L2Advertisement)
  redis/          # Redis deployment + configMapGenerator
  unbound/        # Unbound deployment + configMapGenerator (3設定ファイル)
  kea-dhcp/       # Kustomize helmCharts でHelm chart参照
  monitoring/     # kube-prometheus-stack Helm chart + ServiceMonitors + PrometheusRules
    servicemonitors/   # Unbound / Kea DHCP 用 ServiceMonitor
    prometheusrules/   # Unbound アラートルール
overlays/
  poc/            # PoC環境overlay (MetalLBプール名パッチ、namespace強制)
test/             # テストスクリプト (test-dns/dhcp/scale/all) + テストPod
scripts/          # deploy.sh, teardown.sh
```

## 操作コマンド

```bash
make build        # kustomize build (dry-run)
make deploy       # MetalLB + メインリソースをデプロイ
make status       # リソース状態確認
make test         # DNS + DHCP 全テスト
make test-dns     # DNS テストのみ
make test-dhcp    # DHCP テストのみ
make test-scale   # Unboundスケールテスト (REPLICAS=3)
make clean        # 全削除 (MetalLB含む)
make monitoring        # monitoring stack のみデプロイ
make monitoring-status # monitoring namespace の状態表示
make monitoring-clean  # monitoring stack 削除
make grafana-forward   # Grafana port-forward (localhost:3000)
make prometheus-forward # Prometheus port-forward (localhost:9090)
```

## デプロイ順序

MetalLBは段階的デプロイが必要（CRD→controller→speaker→IPAddressPool）:
1. `base/metallb/namespace.yaml` を先に apply
2. Helm chartを `--server-side` で apply → controller/speaker 待ち
3. `base/metallb/config/` のCRリソースをapply
4. メインリソース（overlay）をapply
5. Monitoring stack (kube-prometheus-stack) を `--server-side` で2段階 apply
   - Phase 1: CRD を apply → `Established` を待つ（PrometheusRule 等の CR を作るために必須）
   - Phase 2: 全リソース（CR含む）を再 apply

## ベンチマーク

`make bench-scale` で dnsperf によるレプリカ別 QPS 比較が可能（`test/scripts/bench-scale.sh`）。

計測結果 (2026-02-24, OrbStack single node 12コア/24GB, dnsperf -c 10 -T 10 -l 30):
- 1 replica: ~50K QPS (avg 1.8ms)
- 2 replicas: ~83K QPS (avg 1.1ms) → +64%
- 3 replicas: ~87K QPS (avg 0.9ms) → +5% 頭打ち

ボトルネック: klipper-lb (svclb) の iptables パケット処理が飽和（Redis/クライアント側は排除済み）。
改善候補: IPVS モード、Keepalived+LVS (DSR)、kube-vip 等。

## 重要な注意事項

- MetalLBリソースは `metallb-system` namespace で別管理（overlayのnamespace変換対象外）
- Helm chartレンダリングリソースにはKustomize namespace変換が効かない → overlayでJSONパッチで強制注入
- IPレンジ: `base/metallb/config/ip-address-pool.yaml` を環境に合わせて変更
- Kea values: `base/kea-dhcp/values.yaml` の `domain-name-servers` にUnbound LB IPを設定
- `kustomize build` には `--enable-helm` フラグが必須
- Monitoring の CRD と CR は同時 apply できない → `make monitoring` で2段階 apply を自動化
- `ruleSelectorNilUsesHelmValues: false` がないと Helm ラベル付き PrometheusRule しか検出されない
