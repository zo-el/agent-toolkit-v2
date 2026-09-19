# B02 — settle whether the project manager's Linear tools resolve

**Status:** blocked on user
**Priority:** P1
**Target:** agents/project-manager.md, tests/install.sh
**Source:** the release-flow lane, 2026-09-18, from the check that reads an agent's MCP tool names
**Owner:** agent, on a machine with Linear connected

`agents/project-manager.md` declares `tools: Read, Bash, Skill, mcp__linear, mcp__linear-server, SendMessage, ToolSearch`. The two Linear entries are bare server prefixes, not tool names, and a subagent's `tools:` list was measured to take neither a wildcard nor a bare prefix: a name with no tool behind it is dropped in silence. If that measurement holds for a server the device config provides, the only agent with Linear has had no Linear tools since it was written, and nothing would have said so.

It cannot be settled on this machine, which has no Linear server configured, so the agent resolves no Linear tool here either way and the two readings look identical. `tests/install.sh`'s "an MCP tool is named in full" check reads only definitions that declare a server of their own, and skips the device-config case for exactly this reason.

The method, on a machine with Linear connected: spawn the project manager, have it list the tools it actually holds, and compare against what the definition names. If the bare prefixes resolve, say so in the check's comment, which currently records the opposite measurement. If they do not, replace them with the fully qualified tool names the server publishes, and widen the check to read every definition rather than only those declaring their own servers.

Done when the project manager provably holds the Linear tools it needs, and the suite reads the same answer on any machine.
