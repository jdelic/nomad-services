job "debugshell" {
    datacenters = ["RZ19", "vagrant"]
    type        = "service"

    group "shell" {
        count = 1

        volume "host-ca-bundle" {
            type      = "host"
            source    = "host-ca-bundle"
            read_only = true
        }

        network {
            mode = "bridge"
        }

        task "debian" {
            driver = "docker"

            volume_mount {
                volume      = "host-ca-bundle"
                destination = "/etc/ssl/certs/ca-certificates.crt"
                read_only   = true
            }

            config {
                image   = "nicolaka/netshoot:latest"
                command = "sleep"
                args    = ["infinity"]
            }

            resources {
                cpu    = 100
                memory = 512
            }
        }
    }
}
