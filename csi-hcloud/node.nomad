job "hcloud-csi-node" {
    datacenters = ["RZ19"]
    namespace   = "default"
    type        = "system"

    group "node" {
        task "plugin" {
            driver = "docker"

            config {
                # Get the latest version on https://hub.docker.com/r/hetznercloud/hcloud-csi-driver/tags
                image      = "hetznercloud/hcloud-csi-driver:v2.19.0"
                args       = [ "-node" ]
                privileged = true
            }

            env {
                CSI_ENDPOINT   = "unix://csi/csi.sock"
                ENABLE_METRICS = true
            }

            template {
                data        = <<EOH
HCLOUD_TOKEN="{{ with nomadVar "secrets/hcloud" }}{{ .fsn1_api_key }}{{ end }}"
EOH
                destination = "${NOMAD_SECRETS_DIR}/hcloud-token.env"
                env         = true
            }

            csi_plugin {
                id        = "csi.hetzner.cloud"
                type      = "node"
                mount_dir = "/csi"
            }

            resources {
                cpu    = 100
                memory = 64
            }
        }
    }
}
