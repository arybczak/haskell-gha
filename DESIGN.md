# haskell-gha design

haskell-gha is a command-line tool. It reads a Haskell cabal project and
writes one GitHub Actions workflow that builds and tests the project on each
GHC version from `tested-with`.

haskell-gha replaces haskell-ci for projects that use only GitHub Actions.
haskell-ci supports many backends, setup methods and old GHC versions. Its
generated workflow for the `all-versions` fixture has 515 lines. haskell-gha
starts again with a small scope, modern defaults and a short workflow. The
model for the output is the hand-written workflow of ghc-tags, which has about
50 lines.

This document is the complete specification for the first version. The
implementation starts from an empty directory.

## Background

The design comes from these facts. The paths are relative to the parent
directory of this repository.

- `haskell-ci/` is the tool that haskell-gha replaces. Read its code for
  ideas, but do not depend on it and do not copy its structure.
- `ghc-tags/.github/workflows/ci.yml` is the model for the generated
  workflow.
- `cabal/` is a checkout of the cabal source (3.18).
- `simple-eff/` is the effectful project, the model for the code style.

The facts below about other projects were read from their source code.

`haskell-actions/setup` resolves a GHC or cabal version with its bundled
`versions.json` (the `resolve` function in `src/opts.ts`). `latest` becomes
the first entry of the list. A short form such as `9.10` becomes the newest
entry that starts with `9.10.`. Any other version goes to GHCup unchanged,
also a full version that the list does not contain. Thus a new GHC release
with a full version works without a new release of the action or of
haskell-gha. A short form gives the newest version that the action knows,
which can be older than the newest version in GHCup.

If the list has no entry for a short form, e.g. a new major series, the
action gives the short form to GHCup unchanged. The implementation must test
what GHCup then does. If GHCup fails, the user must write the exact version
until a release of the action lists the series.

The action pins the GHCup version in `versions.json`. The workflow refers to
the moving tag `haskell-actions/setup@v2`, so a new action release also gives
a new GHCup. The action has the outputs `ghc-version`, `cabal-version`,
`cabal-store`, `ghc-exe` and `cabal-exe`. The input `cabal-update` is true
by default, so the action runs `cabal update`. The generated workflow needs
this, because its first `cabal build` needs the package index.

The action calls `sudo apt-get` only for GHC older than 8.3 and for GHC head.
Both are out of scope. A job container has no `sudo`, and this is one reason
why the jobs run on the runner image.

cabal decides `if impl(ghc ...)` blocks in `cabal.project` with the
configured compiler, before it reads the local packages
(`rebuildProjectConfig` in `cabal-install/src/Distribution/Client/ProjectPlanning.hs`).
Thus a `packages:` line in such a block works in CI, because the action
selects the GHC version.

## Decisions

These decisions are final. Each one has its reason.

The tool uses `Cabal-syntax` and `Cabal`, not the `cabal-install` library.
The `cabal-install` library needs `Cabal ^>=3.18`, and its internal API
changes in each major release. `Cabal-syntax` and `Cabal` allow wide bounds.

The configuration is YAML. The services and hook steps are GitHub Actions
YAML, so users can copy them from the documentation of any action.

The tool copies `services`, `permissions`, `hooks` and the extra matrix
entries without changes. It does not model each service or each install
method.

The tool does not rewrite `cabal.project`. The workflow uses the
`cabal.project` of the user. If packages support different GHC versions, the
user adds `if impl(ghc ...)` blocks to `cabal.project`. The tool finds a
missing block and gives the exact block in the error message. Thus local
builds and CI use the same project.

The jobs run on the runner image, not in a job container. Additional service
containers are supported.

The first version supports only Linux. Three rules keep macOS support easy to
add later:

- The workflow sets `defaults.run.shell: bash`.
- The cache key contains `runner.os`.
- All tool paths come from the outputs of `haskell-actions/setup`, not from
  Linux paths in the code.

The default `runs-on` is `ubuntu-26.04`, not `ubuntu-latest`. GitHub moves
`ubuntu-latest` to a new Ubuntu release over some weeks. During that time,
the jobs of one workflow run on different images. The tool already pins the
versions of the actions by default, and a pinned image follows the same
rule. Thus the workflow only changes with a new release of the tool or a
change of the configuration.

The cache key contains the image of the runner, from the environment
variable `ImageOS`, e.g. `ubuntu26`. A cabal store from another image can
link against system libraries that the new image does not have. The key
does not contain `ImageVersion`, because GitHub updates the image each
week, and each update would start a new cache.

The default `cabal-version` is `3.16.1.0`. For `latest`, the action now
selects cabal `3.18.1.0`. That version has a bug in the GHC job semaphore:
[cabal issue 12306][issue-12306].

[issue-12306]: https://github.com/haskell/cabal/issues/12306

If a cabal release fixes the issue, change the default to `latest`. The
action then resolves it, and a new cabal release needs no new release of
haskell-gha.

The `semaphore` field needs cabal 3.12 or later. If `cabal-version` is an
older version, the tool stops with an error. The tool compares only the
first two parts of the version, so `3.10` and `3.10.3.0` are both errors.

## Command line

The tool has no subcommands. Each run writes the workflow file.

The tool has no check mode. To make sure that a committed workflow is up to
date, run the tool and then `git diff --exit-code`. `git diff` does not show
an untracked file. The README recommends `git status --porcelain` for users
who also want to find a new workflow file that is not committed.

The tool accepts these options:

