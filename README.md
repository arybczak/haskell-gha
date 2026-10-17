# haskell-gha

[![CI](https://github.com/arybczak/haskell-gha/actions/workflows/haskell-gha.yaml/badge.svg?branch=master)](https://github.com/arybczak/haskell-gha/actions/workflows/haskell-gha.yaml)

`haskell-gha` writes a GitHub Actions workflow for a Haskell cabal project. The
workflow builds and tests the project on each GHC version from the `tested-with`
field of its packages, in separate jobs. Only Linux is supported.

## Features

- A new GHC release needs no new release of the tool. GHCup installs each
  version, and a series, e.g. `^>= 9.12`, gets its newest release.
- The workflow builds with the project's own `cabal.project`, so CI uses the
  same settings as a local build.
- The jobs build and test the content of the source tarballs, so CI finds a file
  that the `.cabal` file does not list before your users do.
- You write service containers, hook steps and extra matrix axes in plain GitHub
  Actions YAML, and the tool copies them to the workflow.
- The jobs run on the runner image, or optionally in a job container.
- A job saves a new cache only when its build plan changes.
- Optional jobs test the oldest dependency versions that the bounds allow.
- Optional checks with doctest, fourmolu and HLint.
- `haskell-gha --check` tells whether the committed workflows are up to date.

## Quick start

Build the tool from the source:

```
git clone https://github.com/arybczak/haskell-gha.git
cd haskell-gha
cabal install
```

Give each package of the project its GHC versions in `tested-with`. Each version
is an exact release or a major series, e.g.:

```
tested-with: GHC == 9.6.7 || ^>= 9.10 || ^>= 9.12
```

In the root of your repository, make the workflow:

```
haskell-gha --generate
```

The tool writes `.github/workflows/haskell-gha.yaml`. Commit this file. After a
change to `tested-with`, to the packages of the project or to the configuration
file of haskell-gha, see [Example](#example), make the workflow again:

```
haskell-gha
```

## Example

The configuration file is `.github/haskell-gha.conf.yaml`, and it needs only the
keys that differ from the defaults. This configuration is for a project that
needs the libsodium library and whose tests use Postgres:

```yaml
branches: [master]
apt: [libsodium-dev]
dependencies: both
services:
  postgres:
    image: postgres:18
    env:
      POSTGRES_PASSWORD: postgres
    ports: ['5432:5432']
    options: >-
      --health-cmd pg_isready
      --health-interval 5s
      --health-retries 10
hooks:
  after-build:
  - name: Create the test database
    run: psql -h localhost -U postgres -c 'CREATE DATABASE test'
    env:
      PGPASSWORD: postgres
doctest:
  enabled: true
fourmolu:
  enabled: true
```

With the `tested-with` field above, the workflow has these jobs:

- Six build jobs: for each GHC version, one with the newest dependencies and one
  with the oldest. Each job installs `libsodium-dev` and starts Postgres. After
  the build, it creates the test database, and then it runs the tests and
  doctest.
- A fourmolu job that checks the formatting.

For a complete workflow, see the
[workflow of this repository](https://github.com/arybczak/haskell-gha/blob/master/.github/workflows/haskell-gha.yaml).

## Documentation

- [Configuration](https://github.com/arybczak/haskell-gha/blob/master/docs/configuration.md):
  each key of the configuration file.
- [Guide](https://github.com/arybczak/haskell-gha/blob/master/docs/guide.md):
  the command line, the steps of the workflow, the GHC versions, the
  dependencies, the source tarballs, the container, the caches, common failures
  and known limits.
