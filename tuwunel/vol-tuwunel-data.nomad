# file: db-vol.hcl

type      = "csi"
id        = "tuwunel-data"
name      = "tuwunel-data"
namespace = "default"
plugin_id = "csi.hetzner.cloud"

# Default minimum capacity for Hetzner Cloud is 10G. Tuwunel media benefits
# from a bit of extra room even on a small deployment.
capacity_min = "20G"

capability {
    access_mode     = "single-node-writer"
    attachment_mode = "file-system"
}

mount_options {
    fs_type     = "ext4"
    mount_flags = ["discard", "defaults"]
}

secrets {
    encryption-passphrase = "oGVQvZBP4Vq5n8fDDB9l5Qwv9f4MhbjK"
}
