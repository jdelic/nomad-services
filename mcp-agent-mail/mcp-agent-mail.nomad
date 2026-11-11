variable "bearer_token" {
    type = string
}

variable "domain" {
    type    = string
    default = "maurus.net"
}

job "mcp-agent-mail" {
    datacenters = ["RZ19", "vagrant"]
    type        = "service"

    group "mcp-agent-mail" {
        count = 1

        network {
            port "http" {
                to = 8765
            }
        }

        restart {
            attempts = 10
            interval = "30m"
            delay    = "15s"
            mode     = "delay"
        }

        # Define a host volume named "mcp-agent-mail-data" on the Nomad client
        # for persistent archive storage.
        volume "mailbox" {
            type            = "csi"
            source          = "mcp-agent-mail-data"
            access_mode     = "single-node-writer"
            attachment_mode = "file-system"
            read_only       = false
        }

        # we fix the permissions on cloud volumes so they work with actual block device volumes.
        # On test systems where we run NFS with all_squash, anonuid=1000, anongid=1000, this is a
        # noop.
        task "fix-mailbox-perms" {
            driver = "docker"

            lifecycle {
                hook    = "prestart"
                sidecar = false
            }

            config {
                image   = "alpine:3.20"
                command = "sh"
                args = [
                    "-ec",
                    <<-EOF
                        mkdir -p /data/mailbox
                        chown -R 10001:10001 /data/mailbox
                        chmod 0750 /data/mailbox
                    EOF
                ]
            }

            volume_mount {
                volume      = "mailbox"
                destination = "/data/mailbox"
                read_only   = false
            }

            resources {
                cpu    = 50
                memory = 64
            }
        }

        service {
            name     = "mcp-agent-mail"
            provider = "nomad"
            port     = "http"

            check {
                name     = "http-readiness"
                type     = "http"
                path     = "/health/readiness"
                interval = "15s"
                timeout  = "5s"
            }

            check_restart {
                limit           = 3
                # generous grace: the first start on a legacy (Python) database runs
                # the in-place schema migration before the server becomes ready.
                grace           = "120s"
                ignore_warnings = false
            }
        }

        task "server" {
            driver = "docker"

            config {
                # Rust rewrite: https://github.com/Dicklesworthstone/mcp_agent_mail_rust
                # Image entrypoint is `tini -- mcp-agent-mail serve --no-tui`, runs as uid 10001.
                image = "ghcr.io/dicklesworthstone/mcp_agent_mail_rust:0.3.40"

                ports = ["http"]
            }

            env {
                # Same DB file + storage root as the old Python deployment. On first start
                # the Rust server migrates the legacy schema in place (irreversible), so
                # snapshot the volume before the first deploy.
                DATABASE_URL                       = "sqlite+aiosqlite:////data/mailbox/storage.sqlite3"
                STORAGE_ROOT                       = "/data/mailbox"
                HTTP_HOST                          = "0.0.0.0"
                HTTP_PORT                          = "8765"
                # /api/ and /mcp/ are accepted interchangeably; /api/ matches the edge config.
                HTTP_PATH                          = "/api/"
                # The server rejects unknown Host headers with 421. Allow the public hostname
                # (nginx forwards $host) and the node IP (Nomad health checks use IP:port).
                HTTP_ALLOWED_HOSTS                 = "mcp-mail.${var.domain},${NOMAD_IP_http}"
                # Defense in depth: the server enforces the same token as the edge, so the
                # dynamic host port is not open without auth. The edge injects it for /mail.
                HTTP_BEARER_TOKEN                  = var.bearer_token
                HTTP_RBAC_ENABLED                  = "false"
                TUI_ENABLED                        = "false"
                TOOL_METRICS_EMIT_ENABLED          = "true"
                TOOL_METRICS_EMIT_INTERVAL_SECONDS = "120"
                RUST_LOG                           = "info"
            }

            volume_mount {
                volume      = "mailbox"
                destination = "/data/mailbox"
                read_only   = false
            }

            resources {
                cpu    = 200
                memory = 512
            }
        }
    }

    group "edge" {
        network {
            port "http" {
                to = 8080
            }
        }

        task "nginx" {
            driver = "docker"

            config {
                image = "nginx:1.27-alpine"
                ports = ["http"]

                # Use the rendered config directly.
                command = "nginx"
                args    = ["-g", "daemon off;", "-c", "/local/nginx.conf"]

                cap_add = ["setgid", "setuid"]
            }

            # Render nginx.conf from Nomad service discovery.
            template {
                destination = "local/nginx.conf"
                change_mode = "restart"

                data = <<-EOF
                    worker_processes auto;

                    events {}

                    http {
                        proxy_cache_path /tmp/nginx-auth-cache
                            levels=1:2
                            keys_zone=auth_cache:10m
                            max_size=128m
                            inactive=5m
                            use_temp_path=off;

                        map $http_upgrade $connection_upgrade {
                            default upgrade;
                            ''      close;
                        }

                        upstream app_upstream {
                            {{- range nomadService "mcp-agent-mail" }}
                            server {{ .Address }}:{{ .Port }};
                            {{- end }}
                        }

                        server {
                            listen 8080;
                            absolute_redirect off;
                            port_in_redirect off;

                            location = / {
                                return 302 /mail/$is_args$args;
                            }

                            location = /api {
                                if ($http_authorization != "Bearer ${var.bearer_token}") {
                                    return 401;
                                }

                                proxy_set_header Host $host;
                                proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
                                proxy_set_header X-Forwarded-Proto https;
                                proxy_set_header X-Real-IP $remote_addr;
                                proxy_http_version 1.1;
                                proxy_buffering off;

                                proxy_pass http://app_upstream;
                            }

                            location ^~ /api/ {
                                if ($http_authorization != "Bearer ${var.bearer_token}") {
                                    return 401;
                                }

                                proxy_set_header Host $host;
                                proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
                                proxy_set_header X-Forwarded-Proto https;
                                proxy_set_header X-Real-IP $remote_addr;
                                proxy_http_version 1.1;
                                proxy_buffering off;

                                proxy_pass http://app_upstream;
                            }

                            location / {
                                error_page 401 = @basic_auth_challenge;

                                if ($http_authorization !~* "^Basic[[:space:]]+.+$") {
                                    return 401;
                                }

                                auth_request /_auth;

                                # Basic auth was verified above; the app itself expects the bearer token.
                                proxy_set_header Authorization "Bearer ${var.bearer_token}";
                                proxy_set_header Host $host;
                                proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
                                proxy_set_header X-Forwarded-Proto https;
                                proxy_set_header X-Real-IP $remote_addr;
                                # the /mail UI uses websockets (/mail/ws-state, /mail/ws-input)
                                proxy_http_version 1.1;
                                proxy_set_header Upgrade $http_upgrade;
                                proxy_set_header Connection $connection_upgrade;

                                proxy_pass http://app_upstream;
                            }

                            location @basic_auth_challenge {
                                add_header WWW-Authenticate 'Basic realm="mcp-agent-mail"' always;
                                return 401;
                            }

                            location @auth_rejected {
                                return 401;
                            }

                            location = /_auth {
                                internal;

                                proxy_intercept_errors on;
                                error_page 400 = @auth_rejected;

                                proxy_pass http://authserver-int.service.consul:8999/checkpassword/;
                                proxy_method POST;
                                proxy_pass_request_body off;
                                proxy_set_header Content-Length "";
                                proxy_set_header Authorization $http_authorization;
                                proxy_set_header X-Original-URI $request_uri;
                                proxy_set_header X-Original-Method $request_method;
                                proxy_set_header X-Forwarded-Proto https;
                                proxy_set_header Host authserver-int.service.consul;

                                proxy_cache       auth_cache;
                                proxy_cache_key   $http_authorization;
                                proxy_cache_valid 200 30s;
                                proxy_cache_valid 401 10s;
                                proxy_cache_valid 403 10s;
                                proxy_cache_lock  on;
                            }

                            location = /healthz {
                                access_log off;
                                return 200 "ok\n";
                            }
                        }
                    }
                EOF
            }

            service {
                name     = "mcp-agent-mail-edge"
                port     = "http"
                provider = "consul"
                tags     = [
                    "smartstack:hostname:mcp-mail.${var.domain}",
                    "smartstack:routing:hostname",
                    "smartstack:protocol:https",
                    "smartstack:https-redirect",
                    "smartstack:mode:http",
                    "smartstack:external",
                ]

                check {
                    type     = "http"
                    path     = "/healthz"
                    interval = "10s"
                    timeout  = "2s"
                }
            }

            resources {
                cpu    = 200
                memory = 128
            }
        }
    }
}
