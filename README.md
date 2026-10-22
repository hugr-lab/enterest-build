# enterest-build

Where [Enterest](https://enterest.hugr-lab.com) builds the DuckDB extensions it distributes. Enterest
builds each version of an extension once, from the commit its tag named when Enterest saw it, then
checks and reviews what was built. This repository is the build, in the open: anyone can see how an
extension they run was built, and repeat it.

## How a build runs

Enterest starts `build` (`.github/workflows/build.yml`) as its GitHub App, with:

- the extension's name and version;
- the repository's https git URL, on any git host, and the commit;
- the extension's licence keys' public halves, for a licensed extension.

All of these are public: Enterest builds public repositories only, and holds no secret here.

1. **Plan** (`scripts/plan.sh`) checks the inputs, fetches the version, and reads its
   `description.yml`:
   - **The platforms**: every platform of the build tools' matrix, less the version's
     `extension.excluded_platforms`, and less WebAssembly, which kista's repositories do not serve.
     The opt-in platforms (macOS amd64, Windows arm64, Linux musl) are included.
   - **The DuckDB versions**: `extension.duckdb_versions`, in one of two forms. Without it, the
     DuckDB version whose commit the `duckdb` submodule names. Only the versions in
     `duckdb-versions` are built: releases by their tag, and development builds of DuckDB's next
     release by their source id (the commit's first 10 hex digits, as DuckDB names them), so an
     extension can be tried on the next DuckDB before it is released.

     ```yaml
     extension:
       name: my_ext
       excluded_platforms: "windows_amd64_mingw"
       # tags: each built from the version's commit
       duckdb_versions: "v2.0.0"
       # or a commit of the repository per DuckDB version ("" for the version's own), as DuckDB's
       # community extensions name a ref per DuckDB line; the next release's development build
       # by its source id, quoted (YAML reads a source id of digits as a number)
       # duckdb_versions:
       #   v2.0.0: ""
       #   "3c9f0e1a2b": 0123456789abcdef0123456789abcdef01234567
     ```
2. **Build** runs hugr-lab's [extension-ci-tools](https://github.com/hugr-lab/extension-ci-tools)
   distribution workflow, pinned by commit, once per DuckDB version. DuckDB is checked out from its
   own repository at the commit `duckdb-versions` lists, whatever the extension's `duckdb`
   submodule says. A licensed extension is built
   with the licence keys Enterest gave (`KISTA_LICENSE_KEYS`), whatever its own repository commits.
   - No build cache is read or written: each build starts clean, so no developer's build can leave
     something another's reads. vcpkg's packages come from a binary cache read only (hugr-lab's own
     CI fills it; the token cannot write), then DuckDB's public one.
   - A build job runs at most four hours, and an extension's runs go one at a time.
   - Each build is an artifact `<extension>-<ref>-extension-<platform>`, the ref DuckDB was built
     at: a release's tag, a development build's commit. A development build uses DuckDB's own
     prebuilt library for that commit when DuckDB staged one, and builds DuckDB otherwise (slower).
   - The artifact `plan` names each DuckDB version's name, its ref, and the commit built for it.

Enterest then downloads the builds and checks each one: its DuckDB metadata, and its licence keys
against the extension's. It hashes and keeps them, keeps the run's log, and deletes the run here.

## Building a version yourself

The same build, from the extension's repository (its build contract):

```text
git clone --recurse-submodules <repository> && cd <repository> && git checkout <commit>
git submodule update --init --recursive
git -C duckdb checkout <duckdb commit>             # the DuckDB version built for (duckdb-versions)
make release KISTA_LICENSE_KEYS='/path/key.pem'   # a licensed extension; nothing for a free one
```

The commit is the version's, or the one its `description.yml` names for that DuckDB version.

## Changing this repository

The DuckDB versions (`duckdb-versions`: `<tag> <commit>` for a release, `<source id> <commit> dev`
for a development build, removed when its release replaces it), the build tools' pin and the
workflow change by reviewed pull requests. Enterest pins this repository's commit and refuses a run
of another.
`tests/plan_test.sh` and actionlint run on every pull request (`check`).
