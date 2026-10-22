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
     release whose commit the `duckdb` submodule names. Only the releases in `duckdb-versions` are
     built.

     ```yaml
     extension:
       name: my_ext
       excluded_platforms: "windows_amd64_mingw"
       # tags: each built from the version's commit
       duckdb_versions: "v2.0.0"
       # or a commit of the repository per DuckDB version ("" for the version's own), as DuckDB's
       # community extensions name a ref per DuckDB line
       # duckdb_versions:
       #   v2.0.0: ""
       #   v2.1.0: 0123456789abcdef0123456789abcdef01234567
     ```
2. **Build** runs hugr-lab's [extension-ci-tools](https://github.com/hugr-lab/extension-ci-tools)
   distribution workflow, pinned by commit, once per DuckDB version. A licensed extension is built
   with the licence keys Enterest gave (`KISTA_LICENSE_KEYS`), whatever its own repository commits.
   - No cache is read or written: each build starts clean, so no developer's build can leave
     something another's reads.
   - A build job runs at most four hours, and an extension's runs go one at a time.
   - Each build is an artifact `<extension>-<duckdb tag>-extension-<platform>`.
   - The artifact `plan` names the commit each DuckDB version was built from.

Enterest then downloads the builds and checks each one: its DuckDB metadata, and its licence keys
against the extension's. It hashes and keeps them, keeps the run's log, and deletes the run here.

## Building a version yourself

The same build, from the extension's repository (its build contract):

```text
git clone --recurse-submodules <repository> && cd <repository> && git checkout <commit>
git submodule update --init --recursive
git -C duckdb checkout <duckdb tag>                # the DuckDB version built for
make release KISTA_LICENSE_KEYS='/path/key.pem'   # a licensed extension; nothing for a free one
```

The commit is the version's, or the one its `description.yml` names for that DuckDB version.

## Changing this repository

The DuckDB versions (`duckdb-versions`), the build tools' pin and the workflow change by reviewed
pull requests. Enterest pins this repository's commit and refuses a run of another.
`tests/plan_test.sh` and actionlint run on every pull request (`check`).
