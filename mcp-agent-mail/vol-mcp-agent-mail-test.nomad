# file: db-vol.hcl

type      = "csi"
id        = "mcp-agent-mail-data"
name      = "mcp-agent-mail-data"
namespace = "default"
# local disk, not NFS: the Rust server needs renameat2(RENAME_NOREPLACE),
# hard-link counts and file ownership to behave like a local filesystem.
plugin_id = "csi-hostpath"

capacity_min = "10G"

capability {
    access_mode     = "single-node-writer"
    attachment_mode = "file-system"
}
