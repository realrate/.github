Bumps [some-action](https://github.com/example/some-action) from 4 to 5.

## Release notes

### v5

This release contains no changes to the action's inputs, outputs or behaviour.

* Bump the Node runtime used internally from node20 to node24. Consumers do not
  need to change anything; the action's `with:` inputs are unchanged.
* Update internal dependencies.
* Documentation: clarify the caching example in the README.
* Add support for the linux-arm64 runner image.
* Internal refactor of the logging helper. No user-visible effect.

No inputs were removed or renamed. No outputs were removed or renamed. There are
no deprecations in this release.

---
updated-dependencies:
- dependency-name: example/some-action
  dependency-version: '5'
  dependency-type: direct:production
  update-type: version-update:semver-major
...

Signed-off-by: dependabot[bot] <support@github.com>
