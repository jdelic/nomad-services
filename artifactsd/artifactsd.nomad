# ─── IMPORTANT: count must remain 1 ────────────────────────────────────────
#     artifactsd uses in-process SQLite. Running more than one allocation would
#     cause concurrent writers to contend on the same database file — the second
#     writer will error-loop. Horizontal scaling is explicitly not a design goal.
#     For mass distribution, put a CDN or object-storage proxy in front.
# ────────────────────────────────────────────────────────────────────────────
variable "domain" {
    type        = string
    default = "maurus.net"
}

variable "admin_token" {
    type = string
}

job "artifactsd" {
    datacenters = ["RZ19", "vagrant"]
    type                = "service"

    group "artifactsd" {
        # DO NOT raise count above 1 — see note above.
        count = 1

        volume "data" {
            type                        = "csi"
            source                    = "artifactsd-data"
            access_mode         = "single-node-writer"
            attachment_mode = "file-system"
            read_only             = false
        }

        volume "host-ca-bundle" {
            type            = "host"
            source        = "host-ca-bundle"
            read_only = true
        }

        network {
            port "http" {
                to = 8080
            }
        }

        restart {
            attempts = 5
            delay        = "10s"
            interval = "2m"
            mode         = "delay"
        }

        task "data-init" {
            driver = "docker"

            lifecycle {
                hook    = "prestart"
                sidecar = false
            }

            config {
                image   = "debian:trixie-slim"
                command = "chown"
                args    = ["65532:65532", "/data"]
            }

            volume_mount {
                volume      = "data"
                destination = "/data"
                read_only   = false
            }

            resources {
                cpu    = 50
                memory = 32
            }
        }

        task "artifactsd" {
            driver = "docker"

            config {
                image = "registry.${var.domain}/agent-tools/artifactsd:latest"
                ports = ["http"]

                #mounts = [
                #    {
                #        type         = "bind"
                #        source     = "/etc/ssl/certs/wildcard-combined.crt"
                #        target     = "/etc/ssl/certs/wildcard-combined.crt"
                #        readonly = true
                #    },
                #    {
                #        type         = "bind"
                #        source     = "/etc/ssl/private/wildcard.key"
                #        target     = "/etc/ssl/private/wildcard.key"
                #        readonly = true
                #    }
                #]
            }

            volume_mount {
                volume            = "data"
                destination = "/data"
                read_only     = false
            }

            volume_mount {
                volume            = "host-ca-bundle"
                destination = "/etc/ssl/certs/ca-certificates.crt"
                read_only     = true
            }

            env {
                # Required: the public URL clients use to reach this server.
                ARTIFACTSD_BASE_URL = "https://artifacts.${var.domain}"
                ARTIFACTSD_LISTEN     = ":8080"
                ARTIFACTSD_DATA_DIR = "/data"

                # TLS: set to "acme" and configure ARTIFACTSD_ACME_DOMAINS /
                # ARTIFACTSD_ACME_EMAIL if this allocation terminates TLS directly.
                # Leave "off" when a Nomad ingress gateway or external proxy handles it.
                ARTIFACTSD_TLS = "off"

                # Bootstrap token: seeds the first admin-scoped API token on first
                # boot. Replace "change-me" with a random value (e.g. `openssl rand
                # -hex 32`) and remove this line once you have created a real token.
                ARTIFACTSD_BOOTSTRAP_TOKEN = "${var.admin_token}"

                ARTIFACTSD_OIDC_ISSUER = "https://auth.${var.domain}/o2"
                ARTIFACTSD_OIDC_CLIENT_ID = "artifactsd"
                ARTIFACTSD_OIDC_CLIENT_SECRET = "7vim4o8WvekDQSG9w59oFY1mdGFVAYz6h5g2kYTt0BYhjkcWNkZE0XDqSrckUFOaTk9KI5atmOBI8byPzImFHNaEsG6fBCXr2UKMlzgjJGLcjFNPGnT7qQIJuMRmQRxt"
                ARTIFACTSD_ADMIN_GROUP = "*"
            }

            resources {
                cpu        = 256    # MHz — increase if serving many concurrent downloads
                memory = 256    # MiB
            }

            service {
                name         = "artifactsd"
                port         = "http"
                provider = "consul"    # change to "nomad" if not using Consul

                tags = [
                    "smartstack:external",
                    "smartstack:hostname:artifacts.${var.domain}",
                    "smartstack:routing:hostname",
                    "smartstack:https-redirect",
                    "smartstack:protocol:https",
                ]

                check {
                    type         = "http"
                    path         = "/healthz"
                    interval = "30s"
                    timeout    = "5s"
                }
            }
        }
    }
}
