# haskell-gha design

This document gives the reasons for the behavior of haskell-gha. The
[README](README.md) describes the behavior for users. Before you change a
rule, read its reason here.

haskell-gha replaces haskell-ci for projects that use only GitHub Actions.
haskell-ci supports many backends, setup methods and old GHC versions, and
its workflow for the `all-versions` fixture has 515 lines. haskell-gha has a
small scope, modern defaults and a short workflow. The model for the output
is the hand-written workflow of ghc-tags, which has about 50 lines.

## Facts about other tools

The facts below come from the source code of each tool.

`haskell-actions/setup` resolves a GHC or cabal version with its bundled
`versions.json` (the `resolve` function in `src/opts.ts`). `latest` becomes
the first entry of the list. A short form such as `9.10` becomes the newest
entry that starts with `9.10.`. Any other version goes to GHCup unchanged,
also a full version that the list does not contain. Thus a new GHC release
works with its full version without a new release of the action or of
haskell-gha.

A short form gives the newest version that the action knows. This version
can be older than the newest version in GHCup. If the list has no entry for
a short form, e.g. a new major series, the action gives the short form to
GHCup unchanged. If GHCup then fails, the user must write the exact version
until a release of the action lists the series.

The action pins the GHCup version in `versions.json`. The workflow refers to
the moving tag `v2`, so a new action release also gives a new GHCup. The
input `cabal-update` is true by default, so the action runs `cabal update`.
The workflow needs this, because its first `cabal build` needs the package
index.

The action calls `sudo apt-get` only for GHC older than 8.3 and for GHC head.
Both are out of scope. A job container has no `sudo`, and this is one reason
why the jobs run on the runner image.

cabal decides `if impl(ghc ...)` blocks in `cabal.project` with the
configured compiler, before it reads the local packages
(`rebuildProjectConfig` in
`cabal-install/src/Distribution/Client/ProjectPlanning.hs`). Thus a
`packages:` line in such a block works in CI, because the action selects the
GHC version.

## Decisions

The tool uses `Cabal-syntax` and `Cabal`, not the `cabal-install` library.
The `cabal-install` library needs one exact major version of `Cabal`, and
its internal API changes in each major release. `Cabal-syntax` and `Cabal`
allow wide bounds.

The configuration is YAML. The services and the hook steps are GitHub
Actions YAML, so users can copy them from the documentation of any action.
The tool copies `services`, `permissions`, `hooks` and the extra matrix
entries without changes. It does not model each service or each install
method.

The tool does not rewrite `cabal.project`. If packages support different GHC
versions, the user adds `if impl(ghc ...)` blocks to `cabal.project`. The
tool finds a missing block and gives the exact block in the error message.
Thus local builds and CI use the same project.

The jobs run on the runner image, not in a job container. Service
containers are supported.

The tool supports only Linux. Three rules keep macOS support easy to add
later:

- The workflow sets `defaults.run.shell: bash`.
- The cache key contains `runner.os`.
- The paths of GHC, cabal and the cabal store come from the outputs of
  `haskell-actions/setup`. The other paths are in `$HOME` or
  `$RUNNER_TEMP`, which macOS runners also have.

These parts of the tool work only on Linux:

- The build plan step uses `sha256sum`. macOS has `shasum -a 256` instead.
- The `apt` step uses `apt-get`.
- The project reader decides `os(...)` and `arch(...)` for Linux on x86_64.
  The `macos-latest` runner is macOS on AArch64.
- Service containers need a Linux runner.

The default `runs-on` is `ubuntu-26.04`, not `ubuntu-latest`. GitHub moves
`ubuntu-latest` to a new Ubuntu release over some weeks. During that time,
the jobs of one workflow run on different images. The tool pins the
versions of the actions by default, and it pins the image for the same
reason. Thus the workflow only changes with a new release of the tool or a
change of the configuration.

The cache key contains the image of the runner, from the environment
variable `ImageOS`, e.g. `ubuntu26`. A cabal store from another image can
link against system libraries that the new image does not have. The key
does not contain `ImageVersion`, because GitHub updates the image each week,
and each update would start a new cache.

The default `cabal-version` is `3.16.1.0`. For `latest`, the action now
selects cabal `3.18.1.0`, and that version has a bug in the GHC job
semaphore: [cabal issue 12306][issue-12306]. If a cabal release fixes the
issue, change the default to `latest`. Then a new cabal release needs no new
release of haskell-gha.

[issue-12306]: https://github.com/haskell/cabal/issues/12306

