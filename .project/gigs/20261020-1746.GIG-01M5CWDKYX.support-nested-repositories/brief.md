# Brief

Support nested repositories using the current file’s repository

Delta currently runs Git commands from Neovim’s working directory. Opening a file from a nested repository while cwd remains in the parent repository causes missing changes and incorrect repository assignment.

#### Expected behavior
- Invoking the picker from a parent-repository file lists that repository’s changes.
- Invoking it from a nested-repository file lists the nested repository’s changes.
- When the current buffer cannot identify a repository, resolve it from cwd.
- Spotlight and file diffs use the target file’s repository.
- Neovim’s cwd remains unchanged.

#### Solution
Introduce shared repository context containing the repository root and Git directory, resolved through Git. Represent files with their owning repository, repository-relative path, and absolute filesystem path.

Capture repository context when opening the picker or diff view. Carry it through refreshes, previews, file opening, staging, unstaging, resets, hunk patches, scratch buffers, and watchers. Use stable file identities so identical relative paths in different repositories remain distinct.

Each picker shows one repository. Nested repositories are selected through the invoking file rather than recursively discovered or combined.

Update README documentation alongside the implementation.

#### Verification
Add headless integration coverage for parent and nested files with cwd fixed at the parent, ignored nested repositories, submodules, unnamed buffers, and matching relative filenames across repositories. Verify that staging, unstaging, and resets affect only the selected repository.
