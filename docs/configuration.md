# Configuration

The configuration file is `.github/haskell-gha.conf.yaml`, or the file that you
give with `--config`, see [Command line](guide.md#command-line). Without the
file, all keys take their defaults. For an example, see the
[README](../README.md#example).

The file is YAML, and it needs only the keys that differ from the defaults. An
unknown key is an error, and so is a key without a value, except `container`
and `services`. A text value must be a YAML string, so quote a value that YAML
reads as a number, e.g. `'3.10'`, which is otherwise the number 3.1.

- [Workflow and jobs](#workflow-and-jobs)
- [Hooks](#hooks)
- [Build](#build)
- [Checks](#checks)
- [Versions of the actions](#versions-of-the-actions)
- [Comments](#comments)

## Workflow and jobs

| Key | Default | Meaning |
|---|---|---|
| `name` | `CI` | The name of the workflow. |
| `branches` | `[master, main]` | The branches for the `push` trigger. |
| `permissions` | `contents: read` | The permissions of the `GITHUB_TOKEN`, as in GitHub Actions: a mapping, `read-all` or `write-all`. |
| `os` | `linux` | The operating system of the build jobs: `linux` or `macos`. See [macOS](guide.md#macos). |
| `runs-on` | `ubuntu-26.04`, or `macos-26` with `os: macos` | The runner of the build jobs, as GitHub Actions YAML: a label, e.g. `ubuntu-latest`, a list of labels, e.g. `[self-hosted, linux]`, or a mapping with `group` and `labels`. The tool copies it to the workflow without changes. |
| `container` | none | The image of a job container for the build jobs: `buildpack-deps:22.04`, `buildpack-deps:24.04` or `buildpack-deps:26.04`. See [Container](guide.md#container). |
| `timeout-minutes` | `60` | The time limit of each job, in minutes. |
| `submodules` | `false` | Fetch the Git submodules in the build jobs: `true`, `false` or `recursive`. `recursive` also fetches the submodules of each submodule. The fourmolu and HLint jobs do not fetch them. |
| `matrix` | none | Extra matrix axes, and `include` and `exclude`. The tool copies them next to the `ghc` axis. |
| `apt` | `[]` | Ubuntu packages to install. |
| `services` | none | Service containers, as in GitHub Actions. |

### Matrix, services and permissions

The tool copies `matrix`, `services`, `permissions` and the hook steps to the
workflow without changes, together with their comments. You can use GitHub
expressions in them. For example, this configuration tests each GHC version with
two Postgres versions, except GHC 9.10 with Postgres 15:

```yaml
matrix:
  postgres: ['15', '18']
  exclude:
  - ghc: '9.10'
    postgres: '15'
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
```

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
The `postgres` image has no health check of its own, so the example gives one in
`options`.

## Hooks

| Key | Default | Meaning |
|---|---|---|
| `hooks.after-setup` | `[]` | Steps after the installation of GHC and cabal, and before the source tarballs and the build plan. |
| `hooks.after-build` | `[]` | Steps after the build and before the tests. |

A hook is a list of GitHub Actions steps. An `after-setup` hook can install a
library that the dependencies need, e.g. one that `apt` does not have. An
`after-build` hook can prepare the tests. For example, with the `postgres`
service from the [matrix example](#matrix-services-and-permissions), this hook
creates a database for the tests:

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

The checkout does not keep the `GITHUB_TOKEN` in the git config. A hook that
runs a git command that needs the token, e.g. `git push`, must give the token
itself.

The steps of the build job have the ids `setup`, `versions`, `plan` and `cache`,
and with doctest also `doctest` and `doctest-cache`. A hook step must not use
these ids, also not with other upper and lower case letters, e.g. `Cache`,
because GitHub compares the ids without case. A hook can read the outputs of
these steps, e.g. `${{ steps.setup.outputs.ghc-version }}`. The step `setup`
has the outputs `ghc-version`, `cabal-version` and `cabal-store`, the path of
the cabal store.

A hook can run `ghcup`, e.g. to install another tool. It uses the GHCup of the
job, not the one of the runner image.

With `sdist: true`, the workflow unpacks the source tarballs in
`"$RUNNER_TEMP"/haskell-gha`. The `after-build` hooks can use this directory,
but the `after-setup` hooks run before it exists.

## Build

| Key | Default | Meaning |
|---|---|---|
| `cabal-version` | `3.16.1.0` | The cabal release, with four parts, e.g. `3.16.1.0`. The version must be 3.12 or later. |
| `ghc-options` | `-Werror` | GHC options for the local packages only, on one line. An empty string disables them. |
| `cabal-project-local` | none | Text to add to `cabal.project.local`, e.g. package flags or constraints. See [Extra cabal.project.local text](#extra-cabalprojectlocal-text). |
| `jobs` | `4` | The number of parallel jobs for cabal, as its `jobs` setting, and for GHC in the local packages. |
| `tests` | `true` | Build and run the test suites. |
| `benchmarks` | `true` | Build the benchmarks. The workflow does not run them. |
| `dependencies` | `newest` | The versions of the dependencies: `newest`, `oldest` or `both`. See [Dependencies](guide.md#dependencies). |
| `sdist` | `true` | Build and test the content of the source tarballs, not the checkout. See [Source tarballs](guide.md#source-tarballs). |

### Extra `cabal.project.local` text

The workflow writes the text of `cabal-project-local` to `cabal.project.local`
before it makes the build plan, so the cache of each job contains the
dependencies that the text adds. The `ghc-options` go to a `program-options`
stanza, which cabal applies to all local packages. The text can add another
`program-options` stanza, and cabal merges them. A `package` stanza in the text
overrides the options for one package, e.g. `ghc-options: -Wwarn`. A line of the
text must not be `EOF`. You can use GitHub expressions in the text.

A `cabal.project.local` in the repository makes the job fail. The file holds the
settings of one developer, and a committed file leaves the other developers no
place for their own settings. Move its settings to `cabal.project`, or to
`cabal-project-local` if only CI needs them, and remove the file from the
repository.

## Checks

| Key | Default | Meaning |
|---|---|---|
| `check` | `true` | Run `cabal check` for each local package. A warning does not fail the job. |
| `haddock` | `true` | Build the documentation of the libraries as for a Hackage upload. |
| `doctest` | off | Run doctest. See [Doctest](#doctest). |
| `fourmolu` | off | Check the formatting with fourmolu. See [Fourmolu](#fourmolu). |
| `hlint` | off | Check the code with HLint. See [HLint](#hlint). |

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
| `doctest.ghc` | all versions | The GHC versions to run doctest for, as a version range, e.g. `'>= 9.8'`. The range must include at least one matrix entry, and each entry fully or not at all, as in a [condition](guide.md#packages-for-some-ghc-versions-only). A new GHC release often works with doctest only after some weeks. |
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
| `fourmolu.version` | `0.21.0.0` | The fourmolu version. |
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
| `hlint.path` | the project directory | The directories or files to check, relative to the project directory. A path must be in the repository, must not be empty, and must not contain a tab or another control character. |
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

## Versions of the actions

| Key | Default | Meaning |
|---|---|---|
| `actions.checkout` | `v7` | The version of `actions/checkout`. |
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

## Comments

The workflow contains only the comments in the copied keys and directly above
them. The tool drops a comment above another key, e.g. `apt`, and a comment
above an empty line, e.g. at the top of the file. Of the comments in `hooks`, it
keeps only the comments in the steps of a hook and directly above them.
