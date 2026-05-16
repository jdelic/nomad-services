variable "matrix_server_name" {
    type        = string
    description = "Matrix homeserver identity, e.g. example.com"
}

variable "matrix_rtc_hostname" {
    type        = string
    description = "Public hostname for MatrixRTC / LiveKit traffic, e.g. matrix-rtc.example.com"
}

variable "livekit_external_ipv4" {
    type        = string
    description = "External IPv4 address to advertise to LiveKit clients. If empty, Livekit will use Google's STUN servers to find it. Mostly useful for testing setups."
}

variable "livekit_external_ipv6" {
    type        = string
    description = "External IPv6 address to advertise to LiveKit clients. If empty, Livekit will use Google's STUN servers to find it. Mostly useful for testing setups."
    default     = ""
}

variable "turn_server_hostname" {
    type        = string
    description = "Hostname for the TURN server to advertise to clients, e.g. turn.example.com."
}

job "tuwunel-livekit" {
    datacenters = ["RZ19", "vagrant"]
    type        = "service"
    node_pool   = "edge"

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
                host_network = "external"  # as we work on the "edge" node_pool, we can have direct internet access
            }

            # port "turn_tls" {
            #     static = 5349
            # }
            #
            # port "turn_udp" {
            #     static = 3478
            #     host_network = "external"  # as we work on the "edge" node_pool, we can have direct internet access
            # }
            #
            port "rtc_udp_00" {
                static = 7882
                host_network = "external"  # as we work on the "edge" node_pool, we can have direct internet access
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
                    "smartstack:routing:hostname",
                    "smartstack:protocol:https",
                    "smartstack:https-redirect",
                    "smartstack:mode:http",
                    "smartstack:external",
                    "smartstack:hostport:tcp:7880",
                    "haproxy:backend:timeout:tunnel:1h",
                    "haproxy:backend:timeout:connect:30s",
                    "haproxy:backend:timeout:server:5m",
                    "smartstack:cors:allow-origin:*",
                    "smartstack:cors:allow-methods:GET,POST,PUT,DELETE,OPTIONS",
                    "smartstack:cors:allow-headers:X-Requested-With,Content-Type,Authorization",
                    "haproxy:backend:server-extra:proto h1",
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
                    "smartstack:protocol:tcp",
                    "smartstack:external",
                    "smartstack:extport:7881",
                    "smartstack:outport:tcp:7881",
                ]

                # check {
                #     name     = "matrix-rtc-tcp"
                #     type     = "tcp"
                #     port     = "rtc_tcp"
                #     interval = "15s"
                #     timeout  = "5s"
                # }
            }

            service {
                name     = "tuwunel-matrix-rtc-udp"
                provider = "consul"
                port     = "rtc_udp_00"
                tags = [
                    "smartstack:protocol:udp",
                    "smartstack:external",
                    "smartstack:extport:56000-56010",
                    "smartstack:outport:udp:56000-56010",
                    "smartstack:hostport:udp:56000-56010",
                ]
            }

            # service {
            #     name     = "tuwunel-matrix-rtc-turn-tls"
            #     provider = "consul"
            #     port     = "turn_tls"
            #     tags = [
            #         "smartstack:hostname:${var.turn_server_hostname}",
            #         "smartstack:protocol:sni",
            #         "smartstack:mode:tcp",
            #         "smartstack:external",
            #         "smartstack:routing:hostname",
            #         "smartstack:hostport:tcp:5349",
            #     ]
            #
            #     check {
            #         name     = "matrix-rtc-turn-tls"
            #         type     = "tcp"
            #         port     = "turn_tls"
            #         interval = "15s"
            #         timeout  = "5s"
            #     }
            # }
            #
            # service {
            #     name     = "tuwunel-matrix-rtc-turn-udp"
            #     provider = "consul"
            #     port     = "turn_udp"
            #     tags = [
            #         "smartstack:hostname:${var.turn_server_hostname}",
            #         "smartstack:protocol:udp",
            #         "smartstack:mode:udp",
            #         "smartstack:external",
            #         "smartstack:extport:3478",
            #         "smartstack:outport:udp:3478",
            #         "smartstack:outport:udp:55000-56000",
            #         "smartstack:hostport:udp:55000-56000",
            #     ]
            # }

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
    auto_create: true
logging:
    level: debug
    sample: true
rtc:
    #port_range_start: 56000
    #port_range_end: 56900
    tcp_port: {{env "NOMAD_PORT_rtc_tcp"}}
    udp_port: 56000
    use_external_ip: false
    use_ice_lite: false
    node_ip: "${var.livekit_external_ipv4},${var.livekit_external_ipv6}"
    enable_loopback_candidate: false
    interfaces:
        includes:
            - eth0
keys:
{{ with nomadVar "nomad/jobs/tuwunel-livekit/matrix-rtc" }}
    {{ .livekit_key }}: "{{ .livekit_secret }}"
{{ end }}
turn:
    enabled: false
    external_tls: true
    tls_port: 5349
    udp_port: 3478
    relay_range_start: 55000
    relay_range_end: 55010
    domain: ${var.turn_server_hostname}
    bind_addresses:
        - {{env "NOMAD_IP_ws"}}
        - ${var.livekit_external_ipv4}
        - ${var.livekit_external_ipv6}
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
                    "smartstack:hostport:tcp:8081",
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
{{ with nomadVar "nomad/jobs/tuwunel-livekit/matrix-rtc" -}}
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
