# Contributing

Thanks for your interest! agent-island is early-stage.

## Building and testing

```sh
swift build
swift run AgentIslandSelfTest
```

The self-test runner is framework-free so it works under Command Line Tools (no
full Xcode required). Add new checks in `Sources/AgentIslandSelfTest/main.swift`
when you change `AgentIslandCore`. The AppKit app (under `App/`, in progress)
needs full Xcode.

## Persona Packs

The declarative, legibility-gated Persona Pack format is coming. Packs will be
data-only (no executable code), validated by a hardened loader. Authoring docs
will live in `Docs/persona-pack-format.md` once the format lands.
