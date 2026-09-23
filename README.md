# haskell-gha

[![CI](https://github.com/arybczak/haskell-gha/actions/workflows/haskell-gha.yml/badge.svg?branch=master)](https://github.com/arybczak/haskell-gha/actions/workflows/haskell-gha.yml)

`haskell-gha` writes a GitHub Actions workflow for a Haskell cabal project. The
workflow builds and tests the project on each GHC version from the
`tested-with` field of its packages.

The workflow is short and easy to read. It uses `haskell-actions/setup` to
install GHC and cabal, it caches the cabal store, and it runs each GHC
version in its own job. Only Linux is supported.

## Compared to `haskell-ci`

`haskell-gha` replaces [`haskell-ci`](https://github.com/haskell-CI/haskell-ci)
for projects that use only GitHub Actions on Linux. It improves on
`haskell-ci` in these points:

- The workflow is shorter and easier to read. The jobs use
  `haskell-actions/setup` on the runner image, not a job container with a
  manual installation of GHCup.
- A new GHC release needs no new release of the tool. `haskell-ci` only
  accepts the GHC versions of its built-in list. `haskell-gha` gives the
  version to `haskell-actions/setup`, and a series, e.g. `^>= 9.12`, gets
  the newest release of that series.
- Service containers, hook steps and extra matrix axes are GitHub Actions
  YAML. The tool copies them to the workflow without changes. `haskell-ci`
  only supports a PostgreSQL service, and other changes need patch files
  for the generated workflow.

`haskell-ci` has features that `haskell-gha` does not have, e.g. macOS
jobs, GHC prereleases and head.hackage. If you need one of these features,
use `haskell-ci`.

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
| `--project-dir DIR` | `.` | The directory that contains `cabal.project` or the package. It must be a relative path in the repository. |
| `--output FILE` | `.github/workflows/haskell-gha.yml` | The workflow file. |
| `-v`, `--version` | | Show the version of the tool and exit. |

All paths are relative to the current directory, which must be the root of
the repository.

The first lines of the workflow file are a comment. It gives the version of
the tool, the command that made the file and a link to this repository. If the tool finds a problem, it
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

- An exact version with three parts, e.g. `GHC == 9.10.3`. The job uses
  this version. A shorter version, e.g. `GHC == 9.10`, is an error, because
  no GHC release has it.
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
value of the flag. These errors do not apply to a part of a condition that
cannot change the result, e.g. `flag(dev)` in `os(linux) || flag(dev)`.

For the same reason, all packages must write a series in the same form. If
one package lists `GHC ^>= 9.10` and another lists `GHC == 9.10.3`, the
tool stops with an error. No conditional block can separate the two.

## Configuration

All fields of the configuration file are optional. An unknown field is an
error. This example shows all fields:

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
| `name` | `CI` | The name of the workflow. Two workflows in one repository must have different names, because workflows with the same name cancel each other. |
| `cabal-version` | `3.16.1.0` | The cabal version, or `latest`. The version must be 3.12 or later. |
| `runs-on` | `ubuntu-26.04` | The name of the runner image, e.g. `ubuntu-latest`. |
| `branches` | `[master, main]` | The branches for the `push` trigger. |
| `matrix` | none | Extra matrix axes, and `include` and `exclude`. The tool copies them next to the `ghc` axis. |
| `apt` | `[]` | Ubuntu packages to install. |
| `services` | none | Service containers, as in GitHub Actions. |
| `permissions` | `contents: read` | The permissions of the `GITHUB_TOKEN`, as in GitHub Actions: a mapping, `read-all` or `write-all`. |
| `hooks.before-build` | `[]` | Steps before the build of the local packages. |
| `hooks.after-build` | `[]` | Steps after the build and before the tests. |
| `ghc-options` | `-Werror` | GHC options for the local packages only, on one line. An empty string disables them. |
| `cabal-project-local` | none | Text to add at the end of `cabal.project.local`, e.g. package flags or constraints. |
| `jobs` | `4` | The number of parallel build jobs. |
| `tests` | `true` | Build and run the test suites. |
| `benchmarks` | `true` | Build the benchmarks. The workflow does not run them. |
| `doctest` | none | Run doctest. See [Doctest](#doctest). |
| `check` | `true` | Run `cabal check` for each local package. A warning does not fail the job. |
| `sdist` | `true` | Build and test the content of the source tarballs, not the checkout. See [Source tarballs](#source-tarballs). |
| `haddock` | `true` | Build the documentation as for a Hackage upload. |
| `fourmolu` | none | Check the formatting with fourmolu. See [Fourmolu](#fourmolu). |
| `hlint` | none | Check the code with HLint. See [HLint](#hlint). |
| `actions.checkout` | `v7` | The version of `actions/checkout`. |
| `actions.setup` | `v2` | The version of `haskell-actions/setup`. |
| `actions.cache` | `v6` | The version of `actions/cache/restore` and `actions/cache/save`. |
| `actions.run-fourmolu` | `v13` | The version of `haskell-actions/run-fourmolu`. |
| `actions.hlint-setup` | a commit, see below | The version of `haskell-actions/hlint-setup`. |
| `actions.hlint-run` | a commit, see below | The version of `haskell-actions/hlint-run`. |

A version in `actions` is a Git ref of the action, e.g. a tag such as
`v8` or a commit SHA. If a new major version of an action comes out, you
can use it without a new release of `haskell-gha`. You can also pin an
action to a commit.

The tool copies `matrix`, `services`, `permissions` and the hooks to the
workflow without changes, together with their comments. You can use GitHub expressions in
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

## Source tarballs

A user who installs a package from Hackage gets only the files of its
source tarball. If the build or the tests need a file that the `.cabal`
file does not list, e.g. a CPP header or a test fixture, the package fails
for that user. A build of the checkout does not find this error, because
the checkout has the file.

Thus the workflow makes the tarballs with `cabal sdist all` and unpacks
them into a separate directory. It copies `cabal.project`,
`cabal.project.freeze` and `cabal.project.local` next to them. The build,
the tests, doctest, `cabal check` and haddock then run in that directory.
The hooks still run in the checkout, in the project directory.

Set `sdist: false` in these cases:

- `cabal.project` imports a local file with `import:`.
- `cabal.project` lists a package outside the project directory, e.g.
  `../other`.
- A hook makes a file that the build or the tests need.

The tool finds the first two cases and stops with an error. It cannot find
the third case.

## Doctest

If the configuration has a `doctest` field, the workflow installs doctest
and runs it for the library and the sublibraries of each local package. An
empty `doctest:` field enables doctest with the defaults. The workflow keeps
the doctest binary in its own cache, so a job builds each doctest version
only once for each GHC version.

| Field | Default | Meaning |
|---|---|---|
| `doctest.ghc` | all versions | The GHC versions to run doctest for. A new GHC release often works with doctest only after some weeks. |
| `doctest.version` | any version | The versions of the doctest package. |
| `doctest.skip` | `[]` | The packages to skip. |
| `doctest.options` | `[]` | Extra arguments for doctest. |

## Fourmolu

If the configuration has a `fourmolu` field, the workflow gets a second job
that checks the formatting of the Haskell files with
`haskell-actions/run-fourmolu`. The job needs no GHC, so it runs once, at
the same time as the build jobs. fourmolu reads the `fourmolu.yaml` of the
project. An empty `fourmolu:` field enables the job with the defaults.

| Field | Default | Meaning |
|---|---|---|
| `fourmolu.version` | `0.20.1.0` | The fourmolu version. |
| `fourmolu.pattern` | all `.hs` and `.hs-boot` files | The files to check, as glob patterns. A pattern that starts with `!` excludes files. A pattern must be one line without spaces at the start or the end. |

Set `fourmolu.version` to the version that the developers of the project
use. A new fourmolu version can format the same code differently.
fourmolu 0.20.0.0 and later need `run-fourmolu` v13 or later.

## HLint

If the configuration has an `hlint` field, the workflow gets a job that
installs HLint with `haskell-actions/hlint-setup` and runs it with
`haskell-actions/hlint-run`. Like the fourmolu job, it runs once, at the
same time as the build jobs. The hints appear as annotations in the pull
request. An empty `hlint:` field enables the job with the defaults.

| Field | Default | Meaning |
|---|---|---|
| `hlint.version` | `3.10` | The HLint version. |
| `hlint.fail-on` | `suggestion` | The lowest hint level that fails the job: `never`, `status`, `warning`, `suggestion` or `error`. |
| `hlint.path` | the project directory | The directories or files to check, relative to the project directory. |

By default, every hint fails the job. To turn off a hint that the project
does not want, add an `ignore` entry to `.hlint.yaml`, e.g.
`- ignore: {name: Use camelCase}`.

HLint reads `.hlint.yaml` from the root of the repository, because the
action runs there. With `--project-dir`, put `.hlint.yaml` in the root of
the repository, not in the project directory.

The released versions of both actions still need Node.js 20, and GitHub
removes Node.js 20 in autumn 2026. Thus the default versions are the
commits that moved the actions to Node.js 24. These commits run the same
code as the release `v2.4.10`. When a new release comes out, set
`actions.hlint-setup` and `actions.hlint-run` to it.

## Known limits

- The tool does not read the files of `import:` lines in `cabal.project`.
  cabal reads the imported files in CI, but the tool does not see a
  package that only an imported file lists. Such a package gets no
  `ghc-options` and no `tested-with` check.
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
- The cache keys contain the runner image from the environment variable
  `ImageOS`. Only the runners of GitHub set this variable. On a
  self-hosted runner, the keys have no image part. A cache from an earlier
  system of the runner can then link against system libraries that the
  runner no longer has. If you change the system of a self-hosted runner,
  delete the caches of the repository.
- A comment at the end of a line moves to its own line. A comment before
  the first entry of a mapping or a list moves before the key of that
  mapping or list.
