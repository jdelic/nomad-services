job "tiny-dyndns" {
    datacenters = ["RZ19", "vagrant"]
    node_pool   = "edge" # must run on a node with a public IP address, so we can bind to port 53
    type        = "service"

    group "dyndns" {
        network {
            mode = "host"

            port "dns" {
                static       = 53
                host_network = "external"
            }

            port "dnsv6" {
                static       = 53
                host_network = "external-ipv6"
            }

            port "http" {
                static = 58049
            }
        }

        task "service" {
            driver = "docker"

            config {
                image           = "registry.maurus.net/tiny-dyndns/tiny-dyndns:latest"
                ports           = ["dns", "http"]
                readonly_rootfs = true
                cap_add         = ["net_bind_service"]
                network_mode    = "host"

                # No host volumes: /zones, /var/db/nsd, and /run/nsd are redirected
                # (via env below) onto Nomad's own per-allocation "local" disk, and
                # /tmp gets a plain tmpfs. All of it is wiped whenever the
                # allocation is replaced (deploy, reschedule, node loss) — the zone
                # is rebuilt from defaults by `-init-zone` and the live address
                # comes back on the next crontab-driven `/update` call. See "Nomad"
                # in README.md for the tradeoff.
                mounts = [
                    {
                        type   = "tmpfs"
                        target = "/tmp"
                    }
                ]
            }

            env {
                # Selects which zone this job instance updates; SOA and NS records
                # derive from it unless overridden below. See the "Configuration"
                # section in README.md for the full variable list.
                DYNDNS_ZONE_NAME  = "kameter.maurus.net"
                DYNDNS_NS_RECORDS = "dyndns.maurus.net.,nsb7.schlundtech.de."
                DYNDNS_SOA_MNAME = "dyndns.maurus.net."

                # /local is Nomad's per-task ephemeral disk; it's mounted read-write
                # automatically regardless of readonly_rootfs, so no volume
                # declaration is needed. Keep the basename here in sync with
                # DYNDNS_ZONE_NAME above — the app doesn't derive one from the
                # other once DYNDNS_ZONE_FILE is set explicitly.
                DYNDNS_ZONE_FILE = "/local/zones/kameter.maurus.net.zone"
                NSD_DB_DIR       = "/local/nsd-db"
                NSD_RUN_DIR      = "/local/nsd-run"

                DYNDNS_TRUST_PROXY_HEADERS = "true"
                # Host networking: the updater must bind the advertised static port.
                DYNDNS_LISTEN_ADDR = ":${NOMAD_PORT_http}"
                NSD_LISTEN_ADDR = "${NOMAD_IP_dns}@${NOMAD_PORT_dns},${NOMAD_IP_dnsv6}@${NOMAD_PORT_dnsv6}"
                NSD_VERBOSITY = "2"
            }

            template {
                destination = "secrets/dyndns.env"
                env         = true
                data        = <<-EOT
                    DYNDNS_TOKEN={{ with nomadVar "nomad/jobs/tiny-dyndns/config" }}{{ .token }}{{ end }}
                    NSD_SECONDARIES={{ with nomadVar "nomad/jobs/tiny-dyndns/config" }}{{ .secondary_ips }}{{ end }}
                    NSD_TSIG_NAME={{ with nomadVar "nomad/jobs/tiny-dyndns/config" }}{{ .tsig_name }}{{ end }}
                    NSD_TSIG_ALGORITHM={{ with nomadVar "nomad/jobs/tiny-dyndns/config" }}{{ .tsig_algorithm }}{{ end }}
                    NSD_TSIG_SECRET={{ with nomadVar "nomad/jobs/tiny-dyndns/config" }}{{ .tsig_secret }}{{ end }}
EOT
            }

            resources {
                cpu    = 100
                memory = 256
            }

            service {
                name     = "tiny-dyndns-dns-tcp"
                port     = "dns"
                provider = "consul"
                tags = [
                    "smartstack:external",
                    "smartstack:protocol:tcp",
                    "smartstack:extport:53",
                    "smartstack:hostport:tcp:53",
                ]
            }

            service {
                name     = "tiny-dyndns-dns-udp"
                port     = "dns"
                provider = "consul"
                tags = [
                    "smartstack:external",
                    "smartstack:protocol:udp",
                    "smartstack:extport:53",
                    "smartstack:hostport:udp:53",
                ]
            }

            service {
                name     = "tiny-dyndns-http"
                port     = "http"
                provider = "consul"
                tags = [
                    "smartstack:external",
                    "smartstack:routing:hostname",
                    "smartstack:hostname:dyndns.maurus.net",
                    "smartstack:protocol:https",
                    "smartstack:mode:http",
                    "smartstack:https-redirect",
                ]

                check {
                    name     = "healthz"
                    type     = "http"
                    path     = "/healthz"
                    interval = "10s"
                    timeout  = "2s"
                }
            }
        }
    }
}
