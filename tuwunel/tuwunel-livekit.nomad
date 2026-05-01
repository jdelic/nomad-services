variable "matrix_server_name" {
    type        = string
    description = "Matrix homeserver identity, e.g. example.com"
}

variable "matrix_rtc_hostname" {
    type        = string
    description = "Public hostname for MatrixRTC / LiveKit traffic, e.g. matrix-rtc.example.com"
}



job "tuwunel-livekit" {
    datacenters = ["RZ19", "vagrant"]
    type        = "service"

    group "matrix-rtc" {
        count = 1

        network {
            mode = "host"

            port "jwt" {
                static = 8081
            }

            port "ws" {
                static = 7880
            }

            port "rtc_tcp" {
                static = 7881
            }

            # Nomad doesn't support ranged port declarations here, so we reserve
            # ten explicit UDP ports for a small LiveKit deployment.
            port "rtc_udp_00" {
                static = 50100
            }

            port "rtc_udp_01" {
                static = 50101
            }

            port "rtc_udp_02" {
                static = 50102
            }

            port "rtc_udp_03" {
                static = 50103
            }

            port "rtc_udp_04" {
                static = 50104
            }

            port "rtc_udp_05" {
                static = 50105
            }

            port "rtc_udp_06" {
                static = 50106
            }

            port "rtc_udp_07" {
                static = 50107
            }

            port "rtc_udp_08" {
                static = 50108
            }

            port "rtc_udp_09" {
                static = 50109
            }
        }

        restart {
            attempts = 10
            interval = "30m"
            delay    = "15s"
            mode     = "delay"
        }

        volume "host-ca-bundle" {
            type      = "host"
            source    = "host-ca-bundle"
            read_only = true
        }

        service {
            name     = "tuwunel-matrix-rtc-livekit"
            provider = "consul"
            port     = "ws"
            tags = [
                "smartstack:hostname:${var.matrix_rtc_hostname}",
                "smartstack:protocol:https",
                "smartstack:https-redirect",
                "smartstack:mode:http",
                "smartstack:external",
            ]

            check {
                name     = "matrix-rtc-livekit-tcp"
                type     = "tcp"
                port     = "ws"
                interval = "15s"
                timeout  = "5s"
            }
        }

        service {
            name     = "tuwunel-matrix-rtc-jwt"
            provider = "consul"
            port     = "jwt"
            tags = [
                "smartstack:proxypath:${var.matrix_rtc_hostname}:/livekit/jwt",
                "smartstack:proxypath-strip-prefix:/livekit/jwt",
                "smartstack:protocol:https",
                "smartstack:mode:http",
                "smartstack:external",
            ]

            check {
                name     = "matrix-rtc-jwt-http"
                type     = "http"
                port     = "jwt"
                path     = "/healthz"
                interval = "15s"
                timeout  = "5s"
            }
        }

        service {
            name     = "tuwunel-matrix-rtc-tcp"
            provider = "consul"
            port     = "rtc_tcp"
            tags = [
                "smartstack:hostname:${var.matrix_rtc_hostname}",
                "smartstack:protocol:tcp",
                "smartstack:external",
                "smartstack:routing:port",
                "smartstack:extport:7881",
            ]

            check {
                name     = "matrix-rtc-tcp"
                type     = "tcp"
                port     = "rtc_tcp"
                interval = "15s"
                timeout  = "5s"
            }
        }

        service {
            name     = "tuwunel-matrix-rtc-udp"
            provider = "consul"
            port     = "rtc_udp_00"
            tags = [
                "smartstack:hostname:${var.matrix_rtc_hostname}",
                "smartstack:protocol:udp",
                "smartstack:external",
                "smartstack:routing:port",
                "smartstack:extport:50100-50109",
            ]
        }

        task "livekit" {
            driver = "docker"

            volume_mount {
                volume      = "host-ca-bundle"
                destination = "/etc/ssl/certs/ca-certificates.crt"
                read_only   = true
            }

            config {
                image = "livekit/livekit-server:v1.11.0"
                args  = ["--config", "/local/livekit.yaml"]
            }

            template {
                destination = "local/livekit.yaml"
                change_mode = "restart"

                data = <<-EOF
port: 7880
bind_addresses:
    - ""
room:
    auto_create: false
rtc:
    tcp_port: 7881
    port_range_start: 50100
    port_range_end: 50109
    use_external_ip: true
    enable_loopback_candidate: false
keys:
{{ with nomadVar "nomad/jobs/tuwunel/matrix-rtc" }}
    {{ .livekit_key }}: "{{ .livekit_secret }}"
{{ end }}
EOF
            }

            resources {
                cpu    = 1000
                memory = 1024
            }
        }

        task "jwt" {
            driver = "docker"

            volume_mount {
                volume      = "host-ca-bundle"
                destination = "/etc/ssl/certs/ca-certificates.crt"
                read_only   = true
            }

            config {
                image = "ghcr.io/element-hq/lk-jwt-service:0.4.4"
            }

            env {
                LIVEKIT_FULL_ACCESS_HOMESERVERS = "${var.matrix_server_name}"
                LIVEKIT_JWT_BIND                = ":8081"
                LIVEKIT_URL                     = "wss://${var.matrix_rtc_hostname}"
            }

            template {
                destination = "${NOMAD_SECRETS_DIR}/matrix-rtc.env"
                env         = true
                change_mode = "restart"

                data = <<-EOF
{{ with nomadVar "nomad/jobs/tuwunel/matrix-rtc" -}}
LIVEKIT_KEY={{ .livekit_key }}
LIVEKIT_SECRET={{ .livekit_secret }}
{{ end -}}
EOF
            }

            resources {
                cpu    = 100
                memory = 128
            }
        }
    }
}