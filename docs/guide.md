# Guide

This guide describes how to use the tool and what the workflow does. For the
keys of the configuration file, see [Configuration](configuration.md).

- [What the workflow does](#what-the-workflow-does)
- [Command line](#command-line)
- [GHC versions](#ghc-versions)
- [Dependencies](#dependencies)
- [Source tarballs](#source-tarballs)
- [Container](#container)
- [macOS](#macos)
- [Caches](#caches)
- [Common failures](#common-failures)
- [Known limits](#known-limits)

## What the workflow does

The workflow has a build job for each GHC version. With `dependencies: both`,
each version gets two jobs, one with the newest and one with the oldest
dependencies. The extra axes of `matrix` multiply the jobs in the same way. A
build job has these steps:

1. Make sure that the runner has the operating system of the workflow. Install
   the `apt` packages, then GHCup, and with it GHC and cabal. See
   [GHC versions](#ghc-versions).
2. Unpack the source tarballs of the local packages into a separate directory.
   See [Source tarballs](#source-tarballs).
3. Write the build settings to `cabal.project.local`, e.g. the number of
   parallel jobs and the GHC options of the local packages. If the repository
   contains `cabal.project.local`, the job fails. See
   [Extra cabal.project.local text](configuration.md#extra-cabalprojectlocal-text).
4. Make the build plan, and restore the cached cabal store for that plan.
5. Build the dependencies, and save the cache if the plan is new.
6. Build the project.
7. Run the tests and, if you enable it, doctest.
8. Run `cabal check` and build the documentation.

You can add steps after step 1 and after step 6. See
[Hooks](configuration.md#hooks).

If you enable them, a fourmolu job and an HLint job check the code. They need no
GHC, so each runs once, at the same time as the build jobs.

## Command line

### Options

| Option | Default | Meaning |
|---|---|---|
| `--generate` | | Make one workflow with the options below. Without it, the tool makes all generated workflows again. If the workflow file exists and the tool did not generate it, the tool stops with an error and does not change the file. |
| `--config FILE` | `.github/haskell-gha.conf.yaml` | The configuration file. If the default file does not exist, all keys take their defaults. A file that you name with this option must exist. It must be a relative path in the repository. |
| `--project-dir DIR` | `.` | The directory that contains `cabal.project` or the package. It must be a relative path in the repository. If it has no `cabal.project`, no parent directory in the repository may have one, because cabal would use that file. |
| `--output NAME` | `haskell-gha.yaml` | The name of the workflow file in `.github/workflows`, e.g. `ci.yaml`. It must end with `.yml` or `.yaml` and must not contain a directory, because GitHub reads only such files. It must not contain a comma, because the name is a part of the cache keys. |
| `--check` | | Make sure that all generated workflows are up to date, and do not write them. If one is not up to date, exit with code 1. |
| `-v`, `--version` | | Show the version of the tool and exit. |

You can use `--config`, `--project-dir` and `--output` only with `--generate`.
You cannot use `--check` with `--generate`.

The paths of `--config` and `--project-dir` are relative to the current
directory, which must be the root of the repository. With `--generate`, the
current directory must contain `.git`.

### Keeping the workflow up to date

Each workflow file starts with a header comment that gives the command that made
the file. Without options, the tool finds each file in `.github/workflows` with
this header and generates the workflow again with the options from the header.
If no file has the header, the tool stops with an error. Each error of a
workflow starts with the name of its file.

The `--output` of the command in the header must be the name of the file itself,
so a renamed workflow file is an error. To rename a workflow file, run the
command from its header with the new name as `--output`, and delete the old
file.

To make sure that the committed workflows are up to date, run the tool in CI
with `--check`:

```
haskell-gha --check
```

With `--check`, the tool generates each workflow again and compares the result
with the committed file. It writes no file. If a file differs, the tool exits
with code 1. If a new version of the tool makes a different workflow, run it
again and commit the files.

### More than one workflow

To make a second workflow, e.g. one that tests only the lower bounds of the
dependencies, run `--generate` with its own `--config` and `--output`. Give it
its own `name` in the configuration, so that the two workflows are easy to tell
apart on GitHub. After that, `haskell-gha` without options makes both workflows
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
  newest release of the series in GHCup. Before the first release of a series,
  the job uses its newest prerelease. To build the dependencies of a
  prerelease, see [GHC prereleases](#ghc-prereleases).

A package can mix the two forms, e.g.
`tested-with: GHC == 9.6.7 || ^>= 9.10 || ^>= 9.12`. An open range, e.g.
`GHC >= 9.10`, is an error, because the list of jobs must be finite.

The jobs install GHC and cabal from the vanilla channel of GHCup, which has
only the builds of the GHC and cabal developers. If the vanilla channel has no
release of the GHC version, e.g. before the first release of a series, the job
installs GHC from the prerelease channel. The tool does not ask GHCup about the
versions, so a version that GHCup does not know fails only in CI.

The workflow matrix contains the versions of all local packages. All packages
must write a series in the same form. If one package lists `GHC ^>= 9.10` and
another lists `GHC == 9.10.3`, the tool stops with an error, because no
conditional block can separate the two.

For GHC 9.4 and older, the workflow installs the Ubuntu package `binutils-gold`.
The `hsc2hs` of these versions needs the gold linker, and Ubuntu 25.10 and later
do not install it by default.

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
  Thus if a mistake in an `impl(ghc ...)` condition excludes a package for every
  matrix entry, no job builds the package, and the tool shows no error.

The tool must know the result of each condition for each matrix entry, so these
parts of a condition are errors:

- An `impl(ghc ...)` test that includes only some versions of a matrix entry. If
  the matrix has the entry `9.10`, the test `impl(ghc >= 9.10.2)` is an error,
  because the result depends on the minor version of the job. The first release
  of a series is `X.Y.1`, so `impl(ghc >= 9.10.1)` includes all of `9.10` and is
  not an error. The tool decides each test on its own, so
  `impl(ghc >= 9.10.2) || impl(ghc < 9.10.2)` is an error, although the whole
  condition includes all of `9.10`.
- A `flag(...)` test, because the tool does not know the flag value.

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

Write the condition as `impl(ghc >= 10)`, not `impl(ghc >= 10.0.1)`. A
prerelease, e.g. `10.0.0.20260917`, comes before `10.0.1`, so cabal decides the
second condition as false for it. The tool does not find this error, because it
takes the first release `X.Y.1` as the start of each series.

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

## Container

With `container`, the build jobs run in a job container, not directly on the
runner image. The fourmolu and HLint jobs stay on the runner. A container lets
the jobs use another Ubuntu release than the runner, e.g. Ubuntu 26.04 on a
runner with Ubuntu 24.04.

The tool accepts only the Ubuntu images of `buildpack-deps`, because the
workflow needs their tools, e.g. `git`, `curl` and `xz-utils`. The images also
contain the libraries that GHC needs, e.g. `libgmp-dev`.

These points are different in a container:

- A job runs as root, and the image has no `sudo`. The workflow runs `apt-get`
  without `sudo`, and a hook step must not use it either.
- A service is reachable by its name, e.g. `postgres`, not by `localhost`. The
  service then needs no `ports` mapping.
- `git` does not work in the checkout, because the checkout belongs to another
  user. If a hook runs `git`, first run
  `git config --global --add safe.directory '*'` in the hook.
- In a `run` script, `${{ runner.temp }}` gives a path on the host, which does
  not exist in the container. Use `$RUNNER_TEMP` instead.
- The cache keys contain the container image in place of the runner image.

## macOS

A workflow tests one operating system. To also test macOS, make a second
workflow from its own configuration file, e.g.
`.github/haskell-gha-macos.conf.yaml`:

```yaml
name: CI (macOS)
os: macos
```

Give it its own `name`, so that the two workflows are easy to tell apart on
GitHub. Then make the workflow:

```
haskell-gha --generate --config .github/haskell-gha-macos.conf.yaml --output haskell-gha-macos.yaml
```

Without `runs-on`, the build jobs run on `macos-26`. The tool supports only Macs
with Apple Silicon. A macOS runner cannot run containers and has no apt, so
`container`, `services` and `apt` are an error with `os: macos`. The fourmolu
and HLint jobs do not depend on the operating system, so `fourmolu` and `hlint`
are also an error. Keep them in the Linux workflow.

If the tests need a service, e.g. a database, an `after-setup` hook can install
and start it, e.g. with `brew`. A macOS job is slower than a Linux job, so the
macOS workflow can test fewer GHC versions, e.g. 9.14 and later with
`ghc: '>= 9.14'`. With an open range, a new version in `tested-with` also joins
the macOS workflow. The Linux workflow leaves out `ghc`, so it tests all
versions of `tested-with`.

The first step after the checkout makes sure that the runner has the operating
system of the workflow. The tool cannot tell it from `runs-on`, e.g. from a
runner group. If they differ, the job stops with an error.

## Caches

Each workflow has its own caches of the cabal store. Their keys start with the
name of the workflow file, e.g. `ci.yaml`. Thus a renamed workflow file starts
new caches. The doctest cache holds only the doctest binary, so all workflows
share it.

The cache keys contain the runner image from the environment variable `ImageOS`.
The runners of GitHub set this variable, but a self-hosted runner can lack it.
Then the cache keys have no image part. A cache from an earlier system of the
runner can then link against system libraries that the runner no longer has. If
you change the system of such a runner, delete the repository caches.

When the build plan changes, a job restores the newest cabal store of its
workflow and saves it again with the new dependencies. The store also keeps the
old versions of the dependencies, so it grows with each change of the plan.
GitHub removes a cache that no run used for 7 days, so a workflow that does not
run for a week starts again with an empty store. To shrink the store of a
workflow that runs more often, delete its caches on GitHub.

## Common failures

**A job fails to install GHC.** GHCup does not know the version, e.g. an exact
version that was never released. The tool does not ask GHCup about the versions,
so such a version fails only in CI. Fix the version in `tested-with`.

**The configuration step fails, because the repository contains
`cabal.project.local`.** Move the settings of the file to `cabal.project`, or to
the key `cabal-project-local` if only CI needs them. Then remove the file from
the repository. See
[Extra cabal.project.local text](configuration.md#extra-cabalprojectlocal-text).

**The build or the tests fail in CI, but they work in a local build.** The
`.cabal` file does not list a file that the build or the tests need, e.g. a CPP
header or a test fixture. List it, e.g. in `extra-source-files` or `data-files`.
See [Source tarballs](#source-tarballs).

**An oldest job fails in a dependency.** An old version of the dependency often
has no upper bound on `base` and does not build with a new GHC. Raise the lower
bound in the `.cabal` file. See [Dependencies](#dependencies).

**A job of a GHC prerelease finds no build plan.** A dependency does not yet
allow the versions of the libraries that come with the prerelease. Put a fix in
a conditional block of `cabal.project`, and exclude the oldest job of the
prerelease. See [GHC prereleases](#ghc-prereleases).

**A hook that runs `git` fails with "detected dubious ownership".** The job runs
in a container. See [Container](#container).

## Known limits

### `cabal.project`

- The tool does not read the files of `import:` lines in `cabal.project`. cabal
  reads the imported files in CI, but the tool does not see a package that only
  an imported file lists. Such a package gets no `tested-with` check. A local
  imported file must be in the repository, because CI has only the repository.
- The tool reads all branches of the conditional blocks in `cabal.project`, also
  a branch that no job selects. cabal reads only the branch that it selects, but
  the tool applies the rules for package locations and `import:` lines to each
  branch. For example, a location in `packages:` must exist, and with
  `sdist: true` a local `import:` is an error.
- The tool decides `os(...)` and `arch(...)` conditions for the system of `os`:
  Linux on x86_64, or macOS on AArch64. A runner with another architecture, e.g.
  an ARM runner with Linux, can select other packages than the tool read.

### Packages and jobs

- The matrix contains the `tested-with` versions of all local packages, also of
  a package that no job builds, e.g. one that is in the project only for
  `os(windows)`. Such a package can add a job or cause a misleading error. Give
  it the same `tested-with` versions as the other packages.
- A job runs the tests if one of its packages has a test suite, whatever the
  conditions of the test suite are. If all test suites have `buildable: False`
  for a GHC version, the test step fails for that version.
- doctest skips a module without an error if the library has no `hs-source-dirs`
  or has `.` in it, and the package directory has no `.hs` or `.lhs` file for an
  exposed module. The module can come from another file, e.g. a `.hsc` file for
  `hsc2hs`. The same applies to each sublibrary.
- If an `include` entry cannot extend any job without a change to the value of
  an axis, GitHub adds a new job for it, e.g. for `postgres: '16'` with the axis
  `postgres: ['15', '18']`. The tool does not check such an entry. Give it a
  `ghc` value, and with `dependencies: both` a `dependencies` value. Otherwise
  the new job has no GHC version and fails.
