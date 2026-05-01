# Required plain Nomad vars:
#
#   matrix_server_name
#     Matrix homeserver identity. This becomes the MXID domain in user IDs like
#     @alice:example.com. This is often the apex domain, not the service host.
#     Example: example.com
#
#   matrix_client_hostname
#     Public hostname for Matrix client-server API traffic. HAProxy routes this
#     host to Tuwunel's HTTP listener.
#     Example: matrix.example.com
#
#   matrix_client_base_url
#     Full external client API base URL published in /.well-known/matrix/client
#     and used by SSO callbacks.
#     Example: https://matrix.example.com
#
#   matrix_element_hostname
#     Public hostname for the Element Web Matrix client.
#     Example: element.example.com
#
#   matrix_well_known_hostname
#     Hostname where /.well-known/matrix/* is served. HAProxy uses
#     smartstack:proxypath to forward only that path to the Matrix service.
#     Example: example.com
#
#   matrix_federation_hostname
#     Public hostname for Matrix federation traffic on the load balancer.
#     This can be the same host as matrix_client_hostname.
#     Example: matrix.example.com
#
#   matrix_federation_server
#     Value published in /.well-known/matrix/server for remote homeservers.
#     Include the external federation port when using a non-default endpoint.
#     Example: matrix.example.com:8448
#
#   matrix_rtc_hostname
#     Public hostname for MatrixRTC / LiveKit traffic. The same host serves
#     LiveKit websockets and the JWT endpoint via path-based routing.
#     Example: matrix-rtc.example.com
#
#   issuer_url
#     OpenID Connect issuer URL. For Authserver this is the /o2 endpoint.
#     Example: https://auth.example.com/o2
#

variable "matrix_server_name" {
    type        = string
    description = "Matrix homeserver identity, e.g. example.com"
}

variable "matrix_client_hostname" {
    type        = string
    description = "Public hostname for Matrix client-server API traffic, e.g. matrix.example.com"
}

variable "matrix_client_baseurl" {
    type        = string
    description = "Full external client API base URL published in /.well-known/matrix/client, e.g. https://matrix.example.com"
}

variable "matrix_element_hostname" {
    type        = string
    description = "Public hostname for the Element Web Matrix client, e.g. element.example.com"
}

variable "matrix_well_known_hostname" {
    type        = string
    description = "Hostname where /.well-known/matrix/* is served, e.g. example.com"
}

variable "matrix_federation_hostname" {
    type        = string
    description = "Public hostname for Matrix federation traffic, e.g. matrix.example.com"
}

variable "matrix_federation_server" {
    type        = string
    description = "Value published in /.well-known/matrix/server for remote homeservers, e.g. matrix.example.com:8448"
}

variable "matrix_rtc_hostname" {
    type        = string
    description = "Public hostname for MatrixRTC / LiveKit traffic, e.g. matrix-rtc.example.com"
}

variable "issuer_url" {
    type        = string
    description = "OpenID Connect issuer URL for Authserver, e.g. https://auth.example.com/o2"
}


# Required secret Nomad vars:
#
#   nomad/jobs/tuwunel/oidc
#     OIDC client credentials used by Tuwunel's identity_provider config.
#     Required keys: client_id, client_secret
#
#   nomad/jobs/tuwunel/matrix-rtc
#     Shared LiveKit API key and secret used by livekit-server and
#     lk-jwt-service.
#     Required keys: livekit_key, livekit_secret
#     These are locally chosen shared credentials, not values issued by an
#     external service. livekit_key is a stable key id, for example "matrix".
#     livekit_secret should be a long random string, for example:
#       openssl rand -base64 48
#     Store both in Nomad's variable store. Do not enter them into Tuwunel
#     separately; Tuwunel only publishes the MatrixRTC JWT endpoint URL, while
#     lk-jwt-service signs LiveKit tokens and livekit-server verifies them.

