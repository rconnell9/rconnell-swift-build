# Command Environments in the Build Manifest

How Swift Build hands llbuild the environment for each command it plans, and why
the manifest does not repeat that environment once per command.

## Overview

Swift Build ends task construction by writing a `BuildDescription`, whose visible
half is `manifest.json` -- the JSON build manifest llbuild parses to create its
commands. Each shell command in it carries the environment its process should run
with.

Those environments are very nearly copies of one another. A script phase's command
carries the whole build-settings environment: on a large project that is over a
thousand variables and about 91 KiB, and every script in the same target differs
from its neighbours in a handful of values. Written out per command, this is the
great majority of the manifest -- on a WebKit manifest of 450 MiB, 82% of the bytes
were command environments, spread over 4,164 commands whose environments fell into
only 134 distinct *key lists*.

Two things address this, and they are independent of each other:

- **llbuild computes command signatures.** Swift Build no longer sends a
  `signature` per command; llbuild derives it from the command it was handed.
- **Commands share environment bases.** Commands whose environments have the same
  ordered key list point at a single shared base declared once in the manifest, and
  send only the values that differ from it.

## Signatures

llbuild identifies a command's work by a signature, which it stores in the build
database and compares on the next build to decide whether the command needs to run
again. Swift Build used to compute that signature itself and write it into the
manifest, which meant holding a definition of "what makes this command different"
in step with llbuild's own.

llbuild computes the signature for a shell command from the command line, working
directory, and effective environment (`ShellCommand::getSignature`). Emitting no
`signature` lets it do that, and removes the duplicated definition.

The one-time cost: because Swift Build's computation and llbuild's do not agree
byte-for-byte, every command's signature changes once when a toolchain first adopts
this. The first build after that is a full rebuild. Nothing after it is affected.

## Environment bases

The manifest gains a top-level `env-bases` section mapping a name to a set of
bindings. A command then references one:

```json
"env-bases": {
  "env-base-0": {"CONFIGURATION": "Debug", "PROJECT_NAME": "WebCore", "…": "…"}
},
"commands": {
  "P0:…:PhaseScriptExecution First": {
    "tool": "shell",
    "env-base": "env-base-0"
  },
  "P0:…:PhaseScriptExecution Second": {
    "tool": "shell",
    "env-base": "env-base-0",
    "env": {"SCRIPT_OUTPUT_FILE_0": "…/second.txt"}
  }
}
```

The second command's effective environment is the base with
`SCRIPT_OUTPUT_FILE_0` replaced -- llbuild substitutes an override **in place of**
the base's binding rather than appending it, and appends only keys the base does not
mention (`ShellCommand::getEffectiveEnv`).

### Why the ordered key list is the grouping

Substituting in place is what makes this invisible to the build database. A command
whose keys are exactly its base's keys, in the same order, ends up with an effective
environment identical in values *and* order to the one it would have had unfactored.
Since the signature is computed over the effective environment, factoring changes no
signature: an incremental build can cross between a factored and an unfactored
description without rebuilding anything.

Grouping by the ordered key list rather than by the key *set* is therefore not a
simplification but the requirement. Two environments with the same names in a
different order get separate bases.

### Deciding what earns a base

``EnvironmentBaseTable`` makes the decision. A key list gets a base when at least
two commands share it. There is deliberately no minimum size: SwiftPM-shaped builds
carry a single variable -- a 1.5 KiB `PATH` -- across every command, which a rule
phrased in terms of variable counts would step over. Measured across a range of real
manifests, "shared by two" is exactly as good as choosing per group by computed byte
cost, because a base has to be declared in full somewhere and so a key list used
once always costs more factored than inline.

A key list with a duplicated key cannot survive the round trip -- a base holds one
binding per key -- and is sent inline.

### Determinism

The manifest must be byte-identical across two constructions of the same workspace,
and its commands are described in parallel. The table is therefore built up front,
over the tasks in identifier order, and then queried read-only: which base an
environment lands in depends on the order the table was *built* in, never on the
order commands happen to be emitted in.

The pre-pass has to agree with what emission actually does, since an environment
collected but never emitted leaves an unreferenced base and one emitted but never
collected is merely sent inline. `ConstructedTask.environmentToDescribe` is the
single place that decides, and lives next to `addToDescription` so the two are
changed together.

### Section order

`env-bases` sits between `nodes` and `commands`. llbuild's parser walks the
top-level sections in sequence and rejects one that arrives out of turn, and it
resolves each command's `env-base` as it reads that command, so the bases must
already be declared.

## Effect

Measured by planning each project -- task construction and manifest writing, with
nothing executed -- against a service built before these changes and one built
after:

| Project | Manifest before | After | Reduction | llbuild parse | Planning |
|---|---|---|---|---|---|
| WebKit (`WebKit.xcworkspace`) | 450.1 MiB | 93.3 MiB | 79% | 2.27s → 0.92s | 12.5s → 11.3s |
| Safari (`Safari.xcworkspace`) | 99.0 MiB | 93.6 MiB | 5.4% | 0.68s → 0.67s | no change |
| llbuild (`llbuild.xcodeproj`) | 10.4 MiB | 10.2 MiB | 2.0% | no change | no change |
| Mail (`Mail.xcworkspace`) | 12.05 MiB | 12.04 MiB | 0.05% | no change | no change |

The shape of the win follows the shape of the environments. WebKit's manifest is 82%
command environments: 4,164 commands carry a non-empty one, averaging 1,207
variables and 91 KiB each, and they fall into 134 key lists with a mean of 7 values
differing from the rest of their group. Mail has 15 such commands, so there is
nothing to share and effectively all of its (small) gain is the dropped `signature`
field.

A SwiftPM package sits at the Mail end for a different reason: every command carries
the same single `PATH` variable, around 1.5 KiB of it, which factors to one base and
takes 0.5-1% off the manifest.

## Topics

### Relevant types

- ``EnvironmentBaseTable``
- ``EnvironmentFactoring``