A `cabal-version` older than 3.12 is always an error. The `semaphore` field
needs cabal 3.12, but only the jobs for GHC 9.8 and later use it. One limit
for all jobs is simpler than a limit for each GHC version. Also, nobody
tests older cabal versions with the tool. The tool compares only the first
two parts of the version, so `3.10` and `3.10.3.0` are both errors.

The versions of the actions are fields of the configuration, with the
current major versions as defaults. Thus a user can take a new major version
of an action without a new release of haskell-gha. `actions.cache` is one
field for `actions/cache/restore` and `actions/cache/save`, because both come
from one repository. A value is any Git ref without spaces, so a user can
also pin an action to a commit SHA.

A value can also name another repository, e.g. `runs-on/cache@v4`. The
runners of RunsOn keep their cache in S3 with `runs-on/cache`, a fork of
`actions/cache` with the same inputs and outputs. The repository must have
the form `owner/name`, and the tool adds the path of a sub-action, e.g.
`/restore`, to it.

## Command line

The tool has no subcommands and no check mode. Each run writes the workflow
file. To make sure that a committed workflow is up to date, run the tool and
then `git diff --exit-code`.

The header comment of the workflow gives the command that made the file. If
the user gave `--config`, the command contains it, also with the default
path. The command also contains each other option that is not a default.

The tool works in a sequence of phases. It reads the configuration. Then it
parses `cabal.project`, finds the packages, reads the `.cabal` files and
checks each package against each matrix entry. Last, it checks the
configuration against the project, e.g. `doctest.skip`. In each phase, the
tool collects all errors and prints them all. If a phase has errors, the
tool does not start the next phase, because the next phase needs its result.

## Configuration

An unknown field is an error, because it is usually a typing error.

A text field must hold a YAML string. The parser gives the raw text of each
scalar, so an unquoted `3.10` reaches the reader as the text `3.10`. But the
workflow must quote such a value, and another YAML reader gets the number
3.1. Thus an unquoted value that the YAML 1.2 core schema reads as a number,
a boolean or a null is an error.

GitHub uses the workflow name in the concurrency group. If two workflows in
one repository have the same name, a push starts both in one group, and one
run cancels the other.

The `matrix` field must not contain the key `ghc`, because the tool makes
that axis. A `ghc` value in `include` or `exclude` must be a quoted string
and an entry of the `ghc` axis. Thus an `include` entry cannot add a job for
a new GHC version, because the tool cannot check the packages for such a
job.

Each key of an `exclude` entry must be `ghc` or an axis of the `matrix`
field, because GitHub rejects the workflow otherwise. An `include` entry can
have any key, because GitHub adds a new key to the jobs as a variable.

The name of an axis must start with a letter or `_`, and contain only
letters, digits, `_` and `-`. The job name refers to each axis as
`matrix.<name>`, and GitHub accepts this syntax only for such a name. The
index syntax, e.g. `matrix['os x']`, accepts any name. But the hooks and the
services of the user then also need the index syntax. A user can rename the
axis easily, so the tool rejects such a name.

If a workflow has no `permissions` field, the `GITHUB_TOKEN` gets the
default permissions of the repository. In many older repositories and
organizations, these permissions include write access. The jobs only read
the code, so the default is `contents: read`.

## Reading the project

The reader parses `cabal.project` with `readFields` from
`Distribution.Fields`. It uses the fields `packages:`, `optional-packages:`
and `import:`, and the `if`, `elif` and `else` sections. It ignores all
other fields, because cabal reads them in CI. If `cabal.project` does not
exist, the project is `packages: ./*.cabal`, as in cabal
(`defaultImplicitProjectConfig` in
`cabal-install/src/Distribution/Client/ProjectConfig.hs`).

The reader parses each condition with `parseConditionConfVar` and decides it
for each matrix entry. `os(linux)` and `arch(x86_64)` are true. `flag(...)`
is an error, because the tool does not know the value of the flag. If one
side of `||` is true or one side of `&&` is false, cabal ignores the other
side. Thus an error in the other side does not count.

The glob syntax of `packages:` is the cabal syntax. The reader parses it with
the `Parsec` instance of `RootedGlob` and matches it with `matchGlob` from
`Cabal`. A relative glob needs no root, so the tool does not copy
`matchFileGlob` from `cabal-install`.

An absolute path, a URL or a tarball in `packages:` is an error. The
workflow uses the path on the runner, where only the repository exists.

### GHC versions

The reader splits the `tested-with` range of each package into intervals
with `asVersionIntervals`. Each interval must be an exact version or a major
series, because the matrix needs a finite list. An exact version must have
three parts. For `== 9.10`, the action selects the newest release of the
series, but the tool would decide the conditions for 9.10.0.

