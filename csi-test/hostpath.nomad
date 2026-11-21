# Local-disk CSI driver for test clusters. Volumes are plain directories under
# /var/lib/csi-hostpath on the node that created them, so tasks get a real
# local POSIX filesystem (needed by e.g. mcp-agent-mail, whose SQLite and
# archive code relies on renameat2(RENAME_NOREPLACE) and real file ownership,
# neither of which works on the NFS plugin).
#
# The kubernetes-csi hostpath driver is a single binary that implements both
# the controller and the node service, so it runs as a "monolith" plugin on
# every node. A volume is bound to the node it was created on (CSI topology).
job "csi-hostpath" {
    type      = "system"
    node_pool = "all"

    group "hostpath" {
        task "plugin" {
            driver = "docker"

            csi_plugin {
                id        = "csi-hostpath"
                type      = "monolith"
                mount_dir = "/csi"
            }

            config {
                # https://github.com/kubernetes-csi/csi-driver-host-path
                image = "registry.k8s.io/sig-storage/hostpathplugin:v1.19.0"
                args = [
                    "--drivername=hostpath.csi.k8s.io",
                    "--endpoint=${CSI_ENDPOINT}", # provided by csi_plugin{}
                    "--nodeid=${attr.unique.hostname}",
                    "--statedir=/csi-data-dir",
                    "--v=2",
                ]
                # node plugins are always privileged to mount disks.
                privileged = true

                # Volume data and the driver's state.json live on the host, so
                # volumes survive restarts of this plugin. Bind mounts made by
                # the driver from here propagate to the host through mount_dir.
                volumes = [
                    "/var/lib/csi-hostpath:/csi-data-dir",
                ]
            }

            resources {
                cpu    = 50
                memory = 64
            }
        }
    }
}