| Option | Default | Meaning |
|---|---|---|
| `--config FILE` | `.github/haskell-gha.conf.yml` | The configuration file. If the file does not exist, all fields take their defaults. |
| `--project-dir DIR` | `.` | The directory that contains `cabal.project` or the package. |
| `--output FILE` | `.github/workflows/haskell-gha.yml` | The workflow file. |

All paths are relative to the current directory, which is the root of the
repository. If `--project-dir` is not `.`, the workflow sets
`defaults.run.working-directory` to that directory.

The generated file starts with this comment. The command line in the comment
contains all options that are not defaults.

```yaml
# This file was generated by haskell-gha, do not edit it.
#
# To regenerate it, run:
#   haskell-gha --project-dir examples/multi --config examples/multi/haskell-gha.conf.yml --output .github/workflows/haskell-gha-multi.yml
#
# Version: <version>
#
# For more information, see https://github.com/arybczak/haskell-gha
```

The tool works in three phases. It reads the configuration, then it reads
the project files, and then it checks each package against each matrix
entry. In each phase, the tool collects all errors and prints them all. If
a phase has errors, the tool exits with code 1 and does not start the next
phase.

## Configuration file

All fields are optional. An unknown field is an error, and the message names
the field. This finds typing errors.

```yaml
name: CI
cabal-version: 3.16.1.0
runs-on: ubuntu-26.04
branches: [master, main]
matrix:
  postgres: ['15', '18']
  exclude:
    - ghc: '9.10'
      postgres: '15'
apt: [libpq-dev]
services:
  postgres:
    image: postgres:${{ matrix.postgres }}
    env:
      POSTGRES_PASSWORD: postgres
    ports: ['5432:5432']
permissions:
  contents: read
hooks:
  before-build:
    - name: Show the Postgres version
      run: psql --version
  after-build: []
ghc-options: -Werror
cabal-project-local: |
  package some-package
    flags: +extra-benchmarks
jobs: 4
tests: true
benchmarks: true
doctest:
  ghc: '>=9.6 && <9.14'
  version: '>=0.24'
  skip: [some-package]
  options: [--fast]
check: true
sdist: true
haddock: true
fourmolu:
  version: 0.20.1.0
  pattern: ['src/**/*.hs', '!src/Generated.hs']
hlint:
  version: 3.10
  fail-on: suggestion
  path: [src, test]
actions:
  checkout: v7
  setup: v2
  cache: v6
  run-fourmolu: v13
  hlint-setup: c04631035af0a6787c85e33b3ea0128b8568b590
  hlint-run: d009541bdae0b8492992416e665bb6df8a3b5cde
```