job "tuwunel" {
    datacenters = ["RZ19", "vagrant"]
    type        = "service"

    group "homeserver" {
        count = 1

        network {
            mode = "bridge"

            port "http" {
                to = 8008
            }
        }

        restart {
            attempts = 10
            interval = "30m"
            delay    = "15s"
            mode     = "delay"
        }

        volume "tuwunel-data" {
            type            = "csi"
            source          = "tuwunel-data"
            access_mode     = "single-node-writer"
            attachment_mode = "file-system"
            read_only       = false
        }

        volume "host-ca-bundle" {
            type      = "host"
            source    = "host-ca-bundle"
            read_only = true
        }

        task "init-data" {
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
mkdir -p /data/database /data/media
chmod 0700 /data/database
chmod 0755 /data/media
EOF
                ]
            }

            volume_mount {
                volume      = "tuwunel-data"
                destination = "/data"
                read_only   = false
            }

            resources {
                cpu    = 50
                memory = 64
            }
        }

        service {
            name     = "tuwunel-client"
            provider = "consul"
            port     = "http"
            tags = [
                "smartstack:hostname:${var.matrix_client_hostname}",
                "smartstack:proxypath:${var.matrix_well_known_hostname}:/.well-known/matrix",
                "smartstack:protocol:https",
                "smartstack:https-redirect",
                "smartstack:mode:http",
                "smartstack:external",
            ]

            check {
                name     = "tuwunel-client-http"
                type     = "http"
                path     = "/_tuwunel/server_version"
                interval = "15s"
                timeout  = "5s"
            }
        }

        service {
            name     = "tuwunel-federation"
            provider = "consul"
            port     = "http"
            tags = [
                "smartstack:hostname:${var.matrix_federation_hostname}",
                "smartstack:protocol:https",
                "smartstack:mode:http",
                "smartstack:external",
                "smartstack:routing:port",
                "smartstack:extport:8448",
            ]

            check {
                name     = "tuwunel-federation-http"
                type     = "http"
                path     = "/_matrix/federation/v1/version"
                interval = "15s"
                timeout  = "5s"
            }
        }

        task "server" {
            driver = "docker"

            config {
                image = "ghcr.io/matrix-construct/tuwunel:latest"
            }

            env {
                RUST_BACKTRACE = "1"
                TUWUNEL_CONFIG = "/local/tuwunel.toml"
                TZ             = "UTC"
            }

            volume_mount {
                volume      = "tuwunel-data"
                destination = "/data"
                read_only   = false
            }

            volume_mount {
                volume      = "host-ca-bundle"
                destination = "/etc/ssl/certs/ca-certificates.crt"
                read_only   = true
            }

            template {
                destination = "local/authserver-oidc-client-secret"
                change_mode = "restart"

                data = <<-EOF
{{ with nomadVar "nomad/jobs/tuwunel/oidc" }}{{ .client_secret }}{{ end }}
EOF
            }

            template {
                destination = "local/tuwunel.toml"
                change_mode = "restart"

                data = <<-EOF
[global]
server_name = "${var.matrix_server_name}"
address = "0.0.0.0"
port = 8008
database_path = "/data/database"
allow_registration = false
log = "info"
log_to_stderr = true

[global.well_known]
client = "${var.matrix_client_baseurl}"
server = "${var.matrix_federation_server}"
livekit_url = "https://${var.matrix_rtc_hostname}/livekit/jwt"

[[global.identity_provider]]
brand = "authserver"
name = "Authserver"
client_id = "{{ with nomadVar "nomad/jobs/tuwunel/oidc" }}{{ .client_id }}{{ end }}"
client_secret_file = "/local/authserver-oidc-client-secret"
issuer_url = "${var.issuer_url}"
scope = ["openid", "profile", "email", "username"]
trusted = true
registration = true
default = true
unique_id_fallbacks = false

[global.storage_provider.media.local]
base_path = "/data/media"
create_if_missing = true
EOF
            }

            resources {
                cpu    = 1000
                memory = 2048
            }
        }
    }

    group "element-web" {
        count = 1

        network {
            mode = "bridge"

            port "http" {
                to = 8080
            }
        }

        restart {
            attempts = 10
            interval = "30m"
            delay    = "15s"
            mode     = "delay"
        }

        service {
            name     = "tuwunel-element-web"
            provider = "consul"
            port     = "http"
            tags = [
                "smartstack:hostname:${var.matrix_element_hostname}",
                "smartstack:protocol:https",
                "smartstack:https-redirect",
                "smartstack:mode:http",
                "smartstack:external",
            ]

            check {
                name     = "element-web-http"
                type     = "http"
                path     = "/config.json"
                interval = "15s"
                timeout  = "5s"
            }
        }

        task "element-web" {
            driver = "docker"

            config {
                image   = "vectorim/element-web:latest"
                ports   = ["http"]
                volumes = [
                    "local/config.json:/app/config.json:ro",
                ]
            }

            env {
                ELEMENT_WEB_PORT = "8080"
            }

            template {
                destination = "local/config.json"
                change_mode = "restart"

                data = <<-EOF
{
    "default_server_name": "${var.matrix_server_name}",
    "default_server_config": {
        "m.homeserver": {
            "base_url": "${var.matrix_client_baseurl}"
        }
    },
    "disable_custom_urls": false
}
EOF
            }

            resources {
                cpu    = 200
                memory = 256
            }
        }
    }
}
