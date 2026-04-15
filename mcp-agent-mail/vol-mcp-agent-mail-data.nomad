# file: db-vol.hcl

type      = "csi"
id        = "mcp-agent-mail-data"
name      = "mcp-agent-mail-data"
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
    "encryption-passphrase" = "GMQQF0z2s2v1qBD0gDkzRlX6"
}
