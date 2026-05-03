variable "domain" {
    type    = string
    default = "maurus.net"
}

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

        task "git-init" {
            driver = "docker"

            lifecycle {
                hook    = "prestart"
                sidecar = false
            }

            volume_mount {
                volume      = "beads-dolt-data"
                destination = "/dolt"
                read_only   = false
            }

            config {
                image   = "debian:trixie-slim"
                command = "/usr/bin/bash"
                args = [
                    "-ec",
                    <<-EOS
                    if [ ! -d "/dolt/git/ssh-phone-agent" ]; then
                        echo "Initializing Dolt git remote..."
                        mkdir -p /dolt/git/ssh-phone-agent
                        cd /dolt/git/ssh-phone-agent
                        apt update && apt install -y --no-install-recommends git
                        git config --global --add safe.directory /dolt/git/ssh-phone-agent
                        git init --bare -b main
                        echo "Git remote initialized at /dolt/git/ssh-phone-agent"
                        mkdir -p /dolt/tmp/
                        cd /dolt/tmp/
                        git clone /dolt/git/ssh-phone-agent
                        git config --global --add safe.directory /dolt/tmp/ssh-phone-agent
                        cd ssh-phone-agent
                        git config user.name "Init"
                        git config user.email "dolt-init@local"
                        git commit --allow-empty -m "Initial commit"
                        git push origin main
                        cd ..
                        rm -rf /dolt/tmp/ssh-phone-agent
                    else
                        echo "Git remote already initialized at /dolt/git/ssh-phone-agent"
                    fi
                    chown -R 1000:1000 /dolt/git/
                    EOS
                ]
            }
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
                    },
                    {
                        type     = "bind"
                        source   = "local/servercfg"
                        target   = "/etc/dolt/servercfg.d"
                        readonly = true
                    },
                    {
                        type     = "bind"
                        source   = "/etc/ssl/local/wildcard-combined.crt"
                        target   = "/etc/ssl/certs/wildcard-combined.crt"
                        readonly = true
                    },
                    {
                        type     = "bind"
                        source   = "/etc/ssl/private/wildcard.key"
                        target   = "/etc/ssl/private/wildcard.key"
                        readonly = true
                    }
                ]
            }

            service {
                name = "beads-dolt"
                port = "mysql"
                tags = [
                    "smartstack:external",
                    "smartstack:hostname:beads.${var.domain}",
                    "smartstack:routing:port",
                    "smartstack:extport:33306",
                    "smartstack:protocol:tcp",
                    "haproxy:frontend:option:clitcpka",
                    "haproxy:backend:option:srvtcpka",
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
                destination = "local/initdb/02-git.sh"
                change_mode = "restart"
                perms = "0755"

                data = <<-EOF
#!/bin/bash
git config --global --add safe.directory '*'
EOF
            }

            template {
                destination = "local/servercfg/config.yaml"
                change_mode = "restart"

                data = <<-EOF
log_level: info
listener:
  host: 0.0.0.0
  port: 3306
  tls_cert: /etc/ssl/certs/wildcard-combined.crt
  tls_key: /etc/ssl/private/wildcard.key
  require_secure_transport: true
data_dir: /var/lib/dolt
cfg_dir: /var/lib/dolt/.doltcfg
privilege_file: /var/lib/dolt/.doltcfg/privileges.db
branch_control_file: /var/lib/dolt/.doltcfg/branch_control.db
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

            # https://www.dolthub.com/blog/2023-11-06-securing-procedures/
            config {
                image   = "mysql:8.0"
                command = "sh"
                args = [
                    "-ec",
                    <<-EOS
                    until mysqladmin ping -h 127.0.0.1 -P 3306 --ssl-mode=REQUIRED --silent; do sleep 2; done
                    mysql -h 127.0.0.1 -P 3306 --ssl-mode=REQUIRED -u root -p"$ROOT_PASSWORD" <<SQL
                        DROP DATABASE IF EXISTS test;
                        CREATE DATABASE IF NOT EXISTS test;
                        CREATE DATABASE IF NOT EXISTS ssh_phone_agent;

                        CREATE USER IF NOT EXISTS 'beads'@'%' IDENTIFIED BY '${BEADS_PASSWORD}';
                        ALTER USER 'beads'@'%' IDENTIFIED BY '${BEADS_PASSWORD}';
                        GRANT ALL PRIVILEGES ON test.* TO 'beads'@'%';
                        GRANT ALL PRIVILEGES ON ssh_phone_agent.* TO 'beads'@'%';
                        GRANT EXECUTE ON PROCEDURE ssh_phone_agent.dolt_push TO 'beads'@'%';
                        GRANT EXECUTE ON PROCEDURE ssh_phone_agent.dolt_pull TO 'beads'@'%';
                        GRANT EXECUTE ON PROCEDURE ssh_phone_agent.dolt_backup TO 'beads'@'%';
                        GRANT EXECUTE ON PROCEDURE ssh_phone_agent.dolt_remote TO 'beads'@'%';
                        USE ssh_phone_agent;
                    SQL

                    remote_exists=$(mysql -h 127.0.0.1 -P 3306 --ssl-mode=REQUIRED -u root -p"$ROOT_PASSWORD" -N -B -D ssh_phone_agent -e "SELECT COUNT(*) FROM dolt_remotes WHERE name = 'origin';")
                    if [ "$remote_exists" = "0" ]; then
                        mysql -h 127.0.0.1 -P 3306 --ssl-mode=REQUIRED -u root -p"$ROOT_PASSWORD" -D ssh_phone_agent -e "CALL dolt_remote('add', 'origin', 'file:///var/lib/dolt/git/ssh-phone-agent');"
                    else
                        echo "Dolt remote origin already exists"
                    fi
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
