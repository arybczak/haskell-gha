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
Both are out of scope. Thus the action also works in a job container, which
has no `sudo`.

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
The tool copies `runs-on`, `services`, `permissions`, `hooks` and the extra
matrix entries without changes. It does not model each service or each install
method.

The tool does not rewrite `cabal.project`. If packages support different GHC
versions, the user adds `if impl(ghc ...)` blocks to `cabal.project`. The
tool finds a missing block and gives the exact block in the error message.
Thus local builds and CI use the same project.

By default, the jobs run on the runner image. A job container is optional,
see [Container](#container). Service containers are supported.

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

The fourmolu and HLint jobs have their own optional `runs-on`. They need
much less than a build job, e.g. a smaller self-hosted runner. Without the
key, they use the `runs-on` of the build jobs, not a default of their own.
A repository that allows only self-hosted runners then needs no extra key.

The cache key contains the image of the runner, from the environment
variable `ImageOS`, e.g. `ubuntu26`. A cabal store from another image can
link against system libraries that the new image does not have. The cache
key does not contain `ImageVersion`, because GitHub updates the image each
week, and each update would start a new cache. In a job container, both
variables are empty, and the cache key contains the image of the container
instead.

The cache keys also contain `runner.arch`. The tool supports only x86_64,
but `runs-on` accepts an ARM runner, and the tool does not know whether
`ImageOS` differs between the architectures. A doctest binary or a cabal
store of another architecture does not run.

The cache key starts with the name of the workflow file, e.g. `ci.yml`. The
caches of a repository are shared by all its workflows, and the start of the
key is also the restore key. Without the name, a job could restore the store
of another workflow, e.g. of another project, and then save it again with the
dependencies of both. Thus the stores would keep growing. The name comes from
`--output`, not from `github.workflow_ref`, because `workflow_ref` also
contains the Git ref. A pull request then could not restore a cache of its
base branch. A comma in the name is an error, because `actions/cache` does not
accept a comma in a key. The name keeps its extension, so the two workflows
`ci.yml` and `ci.yaml` do not share their caches.

The default `cabal-version` is `3.16.1.0`. In October 2026, the action selects
cabal `3.18.1.0` for `latest`, and that version uses only version 2 of the
semaphore protocol: [cabal issue 12306][issue-12306]. No released GHC uses
version 2 yet, so with cabal 3.18 no job would use the semaphore. When GHC
9.10.4, 9.12.5 and 9.14.2 are released with version 2, change the default to
`latest`. Then a new cabal release needs no new release of haskell-gha.

[issue-12306]: https://github.com/haskell/cabal/issues/12306

A `cabal-version` older than 3.12 is always an error. The `semaphore` field
needs cabal 3.12, but only the jobs for GHC 9.8 and later use it. One limit
for all jobs is simpler than a limit for each GHC version. Also, nobody
tests older cabal versions with the tool. The tool compares only the first
two parts of the version, so `3.10` and `3.10.3.0` are both errors.

The versions of the actions are keys of the configuration, with the
current major versions as defaults. Thus a user can take a new major version
of an action without a new release of haskell-gha. `actions.cache` is one
key for `actions/cache/restore` and `actions/cache/save`, because both come
from one repository. A value is any Git ref without spaces, so a user can
also pin an action to a commit SHA.

A value can also name another repository, e.g. `runs-on/cache@v4`. The
runners of RunsOn keep their cache in S3 with `runs-on/cache`, a fork of
`actions/cache` with the same inputs and outputs. The repository must have
the form `owner/name`, and the tool adds the path of a sub-action, e.g.
`/restore`, to it.

## Command line

The tool has no subcommands, but it has three modes. With `--generate`, it
makes one workflow from the options. Without options, it makes each
generated workflow again. With `--check`, it makes each generated workflow
in memory and compares it with its file. Most repositories have one
workflow, so the common commands need no options for the workflow.

Each mode has one meaning. A run without options never makes a new
workflow, e.g. if no generated workflow exists, the run is an error.
`--check` does not work with `--generate`, because every generated workflow
has a header, and a run with `--check` already covers it.

A run of the tool and then `git diff --exit-code` does not find a file that
is not committed, and it changes the checkout. `--check` does not have these
problems, and it needs no git.

`--generate` in a subdirectory of the repository would write a workflow that
GitHub never reads, without any sign of the mistake. Thus `--generate` needs
`.git` in the current directory. The other runs do not check it. They find
no generated workflow in a subdirectory, and `actions/checkout` without git
gives a checkout without `.git`, where `--check` must still work.

The header comment of the workflow gives the command that made the file. If
the user gave `--config`, the command contains it, also with the default
path. The command also contains each other option that is not a default.
The configuration file must be a relative path in the repository, because a
run with `--check` in CI or in another checkout reads it from the header.

Two rules apply to each path that the tool reads or writes, and to each path
that the workflow uses on the runner, e.g. `hlint.path` and the local file
of an `import:` line. The runner has only the repository, at another place
than the local checkout.

1. By its text, the path must be relative, and its `..` components must not
   lead above the root. Each reader checks this rule, so its error shows the
   option or the position in the file.
2. On disk, the path must stay in the repository. The tool follows each
   component from the root, also a broken symbolic link, and a `..` after a
   link leaves the target of the link, as in the system. A link may point to
   another place in the repository, but its target must be relative, and the
   path must not go through more than 40 links, the limit of Linux on the
   runner. A component that does not exist is not a link, so the path can
   name a file that the tool or the workflow makes. The tool checks this rule
   before it reads or writes a path, and checks the paths of the runner
   last.

Without the second rule, a broken link at the output path would make the
tool write the workflow out of the repository.

`--generate` does not replace a file without the header. Such a file can be a
workflow that the user wrote, and it may not be committed. The user deletes
it or gives another `--output`, so the tool needs no option to force the
write.

A run without `--generate` reads the command back from the header. The first
line of the header marks a generated workflow, and the next line has the
command. The command must start with `haskell-gha --generate`, and the tool
parses the rest with the parser of the command line. The tool quotes each
word of the command for bash, and the run removes the same quotes. The
other files in the directory are not generated, and the tool skips them.
`--generate` and the other runs decide by the same first line. A file with
the first line and a broken command is thus an error for a run without
`--generate`, and `--generate` replaces it.

The command keeps `--output`, so that a person can copy it from the header
and run it. When the tool reads the command back, the output must be the
file itself. If it is not, the tool stops with an error. Otherwise a renamed
file would make the tool write to the old path.

`--output` gives only the name of the file in `.github/workflows`, and the
name must end with `.yml` or `.yaml`. GitHub reads only the files directly in
that directory with these extensions, and a run without `--generate` finds
only them. Another path would give a workflow that never runs and that the
tool never makes again. A name cannot give such a path, so the tool needs no
check for an absolute path or a path outside the repository.

The tool works in a sequence of phases. It reads the configuration. Then it
parses `cabal.project`, finds the packages, reads the `.cabal` files and
checks each package against each matrix entry. Last, it checks the
configuration against the project, e.g. `doctest.skip`. In each phase, the
tool collects all errors and prints them all. If a phase has errors, the
tool does not start the next phase, because the next phase needs its result.

The decoder of yamlet collects the errors of the independent parts of a
value, e.g. the fields of a record or the items of a list. A check that
the decoder must pass before the next one, e.g. that a value is a mapping,
still stops there.

## Configuration

An unknown key is an error, because it is usually a typing error.

An error of the configuration gives the line and the column of the node
that caused it, the path of keys to it, e.g. `hlint.version`, and that line
of the file. The checks of the configuration against the project run after
the decode, e.g. for `doctest.skip`. The values that they check keep the
position of their node, so their errors have the same form.

A key without a value is an error, not the default. Only a missing key takes the
default, so a key that the user forgot to fill in does not silently disable or
change a feature. YAML reads a key without a value as `null`. For `container`
and `services`, `null` is a valid value, and it means none. That is also their
default, so the value changes nothing.

The value of a text key must be a YAML string. Every YAML reader reads an
unquoted `3.10` as the number 3.1. Thus an unquoted value that the YAML 1.2
core schema reads as a number, a boolean or a null is an error. The error
suggests the quotes.

The `matrix` mapping must not contain the key `ghc`, because the tool makes
that axis. A `ghc` value in `include` or `exclude` must be a quoted string
and an entry of the `ghc` axis. Thus an `include` entry cannot add a job for
a new GHC version, because the tool cannot check the packages for such a
job.

An `include` entry without `ghc` can still add a job without a GHC version,
if it matches no job of the matrix. The tool does not check this, because a
check would have to repeat how GitHub matches the entries, and GitHub
documents that rule. The README lists it as a limit.

Each key of an `exclude` entry must be `ghc`, an axis of the `matrix` mapping,
or `dependencies` with `dependencies: both`, because GitHub rejects the workflow
otherwise. An `include` entry can have any key, because GitHub adds a new key to
the jobs as a variable.

The name of an axis must start with a letter or `_`, and contain only
letters, digits, `_` and `-`. The job name refers to each axis as
`matrix.<name>`, and GitHub accepts this syntax only for such a name. The
index syntax, e.g. `matrix['os x']`, accepts any name. But the hooks and the
services of the user then also need the index syntax. A user can rename the
axis easily, so the tool rejects such a name.

If a workflow has no `permissions` key, the `GITHUB_TOKEN` gets the
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

An error of an entry of `packages:` gives the position of the entry, as for an
`import:` line. The entry of the implicit project has no position, so a
directory without a package gets the error for a project without packages.

The reader parses each condition with `parseConditionConfVar` and decides it
for each matrix entry. `os(linux)` and `arch(x86_64)` are true. `flag(...)`
is an error, because the tool does not know the value of the flag. If one
side of `||` is true or one side of `&&` is false, cabal ignores the other
side. Thus an error in the other side does not count.

The glob syntax of `packages:` is the cabal syntax. The reader parses it with
the `Parsec` instance of `RootedGlob` and matches it with `matchGlob` from
`Cabal`. A relative glob needs no root, so the tool does not copy
`matchFileGlob` from `cabal-install`. Before Cabal 3.18, a wildcard such as
`.*` in `matchGlob` also matches the entries `.` and `..` of a directory, so
a match could lead out of the repository. The tool drops such a match, as
Cabal 3.18 and cabal do.

A match of a glob without a package, e.g. a directory without a `.cabal`
file, is an error only if no match of the glob has a package. In
`optional-packages:` it is never an error. cabal does the same
(`checkIsFileGlobPackage` in
`cabal-install/src/Distribution/Client/ProjectConfig.hs`), so `*/` can match
a directory with documentation next to the packages. A location of
`optional-packages:` that is not a valid glob is an error, as in cabal.

An absolute path, a path outside the repository, a URL or a tarball in
`packages:` is an error. The workflow uses the path on the runner, where
only the repository exists. If a path outside the project directory, e.g.
`../other`, stays in the repository, it is legal. The same rules apply to
the local file of an `import:` line.

The reader removes each component of a package path that a later `..`
cancels, e.g. `a/../b` becomes `b`. Thus two paths of one package give one
package, as in cabal, and not two stanzas and two tarballs in the workflow.
The removal ignores symbolic links, so `a/../b` with a link `a` gives `b`,
but the system reads the other directory. A package path through a link
and `..` has no known use.

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
`>= X.Y.1 && < X.(Y+1)`, because the first release of a GHC series is `X.Y.1`.
The tool uses this range for every decision about a matrix entry, i.e. the
conditions of `cabal.project`, the `doctest.ghc` range, the 8.10 limit of the
supported versions, the 9.8 limit of the semaphore, the 9.4 limit of the gold
linker and the `tested-with` range of each package.

A prerelease, e.g. `10.0.0.20260917`, is below the range of its series. A
job that gets the prerelease then decides a condition such as
`impl(ghc >= 10.0.1)` differently from the tool. The README tells the user
to write `impl(ghc >= 10)` for a prerelease.

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

A package can list an entry in `tested-with` that the project does not
include it for. This is an error, because no job then tests the package
with that version. A package that no job builds is exempt, e.g. a package
only for Windows. Such a package must still list a GHC version. If the rule
applied to it, the tool would reject every project with such a package.

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

The concurrency group is `github.workflow_ref`, which has the path of the
workflow file and the ref. `github.workflow` is the name of the workflow, so
two workflows with the same name in a group with it would cancel each other.

Without `timeout-minutes`, GitHub stops a job only after six hours, so a
test that hangs uses up the runner minutes. A build usually takes way less
than an hour, so the default of 60 minutes leaves room for a build without a
cache.

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
versions, and if GHC and cabal use different versions of the semaphore protocol,
each local package gets `ghc-options: -j<N>`. The dependencies do not get it,
because cabal already builds N of them at the same time.

If a step applies only to some matrix entries, it gets an `if:` condition
that lists them. The packages of the project can differ between GHC
versions. Then the tool makes a step that lists the packages once for each
group of versions with the same packages.

The configuration step writes all its configuration to `cabal.project.local`, so
a developer can run the same `cabal` commands locally. The default `ghc-options`
are `-Werror`, and they apply only to the local packages, so the warnings of a
dependency do not fail the build. A `package` stanza also applies to a package
from Hackage, e.g. to a local package that the project leaves out for a GHC
version and that another package depends on. Thus a job gets the stanzas only
of the packages in its project.

A committed `cabal.project.local` is an error, because each developer needs
the file for their own settings. Without git, the tool cannot tell a
committed file from the file of a developer, so the configuration step
checks for it in the job, where the checkout has only committed files. The
unpack step copies the file next to the tarballs, so the same check covers
both a build of the tarballs and a build of the checkout. An `after-setup`
hook must not make the file.

GHC and cabal must use the same version of the semaphore protocol. A test with
GHC 10.0.0.20260917 and cabal 3.16.1.0 showed the failure: GHC uses version 2
and cabal version 1, so GHC warns with `semaphore-open-failure` and compiles
sequentially, and `-Werror` makes the warning an error. cabal 3.18 and later use
only version 2, and older cabal only version 1. The semaphore step therefore
uses the semaphore only if GHC and cabal use the same version, and otherwise
gives each local package `ghc-options: -j<N>`, like the step for older GHC
versions. The tool knows the cabal version when it makes the workflow, and
`latest` is 3.18 or later.

GHC 9.14.1.20260916, 9.14.2-rc2 and 10.0.0.20260917 show the entry
`("Semaphore version","2")` in `ghc --info`. GHC 9.14.1 and older have no such
entry and use version 1. A series entry gets its newest release when the job
runs, so the tool cannot decide from the matrix which version GHC uses. The step
asks GHC with `ghc --info` instead. A flag `-Wwarn=semaphore-open-failure` is
not a fix, because GHC still compiles sequentially, and an unknown warning flag
makes GHC warn once for each module and each configure step.

cabal merges two `package` stanzas for the same package, so the `-j<N>` stanzas
can come after the stanza with the `ghc-options` of the configuration.

The text of `cabal-project-local` comes at the end of the configuration step, so
it can add to the stanzas of that step. The step comes before the build plan, so
the cache key includes the dependencies that the text adds. The heredocs use
`<<'EOF'`, so bash does not expand text from the configuration. A line `EOF`
ends the heredoc, so such a line is an error.

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

GitHub rejects a workflow if two steps of a job have the same id. Thus a hook
step with the id of a step of the tool is an error. The check uses the ids of
the steps that the workflow has, so without doctest, a hook step can use the
ids of the doctest steps. GitHub compares the ids without case, e.g. `Cache`
and `cache` are the same id, so the check does too. The documentation does not
say this, but the parser of `actions/runner` keeps the ids in a set with
`StringComparer.OrdinalIgnoreCase` (`IdBuilder.cs`), and a test of the parser
in `actions/languageservices` rejects `STEP1` after `step1`.

`cabal test all` fails for a project without test suites. Thus the test step
runs only for the GHC versions with a local package that has a test suite.

The last steps check the packages for a Hackage release, so a build error or
a test error shows first. `cabal haddock` gets `--disable-documentation`,
because otherwise cabal builds the dependencies again with documentation,
outside the cache. `--haddock-for-hackage` makes the same documentation as a
Hackage upload. The step builds only the documentation of the libraries,
because Hackage shows only that. With `--haddock-all`, each component of a
package writes the same documentation tarball. A workflow of effectful
failed now and then with `resource busy (file is locked)` on that tarball,
because cabal builds the components in parallel.

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

### Container

A job container lets the build jobs use another Ubuntu release than the
runner. E.g. a runner that another team manages can have only Ubuntu 24.04.
Only the build job uses the container. The fourmolu and HLint jobs need no
GHC and no system libraries, so the runner is enough for them.

The value is one of a fixed list of `buildpack-deps` images, with the Ubuntu
version in the tag, e.g. `buildpack-deps:26.04`. A plain `ubuntu` image lacks
tools that the workflow and GHC need, e.g. `git`, `xz-utils`, `gcc` and
`libgmp-dev`. The list is the tags of the LTS releases that `buildpack-deps`
publishes. An interim release has support for only 9 months. With interim
releases, the list changes every six months, and each change needs a new release
of the tool. The version tag, not the codename, is the only accepted spelling.
Thus one image gives one cache key, and the value reads like
`runs-on: ubuntu-26.04`. The full image name needs no quotes in YAML, but a bare
`26.04` does.

A job in a container runs as root, and the image has no `sudo`. Thus the
`apt` step and the gold step call `apt-get` without `sudo`. The package
lists of the image are empty, so the steps still run `apt-get update`.
Ubuntu 26.04 has no gold by default, so the gold step stays.

A test on GitHub showed these facts:

- `ImageOS` and `ImageVersion` are empty in a container. The versions step
  thus writes the image of the container to the job summary and to the
  cache key.
- The context `runner.temp` gives the path on the host, and `$RUNNER_TEMP`
  gives the path in the container. A `working-directory` with the context
  still works, because the runner translates it.
- After `actions/checkout`, `git` fails in the checkout with "detected
  dubious ownership", because the checkout belongs to the user of the
  host. The workflow does not run `git` in the checkout, so it adds no step
  for this. The README tells a user with a `git` hook what to do.

### Dependencies

The versions of the dependencies are a matrix axis, not a separate job. The
two kinds need the same steps, so a separate job copies all build steps for
a difference of one line. The axis also applies the extra axes, `include`
and `exclude` of the user to both kinds. With the default `newest`, the axis
does not exist, and the workflow does not change.

An oldest job writes `prefer-oldest: True` to `cabal.project.local`. The
flag `--prefer-oldest` on the command line is not enough, because each
later `cabal` command must use the same plan. A command without the flag
solves the plan again with the newest versions. The line has its own step,
like the semaphore, so the log of a newest job shows the step as skipped.

The workflow puts no constraints on the dependencies, also not on the
libraries that come with GHC. cabal can then build an older version of such
a library from Hackage. A test with GHC 9.10.3 built the oldest plan of
haskell-gha with e.g. `text-2.0.2` and `unix-2.7.3`, and its tests passed.

The cache prefix contains the kind, because the prefix is also the restore
key. Without it, an oldest job restores a store with the newest versions,
and the reverse. With `newest` and `oldest`, the name of the workflow
already separates the kinds, but the kind stays in the prefix, so that all
keys have one form.

The job name shows only the value, e.g. `GHC 9.10, oldest`. The values are
clear without the name of the axis.

The value `oldest` has no axis, and every job uses the oldest versions. It
is for a second workflow that tests only the lower bounds. A failure of an
oldest job often comes from a dependency with wrong bounds, so a user can
make that workflow an optional check.

### GHC prereleases

The tool has no option for the dependencies of a GHC prerelease. The project
puts its fixes in a block `if impl(ghc >= X.Y)` of `cabal.project`, e.g. a
`source-repository-package` with a patched dependency, head.hackage or
`allow-newer`. The fixes then also work for a local build. In a test with
cabal 3.18.1.0, cabal accepted a `repository` stanza and a
`source-repository-package` in such a block. If the condition was false,
cabal ignored both. In a CI test with head.hackage in such a block, the
`cabal update` of `haskell-actions/setup` in the root of the repository also
updated head.hackage. For a project in a subdirectory, that update does not
read its `cabal.project`. The README does not mention this case, because it
is rare. cabal then warns that the package list is missing, and it tells the
user to run `cabal update`. An `after-setup` hook can do that.

An earlier version of the tool had a key `head-hackage` with a step that
added head.hackage. Two tests with GHC 10.0.0.20260917 showed the problems
of a generic setup:

- The `cabal.project` that the page of head.hackage offers pins each patched
  package, e.g. `Cabal-syntax ==3.8.1.0`. That excluded the
  `Cabal-syntax-3.18.1.0` of GHC, and the build plan of haskell-gha failed.
- The step allowed newer versions of all libraries that come with GHC, as
  haskell-ci does. haskell-gha needed only `base`, `template-haskell` and
  `time`. Of head.hackage, it needed only a patch of `hashable`.

`allow-newer` makes an oldest job useless, because it ignores the bounds that
the job tests. With `prefer-oldest`, cabal also tried very old releases, e.g.
`unix-2.0`, and found no build plan. The README tells the user to exclude
these jobs in `matrix`. The tool cannot do it, because it does not read
`allow-newer`, and it copies `matrix` without changes.

The workflow installs doctest with `--ignore-project`, so the block does not
apply to doctest.

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

The workflow installs doctest before it builds the project. A build error is
much more common than a doctest error. Thus a run whose build fails still
saves doctest in its cache, and the run after the fix does not build doctest
again.

A library can have no `hs-source-dirs`, or only `.`. The tool then does not
give `.` to doctest, because the package directory can contain other
components, e.g. the tests. haskell-ci gives the names of the exposed
modules. But then GHC takes the compiled module from the environment file,
and doctest finds no examples without an error. Thus the tool gives the
files of the exposed modules, e.g. `A/B.hs`.

A module can have no `.hs` or `.lhs` file in the package directory, e.g. a
module that `hsc2hs` makes from a `.hsc` file. The tool then leaves the module
out, because doctest would skip its name without an error anyway. The README
lists this as a known limit.

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
syntax tree of `yamlet`, which is pure Haskell and implements YAML 1.2. The
syntax tree keeps the key order and the scalar styles.

The tool decodes the configuration into Haskell types with the generic
instances of yamlet. The parts that the workflow copies, e.g. the hook steps
and `services`, stay nodes of the syntax tree, so they keep their key order,
their scalar styles and their comments. A `Commented` field keeps the
comments around its entry, and the workflow writes them at its own key. The
decoder replaces an alias with a copy of its node, so a copied part never
refers to an anchor outside it. A duplicate key is an error.

The workflow is a syntax tree that the tool builds. The output writes all
sequences and mappings in the block style.

The renderer of yamlet quotes a plain scalar that is not valid YAML, but it
does not look at the schema. Thus the tool gives each scalar its style with
these rules:

- A scalar in a copied part, e.g. in a hook step, keeps its style from the
  input.
- A copied text value, e.g. `name` or a branch, is a plain scalar. If YAML
  does not read the plain text as a string, the value is single-quoted.
- Each `run:` script that the tool makes is a literal block. The first line
  of each script is fixed text from the tool, so user text in a later line
  cannot break the block.
- A version is always single-quoted, e.g. in the `ghc` axis.
- A string that the tool builds from user text is single-quoted, e.g. the
  job name with the extra axis names.
- A plain scalar that the YAML 1.2 core schema reads as a null, a boolean or
  a number is single-quoted, because GitHub reads plain scalars with that
  schema.

Each golden test also parses the output and compares the result with the tree
that the tool wrote. The comparison ignores the positions, the comments and the
collection styles. Thus a wrong scalar style fails the test.

The header comment belongs to the root mapping, and an empty line separates
it from the first key. On the document, the header would need a `---`
marker below it to read back there.

The workflow names the collections with an empty line between their
entries: the top level, the jobs and the steps of each job. Before the tool
renders the tree, it adds an empty line above each entry of these
collections except the first one.

A block scalar with the keep indicator, e.g. `|+`, keeps the empty lines at its
end. It would take the empty line before the next item into its value. Thus the
renderer drops the empty lines right after such a scalar.

The syntax tree keeps each comment at a node, so the comments inside a
copied value go to the workflow with the value. A comment around a value
belongs to its key. If a key becomes exactly one key of the workflow, the
tool keeps its comments. Otherwise the tool drops them:

- The comments above a copied key, e.g. `services`, go above the key that
  the workflow makes. A comment at the end of the line of the key stays at
  the end of that line.
- The comments of `runs-on` go only to the build job. A fourmolu or HLint
  job without its own `runs-on` gets the value of the key, but not its
  comments. A job with its own `runs-on` gets the comments of that key.
- The workflow adds the `ghc` axis as the first entry of `matrix`. The parser
  gives the comments below `matrix:` and above an empty line to the matrix, so
  they describe the whole matrix. They stay below `matrix:`, above the `ghc`
  axis, and the empty line stays below them, so they do not read as a comment
  of `ghc`. The comments below the empty line belong to the first entry of the
  configuration and stay above that entry.
- The workflow has no `hooks` key and no hook lists. The steps of the hooks go
  into the steps of the job unchanged, with the comments inside them and the
  comment lines directly above each step, as for a copied key. The tool drops
  all other comments in `hooks`.
- A comment at the top of the file above an empty line belongs to the root
  mapping, so it describes the file, and the tool drops it. A comment directly
  above the first key belongs to that key. If the workflow copies that key, the
  comment goes above the key, below the empty line after the header comment.

The tool drops a comment above a key that the workflow does not copy, e.g.
`apt`. Such a comment describes the configuration, and the workflow has no place
for it. Of the lines above a copied key, only the comment lines directly above
it, up to the nearest empty line, go to the workflow. A comment above an empty
line describes the layout of the configuration, e.g. a section of it, and the
workflow has its own layout.

## Dependencies

The tool builds with GHC 9.6 and later. The packages that come with GHC are
always permitted. Do not add another dependency, unless it removes a large
amount of code.

The packages that come with GHC have no upper bound, except `base`, which has
the usual `< 5`, and `Cabal` and `Cabal-syntax`, whose API changes in each major
release. Each other dependency has an upper bound below its next major version.

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
output to the expected file.

The repository also tests itself on GitHub.
`.github/workflows/haskell-gha.yml` is the workflow for the tool, and
`.github/workflows/haskell-gha-multi.yml` is the workflow for
`examples/multi/`, a project with a conditional block. The second workflow
has the name `CI (multi)`, so the two workflows are easy to tell apart on
GitHub.

An `after-build` hook in `.github/haskell-gha.conf.yml` runs the tool with
`--check`, which covers both workflows. Thus a pull request with an outdated
workflow fails. The hook runs in the checkout, but the tool was built in the
copy of the source tarballs. The hook thus gets the binary with
`cabal list-bin` in the copy, and it does not build the tool again.

## Out of scope

The tool does not support these features:

- GHC older than 8.10.
- macOS and Windows.
- GHC head.
- Benchmark runs.
- stack.

Each feature can come later as a new optional key, without a breaking
change to the configuration format.
