# Agent-local CalDAV MCP

Run the CalDAV MCP server locally on the agent VM. This is separate from the
Nomad cal.diy service and should not be exposed through smartstack.

Third-party server:

```text
https://github.com/dominik1001/caldav-mcp
```

Example MCP config for an agent that supports stdio MCP servers:

```json
{
  "mcpServers": {
    "calendar": {
      "command": "npx",
      "args": ["-y", "caldav-mcp@0.9.2"],
      "env": {
        "CALDAV_BASE_URL": "https://cal.maurus.net",
        "CALDAV_USERNAME": "<radicale username>",
        "CALDAV_PASSWORD": "<radicale password>"
      }
    }
  }
}
```

The server exposes tools for listing calendars, listing events, and creating,
updating, and deleting events.
