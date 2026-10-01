# haskell-gha

[![CI](https://github.com/arybczak/haskell-gha/actions/workflows/haskell-gha.yml/badge.svg?branch=master)](https://github.com/arybczak/haskell-gha/actions/workflows/haskell-gha.yml)

`haskell-gha` writes a GitHub Actions workflow for a Haskell cabal project. The
workflow builds and tests the project on each GHC version from the `tested-with`
field of its packages.

The workflow uses `haskell-actions/setup` to install GHC and cabal, it caches
the cabal store, and it runs each GHC version in its own job. Only Linux is
supported.

## Contents

- [Quick start](#quick-start)
- [What the workflow does](#what-the-workflow-does)
- [Comparison with `haskell-ci`](#comparison-with-haskell-ci)
- [Usage](#usage)
- [GHC versions](#ghc-versions)
- [Configuration](#configuration)
- [Container](#container)
- [Dependencies](#dependencies)
- [Source tarballs](#source-tarballs)
- [Extra checks](#extra-checks)
- [Known limits](#known-limits)

## Quick start

Build the tool from the source:

```
git clone https://github.com/arybczak/haskell-gha.git
cd haskell-gha
cabal install
```

Each package of the project needs GHC versions in its `tested-with` field, e.g.
`tested-with: GHC ^>= 9.10 || ^>= 9.12`. See [GHC versions](#ghc-versions).

In the root of your repository, make the first workflow:

```
haskell-gha --generate
```

The tool reads the project in the current directory and writes
`.github/workflows/haskell-gha.yml`. Commit this file.

After you change the `tested-with` field of a package, the packages of the
project or the configuration, make the workflow again:

```
haskell-gha
```

To change the defaults, write a configuration file. See
[Configuration](#configuration).

## What the workflow does

The workflow has one build job for each GHC version. A build job has these
steps:

1. Install GHC and cabal with `haskell-actions/setup`.
2. Unpack the source tarballs of the local packages into a separate directory.
   See [Source tarballs](#source-tarballs).
3. Write the build settings to `cabal.project.local`, e.g. the number of
   parallel jobs and the GHC options of the local packages.
4. Make the build plan, and restore the cached cabal store for that plan.
5. Build the dependencies, and save the cache if the plan is new.
6. Build the project.
7. Run the tests.
8. Run `cabal check`, build the documentation and, if you enable it, run
   doctest.

You can add steps after step 1 and after step 6. See [Hooks](#hooks).

If you enable them, a fourmolu job and an HLint job check the code. They need no
GHC, so each runs once, at the same time as the build jobs.

## Comparison with `haskell-ci`

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
- The workflow uses the project's own `cabal.project` with its conditional
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
  `cabal.project.local` and without the tests by default.
- The workflow can check the formatting with fourmolu and the code with HLint,
  each in its own job. `haskell-ci` has no such jobs.

## Usage

### Options

| Option | Default | Meaning |
|---|---|---|
| `--generate` | | Make one workflow with the options below. Without it, the tool makes all generated workflows again. |
| `--config FILE` | `.github/haskell-gha.conf.yml` | The configuration file. If the default file does not exist, all keys take their defaults. A file that you name with this option must exist. |
| `--project-dir DIR` | `.` | The directory that contains `cabal.project` or the package. It must be a relative path in the repository. |
| `--output FILE` | `.github/workflows/haskell-gha.yml` | The workflow file. |
| `--check` | | Make sure that all generated workflows are up to date, and do not write them. If one is not up to date, exit with code 1. |
| `-v`, `--version` | | Show the version of the tool and exit. |

You can use `--config`, `--project-dir` and `--output` only after `--generate`.
You cannot use `--check` with `--generate`.

All paths are relative to the current directory, which must be the root of the
repository.

### Keeping the workflow up to date

Each workflow file starts with a header comment that gives the command that made
the file and the tool version. Without options, the tool finds each file in
`.github/workflows` with this header and generates the workflow again with the
options from the header. If no file has the header, the tool stops with an
error.

The `--output` of the command in the header must be the file itself, so a
renamed workflow file is an error. To rename a workflow file, run the command
from its header with the new path as `--output`, and delete the old file.

To make sure that the committed workflows are up to date, run the tool in CI
with `--check`:

```
haskell-gha --check
```

With `--check`, the tool generates each workflow again and compares the result
with the committed file. It writes no file. If a file differs, the tool exits
with code 1. The comparison includes the header comment with the tool version,
so after you upgrade the tool, run it again and commit the files.

### More than one workflow

To make a second workflow, e.g. one that tests only the lower bounds of the
dependencies, run `--generate` with its own `--config` and `--output`. Give it
its own `name` in the configuration, because workflows with the same name cancel
each other. After that, `haskell-gha` without options makes both workflows
again.

## GHC versions

### Versions in `tested-with`

The `tested-with` field of each package gives the GHC versions. A package
without a GHC version in `tested-with` is an error. The tool supports GHC 8.10
and later, and an older version in `tested-with` is an error. Each part of the
field must be one of these two forms:

- An exact version with three parts, e.g. `GHC == 9.10.3`. The job uses this
  version. A shorter version, e.g. `GHC == 9.10`, is an error, because no GHC
  release has it.
- A major series, e.g. `GHC ^>= 9.10` or `GHC == 9.10.*`. The job uses the
  newest release of the series that `haskell-actions/setup` knows. Before the
  first release of a series, the job uses its newest prerelease. To build the
  dependencies of a prerelease, see [GHC prereleases](#ghc-prereleases).

A package can mix the two forms, e.g.
`tested-with: GHC == 9.6.7 || ^>= 9.10 || ^>= 9.12`. An open range, e.g.
`GHC >= 9.10`, is an error, because the list of jobs must be finite.

The workflow matrix contains the versions of all local packages. All packages
must write a series in the same form. If one package lists
`GHC ^>= 9.10` and another lists `GHC == 9.10.3`, the tool stops with an error,
because no conditional block can separate the two.

For GHC 9.4 and older, the workflow installs the Ubuntu package
`binutils-gold`. The `hsc2hs` of these versions needs the gold linker, and
Ubuntu 25.10 and later do not install it by default.

### Packages for some GHC versions only

If the packages of a project support different GHC versions, put each package in
a conditional block in `cabal.project`:

```
packages: core

if impl(ghc >= 9.10)
  packages: new
```

The tool reads these blocks as cabal does, and it checks them against
`tested-with` in both directions:

- If the project includes a package for a GHC version that its `tested-with`
  does not list, the tool shows the block to add.
- If a package lists a GHC version in `tested-with`, but the project does not
  include the package for that version, the tool stops with an error, because no
  job tests the package with that version. This rule does not apply to a package
  that no job builds, e.g. one that is in the project only for `os(windows)`.

The tool must know the result of each condition for each matrix entry, so these
conditions are errors:

- A condition that includes only some versions of a matrix entry. If the matrix
  has the entry `9.10`, the condition `impl(ghc >= 9.10.2)` is an error, because
  the result depends on the minor version of the job. The first release of a
  series is `X.Y.1`, so `impl(ghc >= 9.10.1)` includes all of `9.10` and is not
  an error.
- A `flag(...)` condition, because the tool does not know the flag value.

These errors do not apply to a part of a condition that cannot change the
result, e.g. `flag(dev)` in `os(linux) || flag(dev)`.

### GHC prereleases

A dependency often does not build yet with a GHC prerelease. Put the fix in a
conditional block of `cabal.project`. The block then applies only to that GHC
version, and it also works for a local build.

head.hackage is a package repository with patched versions of many packages for
GHC prereleases. For example, this block allows newer versions of three
libraries that come with GHC 10, and it uses head.hackage, with the stanza from
the README of head.hackage:

```
if impl(ghc >= 10)
  allow-newer:
    , *:base
    , *:template-haskell
    , *:time
  repository head.hackage.ghc.haskell.org
    url: https://ghc.gitlab.haskell.org/head.hackage/
    secure: True
    key-threshold: 3
    root-keys:
      f76d08be13e9a61a377a85e2fb63f4c5435d40f8feb3e12eb05905edb8cdea89
      26021a13b401500c8eb2761ca95c61f2d625bfef951b939a8124ed12ecf07329
      7541f32a4ccca4f97aea3b22f5e593ba2c0267546016b992dfadcd2fe944e55d
  active-repositories: hackage.haskell.org, head.hackage.ghc.haskell.org:override
```

Allow newer versions only of the libraries that the build plan needs. If cabal
rejects a dependency because of its bounds on such a library, add the library to
the list. If only one dependency needs a patch, the block can also take it from
a fork with a `source-repository-package`.

The `allow-newer` also applies to the oldest jobs. With `prefer-oldest`, cabal
then also tries very old releases and often finds no build plan. With
`dependencies: both`, exclude the oldest job of the prerelease:

```yaml
dependencies: both
matrix:
  exclude:
  - ghc: '10.0'
    dependencies: oldest
```

The workflow installs doctest outside the project, so the block does not apply
to doctest. If doctest does not build with the prerelease, leave that version
out of `doctest.ghc`.

## Configuration

The configuration file is YAML. These rules apply to it:

- All keys are optional. An unknown key is an error.
- YAML reads a key without a value as `null`, which is an error for most keys.
  For `container` and `services`, `null` is valid and means none.
- If YAML reads a text value as a number, a boolean or a null, quote the value,
  e.g. `version: '3.10'`. Without quotes, YAML reads `3.10` as the number 3.1.
- The tool reports all errors in the file together.

A file needs only the keys that differ from the defaults, e.g.:

```yaml
branches: [master]
apt: [libpq-dev]
dependencies: both
fourmolu:
  enabled: true
  version: '0.20.1.0'
hlint:
  enabled: true
  version: '3.10'
```

<details>
<summary>An example with all keys</summary>

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
ghc-options: -Werror -Wwarn=unrecognised-warning-flags -Wwarn=semaphore-open-failure
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

</details>

### Workflow and runner

| Key | Default | Meaning |
|---|---|---|
| `name` | `CI` | The name of the workflow. Two workflows in one repository must have different names, because workflows with the same name cancel each other. |
| `branches` | `[master, main]` | The branches for the `push` trigger. |
| `permissions` | `contents: read` | The permissions of the `GITHUB_TOKEN`, as in GitHub Actions: a mapping, `read-all` or `write-all`. |
| `runs-on` | `ubuntu-26.04` | The runner of the build jobs, as GitHub Actions YAML: a label, e.g. `ubuntu-latest`, a list of labels, e.g. `[self-hosted, linux]`, or a mapping with `group` and `labels`. The tool copies it to the workflow without changes. |
| `container` | none | The image of a job container for the build jobs: `buildpack-deps:22.04`, `buildpack-deps:24.04` or `buildpack-deps:26.04`. See [Container](#container). |
| `timeout-minutes` | `60` | The time limit of each job, in minutes. |
| `submodules` | `false` | Fetch the Git submodules in the build jobs: `true`, `false` or `recursive`. `recursive` also fetches the submodules of each submodule. The fourmolu and HLint jobs do not fetch them. |
| `matrix` | none | Extra matrix axes, and `include` and `exclude`. The tool copies them next to the `ghc` axis. |
| `apt` | `[]` | Ubuntu packages to install. |
| `services` | none | Service containers, as in GitHub Actions. |

#### Matrix, services and permissions

The tool copies `matrix`, `services`, `permissions` and the hook steps to the
workflow without changes, together with their comments. You can use GitHub
expressions in them, e.g. `${{ matrix.postgres }}`.

These rules apply to `matrix`:

- The mapping must not contain the key `ghc`, because the tool makes that axis.
  With `dependencies: both`, the same applies to the key `dependencies`.
- The job name refers to each axis in an expression, so an axis name must start
  with a letter or `_` and contain only letters, digits, `_` and `-`.
- A `ghc` value in `include` or `exclude` must be a quoted string, e.g.
  `'9.10'`, and it must be an entry of the axis.
- Each key of an `exclude` entry must be `ghc`, an axis of the `matrix` mapping,
  or `dependencies` with `dependencies: both`.

If a service has a health check, the runner starts the steps only when the
service is healthy. The workflow then needs no step that waits for the service.
The `postgres` image has no health check of its own, so the example with all
keys gives one in `options`.

### Hooks

| Key | Default | Meaning |
|---|---|---|
| `hooks.after-setup` | `[]` | Steps after the installation of GHC and cabal, and before the source tarballs and the build plan. |
| `hooks.after-build` | `[]` | Steps after the build and before the tests. |

A hook is a list of GitHub Actions steps. An `after-setup` hook can install a
library that the dependencies need, e.g. one that `apt` does not have. An
`after-build` hook can prepare the tests. For example, with the `postgres`
service from the example with all keys, this hook creates a database for the
tests:

```yaml
hooks:
  after-build:
  - name: Create the test database
    run: psql -h localhost -U postgres -c 'CREATE DATABASE test'
    env:
      PGPASSWORD: postgres
```

A `run` step of a hook starts in the project directory of the checkout. A `uses`
step starts in the root of the repository, because GitHub applies the run
defaults only to `run` steps. A `working-directory` of a hook step is relative
to the root of the repository.

The copy of the source tarballs is in `${{ runner.temp }}/haskell-gha`. The
`after-build` hooks can use it, but it does not exist yet for the `after-setup`
hooks.

### Build

| Key | Default | Meaning |
|---|---|---|
| `cabal-version` | `3.16.1.0` | The cabal version, or `latest`. The version must be 3.12 or later. See [Defaults that avoid a bug](#defaults-that-avoid-a-bug). |
| `ghc-options` | `-Werror -Wwarn=unrecognised-warning-flags -Wwarn=semaphore-open-failure` | GHC options for the local packages only, on one line. An empty string disables them. See [Defaults that avoid a bug](#defaults-that-avoid-a-bug). |
| `cabal-project-local` | none | Text to add at the end of `cabal.project.local`, e.g. package flags or constraints. See [Extra cabal.project.local text](#extra-cabalprojectlocal-text). |
| `jobs` | `4` | The number of parallel build jobs. |
| `tests` | `true` | Build and run the test suites. |
| `benchmarks` | `true` | Build the benchmarks. The workflow does not run them. |
| `dependencies` | `newest` | The versions of the dependencies: `newest`, `oldest` or `both`. See [Dependencies](#dependencies). |
| `sdist` | `true` | Build and test the content of the source tarballs, not the checkout. See [Source tarballs](#source-tarballs). |

#### Extra `cabal.project.local` text

The workflow writes the text of `cabal-project-local` to `cabal.project.local`
before it makes the build plan, so the cache of each job contains the
dependencies that the text adds. The text comes after the `ghc-options` stanzas,
so it can add more options. A line of the text must not be `EOF`. You can use
GitHub expressions in the text.

#### Defaults that avoid a bug

The default `cabal-version` is not `latest`. As of October 2026, `latest`
selects cabal 3.18.1.0, and that version has a bug in the GHC job semaphore.
[Cabal issue 12306](https://github.com/haskell/cabal/issues/12306) describes the
bug.

The default `ghc-options` stop one warning from failing the build under
`-Werror`. GHC and cabal can use different versions of the job semaphore
protocol. GHC then warns that it cannot use the semaphore, and it compiles the
modules one at a time. An older GHC does not know this warning, so the options
also stop the warning about an unknown warning flag from failing the build. If
you set `ghc-options`, add both `-Wwarn` options.

### Checks

| Key | Default | Meaning |
|---|---|---|
| `check` | `true` | Run `cabal check` for each local package. A warning does not fail the job. |
| `haddock` | `true` | Build the documentation of the libraries as for a Hackage upload. |
| `doctest` | none | Run doctest. See [Doctest](#doctest). |
| `fourmolu` | none | Check the formatting with fourmolu. See [Fourmolu](#fourmolu). |
| `hlint` | none | Check the code with HLint. See [HLint](#hlint). |

### Versions of the actions

| Key | Default | Meaning |
|---|---|---|
| `actions.checkout` | `v7` | The version of `actions/checkout`. |
| `actions.setup` | `v2` | The version of `haskell-actions/setup`. |
| `actions.cache` | `v6` | The version of `actions/cache/restore` and `actions/cache/save`. |
| `actions.run-fourmolu` | `v13` | The version of `haskell-actions/run-fourmolu`. |
| `actions.hlint-setup` | a commit, see [HLint](#hlint) | The version of `haskell-actions/hlint-setup`. |
| `actions.hlint-run` | a commit, see [HLint](#hlint) | The version of `haskell-actions/hlint-run`. |

A version in `actions` is a Git ref of the action, e.g. a tag such as `v8` or a
commit SHA. If a new major version of an action comes out, you can use it
without a new release of `haskell-gha`. You can also pin an action to a commit.

To use another repository with the same inputs, e.g. a fork, write the
repository in front of the ref, e.g. `cache: runs-on/cache@v4`. For
`actions.cache`, the tool adds `/restore` and `/save` to the repository.

## Container

With `container`, the build jobs run in a job container, not directly on the
runner image. The fourmolu and HLint jobs stay on the runner. A container lets
the jobs use another Ubuntu release than the runner, e.g. Ubuntu 26.04 on a
runner with Ubuntu 24.04.

The tool accepts only the Ubuntu images of `buildpack-deps`, because the
workflow needs their tools, e.g. `git`, `curl` and `xz-utils`. The images also
contain the libraries that GHC needs, e.g. `libgmp-dev`.

`haskell-actions/setup` installs GHC and cabal in each job, because the
container does not have the tools of the runner image, so a job takes some
minutes longer.

These points are different in a container:

- A job runs as root, and the image has no `sudo`. The workflow runs `apt-get`
  without `sudo`, and a hook step must not use it either.
- A service is reachable by its name, e.g. `postgres`, not by `localhost`. The
  service then needs no `ports` mapping.
- `git` does not work in the checkout, because the checkout belongs to another
  user. If a hook runs `git`, first run
  `git config --global --add safe.directory '*'` in the hook.
- The cache keys contain the container image in place of the runner image.

## Dependencies

By default, cabal picks the newest dependency versions that the package bounds
allow, so CI does not test the lower bounds. If a lower bound is too low, the
build fails for a user who has an older version of that dependency.

With `dependencies: oldest`, each job writes `prefer-oldest: True` to
`cabal.project.local`. cabal then picks the oldest versions that the bounds
allow. This also applies to the libraries that come with GHC, e.g. `text`, so
cabal can build an older version of such a library from Hackage.

With `dependencies: both`, the matrix gets the axis `dependencies` with the
values `newest` and `oldest`. Each GHC version gets a job for each value, and
the job name shows the value. The two kinds of jobs have separate caches. All
other steps are the same for both kinds. To remove an oldest job, use `exclude`:

```yaml
dependencies: both
matrix:
  exclude:
    - ghc: '9.6'
      dependencies: oldest
```

A failure of an oldest job often comes from a dependency. For example, an old
version of a dependency has no upper bound on `base` and does not build with a
new GHC. Then raise the lower bound in the `.cabal` file.

You can also test the lower bounds in a second workflow with
`dependencies: oldest`. See [More than one workflow](#more-than-one-workflow).
The main workflow can then be a required check on GitHub, and the second
workflow an optional one.

## Source tarballs

A user who installs a package from Hackage gets only the files of its source
tarball. If the build or the tests need a file that the `.cabal` file does not
list, e.g. a CPP header or a test fixture, the package fails for that user. A
build of the checkout does not find this error, because the checkout has the
file.

To find this error, the workflow makes the tarballs with `cabal sdist all` and
unpacks them into a separate directory. It copies `cabal.project`,
`cabal.project.freeze` and `cabal.project.local` next to them. The build, the
tests, doctest, `cabal check` and haddock then run in that directory. The hooks
still run in the checkout, in the project directory.

Set `sdist: false` in these cases:

- `cabal.project` imports a local file with `import:`.
- `cabal.project` lists a package outside the project directory, e.g.
  `../other`.
- An `after-setup` hook makes a file that the build or the tests need, and the
  `.cabal` file does not list the file.
- An `after-build` hook makes a file in the checkout that the tests need.

The tool finds the first two cases and stops with an error. It cannot find the
hook cases.

## Extra checks

Doctest, fourmolu and HLint are off by default. Each has an `enabled` key, and
its other keys have no effect without it.

### Doctest

If `doctest.enabled` is `true`, the workflow installs doctest and runs it for
the library and the sublibraries of each local package. The workflow keeps the
doctest binary in its own cache, so a job builds each doctest version only once
for each GHC version.

| Key | Default | Meaning |
|---|---|---|
| `doctest.enabled` | `false` | Run doctest. |
| `doctest.ghc` | all versions | The GHC versions to run doctest for. The range must include at least one matrix entry. A new GHC release often works with doctest only after some weeks. |
| `doctest.version` | any version | The versions of the doctest package. |
| `doctest.skip` | `[]` | The packages to skip. |
| `doctest.options` | `[]` | Extra arguments for doctest. |

### Fourmolu

If `fourmolu.enabled` is `true`, the workflow gets a job that checks the
formatting of the Haskell files with `haskell-actions/run-fourmolu`. fourmolu
reads the project's `fourmolu.yaml`.

| Key | Default | Meaning |
|---|---|---|
| `fourmolu.enabled` | `false` | Add the fourmolu job. |
| `fourmolu.version` | `0.20.1.0` | The fourmolu version. |
| `fourmolu.pattern` | all `.hs` and `.hs-boot` files | The files to check, as glob patterns. A pattern that starts with `!` excludes files. A pattern must be one line without spaces at the start or the end. |
| `fourmolu.runs-on` | the value of `runs-on` | The runner of the fourmolu job, e.g. a smaller self-hosted runner than the build jobs need. |

Set `fourmolu.version` to the version that the project developers use. A new
fourmolu version can format the same code differently. fourmolu 0.20.0.0 and
later need `run-fourmolu` v13 or later.

### HLint

If `hlint.enabled` is `true`, the workflow gets a job that installs HLint with
`haskell-actions/hlint-setup` and runs it with `haskell-actions/hlint-run`. The
hints appear as annotations in the pull request.

| Key | Default | Meaning |
|---|---|---|
| `hlint.enabled` | `false` | Add the HLint job. |
| `hlint.version` | `3.10` | The HLint version. |
| `hlint.fail-on` | `suggestion` | The lowest hint level that fails the job: `never`, `status`, `warning`, `suggestion` or `error`. |
| `hlint.path` | the project directory | The directories or files to check, relative to the project directory. A path must be in the repository, and it must not contain a tab or another control character. |
| `hlint.runs-on` | the value of `runs-on` | The runner of the HLint job, as for `fourmolu.runs-on`. |

By default, every hint fails the job. To turn off a hint that the project does
not want, add an `ignore` entry to `.hlint.yaml`, e.g.
`- ignore: {name: Use camelCase}`.

HLint reads `.hlint.yaml` from the root of the repository, because the action
runs there. With `--project-dir`, put `.hlint.yaml` in the root of the
repository, not in the project directory.

The released versions of both actions still need Node.js 20, and GitHub removes
Node.js 20 in autumn 2026, so the default versions are the commits that moved
the actions to Node.js 24. These commits run the same code as the release
`v2.4.10`. When a new release comes out, set `actions.hlint-setup` and
`actions.hlint-run` to it.

## Known limits

### `cabal.project`

- The tool does not read the files of `import:` lines in `cabal.project`. cabal
  reads the imported files in CI, but the tool does not see a package that only
  an imported file lists. Such a package gets no `ghc-options` and no
  `tested-with` check. A local imported file must be in the repository, because
  CI has only the repository.
- If the project directory has no `cabal.project`, the tool reads the packages
  of the directory as the project. If a parent directory has a `cabal.project`,
  cabal uses that file instead. With `sdist: false`, the workflow then builds
  the parent project, but the tool read only the packages of the project
  directory. Pass the parent directory to `--project-dir`.
- The tool reads all branches of the conditional blocks in `cabal.project`, also
  a branch that no job selects. cabal reads only the branch that it selects, but
  the tool applies the rules for package locations and `import:` lines to each
  branch. For example, a location in `packages:` must exist, and with
  `sdist: true` a local `import:` is an error.
- The tool decides `os(...)` and `arch(...)` conditions for Linux on x86_64. It
  assumes that no project selects its packages by operating system or
  architecture.

### Packages and jobs

- The matrix contains the `tested-with` versions of all local packages, also of
  a package that no job builds, e.g. one that is in the project only for
  `os(windows)`. Such a package can add a job or cause a misleading error. Give
  it the same `tested-with` versions as the other packages.
- A job runs the tests if one of its packages has a test suite, whatever the
  conditions of the test suite are. If all test suites have `buildable: False`
  for a GHC version, the test step fails for that version.
- The `ghc-options` stanzas apply to all local packages on all GHC versions. If
  a package is left out of the project for a GHC version and another package
  depends on it, cabal gets it from Hackage and still applies the options, e.g.
  `-Werror`.
- doctest skips a module without an error if the library has no
  `hs-source-dirs` or has `.` in it, and the package directory has no `.hs` or
  `.lhs` file for an exposed module. The module can come from another file, e.g.
  a `.hsc` file for `hsc2hs`. The same applies to each sublibrary.

### Caches

The cache keys contain the runner image from the environment variable `ImageOS`.
The runners of GitHub set this variable, but a self-hosted runner can lack it.
Then the cache keys have no image part. A cache from an earlier system of the
runner can then link against system libraries that the runner no longer has. If
you change the system of such a runner, delete the repository caches.

### Comments

The workflow contains only the comments in the copied keys and above them. The
tool drops a comment above another key, e.g. `apt`. Of the comments in `hooks`,
it keeps only the comments inside and between the steps of a hook. The comments
of `runs-on` go only to the build job. If the first key is a copied key, a
comment at the top of the file goes to the workflow with that key. Otherwise the
tool drops it.
