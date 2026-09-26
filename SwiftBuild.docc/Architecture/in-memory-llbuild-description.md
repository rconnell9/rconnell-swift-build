# In-Memory llbuild Build Descriptions

## Overview

Swift Build links llbuild in-process, yet the build graph has always been handed
over as a file. Task construction produces a `BuildDescription`, whose
`manifest.json` is a YAML rendering of the whole graph: one entry per command with
its tool, inputs, outputs, command line and environment. Swift Build
writes that file, llbuild reads it back and parses it into the object graph Swift
Build just had in hand.

On a large project that file is not small. A Photos-sized workspace produces a
~500 MB manifest; WebKit's is ~542 MB. Writing it costs a few hundred milliseconds
of I/O, and parsing it costs a couple of seconds of CPU on the critical path of
*every* build, including null builds.

When the `UseInMemoryLLBuildDescription` feature flag is set, Swift Build skips
the file: it replays the graph into llbuild through llbuild's
`BuildDescriptionBuilder` API, and no manifest is written at all. Like every
other Swift Build feature flag it is off by default and can be turned on either
way:

```bash
UseInMemoryLLBuildDescription=1 xcodebuild ...
defaults write org.swift.swift-build UseInMemoryLLBuildDescription -bool YES
```

## Both paths are the same path

llbuild's `BuildDescriptionBuilder` is the single place a `BuildDescription` is
assembled; the YAML parser (`BuildFileImpl`) is a front-end for it. Both bottom
out in the same `Tool::createCommand` and `Command::configure*` calls, so the two
paths cannot disagree about how a command is configured or what its signature is.

That matters because the paths must be *interchangeable within an incremental
build*. llbuild's database records, per command, the signature it ran with and the
file info of each output. Flipping the flag between two builds must therefore
not invalidate anything, and the end-to-end null-build test
(`nullBuildAcrossDescriptionPaths`) is the oracle for that: build in memory, null
build via the manifest, null build in memory again.

## Signatures belong to llbuild

Swift Build used to compute every command's signature itself — an MD5 over the
command line, environment, dependency-info style and interruptibility — and ship
the digest in the manifest's `signature` attribute. That was reasonable when the
graph was already being rendered to text, since the hash was one more field in a
file that had to be written anyway. It is not reasonable when the point of the
exercise is to hand llbuild the graph *without* serializing it: hashing all
4,112 of WebKit's shell commands cost 4.8 s, which was 90% of the in-memory handoff
and made the fast path slower than the manifest it replaced.

llbuild computes signatures itself now, from the command line and environment it
was configured with, and it does so lazily — only for commands whose
up-to-dateness it actually has to decide. What Swift Build sends is not a hash
but *metadata about what the command line does not say*:

- **`signature-ignored-args`**, ascending indices into `args` naming arguments
  that cannot affect the command's outputs. A compiler invocation differing only
  in `-fdiagnostics-color` must not trigger a rebuild, and only Swift Build knows
  which arguments those are; llbuild only needs to be told where they sit.
  Task types declare them by overriding
  `TaskTypeDescription.signatureIgnoredArgumentIndices(for:)`.
- **`additional-signature-data`**, for planning state that affects the outputs
  but appears nowhere in the command line or environment.

On WebKit this turns 4.8 s of hashing into under 2 ms of index computation across
4,112 shell commands, and brings the whole in-memory handoff to 394–415 ms against
2.6–2.8 s to parse the equivalent manifest on a null build.

`commandLineForSignature(for:)` survives as a derived default — the ignored
indices applied to the command line — because in-process task actions still hash a
command line of their own to identify their internal state
(`TaskAction.getSignature(_:executionDelegate:)`). Overriding
`signatureIgnoredArgumentIndices(for:)` is the only thing a task type needs to
do; the derived command line follows.

llbuild still honors an explicit `signature` attribute, which overrides
everything else, but nothing in Swift Build sets it.

## The description carries the graph

Nothing llbuild-shaped is persisted, so everything llbuild needs must be
recoverable from the `BuildDescription` itself — including for a description that
was loaded cold from the on-disk cache in a process that never planned the build.

Most of it already is: a `Task` knows its tool, command line, environment,
dependency-info style and additional signature data. Three things did not
survive:

- **Final llbuild node names.** A `Task` keeps only real file paths, because
  that is all execution needs. llbuild's scheduling graph also contains virtual
  gate nodes (`<target-…-begin-compiling>`, mutation trigger nodes,
  `mustPrecede`-derived ordering edges) and the amended inputs/outputs computed
  during construction. These are stored per task as an `LLBuildNodeList`.
- **`repairViaOwnershipAnalysis`**, a planning decision carried on
  `PlannedTask` rather than on `Task`, stored alongside the node list.
- **The non-command remainder of the graph** — standalone node attributes
  (`is-mutated`, `content-exclusion-patterns`, `is-command-timestamp`), the
  synthesized per-target stale-file-removal commands, the inputs of the synthetic
  `<all>` root, and the ownership-analysis flag — stored once as an
  `LLBuildGraphSupplement`.

The first two are stored per task on `FrozenTaskStore`; the supplement is
whole-description metadata and rides on the `BuildDescription` itself. Together
they are everything needed to re-feed llbuild.
`BuildDescription.populateLLBuildDescription(builder:)` walks the store, and
`emitLLBuildCommand(task:nodeList:...)` emits one command per task, mirroring the
JSON emission in `SWBTaskExecution.BuildDescriptionBuilder`. Only the in-memory
path goes through that emitter — the manifest writer still writes its JSON
directly — so the two have to be kept in sync by hand. What stops them drifting
into *signature* disagreement is that neither one computes a signature: both emit
`signature-ignored-args` and `additional-signature-data` and leave the hashing to
llbuild, whose `ShellCommand::configureAttribute` is shared between its YAML
reader and its builder API.

The walk is ordered by command name (`forEachTaskInLLBuildOrder`), which is the
order the manifest emits its `commands` map in. llbuild does not care —
commands and nodes live in name-keyed maps — but the tasks are held in a
dictionary, and Swift seeds dictionary iteration per process, so an unordered
walk would hand llbuild a differently-shuffled description on every build.
Anything derived from encounter order, such as the environment base names below,
would shuffle with it, and two builds of the same description could not be
compared.

### File-system mode travels with the graph

`client.file-system` in the manifest (`default`, `device-agnostic`,
`checksum-only`) is not part of the graph, but it decides *which fields of a
`stat`* llbuild records for each output — `device-agnostic`, Swift Build's
default, zeroes the device and inode. A description replayed under the wrong mode
makes llbuild consider every output modified, so the mode is recorded in the
`LLBuildGraphSupplement` (in the spelling the manifest uses) and applied via
`BuildDescriptionBuilder.setFileSystemMode`. It is recorded rather than re-read at
build time so that the two paths still agree if the preference changes between
builds.

## Environment factoring

A build's shell environments are near-copies of one another. Measured on WebKit:
4,102 non-empty environments, 4,014 of them distinct — but only **123 distinct key
sets**. Sending each one whole means handing llbuild the same few hundred variable
names, and most of the same values, thousands of times over; on WebKit the shell
environments are 84% of the manifest's bytes.

`EnvironmentBaseTable` groups commands by their exact *ordered* key list. The
first command in each group declares its bindings as a shared environment base;
the rest point at that base and send only the keys whose values differ.

The ordering requirement is what makes this invisible to the build database.
llbuild substitutes an override *in place of* the base's own binding rather than
appending it, so a command whose keys are exactly the base's keys ends up with an
effective environment identical — values and order — to the one it would have had
unfactored. Command signatures are computed over the effective environment, so
factoring changes none of them, and an incremental build can cross freely between
factored and unfactored descriptions.

Two cases are deliberately left unfactored: environments smaller than a handful of
variables, where a base declaration costs more than it saves, and key lists
containing a duplicate key, which could not survive the substitution round trip.

## Cache validity

The on-disk build description cache normally requires `manifest.json` to exist,
since it is the artifact llbuild parses. When the in-memory path is enabled the
graph is carried by the frozen task store instead, so validity no longer depends
on the manifest being present (`BuildDescriptionManager`).

`BuildDescription`'s serialized layout is a fixed-width aggregate, so a description
written by a toolchain with a different field count is rejected on load and rebuilt.
Beyond that, a cached description is never reused across toolchains at all:
`manifest.json` and the serialized description live together inside the
signature-keyed `.xcbuilddata` package, and the signature covers the modification
times of the build service binaries -- which is where llbuild itself lives.
