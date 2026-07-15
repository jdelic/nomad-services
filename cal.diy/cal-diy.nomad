# Required plain Nomad vars:
#
#   domain
#     Public domain for the scheduling UI (schedule.[domain]).
#
#   cal_diy_image
#     Open-source cal.diy Docker image to run. Pin this for production.
#
#   redis_url
#     Existing Redis service to use. The hcloud environment provides this
#     through redis.local; this job does not schedule Redis.
#
# Required secret Nomad vars:
#
#   nomad/jobs/caldiy/app
#     nextauth_secret, calendso_encryption_key
#
#   nomad/jobs/caldiy/db
#     host, port, database, user, password

variable "domain" {
  type        = string
  description = "Public domain name for the cal.diy scheduling UI (schedule.[domain])."
  default     = "maurus.net"
}

variable "cal_diy_image" {
  type        = string
  description = "Open-source cal.diy web Docker image. Pin in production."
  default     = "calcom/cal.com:latest"
}

variable "redis_url" {
  type        = string
  description = "Existing Redis URL."
  default     = "redis://redis.service.consul:6379"
}

job "caldiy" {
  datacenters = ["RZ19", "vagrant"]
  type        = "service"

  group "app" {
    count = 1

    shutdown_delay = "10s"

    network {
      mode = "bridge"

      port "web" {
        to = 3000
      }

      dns {
        servers = ["169.254.1.1"]
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
      name     = "cal-diy-web"
      provider = "consul"
      port     = "web"
      tags = [
        "smartstack:hostname:schedule.${var.domain}",
        "smartstack:routing:hostname",
        "smartstack:protocol:https",
        "smartstack:https-redirect",
        "smartstack:mode:http",
        "smartstack:external",
      ]

      check {
        name     = "cal-diy-web-http"
        type     = "http"
        path     = "/"
        interval = "15s"
        timeout  = "5s"
      }
    }

    task "web" {
      driver = "docker"

      config {
        image = var.cal_diy_image
        ports = ["web"]
      }

      volume_mount {
        volume      = "host-ca-bundle"
        destination = "/etc/ssl/certs/ca-certificates.crt"
        read_only   = true
      }

      env {
        NEXT_PUBLIC_WEBAPP_URL      = "https://schedule.${var.domain}"
        NEXTAUTH_URL                = "https://schedule.${var.domain}"
        REDIS_URL                   = "${var.redis_url}"
        CALCOM_TELEMETRY_DISABLED   = "1"
        NEXT_PUBLIC_LICENSE_CONSENT = "agree"
        NODE_ENV                    = "production"
        PORT                        = "3000"
        NODE_EXTRA_CA_CERTS         = "/etc/ssl/certs/ca-certificates.crt"
        TURBO_ENV_MODE              = "loose"  # this will stop Turbo from filtering out NODE_EXTRA_CA_CERTS
      }

      template {
        destination = "${NOMAD_SECRETS_DIR}/web.env"
        env         = true
        change_mode = "restart"

        data = <<-EOF
DATABASE_URL={{ with nomadVar "nomad/jobs/caldiy/db" }}postgresql://{{ .user }}:{{ .password }}@{{ .host }}:{{ .port }}/{{ .database }}{{ end }}
DATABASE_DIRECT_URL={{ with nomadVar "nomad/jobs/caldiy/db" }}postgresql://{{ .user }}:{{ .password }}@{{ .host }}:{{ .port }}/{{ .database }}{{ end }}
NEXTAUTH_SECRET={{ with nomadVar "nomad/jobs/caldiy/app" }}{{ .nextauth_secret }}{{ end }}
CALENDSO_ENCRYPTION_KEY={{ with nomadVar "nomad/jobs/caldiy/app" }}{{ .calendso_encryption_key }}{{ end }}
EOF
      }

      resources {
        cpu    = 1000
        memory = 2048
      }
    }
  }
}