| Field | Default | Meaning |
|---|---|---|
| `name` | `CI` | The name of the workflow. |
| `cabal-version` | `3.16.1.0` | The cabal version for `haskell-actions/setup`. `latest` is also valid. See [Decisions](#decisions). |
| `runs-on` | `ubuntu-26.04` | The name of the runner image, e.g. `ubuntu-latest`. A list of labels is an error. See [Decisions](#decisions). |
| `branches` | `[master, main]` | The branches for the `push` trigger. An empty list is an error. |
| `matrix` | none | Extra matrix axes, and `include` and `exclude`. The tool copies them next to the `ghc` axis. |
| `apt` | `[]` | Ubuntu packages to install. |
| `services` | none | Service containers. The tool copies the map to `jobs.build.services`. |
| `permissions` | `contents: read` | The permissions of the `GITHUB_TOKEN`: a mapping, `read-all` or `write-all`. The tool copies the value to the top-level `permissions`. |
| `hooks.before-build` | `[]` | Steps before the build of the local packages. |
| `hooks.after-build` | `[]` | Steps after the build and before the tests. |
| `ghc-options` | `-Werror` | GHC options for the local packages only. An empty string disables them. |
| `cabal-project-local` | none | Text to add at the end of `cabal.project.local`. A line `EOF` is an error. |
| `jobs` | `4` | The number of parallel build jobs, a positive integer. See [The generated workflow](#the-generated-workflow). |
| `tests` | `true` | Build and run the test suites. |
| `benchmarks` | `true` | Build the benchmarks. The workflow does not run them. |
| `doctest` | none | Run doctest. See [Doctest](#doctest). |
| `check` | `true` | Run `cabal check` for each local package. |
| `sdist` | `true` | Build and test the content of the source tarballs. See [The source tarballs](#the-source-tarballs). |
| `haddock` | `true` | Build the documentation for Hackage. |
| `fourmolu` | none | Check the formatting. See [Fourmolu](#fourmolu). |
| `hlint` | none | Check the code with HLint. See [HLint](#hlint). |
| `actions.checkout` | `v7` | The Git ref of `actions/checkout`. |
| `actions.setup` | `v2` | The Git ref of `haskell-actions/setup`. |
| `actions.cache` | `v6` | The Git ref of `actions/cache/restore` and `actions/cache/save`. |
| `actions.run-fourmolu` | `v13` | The Git ref of `haskell-actions/run-fourmolu`. |
| `actions.hlint-setup` | `c04631035af0a6787c85e33b3ea0128b8568b590` | The Git ref of `haskell-actions/hlint-setup`. See [HLint](#hlint). |
| `actions.hlint-run` | `d009541bdae0b8492992416e665bb6df8a3b5cde` | The Git ref of `haskell-actions/hlint-run`. See [HLint](#hlint). |

A value of the wrong type is an error, and the message names the field.

GitHub uses the workflow name in the concurrency group. Thus two workflows
in one repository must have different names. If they have the same name, a
push starts both in one group, and one run cancels the other.

The `matrix` field must not contain the key `ghc`, because the tool makes
that axis. A value in `include` or `exclude` can refer to `ghc`. The value
must then be a quoted string, and it must be an entry of the `ghc` axis.
Any other `ghc` value is an error. An `include` entry with a new GHC version
adds a job, and the tool does not check the packages for that job.

Each key of an `exclude` entry must be `ghc` or an axis of the `matrix`
field, because GitHub rejects the workflow otherwise. An `include` entry can
have any key, because GitHub adds a new key to the jobs as a variable.

Expressions such as `${{ matrix.postgres }}` work in `services`, `apt` and
the hooks, because GitHub evaluates them. The tool does not read them.

If a workflow has no `permissions` field, the `GITHUB_TOKEN` gets the
default permissions of the repository. In many older repositories and
organizations, these permissions include write access. The jobs of the
workflow only read the code, so the default is `contents: read`. A hook
that needs more permissions, e.g. to post the test results, needs a
`permissions` field in the configuration.

## Reading the project

The project reader makes a list of local packages. For each matrix entry, it
also decides which packages are in the project.

If `cabal.project` does not exist in the project directory, the project is
`packages: ./*.cabal`, as in cabal (`defaultImplicitProjectConfig` in
`cabal-install/src/Distribution/Client/ProjectConfig.hs`).

If `cabal.project` exists, the reader parses it with `readFields` from
`Distribution.Fields`. It uses the fields `packages:` and
`optional-packages:`. A missing match is an error for `packages:` and is not
an error for `optional-packages:`. It also uses the `if`, `elif` and `else`
sections. The reader parses each condition with `parseConditionConfVar` from
`Distribution.Fields.ConfVar`, and it decides the condition for each matrix
entry.

The reader ignores all other fields. cabal reads them, so the workflow gets
them without changes.

The reader also ignores `import:` lines. cabal reads the imported files in
CI, but the tool does not see a package that only an imported file lists.
Such a package gets no `ghc-options` stanza and no `tested-with` check. If
all test suites are in such packages, the workflow has no test step, and CI
does not run the tests. This is a known limit.

If the project has no packages for a matrix entry, the tool stops with an
error. If the project lists no packages, cabal also stops
(`ProjectConfigNoPackages` in
`cabal-install/src/Distribution/Client/ProjectOrchestration.hs`).

For conditions, `impl(ghc <range>)` is decided with the matrix entry. See
[GHC versions](#ghc-versions) for a major series. `os(linux)` is true, and
`arch(x86_64)` is true. Other operating systems and
architectures are false. `flag(...)` is an error, because the tool does not
know the flag value. An `impl` for a compiler other than GHC is false.

The tool assumes that no project selects its packages by operating system
or architecture. Thus the fixed values for `os` and `arch` do not change the
list of packages, also on a runner that is not x86_64.

A `packages:` entry can be a directory, a `.cabal` file or a glob. A
directory must contain exactly one `.cabal` file. A tarball or a URL is an
error. An absolute path, or a path that starts with `~/`, is also an error.
The workflow uses the path on the runner, where it does not exist.
A relative path outside the project directory, e.g. `../other`, is legal.
The glob syntax is the cabal syntax. Parse it with the `Parsec` instance of
`RootedGlob` from `Distribution.Simple.FileMonitor.Types`, and match it with
`matchGlob` from `Distribution.Simple.Glob`. Both are in `Cabal` 3.14 and
later. A relative glob needs no root, so the tool does not copy
`matchFileGlob` from `cabal-install/src/Distribution/Client/Glob.hs`.

### GHC versions

The reader parses each `.cabal` file with `parseGenericPackageDescription`
and reads `tested-with`. The GHC range of a package is the union of its GHC
entries. Entries for other compilers are ignored. A package without a GHC
entry is an error.

The reader splits the range into its intervals with `asVersionIntervals`.
Each interval must be one of these two kinds:

- An exact version, e.g. `== 9.10.3`. The matrix entry is `'9.10.3'`.
- A major series, i.e. `>= X.Y && < X.(Y+1)`. The matrix entry is `'X.Y'`,
  and the action selects the newest release of the series. Users write it
  as `^>= 9.10` or `== 9.10.*`.

Any other interval is an error, e.g. `>= 9.10`, because the matrix needs a
finite list. The message names the package and the interval, and shows the
two supported forms. A package can mix the two kinds, e.g.
`GHC == { 9.6.7 } || ^>= 9.10 || ^>= 9.12`.

The `ghc` axis of the matrix is the union of the entries of all packages.
The axis is in version order. A series entry is sorted as its lowest
version.

A matrix entry has a version range. An exact entry has one version. A
series entry `X.Y` has the range `>= X.Y && < X.(Y+1)`. The tool uses this
range for every decision about a matrix entry:

- Conditions such as `impl(ghc >= 9.8)`, the `doctest.ghc` range, and the
  9.8 limit of the semaphore are ranges too. If such a range includes all
  of the range of the entry, it is true for the entry. If it includes none
  of it, it is false. If it includes only a part of it, the tool stops with
  an error. The result then depends on the minor version that the action
  selects.
- If the `tested-with` range of a package includes all of the range of an
  entry, the package supports the entry. Thus `^>= 9.10` in one package and
  `== 9.10.3` in another package give two entries. The second package does
  not support the entry `'9.10'`.

For each matrix entry, a package that is in the project must support that
entry. If it does not, the tool stops with an error that names the package
and the version.

If the package supports only a part of the entry, no block can help. Such
a block must include the exact entries and exclude the series entry, but
each exact entry is a part of the series entry. The error then tells the
user to write the series in the same form in all packages.

If the package supports none of the entry, the error shows the block to
add. The condition of the block is
the GHC range of the package from `tested-with`, written with `prettyShow`.
The `packages:` line gives the directory of the package, relative to the
project directory. The original entry can be a glob that also matches other
packages, so the block does not repeat it:

```
Package servant-client does not list GHC 9.6.7 in tested-with, but
cabal.project includes it for that GHC version. Move the package to a
conditional block in cabal.project, e.g.:

if impl(ghc ^>=9.10 || ^>=9.12)
  packages: servant-client
```

## The generated workflow

This is the workflow for a single package `example` with
`tested-with: GHC == 9.6.7 || ^>= 9.10 || ^>= 9.12`, a test suite and an
empty configuration. The implementation must produce this output, apart
from the tool version.

```yaml
# This file was generated by haskell-gha, do not edit it.
#
# To regenerate it, run:
#   haskell-gha
#
# Version: 0.1.0.0
#
# For more information, see https://github.com/arybczak/haskell-gha
name: CI

on:
  push:
    branches:
    - master
    - main
  pull_request:
  merge_group:
  workflow_dispatch:

permissions:
  contents: read

concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true

defaults:
  run:
    shell: bash

jobs:
  build:
    name: GHC ${{ matrix.ghc }}
    runs-on: ubuntu-26.04
    strategy:
      fail-fast: false
      matrix:
        ghc:
        - '9.6.7'
        - '9.10'
        - '9.12'
    steps:
    - uses: actions/checkout@v7

    - uses: haskell-actions/setup@v2
      id: setup
      with:
        ghc-version: ${{ matrix.ghc }}
        cabal-version: '3.16.1.0'

    - name: Show the versions
      id: versions
      run: |
        ghc --version
        cabal --version
        echo "GHC ${{ steps.setup.outputs.ghc-version }}, cabal ${{ steps.setup.outputs.cabal-version }}, image $ImageOS $ImageVersion" >> "$GITHUB_STEP_SUMMARY"
        echo "image=$ImageOS" >> "$GITHUB_OUTPUT"

    - name: Unpack the source tarballs
      run: |
        cabal sdist all --output-directory="$RUNNER_TEMP"/haskell-gha-sdist
        mkdir "$RUNNER_TEMP"/haskell-gha
        for f in cabal.project cabal.project.freeze cabal.project.local; do
          if [ -f "$f" ]; then cp "$f" "$RUNNER_TEMP"/haskell-gha; fi
        done
        tar -xzf "$RUNNER_TEMP"/haskell-gha-sdist/example-[0-9]*.tar.gz --strip-components=1 -C "$RUNNER_TEMP"/haskell-gha

    - name: Configure the project
      working-directory: ${{ runner.temp }}/haskell-gha
      run: |
        cat >> cabal.project.local <<'EOF'
        jobs: 4
        tests: True
        benchmarks: True

        package example
          ghc-options: -Werror
        EOF

    - name: Enable parallel module builds for the local packages
      if: contains(fromJSON('["9.6.7"]'), matrix.ghc)
      working-directory: ${{ runner.temp }}/haskell-gha
      run: |
        cat >> cabal.project.local <<'EOF'
        package example
          ghc-options: -j4
        EOF

    - name: Enable the GHC job semaphore
      if: contains(fromJSON('["9.10","9.12"]'), matrix.ghc)
      working-directory: ${{ runner.temp }}/haskell-gha
      run: |
        echo 'semaphore: True' >> cabal.project.local

    - name: Make the build plan
      id: plan
      working-directory: ${{ runner.temp }}/haskell-gha
      run: |
        cabal build all --dry-run
        echo "hash=$(sha256sum dist-newstyle/cache/plan.json | cut -d ' ' -f 1)" >> "$GITHUB_OUTPUT"

    - uses: actions/cache/restore@v6
      id: cache
      with:
        path: ${{ steps.setup.outputs.cabal-store }}
        key: ${{ runner.os }}-${{ steps.versions.outputs.image }}-ghc-${{ steps.setup.outputs.ghc-version }}-${{ steps.plan.outputs.hash }}
        restore-keys: ${{ runner.os }}-${{ steps.versions.outputs.image }}-ghc-${{ steps.setup.outputs.ghc-version }}-

    - name: Build the dependencies
      working-directory: ${{ runner.temp }}/haskell-gha
      run: |
        cabal build all --only-dependencies

    - uses: actions/cache/save@v6
      if: steps.cache.outputs.cache-hit != 'true'
      with:
        path: ${{ steps.setup.outputs.cabal-store }}
        key: ${{ steps.cache.outputs.cache-primary-key }}

    - name: Build
      working-directory: ${{ runner.temp }}/haskell-gha
      run: |
        cabal build all

    - name: Run the tests
      working-directory: ${{ runner.temp }}/haskell-gha
      run: |
        cabal test all --test-show-details=direct

    - name: Check the packages
      working-directory: ${{ runner.temp }}/haskell-gha
      run: |
        cabal check

    - name: Build the documentation
      working-directory: ${{ runner.temp }}/haskell-gha
      run: |
        cabal haddock all --disable-documentation --haddock-all --haddock-for-hackage
```

A sequence under a key has no indent. See
[YAML input and output](#yaml-input-and-output).

The rules for each part follow.

The `merge_group` trigger runs the workflow for a merge queue. Without it,
a merge queue waits for the required checks of this workflow, and they
never start. The trigger does nothing in a repository without a merge
queue, so the workflow always has it.

The `name` of the job contains each extra axis, e.g.
`GHC ${{ matrix.ghc }}, postgres ${{ matrix.postgres }}`.

The versions in the `ghc` axis are quoted strings, because YAML reads
`9.10` as a number.

The job `name` cannot show the version that the action selects for a series
entry, because GitHub evaluates the job name before the steps run. Thus the
step `Show the versions` prints the versions in the log and in the job
summary. The cache key also uses the selected version, from the
`ghc-version` output of the action. Thus a new minor release starts a new
cache, and the job does not restore a store for the old minor release.

An expression cannot read an environment variable of the runner, e.g.
`ImageOS`. Thus the step `Show the versions` writes the image to its output
`image`, and the cache key reads it from there.

The `jobs` field sets the parallel work, and its default is 4, because the
standard Linux runners of GitHub have 4 CPUs. The configuration step always
writes `jobs: <N>`, so cabal builds up to N packages at the same time. The
other part depends on the GHC version:

- GHC 9.8 and later support the GHC job semaphore (a job count that cabal
  and all GHC processes share). For these versions, the semaphore step adds
  `semaphore: True`. Then GHC also compiles modules in parallel, and the
  total stays at N.
- Older GHC versions do not support the semaphore. For these versions, the
  parallel module step adds `ghc-options: -j<N>` for each local package.
  The dependencies do not get `-j<N>`, because cabal already builds N of
  them at the same time, and more work would overload the CPUs.

The condition of each step lists its GHC versions. If a step has no GHC
versions, the workflow does not contain it. For a package that is not in the
project for a GHC version, the parallel module step has no stanza for that
version. If this makes the stanza lists different for different versions,
the tool makes one step for each group of versions with the same list.

The configuration step writes all its configuration to
`cabal.project.local`, so a developer can run the same `cabal` commands
locally. If `tests` is false, the step omits `tests: True`. If `benchmarks`
is false, the step omits `benchmarks: True`. If `ghc-options` is not an
empty string, the step adds one `package` stanza with the options for each
local package. The default is `-Werror`, so a warning in a local package
fails the build. The dependencies do not get the options, so their warnings
do not fail the build. A new GHC release often adds new warnings, and then
the job for that GHC version fails until the code is fixed.

The text of `cabal-project-local` comes last in the configuration step,
without changes. It can then add to the stanzas of the tool, e.g. more
`ghc-options`. The step comes before the build plan, so the cache key
includes the dependencies that the text adds, e.g. with a package flag.
The step writes the text with a quoted heredoc, so the shell does not
expand it. A line `EOF` ends the heredoc, so such a line is an error.

The configuration step writes the `package` stanzas for all local packages
on all GHC versions. Take a package that is not in the project for a GHC
version. If another package depends on it, cabal gets it from Hackage and
applies the stanza. Then the warnings of that dependency fail the build.
This is a known limit.

cabal merges two `package` stanzas for the same package, so this stanza
and the `-j<N>` stanza can both be present. The heredocs use `<<'EOF'`, so
that bash does not expand text from the configuration.

Some user values go on a command line, e.g. the `apt` packages and the
`doctest.options`. The tool puts each one in single quotes and escapes a
`'` in it. GitHub replaces `${{ }}` expressions before bash runs, so an
expression in such a value still works.

The cache is saved after the dependencies are built. Thus a build error or a
test error in a local package does not prevent the save.

If `apt` is not empty, a step after the checkout runs
`sudo apt-get update` and
`sudo apt-get install -y --no-install-recommends <packages>`.

If `services` is set, the tool puts it in `jobs.build.services`.

The `before-build` hooks come before the step `Build`. The `after-build`
hooks come after it.

If `tests` is false or no local package has a test suite, the workflow has
no test step. If only some GHC versions have a package with a test suite,
the step gets an `if:` condition with those versions. If the project has no
test suites, `cabal test all` fails. Thus the condition is necessary.

A `test-suite` section counts, whatever its conditions are. Take a project
whose test suites all have `buildable: False` for a GHC version. Then the
test step fails for that version. This is a known limit.

The last two steps check the packages for a Hackage release. They come
after the tests and doctest, so a build error or a test error shows first.
Each step has a field of the configuration, and both are true by default.

- If `check` is true, the step `Check the packages` runs `cabal check` in
  the directory of each local package. `cabal check` exits with 1 for an
  error, and a warning does not fail the step. If the packages of the
  project differ between GHC versions, the tool makes one step for each
  group of versions with the same packages.
- If `haddock` is true, the step `Build the documentation` runs
  `cabal haddock all --disable-documentation --haddock-all --haddock-for-hackage`.
  `--disable-documentation` prevents a rebuild of the dependencies with
  documentation, which would bypass the cache. `--haddock-all` adds the
  executables, the test suites and the benchmarks that are in the build
  plan. If `tests` is false, it does not add the test suites.
  `--haddock-for-hackage` makes the same documentation as a Hackage upload,
  e.g. with hyperlinked source.

If `--project-dir` is not `.`, the workflow gets
`defaults.run.working-directory`.

The build plan step writes the SHA-256 hash of
`dist-newstyle/cache/plan.json` to its output `hash`, and the cache key
reads it. `hashFiles` cannot read the plan, because it only reads files in
the workspace, and the content of the tarballs is outside it.

### The source tarballs

A Hackage user gets only the files of the source tarball. The build or the
tests can use a file that the `.cabal` file does not list, e.g. a header
for CPP, a file for Template Haskell or a test fixture. Then the checkout
has the file, but the tarball does not. cabal gives no warning for such a
file, and `cabal check` and `cabal sdist` succeed. Only a build from the
content of the tarball fails.

If `sdist` is true, the workflow thus builds the content of the tarballs
and not the checkout. The step `Unpack the source tarballs` comes after the
step `Show the versions`:

1. It runs `cabal sdist all --output-directory="$RUNNER_TEMP"/haskell-gha-sdist`.
2. It copies each of `cabal.project`, `cabal.project.freeze` and
   `cabal.project.local` that exists to `$RUNNER_TEMP/haskell-gha`.
3. It unpacks the tarball of each local package into `$RUNNER_TEMP/haskell-gha`, at
   the relative path of the package in the project directory.

The copy of `cabal.project` thus finds the packages at the same paths, and
the build reads the same project as a local build. The tool does not
rewrite `cabal.project`. `cabal sdist all` makes a tarball only for the
packages of the project, so the step unpacks only those. If the packages
differ between GHC versions, the tool makes one step for each group of
versions with the same packages.

All later steps that run cabal get
`working-directory: ${{ runner.temp }}/haskell-gha`. The install step of doctest
does not get it, because it ignores the project. The hooks do not get it,
so they run in the checkout. Thus a hook can use files of the repository,
e.g. a script, and it can compare the checkout with `git diff`.

The unpack step does not delete files in the checkout. An earlier design
replaced the files of each package directory with the content of its
tarball. That design fails for a package in the root of the repository,
because the package directory is then the whole repository. It also fails
for a hook that uses `git diff`.

A project must set `sdist: false` in these cases:

- `cabal.project` has an `import:` line. The step does not copy the
  imported file.
- `cabal.project` lists a package outside the project directory, e.g.
  `../other`. The relative path does not exist in `$RUNNER_TEMP/haskell-gha`.
- A hook makes a file that a later cabal step needs. The hook runs in the
  checkout, so the cabal step does not see the file.

The versions of the actions are fields of the configuration, with the
current major versions as defaults. Thus a user can take a new major
version of an action without a new release of haskell-gha. A new release
of haskell-gha changes the defaults. `actions.cache` is one field for
`actions/cache/restore` and `actions/cache/save`, because both come from one
repository. A value is any Git ref without spaces, so a user can also pin an
action to a commit SHA.

## Doctest

If the configuration has a `doctest` field, the workflow runs doctest after
the tests. The `ghc` field is a version range, and its default is all
versions. The doctest steps run only for GHC versions in that range, because
a new GHC release often works with doctest only after some weeks. The
`version` field is a version range for the doctest package. The `skip` field
lists packages that the workflow does not test with doctest. A name in
`skip` that is not a local package is an error. The `options` field lists
extra arguments for doctest.

The experiment of stage 5 tested two methods with doctest 0.25.0 and GHC
9.10.3. The method from the doctest README is
`cabal repl --with-compiler=doctest` for each package. It works for a
package without local dependencies, with cabal 3.14 and 3.16. It fails in
two cases:

- A package depends on another local package. cabal then builds the
  dependency with doctest as the compiler, and that build fails.
- cabal 3.18.1.0 gives the option `--interactive` to the compiler, and
  doctest rejects it.

Thus the workflow uses the haskell-ci method. See the doctest steps in
`haskell-ci/src/HaskellCI/GitHub.hs` and `doctestArgs` in
`haskell-ci/src/HaskellCI/Tools.hs`. The experiment showed that it works in
both cases above. The steps are these:

1. Make cabal write GHC environment files, which tell doctest where the
   dependencies are. If doctest is enabled, the configuration step adds
   `write-ghc-environment-files: always` to `cabal.project.local`.
2. Install doctest with the GHC of the job. doctest uses the GHC API, so it
   must be built with the same GHC. Three steps after the step that saves
   the main cache do this:
   1. `Find the doctest version` runs
      `cabal install doctest --ignore-project --dry-run` and writes the
      doctest version of the plan to its output `version`. If
      `doctest.version` is set, it adds `--constraint='doctest <version>'`.
      The dry run uses an empty store with `--store-dir`, because a plan
      for a store that already contains doctest does not list doctest.
   2. `actions/cache` restores and saves `~/.local/bin/doctest`. The key
      contains `runner.os`, the image, the doctest version and the GHC
      version.
   3. If the cache has no hit, `Install doctest` runs
      `cabal install doctest --ignore-project --install-method=copy --installdir="$HOME/.local/bin" --overwrite-policy=always --constraint='doctest ==<version>'`.

   The key of the main cache depends only on the build plan of the
   project. If doctest were in the main store, each job would build a new
   doctest release again until the plan changes. With its own cache, a job
   builds each doctest version only once for each GHC version. The binary
   is a copy and not a link into the store, so the cache needs only that
   file.
3. In each package directory, run `$HOME/.local/bin/doctest` by its full
   path, because a cache hit skips the install step, and no step adds the
   directory to `GITHUB_PATH`. The arguments are the `hs-source-dirs`, the
   `default-language` and the `default-extensions` of the library and of
   each sublibrary as arguments.

A library without `hs-source-dirs`, or with only `.`, is different from
haskell-ci. The package directory can also contain other components, e.g.
the tests, so the tool does not give `.` to doctest. haskell-ci gives the
names of the exposed modules instead. But then GHC takes the compiled
module from the environment file, and doctest finds no examples without an
error. Thus the tool gives the files of the exposed modules, e.g. `A/B.hs`.
If `hs-source-dirs` contains `.` and other directories, the tool gives the
other directories and the files of the exposed modules in `.`.

Each doctest step for a package has an `if:` condition. The condition lists
the GHC versions that are in the `doctest.ghc` range and that include the
package in the project.

## Fourmolu

If the configuration has a `fourmolu` field, the workflow gets the job
`fourmolu` after the job `build`. The formatting does not depend on the
GHC version, so the job has no matrix, and it needs no GHC. It runs at the
same time as the build jobs, and a failure does not stop them.

The job has two steps. The first is `actions/checkout`. The second is
`haskell-actions/run-fourmolu`, which downloads a fourmolu release binary and
checks the files. The step gets these inputs:

- `version` is always present, from `fourmolu.version`.
- `pattern` has one pattern on each line. If `fourmolu.pattern` is empty,
  the step has no `pattern`, and the action checks all `.hs` and `.hs-boot`
  files.
- `working-directory` is the project directory. If `--project-dir` is `.`,
  the step has no `working-directory`. The `defaults.run` field of the
  workflow does not apply to a `uses` step.

The default version is `0.20.1.0`, not `latest`. The action resolves
`latest` on each run. With `latest`, a new fourmolu release can fail CI
without a change in the repository. A new release can also change the format of the
release files. fourmolu 0.20.0.0 changed the binary to a zip file, and
only `run-fourmolu` v13 and later can read it. With `latest`, the next such
change would fail every workflow with the defaults. The defaults
`fourmolu.version` and `actions.run-fourmolu` must work together, and a new
release of haskell-gha changes them together.

## HLint

If the configuration has an `hlint` field, the workflow gets the job
`hlint` after the other jobs. Like the fourmolu job, it has no matrix and
needs no GHC. It has three steps:

1. `actions/checkout`.
2. `haskell-actions/hlint-setup`, with the input `version` from
   `hlint.version`. The action downloads an HLint release binary.
3. `haskell-actions/hlint-run`, with the inputs `path` and `fail-on`.

`hlint-run` has no `working-directory` input, so it runs in the root of the
repository. Thus the tool puts the project directory in front of each path
of `hlint.path`. An empty `hlint.path` gives the project directory. If the
result is `.`, the step has no `path` input, because `.` is the default of
the action. For more than one path, the input is a JSON array, e.g.
`'["src", "test"]'`.

HLint reads `.hlint.yaml` from its working directory, not from the
directory that it checks. The implementation tested this. Thus, with
`--project-dir`, HLint only reads a `.hlint.yaml` in the root of the
repository. This is a known limit.

The default of `hlint.fail-on` is `suggestion`, so every hint fails the
job. The default of the action is `never`, and then the job never fails.
A project enables the job to follow the advice of HLint. A hint that does
not fail the job is only an annotation, and it is easy to miss. A project
can turn off a hint that it does not want with an `ignore` entry in
`.hlint.yaml`.

The default of `hlint.version` is `3.10`, the newest HLint release. It is
pinned for the same reason as `fourmolu.version`.

The released versions of both actions, up to `v2.4.10`, declare Node.js 20.
GitHub removes Node.js 20 in autumn 2026. The default branches of both
actions declare Node.js 24, but they have no release. The defaults of
`actions.hlint-setup` and `actions.hlint-run` are thus the commits
"Upgrade to node24". These commits only change `action.yml`. The built
`dist/index.js` is the same as in `v2.4.10`. The later commits on the
default branches only update the dependencies of the build check of the
actions. When the actions have a release for Node.js 24, a new release of
haskell-gha changes the defaults to it.

## YAML input and output

The tool must keep the key order of the fragments that it copies. A
reordered step is hard to review. `aeson` objects sort their keys, so the
tool does not use `aeson` or `Data.Yaml`.

The tool reads the configuration with the event API of `HsYAML`
(`parseEvents` from `Data.YAML.Event`). HsYAML is pure Haskell and
implements YAML 1.2. From the events, the tool builds a small ordered tree.
Each scalar keeps its style from the input, i.e. plain, quoted, or a
literal block with its chomping indicator and indent. The output writes all
sequences and mappings in the block style. A flow sequence in the input,
e.g. `[master, main]`, thus becomes a block sequence.

The tree has only mappings, sequences, scalars and comments. An anchor, an
alias, a tag or a duplicate key is an error, and the message gives its
position.

The tool writes the workflow with `writeEvents` from `Data.YAML.Event`. The
writer uses the style of each scalar as it is. It does not make sure that a
plain scalar is valid YAML. Thus the tool gives each scalar its style with
these rules:

- A copied scalar keeps its style from the input. A plain scalar that is
  valid in the input is also valid in the output, because the output uses
  the block style.
- Each `run:` value that the tool makes is a literal block with the default
  chomping (`|`). The first line of each script is fixed text from the
  tool, so user text in a later line cannot break the block.
- A version is always single-quoted, e.g. in the `ghc` axis and in
  `cabal-version`.
- The tool single-quotes each string that it builds from user text, e.g.
  the job name with the extra axis names.
- Other text that the tool makes, e.g. step names and expressions, gets its
  style in the code.

Each golden test also parses the output with HsYAML and compares the result
with the tree that the tool wrote. Thus a wrong style fails the test, also
after `HASKELL_GHA_ACCEPT=1` wrote the expected file.

The writer writes `Comment` events, so the tool writes the header comment as
events. The writer cannot write empty lines. The tool adds them to the output
text. It puts an empty line before each top-level key except the first, and
before each step except the first. The workflow has one job, so each step
starts with `- ` in the same column.

The first round-trip test of stage 1 makes sure that the writer behaves as
this section says. It also shows the indent of a sequence under a key. If
the indent is different from the example in
[The generated workflow](#the-generated-workflow), change the example.

The tool keeps the YAML comments in the copied fragments. The HsYAML parser
gives each comment as a `Comment` event. The tree keeps each comment at its
position in a mapping or a sequence. The writer writes it back at the same
position. The configuration reader skips the comments in the tree.

The round-trip tests of stage 1 include comments on their own lines and
comments at the end of a line. If the writer moves an end-of-line comment
to its own line, that is acceptable. The comment must stay next to the same
entry.

The writer cannot put a comment before the first entry of a mapping or a
sequence. It writes a complex key or a lone `-` there. Thus the tool moves
such a comment up, before the entry that contains the collection.

## Dependencies

| Package | Use |
|---|---|
| `Cabal-syntax >=3.14 && <3.20` | The parsers for `.cabal` files, fields and conditions. |
| `Cabal >=3.14 && <3.20` | Globs. |
| `HsYAML` | The YAML parser and writer, from `Data.YAML.Event`. |
| `optparse-applicative` | The command line. |
| `tasty`, `tasty-hunit` | Tests. |

The tool builds with GHC 9.6 and later. The packages that come with GHC,
e.g. `containers`, `directory`, `filepath` and `text`, are always
permitted. For any other package, the rule is this: if a new dependency
does not remove a large amount of code, do not add it. Do not add
`cabal-install-parsers` or `cabal-docspec`.

## Code style

The code follows the style of the effectful project in `simple-eff/`. Read
`simple-eff/effectful-core/effectful-core.cabal` and some modules in
`simple-eff/effectful-core/src/Effectful/` before you write code. Do not
copy the style of haskell-ci, which is different.

These are the main rules:

- Copy `simple-eff/fourmolu.yaml` to the root of the repository, and format
  all Haskell code with fourmolu. With this configuration, arrows and
  commas start the line, the indent is two spaces, and lines have no
  length limit.
- Use `cabal-version: 3.8` and a `common language` stanza that each
  component imports. Copy its `ghc-options`, `default-language: GHC2021`
  and `default-extensions` from `effectful-core.cabal`. Align the field
  values in the `.cabal` file as that file does.
- Give each module an export list with Haddock section headings, e.g.
  `-- * Configuration`.
- Give each exported function a Haddock comment. For an argument that needs
  an explanation, put a `-- ^` comment after the argument type.
- Records use `NoFieldSelectors` and `OverloadedRecordDot`, from the default
  extensions. Access a field with `config.jobs`, not with a selector
  function.

The style applies to the code only. The tool does not depend on
`effectful`, because it has no need for effects. Plain `IO` is enough.

## Tests

The tests use `tasty` and `tasty-hunit`.

Golden tests (tests that compare the output with a stored file) cover the
generated workflow. Each fixture is a directory under `tests/golden/` with a
project, an optional configuration file and the expected workflow. When the
environment variable `HASKELL_GHA_ACCEPT=1` is set, the tests write the new
output to the expected file. The comparison ignores the header comment, so
a new tool version does not change the result. It does not ignore the
comments that the tool copies from the configuration.

Make these fixtures:

- A single package without a configuration file. The output is the example
  in [The generated workflow](#the-generated-workflow).
- A multi-package project with an `if impl(ghc ...)` block.
- A project with `services`, `matrix`, `apt`, `hooks` and `ghc-options`.
  The configuration contains comments in `services` and `hooks`.
- A project with doctest.
- A project with `--project-dir`.

Unit tests cover the project reader: globs, conditions, each `tested-with`
error, the error for an empty project and the error for a missing
conditional block. Other unit tests cover each error of the configuration
reader. The unit tests also cover these cases for series entries:

- A mix of exact and series entries.
- A condition that includes only a part of a series.
- A package with `== 9.10.3` next to a package with `^>= 9.10`.

The repository also tests itself on GitHub. The file
`.github/workflows/haskell-gha.yml` is generated for the tool itself. A
second file, `.github/workflows/haskell-gha-multi.yml`, is generated for
`examples/multi/`, a multi-package project with its own `cabal.project`.
Make it with this command:

```
haskell-gha --project-dir examples/multi --config examples/multi/haskell-gha.conf.yml --output .github/workflows/haskell-gha-multi.yml
```

The configuration of `examples/multi/` sets `name: CI (multi)`, because two
workflows with the same name cancel each other.

The configuration of the tool, `.github/haskell-gha.conf.yml`, has an
`after-build` hook that makes both files again. Thus a pull request with an
outdated workflow file fails:

```yaml
- name: Make sure that the workflows are up to date
  run: |
    cabal run haskell-gha
    cabal run haskell-gha -- --project-dir examples/multi --config examples/multi/haskell-gha.conf.yml --output .github/workflows/haskell-gha-multi.yml
    git diff --exit-code
```

## Stages

Do the work in this order. Start a stage after all tests of the stage
before it pass.

1. Make the package skeleton, the ordered YAML tree, the configuration
   reader and the output. Add round-trip tests.
2. Make the project reader with globs, conditions and `tested-with`. Add a
   unit test for each error message.
3. Make the workflow model and the command line. Add the golden test for a
   single package.
4. Add `apt`, `services`, `matrix`, `hooks`, `ghc-options`, `jobs`, `tests`,
   `benchmarks`, the cache and `--project-dir`. Add their golden tests.
5. Do the doctest experiment, then add doctest and its golden test.
6. Write the README and the changelog. Add `examples/multi/` and the two
   workflows of the repository. Run them on GitHub.

## Out of scope

The first version does not support these features:

- A job container.
- macOS and Windows.
- GHC prereleases and GHC head.
- head.hackage.
- A job that tests the lower bounds with `--prefer-oldest`.
- `before-test` and `after-test` hooks.
- Benchmark runs.
- stack.

Each feature can come later as a new optional field, without a breaking
change to the configuration format.
