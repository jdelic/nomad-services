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

  # v6.2.0 (2026-03-02) is the newest published tag and is what :latest currently
  # resolves to (sha256:ace3bb1219fb...), so pinning it is a no-op for a running
  # deployment. Upstream has since renamed the OSS repo to calcom/cal.diy, but
  # that Docker Hub repo has no tags yet -- keep using calcom/cal.com until it does.
  default = "calcom/cal.com:v6.2.0"
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

        # Org-subdomain machinery. Both are parsed as JSON.parse("[" + value + "]"),
        # so they are comma-separated *quoted* strings without the brackets.
        #
        # ALLOWED_HOSTNAMES holds the base domain, not the app hostname: cal.com
        # checks that the WEBAPP_URL host ends with ".${var.domain}" and takes the
        # remaining label as the org slug. Leaving it empty is what produces the
        # "Match of WEBAPP_URL with ALLOWED_HOSTNAMES failed" warning on every request.
        #
        # That makes "schedule" the derived org slug, so it must be listed in
        # RESERVED_SUBDOMAINS -- otherwise every request is resolved against a
        # non-existent organization instead of this single-tenant instance.
        ALLOWED_HOSTNAMES   = "\"${var.domain}\""
        RESERVED_SUBDOMAINS = "\"schedule\""

        # Telemetry opt-outs, one per vendor that ships inside this image.
        #
        # DO_NOT_TRACK is the cross-vendor convention and already covers Turborepo;
        # TURBO_TELEMETRY_DISABLED is kept as the explicit belt-and-braces. Both are
        # read by the turbo binary itself, so TURBO_ENV_MODE does not affect them.
        #
        # CHECKPOINT_DISABLE stops the Prisma CLI phoning checkpoint.prisma.io, which
        # it otherwise does on every container start via `prisma migrate deploy`.
        #
        # NEXT_TELEMETRY_DISABLED is *not* in turbo.json's globalEnv, so like
        # NODE_EXTRA_CA_CERTS below it only reaches `next start` because of
        # TURBO_ENV_MODE = "loose".
        #
        # CALCOM_TELEMETRY_DISABLED is a no-op as of v6.2.0 -- cal.com's own Jitsu
        # collector is no longer present in the built app -- but keep it set so the
        # opt-out survives a version bump that reintroduces it.
        DO_NOT_TRACK              = "1"
        TURBO_TELEMETRY_DISABLED  = "1"
        NEXT_TELEMETRY_DISABLED   = "1"
        CHECKPOINT_DISABLE        = "1"
        CALCOM_TELEMETRY_DISABLED = "1"

        NEXT_PUBLIC_LICENSE_CONSENT = "agree"
        NODE_ENV                    = "production"
        PORT                        = "3000"
        NODE_EXTRA_CA_CERTS         = "/etc/ssl/certs/ca-certificates.crt"
        TURBO_ENV_MODE              = "loose"  # this will stop Turbo from filtering out NODE_EXTRA_CA_CERTS
        EMAIL_SERVER_HOST           = "mail-smtp.service.consul"
        EMAIL_SERVER_PORT           = "25"
        EMAIL_FROM                  = "noreply@maurus.net"
      }

      template {
        destination = "${NOMAD_SECRETS_DIR}/web.env"
        env         = true
        change_mode = "restart"

        # The image entrypoint runs wait-for-it.sh on DATABASE_HOST before applying
        # migrations, and that script wants a single host:port argument. Without it
        # the wait degrades to a no-op and prisma migrate deploy races Postgres on a
        # cold start.
        data = <<-EOF
DATABASE_HOST={{ with nomadVar "nomad/jobs/caldiy/db" }}{{ .host }}:{{ .port }}{{ end }}
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