A GHC version older than 8.10 is an error. The bindists of old versions link
against system libraries that new Ubuntu releases can lack, and nobody
tests them on the current runner images. A hard limit gives a clear error
before CI runs. cabal has a similar limit, see [Decisions](#decisions).

A matrix entry has a version range. A series entry `X.Y` has the range
`>= X.Y.1 && < X.(Y+1)`, because the first release of a GHC series is
`X.Y.1`. The tool uses this range for every decision about a matrix entry,
i.e. the conditions of `cabal.project`, the `doctest.ghc` range, the 9.8
limit of the semaphore and the `tested-with` range of each package.

If a range includes all of the entry, it is true for the entry. If it
includes none of it, it is false. If it includes only a part of it, the
tool stops with an error. The result then depends on the minor version that
the action selects.

Thus `^>= 9.10` in one package and `== 9.10.3` in another package give two
entries, `9.10` and `9.10.3`. The second package supports only a part of the
entry `9.10`. No conditional block can help, because each exact entry is a
part of the series entry. The error thus tells the user to write the series
in the same form in all packages.

If a package in the project supports none of an entry, the error shows the
block to add. The condition of the block is the `tested-with` range of the
package. The `packages:` line gives the directory of the package, because
the original entry can be a glob that also matches other packages.

## The generated workflow

The expected output of the golden test
[`single`](tests/golden/single/expected.yml) shows the workflow for one
package with the default configuration. The reasons for its parts follow.

The fourmolu and HLint jobs come before the build job in the file. The build
job has more than 100 lines, so a short job after it is easy to miss. No job
needs another, so all jobs start at the same time in any order.

The `merge_group` trigger runs the workflow for a merge queue. Without it, a
merge queue waits for the required checks of this workflow, and they never
start. The trigger does nothing in a repository without a merge queue.

A push to a branch of the `push` trigger cancels the older run of the same
branch. The newer run tests the newer code, and it saves the cache that the
older run did not save.

Without `timeout-minutes`, GitHub stops a job only after six hours, so a
test that hangs uses up the runner minutes. The default of 60 minutes leaves
room for a build without a cache.

The job `name` cannot show the version that the action selects for a series
entry, because GitHub evaluates the job name before the steps run. Thus the
step `Show the versions` prints the versions in the log and in the job
summary. The cache key uses the selected version, from the `ghc-version`
output of the action. Thus a new minor release starts a new cache.

An expression cannot read an environment variable of the runner. Thus the
step `Show the versions` writes `ImageOS` to its output `image`, and the
cache key reads it from there.

GHC 9.4 and older prefer the gold linker. If the runner has no gold, GHC
uses the standard linker after its installation. But the `hsc2hs` wrapper of
these versions still passes `-fuse-ld=gold` to gcc, so each package that
uses `hsc2hs` fails to build. Ubuntu 25.10 and later have gold only in the
package `binutils-gold`, which the runner image does not install. Thus the
workflow installs it for these GHC versions only.

For GHC 9.6 and later, the package would cost an `apt-get update` in each
job. These versions can also pick gold as their linker, and gold is
deprecated.

The default of `jobs` is 4, because the standard Linux runners of GitHub have
4 CPUs. The configuration step writes `jobs: <N>`, so cabal builds up to N
packages at the same time. GHC 9.8 and later support the GHC job semaphore,
which makes cabal and all GHC processes share one job count. For older GHC
versions, each local package gets `ghc-options: -j<N>`. The dependencies do
not get it, because cabal already builds N of them at the same time.

If a step applies only to some matrix entries, it gets an `if:` condition
that lists them. The packages of the project can differ between GHC
versions. Then the tool makes a step that lists the packages once for each
group of versions with the same packages.

The configuration step writes all its configuration to
`cabal.project.local`, so a developer can run the same `cabal` commands
locally. The default `ghc-options` is `-Werror`, and it applies only to the
local packages, so the warnings of a dependency do not fail the build. cabal
merges two `package` stanzas for the same package, so the `-j<N>` stanza can
come after it.

The text of `cabal-project-local` comes last, so it can add to the stanzas of
the tool. The step comes before the build plan, so the cache key includes
the dependencies that the text adds. The heredocs use `<<'EOF'`, so bash
does not expand text from the configuration. A line `EOF` ends the heredoc,
so such a line is an error.

If a user value on a command line needs quotes, the tool puts it in single
quotes, e.g. an `apt` package or an entry of `doctest.options`. GitHub
replaces `${{ }}` expressions before bash runs, so an expression in such a
value still works.

The build plan step writes the SHA-256 hash of `plan.json` to its output,
and the cache key reads it. `hashFiles` cannot read the plan, because it
reads only files in the workspace, and the copy of the tarballs is outside
it. The workflow saves the cache after it builds the dependencies. Thus an
error in a local package does not prevent the save.

The fourmolu and HLint jobs do not fetch the Git submodules, because the
files of a submodule are not the code of the project, e.g. a vendored C
library.

The `after-setup` hooks come after the installation of GHC and cabal, and
before the source tarballs and the build plan. Thus a hook can install a
library that the build plan needs, and a file that a hook makes can be in a
tarball. The `after-build` hooks come after the build, so a hook can run an
executable of the project. Other hook points, e.g. after the tests, have no
known use. They can come later without a breaking change.

A service needs no step that waits for it. If a service has a health check,
the runner waits for a healthy service before it starts the steps.

`cabal test all` fails for a project without test suites. Thus the test step
runs only for the GHC versions with a local package that has a test suite.

The last steps check the packages for a Hackage release, so a build error or
a test error shows first. `cabal haddock` gets `--disable-documentation`,
because otherwise cabal builds the dependencies again with documentation,
outside the cache. `--haddock-for-hackage` makes the same documentation as a
Hackage upload.

The output of `cabal check` does not name the package, so the check step
prints the name before each check. A failed check does not stop the step.
Thus one run shows the problems of all packages, and an error annotation
names each package that failed.

### The source tarballs

A Hackage user gets only the files of the source tarball. The build or the
tests can use a file that the `.cabal` file does not list, e.g. a header for
CPP or a test fixture. cabal gives no warning for such a file, and
`cabal check` and `cabal sdist` succeed. Only a build from the content of the
tarball fails. Thus, by default, the workflow builds the content of the
tarballs and not the checkout.

The unpack step unpacks each tarball in `$RUNNER_TEMP/haskell-gha`, at the
relative path of the package in the project directory. It copies
`cabal.project`, `cabal.project.freeze` and `cabal.project.local` there too.
Thus the copy of `cabal.project` finds the packages at the same paths, and
the tool does not rewrite it.

The hooks run in the checkout, not in the copy. Thus a hook can use files of
the repository, e.g. a script, and it can compare the checkout with
`git diff`. An earlier design replaced the files of each package directory
in the checkout with the content of its tarball. That design failed for a
package in the root of the repository and for a hook that uses `git diff`.

The unpack step does not copy a local file of an `import:` line. It also
keeps the relative path of a package outside the project directory, e.g.
`../other`, and such a package then lands outside the copy. The tool finds
both cases and asks for `sdist: false`. A path such as `a/../b` stays inside
the project directory, so it is legal.

### Doctest

The doctest README recommends `cabal repl --with-compiler=doctest`. A test
with doctest 0.25.0 and GHC 9.10.3 showed two failures of that method:

- If a package depends on another local package, cabal builds the dependency
  with doctest as the compiler, and that build fails.
- cabal 3.18.1.0 gives the option `--interactive` to the compiler, and
  doctest rejects it.

Thus the workflow uses the method of haskell-ci, which works in both cases.
cabal writes GHC environment files, which tell doctest where the
dependencies are. The workflow installs doctest with the GHC of the job,
because doctest uses the GHC API. Then it runs doctest with the source
directories, the language and the extensions of each library.

The key of the main cache depends only on the build plan of the project. If
doctest were in the main store, each job would build a new doctest release
again until the plan changes. Thus doctest has its own cache, with only the
binary, and a job builds each doctest version once for each GHC version.

The step `Find the doctest version` gets the version from a dry run of
`cabal install`. The dry run uses an empty store, because a plan for a store
that already contains doctest does not list doctest. The doctest cache has
separate restore and save steps, because the combined `actions/cache` saves
only at the end of a successful job. The workflow runs doctest by its full
path, because a cache hit skips the install step.

A library can have no `hs-source-dirs`, or only `.`. The tool then does not
give `.` to doctest, because the package directory can contain other
components, e.g. the tests. haskell-ci gives the names of the exposed
modules. But then GHC takes the compiled module from the environment file,
and doctest finds no examples without an error. Thus the tool gives the
files of the exposed modules, e.g. `A/B.hs`.

### Fourmolu

The formatting does not depend on the GHC version, so the fourmolu job has no
matrix and needs no GHC. It runs at the same time as the build jobs.

The default version is a fixed version, not `latest`. With `latest`, a new
fourmolu release can fail CI without a change in the repository. A new
release can also change the format of the release files. fourmolu 0.20.0.0
changed the binary to a zip file, and only `run-fourmolu` v13 and later can
read it. Thus the defaults of `fourmolu.version` and `actions.run-fourmolu`
must work together, and a new release of haskell-gha changes them together.

### HLint

Like the fourmolu job, the HLint job has no matrix and needs no GHC.

`hlint-run` has no `working-directory` input, so it runs in the root of the
repository. Thus the tool puts the project directory in front of each path
of `hlint.path`. For the same reason, HLint reads only a `.hlint.yaml` in the
root of the repository, because it reads the file from its working
directory.

The default of `hlint.fail-on` is `suggestion`, so every hint fails the job.
The default of the action is `never`, and then the job never fails. A hint
that does not fail the job is only an annotation, and it is easy to miss. The
default `hlint.version` is fixed for the same reason as `fourmolu.version`.

The released versions of both HLint actions, up to `v2.4.10`, declare
Node.js 20, and GitHub removes Node.js 20 in autumn 2026. The defaults are
thus the commits "Upgrade to node24" on the default branches. These commits
change only `action.yml`, and the built `dist/index.js` is the same as in
`v2.4.10`. When the actions have a release for Node.js 24, change the
defaults to it.

## YAML input and output

The tool must keep the key order of the fragments that it copies, because a
reordered step is hard to review. `aeson` objects sort their keys, so the
tool does not use `aeson` or `Data.Yaml`. It reads and writes YAML with the
event API of `HsYAML`, which is pure Haskell and implements YAML 1.2.

From the events, the tool builds a small ordered tree. Each scalar keeps its
style from the input. An anchor, an alias, a tag or a duplicate key is an
error. The output writes all sequences and mappings in the block style.

The writer of HsYAML does not make sure that a plain scalar is valid. Thus
the tool gives each scalar its style with these rules:

- A copied scalar keeps its style from the input. A plain scalar that is
  valid in the input is also valid in the output, because the output uses
  the block style.
- Each `run:` script that the tool makes is a literal block. The first line
  of each script is fixed text from the tool, so user text in a later line
  cannot break the block.
- A version is always single-quoted, e.g. in the `ghc` axis.
- A string that the tool builds from user text is single-quoted, e.g. the
  job name with the extra axis names.
- A plain scalar that the YAML 1.2 core schema reads as a null, a boolean or
  a number is single-quoted, because GitHub reads plain scalars with that
  schema.

Each golden test also parses the output and compares the result with the
tree that the tool wrote. Thus a wrong style fails the test.

The writer cannot write empty lines. The tool writes a comment with a marker
in place of each empty line, and then replaces the marker lines in the text.
The writer cannot write a comment before the first entry of a mapping or a
sequence, so that entry never gets an empty line.

The parser drops the YAML comments, so the workflow does not contain the
comments of the copied fragments. A comment near a key or at the end of a
list can belong to more than one place. Thus a correct copy of the comments
needs much code.

## Dependencies

The tool builds with GHC 9.6 and later. The packages that come with GHC are
always permitted. Do not add another dependency, unless it removes a large
amount of code.

## Code style

The code follows the style of the effectful project. `fourmolu.yaml` gives
the formatting, and the `common language` stanza of the `.cabal` file gives
the extensions. Each module has an export list with Haddock section
headings, and each exported function has a Haddock comment. Records use
`NoFieldSelectors` and `OverloadedRecordDot`. The tool does not depend on
`effectful`, because plain `IO` is enough.

## Tests

Golden tests cover the generated workflow. Each directory under
`tests/golden/` has a project, an optional configuration file, an optional
file `args` with the command line, and the expected workflow. If the
environment variable `HASKELL_GHA_ACCEPT=1` is set, the tests write the new
output to the expected file. The comparison ignores the header comment, so a
new tool version does not change the result.

The repository also tests itself on GitHub.
`.github/workflows/haskell-gha.yml` is the workflow for the tool, and
`.github/workflows/haskell-gha-multi.yml` is the workflow for
`examples/multi/`, a project with a conditional block. The second workflow
has the name `CI (multi)`, because two workflows with the same name cancel
each other.

An `after-build` hook in `.github/haskell-gha.conf.yml` makes both files
again and runs `git diff --exit-code`. Thus a pull request with an outdated
workflow fails. The hook runs in the checkout, but the tool was built in the
copy of the source tarballs. The hook thus gets the binary with
`cabal list-bin` in the copy, and it does not build the tool again.

## Out of scope

The tool does not support these features:

- A job container.
- GHC older than 8.10.
- macOS and Windows.
- GHC prereleases and GHC head.
- head.hackage.
- A job that tests the lower bounds with `--prefer-oldest`.
- Benchmark runs.
- stack.

Each feature can come later as a new optional field, without a breaking
change to the configuration format.
