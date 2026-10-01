# haskell-gha

[![CI](https://github.com/arybczak/haskell-gha/actions/workflows/haskell-gha.yml/badge.svg?branch=master)](https://github.com/arybczak/haskell-gha/actions/workflows/haskell-gha.yml)

`haskell-gha` writes a GitHub Actions workflow for a Haskell cabal project. The
workflow builds and tests the project on each GHC version from the
`tested-with` field of its packages.

The workflow is short and easy to read. It uses `haskell-actions/setup` to
install GHC and cabal, it caches the cabal store, and it runs each GHC
version in its own job. Only Linux is supported.

## Compared to `haskell-ci`

`haskell-gha` is an alternative to
[`haskell-ci`](https://github.com/haskell-CI/haskell-ci) for projects that use
only GitHub Actions on Linux. It improves on `haskell-ci` in these points:

- The jobs install GHC and cabal with `haskell-actions/setup`, not with a manual
  installation of GHCup. They run on the runner image, or optionally in a job
  container. `haskell-ci` always runs the jobs in a container.
- A new GHC release needs no new release of the tool. `haskell-ci` only accepts
  the GHC versions of its built-in list. `haskell-gha` gives the version to
  `haskell-actions/setup`, and a series, e.g. `^>= 9.12`, gets the newest
  release of that series.
- The workflow uses the `cabal.project` of the project with its conditional
  blocks, and the tool checks the blocks against `tested-with`. `haskell-ci`
  writes its own `cabal.project` for each job.
- Service containers, hook steps and extra matrix axes are GitHub Actions YAML.
  The tool copies them to the workflow without changes. `haskell-ci` only
  supports a PostgreSQL service, and other changes need patch files for the
  generated workflow.
- The cache of a job changes only with its build plan. `haskell-ci` saves a new
  cache for each commit.
- With `dependencies: both`, separate jobs test the oldest versions that the
  bounds allow, with the same steps as the other jobs. In `haskell-ci`, a
  constraint set with `prefer-oldest` runs at the end of the same job, without
  `cabal.project.local`, and without the tests by default.
- The workflow can check the formatting with fourmolu and the code with HLint,
  each in its own job. `haskell-ci` has no such jobs.

`haskell-ci` has features that `haskell-gha` does not have, e.g. macOS jobs, GHC
prereleases, head.hackage, GHCJS and constraint sets with arbitrary constraints.
If you need one of these features, use `haskell-ci`.

## Installation

Build the tool from the source:

```
git clone https://github.com/arybczak/haskell-gha.git
cd haskell-gha
cabal install
```

## Usage

To make the first workflow, run the tool in the root of your repository with
`--generate`:

```
haskell-gha --generate
```

The tool reads the project in the current directory and writes
`.github/workflows/haskell-gha.yml`. Commit this file.

The tool accepts these options:

| Option | Default | Meaning |
|---|---|---|
| `--generate` | | Make one workflow with the options below. Without it, the tool makes all generated workflows again. |
| `--config FILE` | `.github/haskell-gha.conf.yml` | The configuration file. If the default file does not exist, all keys take their defaults. A file that you name with this option must exist. |
| `--project-dir DIR` | `.` | The directory that contains `cabal.project` or the package. It must be a relative path in the repository. |
| `--output FILE` | `.github/workflows/haskell-gha.yml` | The workflow file. |
| `--check` | | Make sure that all generated workflows are up to date, and do not write them. If one is not up to date, exit with code 1. |
| `-v`, `--version` | | Show the version of the tool and exit. |

You can give `--config`, `--project-dir` and `--output` only after
`--generate`. You cannot give `--check` with `--generate`.

All paths are relative to the current directory, which must be the root of
the repository.

The first lines of the workflow file are a comment. It gives the version of
the tool, the command that made the file and a link to this repository. If
the tool finds a problem, it prints all problems of the step that failed
and exits with code 1.

### Keep the workflow up to date

When you change the `tested-with` field of a package, the packages of the
project or the configuration, run the tool without options:

```
haskell-gha
```

The tool finds each file in `.github/workflows` that starts with its header,
and runs the command from the header again. If no file has the header, the
tool stops with an error. The `--output` of the command must be the file
itself. If you rename a workflow file, run its command with the new
`--output`.

To make sure that the committed workflows are up to date, run the tool in CI
with `--check`:

```
haskell-gha --check
```

The tool compares each workflow with its file and does not change the files.
The comparison also includes the header comment, e.g. the version of the
tool.

A new version of the tool writes its version into the files. After you
upgrade the tool, run it again and commit the files.

## GHC versions

The `tested-with` field of each package gives the GHC versions. The tool
supports GHC 8.10 and later, and an older version in `tested-with` is an
error. Each part of the field must be one of these two forms:

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
the block to add. The opposite is also an error. Take a package that lists
a GHC version in `tested-with`. If the project does not include the package
for that version, no job tests the package with it. This rule does not
apply to a package that no job builds, e.g. one that is in the project only
for `os(windows)`.

A condition must include all versions of a matrix entry or none of them. If
the matrix has the entry `9.10`, the condition `impl(ghc >= 9.10.2)` is an
error, because the result depends on the minor version of the job. The
first release of a series is `X.Y.1`, so `impl(ghc >= 9.10.1)` includes
all of `9.10` and is not an error. A `flag(...)` condition is also an
error, because the tool does not know the value of the flag. These errors
do not apply to a part of a condition that cannot change the result, e.g.
`flag(dev)` in `os(linux) || flag(dev)`.

For the same reason, all packages must write a series in the same form. If
one package lists `GHC ^>= 9.10` and another lists `GHC == 9.10.3`, the
tool stops with an error. No conditional block can separate the two.

For GHC 9.4 and older, the workflow installs the Ubuntu package
`binutils-gold`. The `hsc2hs` of these versions needs the gold linker, and
Ubuntu 25.10 and later do not install it by default.

## Configuration

All keys of the configuration file are optional. An unknown key is an error.
YAML reads a key without a value as `null`, which is an error for most keys. For
`container` and `services`, `null` is valid and means none. The tool reports all
errors in the file together. If YAML reads a text value as a number, a boolean
or a null, quote the value, e.g. `version: '3.10'`. Without quotes, YAML reads
`3.10` as the number 3.1. This example shows all keys:

```yaml
name: CI
cabal-version: '3.16.1.0'
runs-on: ubuntu-26.04
container: buildpack-deps:26.04
timeout-minutes: 60
branches: [master, main]
submodules: false
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
    options: >-
      --health-cmd pg_isready
      --health-interval 5s
      --health-retries 10
permissions:
  contents: read
hooks:
  after-setup:
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
dependencies: newest
doctest:
  enabled: true
  ghc: '>=9.6 && <9.14'
  version: '>=0.24'
  skip: [some-package]
  options: [--fast]
check: true
sdist: true
haddock: true
fourmolu:
  enabled: true
  version: '0.20.1.0'
  pattern: ['src/**/*.hs', '!src/Generated.hs']
hlint:
  enabled: true
  version: '3.10'
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

| Key | Default | Meaning |
|---|---|---|
| `name` | `CI` | The name of the workflow. Two workflows in one repository must have different names, because workflows with the same name cancel each other. |
| `cabal-version` | `3.16.1.0` | The cabal version, or `latest`. The version must be 3.12 or later. |
| `runs-on` | `ubuntu-26.04` | The runner of the build jobs, as GitHub Actions YAML: a label, e.g. `ubuntu-latest`, a list of labels, e.g. `[self-hosted, linux]`, or a mapping with `group` and `labels`. The tool copies it to the workflow without changes. |
| `container` | none | The image of a job container for the build jobs: `buildpack-deps:22.04`, `buildpack-deps:24.04` or `buildpack-deps:26.04`. See [Container](#container). |
| `timeout-minutes` | `60` | The time limit of each job, in minutes. |
| `branches` | `[master, main]` | The branches for the `push` trigger. |
| `submodules` | `false` | Fetch the Git submodules in the build jobs: `true`, `false` or `recursive`. `recursive` also fetches the submodules of each submodule. The fourmolu and HLint jobs do not fetch them. |
| `matrix` | none | Extra matrix axes, and `include` and `exclude`. The tool copies them next to the `ghc` axis. |
| `apt` | `[]` | Ubuntu packages to install. |
| `services` | none | Service containers, as in GitHub Actions. |
| `permissions` | `contents: read` | The permissions of the `GITHUB_TOKEN`, as in GitHub Actions: a mapping, `read-all` or `write-all`. |
| `hooks.after-setup` | `[]` | Steps after the installation of GHC and cabal, and before the source tarballs and the build plan. A hook can install a library that the dependencies need, e.g. one that `apt` does not have. |
| `hooks.after-build` | `[]` | Steps after the build and before the tests. |
| `ghc-options` | `-Werror` | GHC options for the local packages only, on one line. An empty string disables them. |
| `cabal-project-local` | none | Text to add at the end of `cabal.project.local`, e.g. package flags or constraints. |
| `jobs` | `4` | The number of parallel build jobs. |
| `tests` | `true` | Build and run the test suites. |
| `benchmarks` | `true` | Build the benchmarks. The workflow does not run them. |
| `dependencies` | `newest` | The versions of the dependencies: `newest`, `oldest` or `both`. See [Dependencies](#dependencies). |
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

To use another repository with the same inputs, e.g. a fork, write the
repository in front of the ref, e.g. `cache: runs-on/cache@v4`. For
`actions.cache`, the tool adds `/restore` and `/save` to the repository.

The tool copies `matrix`, `services`, `permissions` and the steps of the
hooks to the workflow without changes, together with their comments. You can
use GitHub expressions in them, e.g. `${{ matrix.postgres }}`. The `matrix`
mapping must not contain the key `ghc`, because the tool makes that axis.
With `dependencies: both`, the same applies to the key `dependencies`.
The job name refers to each axis in an expression. Thus the name of an axis
must start with a letter or `_`, and contain only letters, digits, `_` and
`-`. A `ghc` value in `include` or `exclude` must be a quoted string, e.g.
`'9.10'`, and it must be an entry of the axis. Each key of an `exclude`
entry must be `ghc`, an axis of the `matrix` mapping, or `dependencies`
with `dependencies: both`.

If a service has a health check, the runner starts the steps only when the
service is healthy. Thus the workflow needs no step that waits for the
service. The `postgres` image has no health check of its own, so the
example gives one in `options`.

A `run` step of a hook starts in the project directory of the checkout. A
`uses` step starts in the root of the repository, because GitHub applies
the run defaults only to `run` steps. A `working-directory` of a hook
step is relative to the root of the repository. The copy of the source
tarballs is in `${{ runner.temp }}/haskell-gha`. The `after-build` hooks
can use it, but it does not exist yet for the `after-setup` hooks.

The workflow writes the text of `cabal-project-local` to
`cabal.project.local` before it makes the build plan. Thus the cache of
each job contains the dependencies that the text adds. The text comes
after the `ghc-options` stanzas, so it can add more options. A line of the
text must not be `EOF`. You can use GitHub expressions in the text.

The default `cabal-version` is not `latest`. Now `latest` selects cabal
3.18.1.0, and that version has a bug in the GHC job semaphore.
[Cabal issue 12306](https://github.com/haskell/cabal/issues/12306) describes
the bug.

## Container

With `container`, the build jobs run in a job container, not directly on
the runner image. The fourmolu and HLint jobs stay on the runner. A
container lets the jobs use another Ubuntu release than the runner, e.g.
Ubuntu 26.04 on a runner with Ubuntu 24.04.

The tool accepts only the Ubuntu images of `buildpack-deps`, because the
workflow needs their tools, e.g. `git`, `curl` and `xz-utils`. The images
also contain the libraries that GHC needs, e.g. `libgmp-dev`.

A job in a container runs as root, and the image has no `sudo`. Thus the
workflow runs `apt-get` without `sudo`, and a hook step must also not use
it. `haskell-actions/setup` installs GHC and cabal in each job, because the
container does not have the tools of the runner image. Thus a job takes
some minutes longer.

These points are different in a container:

- A service is reachable by its name, e.g. `postgres`, not by
  `localhost`. The service then needs no `ports` mapping.
- `git` does not work in the checkout, because the checkout belongs to
  another user. If a hook runs `git`, first run
  `git config --global --add safe.directory '*'` in the hook.
- The cache keys contain the image of the container in place of the runner
  image.

## Dependencies

By default, cabal picks the newest versions of the dependencies that the
bounds of the packages allow. Thus CI does not test the lower bounds. If a
lower bound is too low, the build fails for a user who has an older version
of that dependency.

With `dependencies: oldest`, each job writes `prefer-oldest: True` to
`cabal.project.local`. cabal then picks the oldest versions that the bounds
allow. This also applies to the libraries that come with GHC, e.g. `text`,
so cabal can build an older version of such a library from Hackage.

With `dependencies: both`, the matrix gets the axis `dependencies` with the
values `newest` and `oldest`. Each GHC version gets a job for each value,
and the job name shows the value. The two kinds of jobs have separate
caches. All other steps are the same for both kinds. To remove an oldest
job, use `exclude`:

```yaml
dependencies: both
matrix:
  exclude:
    - ghc: '9.6'
      dependencies: oldest
```

A failure of an oldest job often comes from a dependency. E.g. an old
version of a dependency has no upper bound on `base` and does not build
with a new GHC. Then raise the lower bound in the `.cabal` file.

`dependencies: oldest` is useful for a second workflow that tests only the
lower bounds. Make it with `--generate`, `--config` and `--output`, and give
it its own `name`. The main workflow can then be a required check on GitHub,
and the second workflow an optional one.

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
- An `after-setup` hook makes a file that the build or the tests need, and
  the `.cabal` file does not list the file.
- An `after-build` hook makes a file in the checkout that the tests need.

The tool finds the first two cases and stops with an error. It cannot find
the hook cases.

## Doctest

If `doctest.enabled` is `true`, the workflow installs doctest and runs it
for the library and the sublibraries of each local package. The workflow
keeps the doctest binary in its own cache, so a job builds each doctest
version only once for each GHC version.

| Key | Default | Meaning |
|---|---|---|
| `doctest.enabled` | `false` | Run doctest. The other `doctest` keys have no effect without it. |
| `doctest.ghc` | all versions | The GHC versions to run doctest for. A new GHC release often works with doctest only after some weeks. |
| `doctest.version` | any version | The versions of the doctest package. |
| `doctest.skip` | `[]` | The packages to skip. |
| `doctest.options` | `[]` | Extra arguments for doctest. |

## Fourmolu

If `fourmolu.enabled` is `true`, the workflow gets a second job that checks
the formatting of the Haskell files with `haskell-actions/run-fourmolu`.
The job needs no GHC, so it runs once, at the same time as the build jobs.
fourmolu reads the `fourmolu.yaml` of the project.

| Key | Default | Meaning |
|---|---|---|
| `fourmolu.enabled` | `false` | Add the fourmolu job. The other `fourmolu` keys have no effect without it. |
| `fourmolu.version` | `0.20.1.0` | The fourmolu version. |
| `fourmolu.pattern` | all `.hs` and `.hs-boot` files | The files to check, as glob patterns. A pattern that starts with `!` excludes files. A pattern must be one line without spaces at the start or the end. |
| `fourmolu.runs-on` | the value of `runs-on` | The runner of the fourmolu job, e.g. a smaller self-hosted runner than the build jobs need. |

Set `fourmolu.version` to the version that the developers of the project
use. A new fourmolu version can format the same code differently.
fourmolu 0.20.0.0 and later need `run-fourmolu` v13 or later.

## HLint

If `hlint.enabled` is `true`, the workflow gets a job that installs HLint
with `haskell-actions/hlint-setup` and runs it with
`haskell-actions/hlint-run`. Like the fourmolu job, it runs once, at the
same time as the build jobs. The hints appear as annotations in the pull
request.

| Key | Default | Meaning |
|---|---|---|
| `hlint.enabled` | `false` | Add the HLint job. The other `hlint` keys have no effect without it. |
| `hlint.version` | `3.10` | The HLint version. |
| `hlint.fail-on` | `suggestion` | The lowest hint level that fails the job: `never`, `status`, `warning`, `suggestion` or `error`. |
| `hlint.path` | the project directory | The directories or files to check, relative to the project directory. A path must be in the repository, and it must not contain a tab or another control character. |
| `hlint.runs-on` | the value of `runs-on` | The runner of the HLint job, as for `fourmolu.runs-on`. |

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
  `ghc-options` and no `tested-with` check. A local imported file must be
  in the repository, because CI has only the repository.
- If the project directory has no `cabal.project`, the tool reads the
  packages of the directory as the project. If a parent directory has a
  `cabal.project`, cabal uses that file instead. With `sdist: false`, the
  workflow then builds the parent project, but the tool read only the
  packages of the project directory. Give the directory of the parent
  `cabal.project` to `--project-dir`.
- The tool decides `os(...)` and `arch(...)` conditions for Linux on
  x86_64. It assumes that no project selects its packages by operating
  system or architecture.
- The matrix contains the `tested-with` versions of all local packages,
  also of a package that no job builds, e.g. one that is in the project only
  for `os(windows)`. Such a package can add a job or cause a misleading
  error. Give it the same `tested-with` versions as the other packages.
- The tool reads all branches of the conditional blocks in `cabal.project`,
  also a branch that no job selects. cabal reads only the branch that it
  selects. Thus the rules for package locations and `import:` lines apply
  to each branch. E.g. a location in `packages:` must exist, and with
  `sdist: true` a local `import:` is an error.
- doctest skips a module without an error in one case. The library has no
  `hs-source-dirs` or has `.` in it, and the package directory has no
  `.hs` or `.lhs` file for an exposed module. The module can come from
  another file, e.g. a `.hsc` file for `hsc2hs`. The same applies to each
  sublibrary.
- A test suite counts, whatever its conditions are. If all test suites of a
  project have `buildable: False` for a GHC version, the test step fails for
  that version.
- The `ghc-options` stanzas apply to all local packages on all GHC versions.
  Take a package that is not in the project for a GHC version. If another
  package depends on it, cabal gets it from Hackage and applies the
  options, e.g. `-Werror`.
- The cache keys contain the runner image from the environment variable
  `ImageOS`. The runners of GitHub set this variable, but a self-hosted
  runner can lack it. Then the cache keys have no image part. A cache from an
  earlier system of the runner can then link against system libraries that
  the runner no longer has. If you change the system of such a runner, delete
  the caches of the repository.
- The workflow contains only the comments in the copied keys and above
  them. The tool drops a comment above another key, e.g. `apt`. Of the
  comments in `hooks`, it keeps only the comments inside and between the
  steps of a hook. The comments of `runs-on` go only to the build job. If the
  first key is a copied key, a comment at the top of the file goes to the
  workflow with that key. Otherwise the tool drops it.
