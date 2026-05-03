variable "matrix_server_name" {
    type        = string
    description = "Matrix homeserver identity, e.g. example.com"
}

variable "matrix_rtc_hostname" {
    type        = string
    description = "Public hostname for MatrixRTC / LiveKit traffic, e.g. matrix-rtc.example.com"
}

variable "livekit_external_ip" {
    type        = string
    description = "External IP address to advertise to LiveKit clients. If empty, Livekit will use Google's STUN servers to find it. Mostly useful for testing setups."
    default     = ""
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

            port "turn_tls" {
                static = 5349
            }

            port "turn_udp" {
                static = 3478
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

        task "livekit" {
            driver = "docker"

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
                    "smartstack:mode:udp",
                    "smartstack:external",
                    "smartstack:routing:port",
                    "smartstack:extport:50100-50109",
                ]
            }

            service {
                name     = "tuwunel-matrix-rtc-turn-tls"
                provider = "consul"
                port     = "turn_tls"
                tags = [
                    "smartstack:hostname:${var.matrix_rtc_hostname}",
                    "smartstack:protocol:sni",
                    "smartstack:ssl-terminate",
                    "smartstack:mode:tcp",
                    "smartstack:external",
                    "smartstack:routing:port",
                    "smartstack:extport:5349",
                    "smartstack:outport:tcp:5349",
                ]

                check {
                    name     = "matrix-rtc-turn-tls"
                    type     = "tcp"
                    port     = "turn_tls"
                    interval = "15s"
                    timeout  = "5s"
                }
            }

            service {
                name     = "tuwunel-matrix-rtc-turn-udp"
                provider = "consul"
                port     = "turn_udp"
                tags = [
                    "smartstack:hostname:${var.matrix_rtc_hostname}",
                    "smartstack:protocol:udp",
                    "smartstack:mode:udp",
                    "smartstack:external",
                    "smartstack:routing:port",
                    "smartstack:extport:3478",
                    "smartstack:outport:udp:3478",
                    "smartstack:outport:udp:55000-60000",
                ]
            }

            volume_mount {
                volume      = "host-ca-bundle"
                destination = "/etc/ssl/certs/ca-certificates.crt"
                read_only   = true
            }

            config {
                image = "livekit/livekit-server:v1.11.0"
                network_mode = "host"
                args  = ["--config", "/local/livekit.yaml"]
            }

            template {
                destination = "local/livekit.yaml"
                change_mode = "restart"

                data = <<-EOF
port: {{env "NOMAD_PORT_ws"}}
bind_addresses:
    - {{env "NOMAD_IP_ws"}}
room:
    auto_create: false
rtc:
    tcp_port: {{env "NOMAD_PORT_rtc_tcp"}}
    udp_port: 50100-50109
{{- if eq "${var.livekit_external_ip}" "" }}
    use_external_ip: true
{{- else }}
    use_external_ip: false
    node_ip: "${var.livekit_external_ip}"
{{- end }}
    ips:
        includes:
            - {{env "NOMAD_IP_ws"}}/32
    enable_loopback_candidate: false
keys:
{{ with nomadVar "nomad/jobs/tuwunel/matrix-rtc" }}
    {{ .livekit_key }}: "{{ .livekit_secret }}"
{{ end }}
turn:
    enabled: true
    external_tls: true
    tls_port: 5349
    udp_port: 3478
    relay_range_start: 55000
    relay_range_end: 60000
    domain: ${var.matrix_rtc_hostname}
EOF
            }

            resources {
                cpu    = 1000
                memory = 1024
            }
        }

        task "jwt" {
            driver = "docker"

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

            volume_mount {
                volume      = "host-ca-bundle"
                destination = "/etc/ssl/certs/ca-certificates.crt"
                read_only   = true
            }

            config {
                image = "ghcr.io/element-hq/lk-jwt-service:0.4.4"
                network_mode = "host"
            }

            env {
                LIVEKIT_FULL_ACCESS_HOMESERVERS = "${var.matrix_server_name}"
                LIVEKIT_JWT_BIND                = "${NOMAD_IP_jwt}:${NOMAD_PORT_jwt}"
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