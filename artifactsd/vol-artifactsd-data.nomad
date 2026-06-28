# file: db-vol.hcl

variable "encryption_passphrase" {
    type = string
}

type      = "csi"
id        = "artifactsd-data"
name      = "artifactsd-data"
namespace = "default"
plugin_id = "csi.hetzner.cloud"

# Default minimum capacity for Hetzner Cloud is 10G
capacity_min = "10G"

capability {
    access_mode     = "single-node-writer"
    attachment_mode = "file-system"
}

mount_options {
    fs_type     = "ext4"
    mount_flags = ["discard", "defaults"]
}

secrets {
    "encryption-passphrase" = "${var.encryption_passphrase}"
}
