# pg_query_advisor — Grafana Dashboard

PostgreSQL sağlık durumunu görselleştiren Grafana dashboard'u.
pg_query_advisor v1.5 gerektirir.

## Yapı

```
grafana/
├── dashboards/
│   └── pg_query_advisor.json          # Ana dashboard (16 panel, 8 satır)
└── provisioning/
    ├── datasources/
    │   └── postgres.yml               # PostgreSQL datasource şablonu
    └── dashboards/
        └── pg_query_advisor.yml       # Dashboard provisioning config
```

## Kurulum

### 1. Grafana kur (RHEL 8/9)

```bash
cat > /etc/yum.repos.d/grafana.repo << 'EOF'
[grafana]
name=grafana
baseurl=https://rpm.grafana.com
repo_gpgcheck=1
enabled=1
gpgcheck=1
gpgkey=https://rpm.grafana.com/gpg.key
sslverify=1
sslcacert=/etc/pki/tls/certs/ca-bundle.crt
EOF

dnf install -y grafana
systemctl enable --now grafana-server
```

### 2. Datasource yapılandır

`grafana/provisioning/datasources/postgres.yml` dosyasını düzenle:

```yaml
url: localhost:5432      # PostgreSQL sunucu adresi
user: postgres           # Kullanıcı adı
database: mydb           # İzlenecek veritabanı
```

Sonra kopyala:
```bash
cp grafana/provisioning/datasources/postgres.yml \
   /etc/grafana/provisioning/datasources/

cp grafana/provisioning/dashboards/pg_query_advisor.yml \
   /etc/grafana/provisioning/dashboards/

cp grafana/dashboards/pg_query_advisor.json \
   /etc/grafana/provisioning/dashboards/
```

### 3. Grafana'yı yeniden başlat

```bash
systemctl restart grafana-server
```

### 4. Erişim

`http://<sunucu_ip>:3000` → admin / admin

---

## Manuel Import (provisioning olmadan)

1. Grafana → Dashboards → Import
2. `grafana/dashboards/pg_query_advisor.json` dosyasını yükle
3. PostgreSQL datasource seç → Import

---

## Dashboard Panelleri

| Satır | Panel | Fonksiyon |
|-------|-------|-----------|
| Genel Özet | CRITICAL sayısı | `report()` |
| Genel Özet | WARNING sayısı | `report()` |
| Genel Özet | Aktif bağlantı | `pg_stat_activity` |
| Genel Özet | Idle in transaction | `idle_in_transaction()` |
| Genel Özet | Lock bekleyen | `pg_locks` |
| Genel Özet | Deadlock sayısı | `pg_stat_database` |
| Öncelikli Bulgular | CRITICAL/WARNING tablo | `report()` |
| Vacuum & Dead Tuple | Tablo sağlığı | `table_health()` |
| Vacuum & Dead Tuple | Vacuum ihtiyacı | `vacuum_needs()` |
| Index Analizi | Kullanılmayan indexler | `unused_indexes()` |
| Index Analizi | Index eksikliği | `missing_indexes()` |
| Index Analizi | FK index eksikleri | `fk_without_index()` |
| Index Analizi | Index bloat | `index_bloat_estimate()` |
| Sorgu Performansı | En yavaş 15 sorgu | `slow_queries()` |
| Sorgu Performansı | Uzun sorgular | `long_running_queries()` |
| Sorgu Performansı | Wait events | `wait_event_summary()` |
| Lock & Transaction | Lock zinciri | `lock_waits()` |
| Lock & Transaction | Idle txn sessionlar | `idle_in_transaction()` |
| Bağlantı & Config | Bağlantı istatistikleri | `connection_stats()` |
| Bağlantı & Config | Config danışmanı | `config_advisor()` |
| Güvenlik & Kapasite | Yetki denetimi | `table_privileges_audit()` |
| Güvenlik & Kapasite | Sequence riski | `sequence_health()` |
| Güvenlik & Kapasite | Tablespace kullanımı | `tablespace_usage()` |
| Güvenlik & Kapasite | TOAST analizi | `toast_analysis()` |
| Vacuum & Temp | Aktif vacuum | `vacuum_progress()` |
| Vacuum & Temp | Temp file | `temp_file_stats()` |

---

## Gereksinimler

| Gereksinim | Versiyon |
|-----------|---------|
| Grafana | 10.0+ |
| PostgreSQL | 17 veya 18 |
| pg_query_advisor | 1.5 |
| pg_stat_statements | — (slow_queries için) |
| pg_buffercache | — (buffercache_top için, opsiyonel) |

---

## Dashboard Yenileme

Dashboard varsayılan olarak **5 dakikada bir** yenilenir.
Sağ üstten değiştirilebilir (1m / 5m / 30m / 1h).
