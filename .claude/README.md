# Agent setup

Echo is written with AI coding agents, and this directory is how that setup
travels with the repository.

## Echo's own skills

`skills/echo-*` are written here and tracked. Each one holds what was learned by
measuring real calls — the thresholds, the traps and the rules that look wrong
until you know why they exist. They are the reason a fresh session does not
rediscover a solved problem by breaking it.

Every claim in them cites the code or test that proves it. When you change
behaviour a skill describes, update the skill in the same pull request; a stale
skill is worse than no skill, because agents trust it.

## Third-party skills

Declared in `skills-lock.json` at the repository root, not copied in. Restore
them with:

```sh
npx skills experimental_install
```

They install into `.agents/skills/` and are symlinked into `skills/`, both of
which are ignored.

## Xcode build server

Optional, and not declared in the repository so it does not prompt everyone who
opens it. It gives an agent structured build, test and log tools instead of
hand-parsed `xcodebuild` output:

```sh
claude mcp add XcodeBuildMCP -- npx -y xcodebuildmcp@latest mcp
```
