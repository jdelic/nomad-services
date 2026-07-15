type      = "csi"
id        = "caldiy-uploads"
name      = "caldiy-uploads"
namespace = "default"
plugin_id = "csi.hetzner.cloud"

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
    "encryption-passphrase" = "${ENCRYPTION_PASSPHRASE}"
}
