job "beads-dolt" {
    datacenters = ["RZ19", "vagrant"]
    type        = "service"

    group "db" {
        count = 1

        network {
            mode = "bridge"
            port "mysql" {
                to = 3306
            }
        }

        volume "beads-dolt-data" {
            type            = "csi"
            source          = "beads-dolt-data"
            access_mode     = "single-node-writer"
            attachment_mode = "file-system"
            read_only       = false
        }

        task "dolt" {
            driver = "docker"

            volume_mount {
                volume      = "beads-dolt-data"
                destination = "/var/lib/dolt"
                read_only   = false
            }

            config {
                image = "dolthub/dolt-sql-server:latest"
                ports = ["mysql"]

                mounts = [
                    {
                        type     = "bind"
                        source   = "local/initdb"
                        target   = "/docker-entrypoint-initdb.d"
                        readonly = true
                    }
                ]
            }

            service {
                name = "beads-dolt"
                port = "mysql"
                tags = [
                    "smartstack:external",
                    "smartstack:hostname:beads.maurus.net",
                    "smartstack:routing:port",
                    "smartstack:extport:33306",
                    "smartstack:protocol:tcp",
                ]

                check {
                    name     = "tcp"
                    type     = "tcp"
                    port     = "mysql"
                    interval = "10s"
                    timeout  = "2s"
                }
            }

            template {
                destination = "local/initdb/01-users.sql"
                change_mode = "noop"

                data = <<-EOF
CREATE DATABASE IF NOT EXISTS test;
EOF
            }

            template {
                destination = "${NOMAD_SECRETS_DIR}/dolt.env"
                env         = true
                change_mode = "restart"

                data = <<-EOF
DOLT_ROOT_HOST=%
DOLT_ROOT_PASSWORD={{ with nomadVar "nomad/jobs/beads-dolt/db" }}{{ .root_password }}{{ end }}
EOF
            }

            resources {
                cpu    = 500
                memory = 512
            }

            restart {
                attempts = 10
                interval = "30m"
                delay    = "15s"
                mode     = "delay"
            }
        }

        task "migrate" {
            lifecycle {
                hook    = "poststart"
                sidecar = false
            }

            driver = "docker"

            config {
                image   = "mysql:8.0"
                command = "sh"
                args = [
                    "-ec",
                    <<-EOS
                    until mysqladmin ping -h 127.0.0.1 -P 3306 --silent; do sleep 2; done
                    mysql -h 127.0.0.1 -P 3306 -u root -p"$ROOT_PASSWORD" <<SQL
                        DROP DATABASE IF EXISTS test;
                        CREATE DATABASE IF NOT EXISTS test;
                        CREATE DATABASE IF NOT EXISTS ssh_phone_agent;

                        CREATE USER IF NOT EXISTS 'beads'@'%' IDENTIFIED BY '${BEADS_PASSWORD}';
                        ALTER USER 'beads'@'%' IDENTIFIED BY '${BEADS_PASSWORD}';
                        GRANT ALL PRIVILEGES ON test.* TO 'beads'@'%';
                        GRANT ALL PRIVILEGES ON ssh_phone_agent.* TO 'beads'@'%';
                    SQL
                    EOS
                ]
            }

            template {
                destination = "${NOMAD_SECRETS_DIR}/migrate.env"
                env         = true
                change_mode = "restart"
                data        = <<-EOF
ROOT_PASSWORD={{ with nomadVar "nomad/jobs/beads-dolt/db" }}{{ .root_password }}{{ end }}
BEADS_PASSWORD={{ with nomadVar "nomad/jobs/beads-dolt/db" }}{{ .beads_password }}{{ end }}
EOF
            }
        }
    }
}