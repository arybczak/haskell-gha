# haskell-gha

[![CI](https://github.com/arybczak/haskell-gha/actions/workflows/haskell-gha.yml/badge.svg?branch=master)](https://github.com/arybczak/haskell-gha/actions/workflows/haskell-gha.yml)

haskell-gha writes a GitHub Actions workflow for a Haskell cabal project. The
workflow builds and tests the project on each GHC version from the
`tested-with` field of its packages.

The workflow is short and easy to read. It uses `haskell-actions/setup` to
install GHC and cabal, it caches the cabal store, and it runs each GHC
version in its own job. Only Linux is supported.

## Installation

Build the tool from the source:

```
git clone https://github.com/arybczak/haskell-gha.git
cd haskell-gha
cabal install
```

## Usage

Run the tool in the root of your repository:

```
haskell-gha
```

The tool reads the project in the current directory and writes
`.github/workflows/haskell-gha.yml`. Commit this file. When you change the
`tested-with` field of a package, the packages of the project or the
configuration, run the tool again.

The tool accepts these options:

| Option | Default | Meaning |
|---|---|---|
| `--config FILE` | `.github/haskell-gha.conf.yml` | The configuration file. If the file does not exist, all fields take their defaults. |
| `--project-dir DIR` | `.` | The directory that contains `cabal.project` or the package. |
| `--output FILE` | `.github/workflows/haskell-gha.yml` | The workflow file. |

All paths are relative to the current directory, which must be the root of
the repository.

The first lines of the workflow file are a comment with the version of the
tool and the command that made the file. If the tool finds a problem, it
prints all problems of the step that failed and exits with code 1.

### Keep the workflow up to date

To make sure that the committed workflow is up to date, run the tool in CI
and then compare the result with the committed file:

```
haskell-gha
git diff --exit-code
```

`git diff` does not show an untracked file. To also find a workflow file
that is not committed, use `git status --porcelain` and make sure that its
output is empty.

A new version of the tool writes its version into the file. After you
upgrade the tool, run it again and commit the file.

## GHC versions

The `tested-with` field of each package gives the GHC versions. Each part of
the field must be one of these two forms:

- An exact version, e.g. `GHC == 9.10.3`. The job uses this version.
- A major series, e.g. `GHC ^>= 9.10` or `GHC == 9.10.*`. The job uses the
  newest release of the series that `haskell-actions/setup` knows.

A package can mix the two forms, e.g.
`tested-with: GHC == 9.6.7 || ^>= 9.10 || ^>= 9.12`. An open range, e.g.
`GHC >= 9.10`, is an error, because the list of jobs must be finite. The
matrix of the workflow contains the versions of all local packages.

If the packages of a project support different GHC versions, put each
package in a conditional block in `cabal.project`:

```
packages: core

if impl(ghc >= 9.10)
  packages: new
```

The tool reads these blocks as cabal does. If a package is in the project
for a GHC version that its `tested-with` field does not list, the tool shows
the block to add.

A condition must include all versions of a matrix entry or none of them. If
the matrix has the entry `9.10`, the condition `impl(ghc >= 9.10.2)` is an
error, because the result depends on the minor version of the job. A
`flag(...)` condition is also an error, because the tool does not know the
value of the flag.

## Configuration

All fields of the configuration file are optional. An unknown field is an
error. This example shows all fields:

```yaml
name: CI
cabal-version: 3.16.1.0
runs-on: ubuntu-latest
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
```

| Field | Default | Meaning |
|---|---|---|
| `name` | `CI` | The name of the workflow. Two workflows in one repository must have different names, because workflows with the same name cancel each other. |
| `cabal-version` | `3.16.1.0` | The cabal version, or `latest`. The version must be 3.12 or later. |
| `runs-on` | `ubuntu-latest` | The name of the runner image, e.g. `ubuntu-24.04`. |
| `branches` | `[master, main]` | The branches for the `push` trigger. |
| `matrix` | none | Extra matrix axes, and `include` and `exclude`. The tool copies them next to the `ghc` axis. |
| `apt` | `[]` | Ubuntu packages to install. |
| `services` | none | Service containers, as in GitHub Actions. |
| `hooks.before-build` | `[]` | Steps before the build of the local packages. |
| `hooks.after-build` | `[]` | Steps after the build and before the tests. |
| `ghc-options` | `-Werror` | GHC options for the local packages only. An empty string disables them. |
| `cabal-project-local` | none | Text to add at the end of `cabal.project.local`, e.g. package flags or constraints. |
| `jobs` | `4` | The number of parallel build jobs. |
| `tests` | `true` | Build and run the test suites. |
| `benchmarks` | `true` | Build the benchmarks. The workflow does not run them. |
| `doctest` | none | Run doctest. See [Doctest](#doctest). |

The tool copies `matrix`, `services` and the hooks to the workflow without
changes, together with their comments. You can use GitHub expressions in
them, e.g. `${{ matrix.postgres }}`. The `matrix` field must not contain the
key `ghc`, because the tool makes that axis. A `ghc` value in `include` or
`exclude` must be a quoted string, e.g. `'9.10'`, and it must be an entry of
the axis. Each key of an `exclude` entry must be `ghc` or an axis of the
`matrix` field.

The workflow writes the text of `cabal-project-local` to
`cabal.project.local` before it makes the build plan. Thus the cache of
each job contains the dependencies that the text adds. The text comes
after the `ghc-options` stanzas, so it can add more options. A line of the
text must not be `EOF`. You can use GitHub expressions in the text.

The default `cabal-version` is not `latest`. Now `latest` selects cabal
3.18.1.0, and that version has a bug in the GHC job semaphore.
[Cabal issue 12306](https://github.com/haskell/cabal/issues/12306) describes
the bug.

## Doctest

If the configuration has a `doctest` field, the workflow installs doctest
and runs it for the library and the sublibraries of each local package. An
empty `doctest:` field enables doctest with the defaults.

| Field | Default | Meaning |
|---|---|---|
| `doctest.ghc` | all versions | The GHC versions to run doctest for. A new GHC release often works with doctest only after some weeks. |
| `doctest.version` | any version | The versions of the doctest package. |
| `doctest.skip` | `[]` | The packages to skip. |
| `doctest.options` | `[]` | Extra arguments for doctest. |

## Known limits

- The tool ignores `import:` lines in `cabal.project`. cabal reads the
  imported files in CI, but the tool does not see a package that only an
  imported file lists. Such a package gets no `ghc-options` and no
  `tested-with` check.
- The tool decides `os(...)` and `arch(...)` conditions for Linux on
  x86_64. It assumes that no project selects its packages by operating
  system or architecture.
- A test suite counts, whatever its conditions are. If all test suites of a
  project have `buildable: False` for a GHC version, the test step fails for
  that version.
- The `ghc-options` stanzas apply to all local packages on all GHC versions.
  Take a package that is not in the project for a GHC version. If another
  package depends on it, cabal gets it from Hackage and applies the
  options, e.g. `-Werror`.
- A comment at the end of a line moves to its own line. A comment before
  the first entry of a mapping or a list moves before the key of that
  mapping or list.
