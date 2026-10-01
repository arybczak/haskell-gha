# haskell-gha

[![CI](https://github.com/arybczak/haskell-gha/actions/workflows/haskell-gha.yml/badge.svg?branch=master)](https://github.com/arybczak/haskell-gha/actions/workflows/haskell-gha.yml)

`haskell-gha` generates a GitHub Actions workflow for a Haskell cabal project.
The workflow builds and tests the project with every GHC version listed in the
`tested-with` field of its packages, one job per version. It installs GHC and
cabal with `haskell-actions/setup` and caches the cabal store. Only Linux is
supported.

It is an alternative to [`haskell-ci`](https://github.com/haskell-CI/haskell-ci)
for projects that only need GitHub Actions on Linux. See
[Comparison with haskell-ci](#comparison-with-haskell-ci) for the differences.

## Installation

Build the tool from source:

```
git clone https://github.com/arybczak/haskell-gha.git
cd haskell-gha
cabal install
```

## Usage

To create your first workflow, run the tool with `--generate` in the root of
your repository:

```
haskell-gha --generate
```

The tool reads the project in the current directory and writes
`.github/workflows/haskell-gha.yml`. Commit this file. For an example of the
output, see the
[workflow of this repository](.github/workflows/haskell-gha.yml).

| Option | Default | Meaning |
|---|---|---|
| `--generate` | | Generate one workflow from the options below. Without it, the tool regenerates all existing workflows. |
| `--config FILE` | `.github/haskell-gha.conf.yml` | The configuration file. If the default file does not exist, every key takes its default value. A file given with this option must exist. |
| `--project-dir DIR` | `.` | The directory with `cabal.project` or the package. It must be a relative path inside the repository. |
| `--output FILE` | `.github/workflows/haskell-gha.yml` | The workflow file to write. |
| `--check` | | Check that all generated workflows are up to date without writing them. Exits with code 1 if one is out of date. |
| `-v`, `--version` | | Print the version of the tool and exit. |

`--config`, `--project-dir` and `--output` are only allowed together with
`--generate`, and `--check` cannot be combined with `--generate`. All paths are
relative to the current directory, which must be the root of the repository.

### Keeping the workflow up to date

Whenever you change the `tested-with` field of a package, the set of packages in
the project, or the configuration, regenerate the workflows by running the tool
without options:

```
haskell-gha
```

Every generated file starts with a header comment that records the command that
created it and the version of the tool. The tool finds all files in
`.github/workflows` with this header and runs the recorded command again. If no
file has the header, the tool stops with an error.

The `--output` in the header must name the file itself, so renaming a workflow
file is an error. To rename one, run the command from its header with the new
path as `--output`, then delete the old file.

To make sure that the committed workflows stay up to date, run the tool in CI
with `--check`:

```
haskell-gha --check
```

This regenerates each workflow in memory and compares it with the committed
file. If a file differs, the tool exits with code 1. The comparison includes the
header, which contains the version of the tool, so after upgrading the tool you
need to regenerate and commit the workflows.

## What the workflow does

The workflow has one build job for each GHC version, or for each combination
with the extra [matrix axes](#matrix-services-and-permissions). Each build job
runs these steps:

1. Check out the repository, install the `apt` packages, and install GHC and
   cabal.
2. Run the `after-setup` [hooks](#hooks).
3. Unpack the [source tarballs](#source-tarballs), write
   `cabal.project.local`, and make the build plan.
4. Restore the cache, build the dependencies, and save the cache. The cache key
   comes from the build plan, so the cache changes only when the plan changes.
5. Install [doctest](#doctest) if it is enabled, and build the project.
6. Run the `after-build` hooks.
7. Run the tests, doctest, `cabal check` and haddock.

If [fourmolu](#fourmolu) or [HLint](#hlint) is enabled, it runs in its own job,
alongside the build jobs.

## GHC versions

The GHC versions come from the `tested-with` field of each package. GHC 8.10
and later are supported, and an older version in `tested-with` is an error. Each
part of the field must have one of two forms:

- An exact version with three components, e.g. `GHC == 9.10.3`. The job uses
  exactly this version. A shorter version such as `GHC == 9.10` is an error,
  because no GHC release has that number.
- A major series, e.g. `GHC ^>= 9.10` or `GHC == 9.10.*`. The job uses the
  newest release of the series that `haskell-actions/setup` knows about. Before
  the first release of a series, it uses the newest prerelease. To build the
  dependencies of a prerelease, see [GHC prereleases](#ghc-prereleases).

A package can mix both forms, e.g.
`tested-with: GHC == 9.6.7 || ^>= 9.10 || ^>= 9.12`. An open range such as
`GHC >= 9.10` is an error, because the list of jobs must be finite. The matrix
of the workflow is the union of the versions of all local packages.

All packages must write a given series in the same form. If one package lists
`GHC ^>= 9.10` and another lists `GHC == 9.10.3`, the tool stops with an error,
because no conditional block can tell the two apart.

### Conditional blocks in `cabal.project`

If the packages of a project support different GHC versions, put each package in
a conditional block in `cabal.project`:

```
packages: core

if impl(ghc >= 9.10)
  packages: new
```

The tool evaluates these blocks the same way cabal does, and checks them against
`tested-with` in both directions:

- If a package is in the project for a GHC version that its `tested-with` does
  not list, the tool reports an error and shows the block to add.
- If a package lists a GHC version in `tested-with` but the project does not
  include it for that version, no job would test it, so this is an error too.
  The rule does not apply to a package that no job builds, e.g. one that is in
  the project only for `os(windows)`.

A condition must include either all versions of a matrix entry or none of them.
With the entry `9.10`, the condition `impl(ghc >= 9.10.2)` is an error, because
its result depends on the minor version that the job happens to get. The first
release of a series is `X.Y.1`, so `impl(ghc >= 9.10.1)` covers all of `9.10`
and is fine. A `flag(...)` condition is also an error, because the tool does
not know the value of the flag. None of these errors apply to a part of a
condition that cannot change its result, e.g. `flag(dev)` in
`os(linux) || flag(dev)`.

### GHC prereleases

Dependencies often do not build yet with a GHC prerelease. Put the fix in a
conditional block of `cabal.project`, so that it applies only to that GHC
version and also works for local builds.

head.hackage is a package repository with patched versions of many packages
for GHC prereleases. For example, this block allows newer versions of three
libraries that come with GHC 10, and adds head.hackage with the stanza from its
README:

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

Only allow newer versions of the libraries that the build plan needs. If cabal
rejects a dependency because of its bounds on such a library, add the library to
the list. If only one dependency needs a patch, you can instead take it from a
fork with a `source-repository-package` in the block.

The `allow-newer` also applies to the [oldest jobs](#dependencies). Combined
with `prefer-oldest`, it makes cabal try very old releases, and it often finds
no build plan. With `dependencies: both`, exclude the oldest job of the
prerelease:

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

The configuration lives in `.github/haskell-gha.conf.yml`. Every key is
optional. A typical configuration only sets a few of them:

```yaml
apt: [libpq-dev]
dependencies: both
doctest:
  enabled: true
hlint:
  enabled: true
```

Some general rules:

- An unknown key is an error, and the tool reports all errors in the file at
  once.
- YAML reads a key without a value as `null`. That is an error for most keys,
  but for `container` and `services` it means none.
- If YAML would read a text value as a number, a boolean or a null, quote it,
  e.g. `version: '3.10'`. Without the quotes, YAML reads `3.10` as the number
  3.1.

### All keys

This example sets every key:

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

| Key | Default | Meaning |
|---|---|---|
| `name` | `CI` | The name of the workflow. Two workflows in one repository need different names, because workflows with the same name cancel each other. |
| `cabal-version` | `3.16.1.0` | The cabal version, or `latest`. It must be 3.12 or later. See [Why these defaults](#why-these-defaults). |
| `runs-on` | `ubuntu-26.04` | The runner of the build jobs, as GitHub Actions YAML: a label such as `ubuntu-latest`, a list of labels such as `[self-hosted, linux]`, or a mapping with `group` and `labels`. It is copied to the workflow as is. |
| `container` | none | The image of a job container for the build jobs: `buildpack-deps:22.04`, `buildpack-deps:24.04` or `buildpack-deps:26.04`. See [Container](#container). |
| `timeout-minutes` | `60` | The time limit of each job, in minutes. |
| `branches` | `[master, main]` | The branches that trigger the workflow on `push`. |
| `submodules` | `false` | Whether the build jobs fetch Git submodules: `true`, `false` or `recursive`. `recursive` also fetches nested submodules. The fourmolu and HLint jobs never fetch them. |
| `matrix` | none | Extra matrix axes, plus `include` and `exclude`. See [Matrix, services and permissions](#matrix-services-and-permissions). |
| `apt` | `[]` | Ubuntu packages to install. |
| `services` | none | Service containers, as in GitHub Actions. |
| `permissions` | `contents: read` | The permissions of the `GITHUB_TOKEN`, as in GitHub Actions: a mapping, `read-all` or `write-all`. |
| `hooks.after-setup` | `[]` | Steps that run after GHC and cabal are installed. See [Hooks](#hooks). |
| `hooks.after-build` | `[]` | Steps that run after the build and before the tests. |
| `ghc-options` | `-Werror -Wwarn=unrecognised-warning-flags -Wwarn=semaphore-open-failure` | GHC options for the local packages only, on one line. An empty string disables them. See [Why these defaults](#why-these-defaults). |
| `cabal-project-local` | none | Text to append to `cabal.project.local`, e.g. package flags or constraints. See [`cabal.project.local`](#cabalprojectlocal). |
| `jobs` | `4` | The number of parallel build jobs. |
| `tests` | `true` | Build and run the test suites. |
| `benchmarks` | `true` | Build the benchmarks. The workflow does not run them. |
| `dependencies` | `newest` | Which versions of the dependencies to use: `newest`, `oldest` or `both`. See [Dependencies](#dependencies). |
| `doctest` | none | Run doctest. See [Doctest](#doctest). |
| `check` | `true` | Run `cabal check` for each local package. Warnings do not fail the job. |
| `sdist` | `true` | Build and test the contents of the source tarballs instead of the checkout. See [Source tarballs](#source-tarballs). |
| `haddock` | `true` | Build the documentation of the libraries the same way as for a Hackage upload. |
| `fourmolu` | none | Check the formatting with fourmolu. See [Fourmolu](#fourmolu). |
| `hlint` | none | Check the code with HLint. See [HLint](#hlint). |
| `actions.checkout` | `v7` | The version of `actions/checkout`. |
| `actions.setup` | `v2` | The version of `haskell-actions/setup`. |
| `actions.cache` | `v6` | The version of `actions/cache/restore` and `actions/cache/save`. |
| `actions.run-fourmolu` | `v13` | The version of `haskell-actions/run-fourmolu`. |
| `actions.hlint-setup` | a commit, see [HLint](#hlint) | The version of `haskell-actions/hlint-setup`. |
| `actions.hlint-run` | a commit, see [HLint](#hlint) | The version of `haskell-actions/hlint-run`. |

### Action versions

A version in `actions` is any Git ref of the action, e.g. a tag such as `v8` or
a commit SHA. This lets you use a new major version of an action without waiting
for a new release of `haskell-gha`, or pin an action to a commit.

To use a different repository with the same inputs, e.g. a fork, put the
repository in front of the ref, e.g. `cache: runs-on/cache@v4`. For
`actions.cache`, the tool appends `/restore` and `/save` to the repository.

### Matrix, services and permissions

The tool copies `matrix`, `services`, `permissions` and the hook steps to the
workflow as they are, so you can use GitHub expressions in them, e.g.
`${{ matrix.postgres }}`.

The extra `matrix` axes appear next to the `ghc` axis, which the tool generates
itself. These rules apply:

- `matrix` must not contain the key `ghc`. With `dependencies: both`, the same
  goes for the key `dependencies`.
- The job name refers to each axis in an expression, so an axis name must start
  with a letter or `_` and contain only letters, digits, `_` and `-`.
- A `ghc` value in `include` or `exclude` must be a quoted string, e.g.
  `'9.10'`, and must be an entry of the `ghc` axis.
- Each key of an `exclude` entry must be `ghc`, one of your axes, or
  `dependencies` with `dependencies: both`.

If a service has a health check, the runner starts the steps only when the
service is healthy, so the workflow needs no step that waits for it. The
`postgres` image has no health check of its own, which is why the example
defines one in `options`.

The copied keys keep their comments, as well as the comments directly above
them. Other comments are dropped:

- A comment above a key that is not copied, e.g. `apt`, is dropped.
- In `hooks`, only the comments inside and between the steps of a hook are kept.
- The comments of `runs-on` only go to the build job.
- A comment at the top of the file goes to the workflow only if the first key is
  a copied key.

### Hooks

Hooks are extra steps in the build jobs. See
[What the workflow does](#what-the-workflow-does) for where they run.

- `after-setup` steps run after GHC and cabal are installed, and before the
  source tarballs are unpacked and the build plan is made. Use them, e.g., to
  install a library that the dependencies need and that `apt` does not have.
- `after-build` steps run after the build and before the tests.

A `run` step of a hook starts in the project directory of the checkout. A `uses`
step starts in the root of the repository, because GitHub applies the run
defaults only to `run` steps. A `working-directory` of a hook step is relative
to the root of the repository.

The unpacked source tarballs are in `${{ runner.temp }}/haskell-gha`. The
`after-build` hooks can use them, but they do not exist yet when the
`after-setup` hooks run.

### `cabal.project.local`

The workflow writes the text of `cabal-project-local` to `cabal.project.local`
before it makes the build plan, so the cache of each job contains any
dependencies that the text adds. The text comes after the `ghc-options` stanzas,
so it can add more options. You can use GitHub expressions in it. A line of the
text must not be `EOF`.

### Why these defaults

The default `cabal-version` is not `latest`, because `latest` currently selects
cabal 3.18.1.0, which has a bug in the GHC job semaphore. See
[cabal issue 12306](https://github.com/haskell/cabal/issues/12306).

The default `ghc-options` keep one warning a warning under `-Werror`. GHC and
cabal can use different versions of the job semaphore protocol. GHC then warns
that it cannot use the semaphore and compiles modules one at a time. Older GHC
versions do not know this warning, so the options also keep the warning about an
unknown warning flag a warning. If you set your own `ghc-options`, include both
`-Wwarn` options.

## Features

### Container

With `container`, the build jobs run in a job container instead of directly on
the runner image. This lets them use a different Ubuntu release than the runner,
e.g. Ubuntu 26.04 on a runner with Ubuntu 24.04. The fourmolu and HLint jobs
still run on the runner.

Only the Ubuntu images of `buildpack-deps` are accepted, because the workflow
needs their tools, e.g. `git`, `curl` and `xz-utils`. The images also contain
the libraries that GHC needs, e.g. `libgmp-dev`.

A job in a container runs as root, and the image has no `sudo`. The workflow
therefore runs `apt-get` without `sudo`, and your hook steps must not use it
either. The container lacks the tools of the runner image, so
`haskell-actions/setup` installs GHC and cabal in every job, which makes each
job take a few minutes longer.

Some other things are different in a container:

- A service is reachable by its name, e.g. `postgres`, not by `localhost`, so it
  needs no `ports` mapping.
- `git` does not work in the checkout, because the checkout belongs to another
  user. If a hook runs `git`, first run
  `git config --global --add safe.directory '*'` in the hook.
- The cache keys contain the container image instead of the runner image.

### Dependencies

By default, cabal picks the newest versions of the dependencies that the bounds
allow, so CI never tests the lower bounds. If a lower bound is too low, the
build fails for a user who has an older version of that dependency.

With `dependencies: oldest`, each job adds `prefer-oldest: True` to
`cabal.project.local`, and cabal picks the oldest versions that the bounds
allow. This includes the libraries that come with GHC, e.g. `text`, so cabal
may build an older version of such a library from Hackage.

With `dependencies: both`, the matrix gets a `dependencies` axis with the values
`newest` and `oldest`. Each GHC version gets one job for each value, and the job
name shows which one it is. The two kinds of jobs have separate caches, but
otherwise run the same steps. To remove an oldest job, use `exclude`:

```yaml
dependencies: both
matrix:
  exclude:
    - ghc: '9.6'
      dependencies: oldest
```

When an oldest job fails, the cause is often a dependency. For example, an old
version of a dependency may have no upper bound on `base` and fail to build with
a new GHC. In that case, raise the lower bound in your `.cabal` file.

`dependencies: oldest` is also useful for a second workflow that only tests the
lower bounds. Generate it with `--generate`, `--config` and `--output`, and give
it its own `name`. You can then make the main workflow a required check on
GitHub and the second one optional.

### Source tarballs

A user who installs a package from Hackage gets only the files in its source
tarball. If the build or the tests need a file that the `.cabal` file does not
list, e.g. a CPP header or a test fixture, the package fails for that user. A
build of the checkout does not catch this, because the checkout has the file.

The workflow therefore creates the tarballs with `cabal sdist all` and unpacks
them into a separate directory, together with copies of `cabal.project`,
`cabal.project.freeze` and `cabal.project.local`. The build, the tests, doctest,
`cabal check` and haddock all run in that directory. The hooks still run in the
project directory of the checkout.

Set `sdist: false` if any of these is true:

- `cabal.project` imports a local file with `import:`.
- `cabal.project` lists a package outside the project directory, e.g.
  `../other`.
- An `after-setup` hook creates a file that the build or the tests need, and the
  `.cabal` file does not list it.
- An `after-build` hook creates a file in the checkout that the tests need.

The tool detects the first two cases and stops with an error. It cannot detect
the hook cases.

### Doctest

If `doctest.enabled` is `true`, the workflow installs doctest and runs it on the
library and sublibraries of each local package. The doctest binary has its own
cache, so each doctest version is built only once per GHC version.

| Key | Default | Meaning |
|---|---|---|
| `doctest.enabled` | `false` | Run doctest. The other `doctest` keys have no effect without it. |
| `doctest.ghc` | all versions | The GHC versions to run doctest with. The range must include at least one matrix entry. A new GHC release often works with doctest only after a few weeks. |
| `doctest.version` | any version | The allowed versions of the doctest package. |
| `doctest.skip` | `[]` | Packages to skip. |
| `doctest.options` | `[]` | Extra arguments for doctest. |

### Fourmolu

If `fourmolu.enabled` is `true`, the workflow gets a separate job that checks
the formatting of the Haskell files with `haskell-actions/run-fourmolu`. The
job needs no GHC, so it runs once, alongside the build jobs. fourmolu reads the
`fourmolu.yaml` of the project.

| Key | Default | Meaning |
|---|---|---|
| `fourmolu.enabled` | `false` | Add the fourmolu job. The other `fourmolu` keys have no effect without it. |
| `fourmolu.version` | `0.20.1.0` | The fourmolu version. |
| `fourmolu.pattern` | all `.hs` and `.hs-boot` files | The files to check, as glob patterns. A pattern that starts with `!` excludes files. Each pattern must be a single line without leading or trailing spaces. |
| `fourmolu.runs-on` | the value of `runs-on` | The runner of the fourmolu job, e.g. a smaller self-hosted runner than the build jobs need. |

Set `fourmolu.version` to the version that the developers of the project use,
because a new fourmolu version can format the same code differently. fourmolu
0.20.0.0 and later need `run-fourmolu` v13 or later.

### HLint

If `hlint.enabled` is `true`, the workflow gets a job that installs HLint with
`haskell-actions/hlint-setup` and runs it with `haskell-actions/hlint-run`.
Like the fourmolu job, it runs once, alongside the build jobs. The hints show up
as annotations in the pull request.

| Key | Default | Meaning |
|---|---|---|
| `hlint.enabled` | `false` | Add the HLint job. The other `hlint` keys have no effect without it. |
| `hlint.version` | `3.10` | The HLint version. |
| `hlint.fail-on` | `suggestion` | The lowest hint level that fails the job: `never`, `status`, `warning`, `suggestion` or `error`. |
| `hlint.path` | the project directory | The directories or files to check, relative to the project directory. Each path must be inside the repository and must not contain a tab or another control character. |
| `hlint.runs-on` | the value of `runs-on` | The runner of the HLint job, as for `fourmolu.runs-on`. |

By default, every hint fails the job. To turn off a hint that the project does
not want, add an `ignore` entry to `.hlint.yaml`, e.g.
`- ignore: {name: Use camelCase}`.

HLint reads `.hlint.yaml` from the root of the repository, because the action
runs there. With `--project-dir`, put `.hlint.yaml` in the root of the
repository, not in the project directory.

The released versions of both actions still need Node.js 20, which GitHub
removes in autumn 2026. The defaults are therefore the commits that moved the
actions to Node.js 24. These commits run the same code as release `v2.4.10`.
When a new release comes out, set `actions.hlint-setup` and `actions.hlint-run`
to it.

## Comparison with haskell-ci

Compared with `haskell-ci`, `haskell-gha` differs in these ways:

- The jobs install GHC and cabal with `haskell-actions/setup` instead of a
  manual GHCup installation. They run on the runner image, or optionally in a job
  container. `haskell-ci` always runs the jobs in a container.
- A new GHC release does not need a new release of the tool. `haskell-ci` only
  accepts the GHC versions from its built-in list. `haskell-gha` passes the
  version to `haskell-actions/setup`, and a series such as `^>= 9.12` gets the
  newest release of that series.
- The workflow uses the `cabal.project` of your project, including its
  conditional blocks, and the tool checks these blocks against `tested-with`.
  `haskell-ci` writes its own `cabal.project` for each job.
- Service containers, hook steps and extra matrix axes are plain GitHub Actions
  YAML that the tool copies into the workflow. `haskell-ci` only supports a
  PostgreSQL service, and other changes need patch files for the generated
  workflow.
- The cache of a job changes only when its build plan changes. `haskell-ci`
  saves a new cache for each commit.
- With `dependencies: both`, separate jobs test the oldest versions that the
  bounds allow, with the same steps as the other jobs. In `haskell-ci`, a
  constraint set with `prefer-oldest` runs at the end of the same job, without
  `cabal.project.local` and, by default, without the tests.
- The workflow can check the formatting with fourmolu and the code with HLint,
  each in its own job. `haskell-ci` has no such jobs.

## Known limits

Reading `cabal.project`:

- The tool does not read the files of `import:` lines in `cabal.project`. cabal
  reads them in CI, but the tool does not see a package that only an imported
  file lists, so that package gets no `ghc-options` and no `tested-with` check.
  A local imported file must be in the repository, because CI has only the
  repository.
- The tool reads all branches of the conditional blocks in `cabal.project`,
  including branches that no job selects, while cabal reads only the branch it
  selects. The rules for package locations and `import:` lines therefore apply
  to every branch. E.g. a location in `packages:` must exist, and with
  `sdist: true` a local `import:` is an error.
- The tool evaluates `os(...)` and `arch(...)` conditions for Linux on x86_64.
  It assumes that no project selects its packages by operating system or
  architecture.
- If the project directory has no `cabal.project`, the tool treats the packages
  in the directory as the project. But if a parent directory has a
  `cabal.project`, cabal uses that file instead. With `sdist: false`, the
  workflow then builds the parent project, although the tool only read the
  packages of the project directory. Pass the directory of the parent
  `cabal.project` to `--project-dir`.

Packages and components:

- The matrix contains the `tested-with` versions of all local packages, even of
  a package that no job builds, e.g. one that is in the project only for
  `os(windows)`. Such a package can add a job or cause a misleading error. Give
  it the same `tested-with` versions as the other packages.
- The `ghc-options` stanzas apply to all local packages on all GHC versions.
  Suppose a package is not in the project for some GHC version, but another
  package depends on it. cabal then gets it from Hackage and still applies the
  options, e.g. `-Werror`.
- A test suite counts whatever its conditions are. If all test suites of a
  project have `buildable: False` for a GHC version, the test step fails for
  that version.
- doctest silently skips a module in one case: the library has no
  `hs-source-dirs` or has `.` in it, and the package directory has no `.hs` or
  `.lhs` file for an exposed module. The module can come from another file,
  e.g. a `.hsc` file for `hsc2hs`. The same applies to each sublibrary.

Runners:

- The cache keys contain the runner image from the environment variable
  `ImageOS`. GitHub's runners set this variable, but a self-hosted runner may
  not. The cache keys then have no image part, and a cache from an earlier
  system of the runner can link against system libraries that the runner no
  longer has. If you change the system of such a runner, delete the caches of
  the repository.
