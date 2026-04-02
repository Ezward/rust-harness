I want to create a template project for a claude-code harness that will be used to develop applications based on the Rust programming language.

- The harness should expect that a Github repository exists

The project will have a /scripts folder that contains shell scripts.
- The init.sh shell script will initialize the project and ensure that the repository is secure and the necessary tools are installed.
  - The script will take a single argument; the name of the Github repository.
  - The script will ask for a Github fine-grained access token that it will used for subsequent github commands.
  - The script will initialize git `git init` and make a `main` branch that is the default branch.
  - The script will create a tools folder to hold executable tools.
  - The script will install the github command line (gh) for this repo in the tools folder.
  - it will initialize cargo `cargo init`
  - it will use the latest `Stable` release.
  - it will install the clippy linter to allow the `cargo clippy` command.
  - it will install the `cargo-llvn-cov` code coverage tool.
  - it will create a cargo format configuration using a 120 character line length.
  - it will install `x86_64-unknown-linux-gnu` and `aarch64-unknown-linux-gnu` targets.
  - it will create a scripts/check.sh script that will:
    - compile the code and fail on any errors or warnings.
    - run the `cargo clippy` command to lint the code and fail on any errors or warnings.
    - run the `cargo-llvm-cov` test coverage and fail on any errors or if test coverage is less than 100%.
    - run `cargo fmt -- --check` and fail on any errors or warnings.
  - create a .gitignore file appropriate for a Rust project.
  - create a README.md
  - create a git pre-commit hook that uses scripts/check.sh to check the code before allowing a commit.
  - create a github action that runs the scripts/check.sh to check that any PR passes all the checks before it can be merged.
  - create a claude-code hook that will run the scripts/check.sh if any of the rust files have changed so that claude and fix the errors and retry.
  - create a claude-code hook that will ask for a Github fine-grained access token to allow claude-code access to github at the beginning of the session.
  - create a claude-code hook that will remove the fine-grained access token at the end of a session.
  - it will protect the .git/hooks folder from any further changes by claude by adding it to the .file-guard file.
  - it will create an initial commit with all of these changes, then connect it to the origin.
  - The script will then wait for the commit to be pushed to origin and then:
    - The script will use the github cli to ensure the github repository is secure:
      - it will make sure the 'main' branch is secured by checking that these restrictions are already in place (it does not try to create them itself)
        - Restrict creations, updates and deletions — prevent unauthorized changes to main
        - Require a pull request before merging — no direct pushes to main
        - Require at least one approval to merge — so that Claude cannot merge its own code
        - Require approval of the most recent reviewable push — a PR can only be merged if all commits are approved (prevents pushing a commit after approval.

After creating init.sh, check that it works by running for this repository.
