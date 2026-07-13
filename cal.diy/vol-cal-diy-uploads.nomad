type      = "csi"
id        = "cal-diy-uploads"
name      = "cal-diy-uploads"
plugin_id = "csi.hetzner.cloud"

capacity_min = "10GiB"
capacity_max = "10GiB"

capability {
  access_mode     = "single-node-writer"
  attachment_mode = "file-system"
}
