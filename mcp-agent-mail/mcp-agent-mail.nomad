variable "registry_password" {
    type = string
}

variable "postgresql_password" {
    type      = string
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
        volume "archive" {
            type            = "csi"
            source          = "mcp-agent-mail-data"
            access_mode     = "single-node-writer"
            attachment_mode = "file-system"
            read_only       = false
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
                grace           = "45s"
                ignore_warnings = false
            }
        }

        task "server" {
            driver = "docker"

            config {
                image = "registry.maurus.net/agent-tools/mcp_agent_mail:2026.04.02"
                ports = ["http"]

                auth {
                    server_address = "registry.maurus.net"
                    username       = "nomad-deploy@maurus.net"
                    password       = var.registry_password
                }
                #force_pull = true
            }

            env {
                #DATABASE_URL                       = "postgresql+asyncpg://mcp-agent-mail:${var.postgres_password}@192.168.55.1:5432/mcp-agent-mail"
                HTTP_HOST                          = "0.0.0.0"
                HTTP_PORT                          = "8765"
                STORAGE_ROOT                       = "/data/archive"
                TOOL_METRICS_EMIT_ENABLED          = "true"
                TOOL_METRICS_EMIT_INTERVAL_SECONDS = "120"
            }

            volume_mount {
                volume      = "archive"
                destination = "/data/archive"
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

                        upstream app_upstream {
                            {{- range nomadService "mcp-agent-mail" }}
                            server {{ .Address }}:{{ .Port }};
                            {{- end }}
                        }

                        server {
                            listen 8080;

                            location / {
                                if ($http_authorization = "") {
                                    add_header WWW-Authenticate 'Basic realm="mcp-agent-mail"' always;
                                    return 401;
                                }
                                auth_request /_auth;

                                proxy_set_header Host $host;
                                proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
                                proxy_set_header X-Forwarded-Proto $scheme;
                                proxy_set_header X-Real-IP $remote_addr;

                                proxy_pass http://app_upstream;
                            }

                            location = /_auth {
                                internal;

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
                    "smartstack:hostname:mcp-mail.maurus.net",
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
