# Required plain Nomad vars:
#
#   cal_diy_hostname
#     Public hostname for the scheduling UI.
#
#   cal_diy_image
#     Open-source cal.diy Docker image to run. Pin this for production.
#
#   postgres_host, postgres_port, postgres_database, postgres_user
#     Existing PostgreSQL service to use. The hcloud environment provides this
#     through postgresql.local; this job does not schedule PostgreSQL.
#
#   redis_url
#     Existing Redis service to use. The hcloud environment provides this
#     through redis.local; this job does not schedule Redis.
#
# Required secret Nomad vars:
#
#   nomad/jobs/cal.diy/app
#     nextauth_secret, calendso_encryption_key
#
#   nomad/jobs/cal.diy/db
#     postgres_password

variable "cal_diy_hostname" {
  type        = string
  description = "Public hostname for the cal.diy scheduling UI."
  default     = "schedule.maurus.net"
}

variable "cal_diy_image" {
  type        = string
  description = "Open-source cal.diy web Docker image. Pin in production."
  default     = "calcom/cal.diy:latest"
}

variable "postgres_host" {
  type        = string
  description = "Existing PostgreSQL hostname."
  default     = "postgresql.local"
}

variable "postgres_port" {
  type        = string
  description = "Existing PostgreSQL port."
  default     = "5432"
}

variable "postgres_database" {
  type        = string
  description = "PostgreSQL database name for cal.diy."
  default     = "caldiy"
}

variable "postgres_user" {
  type        = string
  description = "PostgreSQL user for cal.diy."
  default     = "caldiy"
}

variable "redis_url" {
  type        = string
  description = "Existing Redis URL."
  default     = "redis://redis.local:6379"
}

job "cal-diy" {
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
    }

    restart {
      attempts = 10
      interval = "30m"
      delay    = "15s"
      mode     = "delay"
    }

    volume "uploads" {
      type            = "csi"
      source          = "cal-diy-uploads"
      access_mode     = "single-node-writer"
      attachment_mode = "file-system"
      read_only       = false
    }

    task "init-uploads" {
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
mkdir -p /uploads
chown -R 1000:1000 /uploads
chmod 0750 /uploads
EOF
        ]
      }

      volume_mount {
        volume      = "uploads"
        destination = "/uploads"
        read_only   = false
      }

      resources {
        cpu    = 50
        memory = 64
      }
    }

    service {
      name     = "cal-diy-web"
      provider = "consul"
      port     = "web"
      tags = [
        "smartstack:hostname:${var.cal_diy_hostname}",
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

      env {
        NEXT_PUBLIC_WEBAPP_URL      = "https://${var.cal_diy_hostname}"
        NEXTAUTH_URL                = "https://${var.cal_diy_hostname}"
        DATABASE_HOST               = "${var.postgres_host}"
        DATABASE_PORT               = "${var.postgres_port}"
        DATABASE_NAME               = "${var.postgres_database}"
        DATABASE_USER               = "${var.postgres_user}"
        REDIS_URL                   = "${var.redis_url}"
        CALCOM_TELEMETRY_DISABLED   = "1"
        NEXT_PUBLIC_LICENSE_CONSENT = "agree"
        NODE_ENV                    = "production"
        PORT                        = "3000"
      }

      template {
        destination = "${NOMAD_SECRETS_DIR}/web.env"
        env         = true
        change_mode = "restart"

        data = <<-EOF
DATABASE_URL=postgresql://${var.postgres_user}:{{ with nomadVar "nomad/jobs/cal.diy/db" }}{{ .postgres_password }}{{ end }}@${var.postgres_host}:${var.postgres_port}/${var.postgres_database}
DATABASE_DIRECT_URL=postgresql://${var.postgres_user}:{{ with nomadVar "nomad/jobs/cal.diy/db" }}{{ .postgres_password }}{{ end }}@${var.postgres_host}:${var.postgres_port}/${var.postgres_database}
NEXTAUTH_SECRET={{ with nomadVar "nomad/jobs/cal.diy/app" }}{{ .nextauth_secret }}{{ end }}
CALENDSO_ENCRYPTION_KEY={{ with nomadVar "nomad/jobs/cal.diy/app" }}{{ .calendso_encryption_key }}{{ end }}
EOF
      }

      volume_mount {
        volume      = "uploads"
        destination = "/uploads"
        read_only   = false
      }

      resources {
        cpu    = 1000
        memory = 2048
      }
    }
  }
}
