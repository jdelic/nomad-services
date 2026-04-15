# file: db-vol.hcl

type      = "csi"
id        = "mcp-agent-mail-data"
name      = "mcp-agent-mail-data"
namespace = "default"
plugin_id = "rocketduck-nfs"

capability {
    access_mode     = "single-node-writer"
    attachment_mode = "file-system"
}

mount_options {
    fs_type     = "ext4"
    mount_flags = ["discard", "defaults"]
}

parameters {
    # set volume directory user/group/perms (optional)
    uid  = "1000" # vagrant
    gid  = "1000"
    mode = "770"
}