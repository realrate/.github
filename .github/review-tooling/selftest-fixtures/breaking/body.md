Bumps [numpy](https://github.com/numpy/numpy) from 1.26.4 to 2.5.0.

## Release notes

### NumPy 2.5.0 Release Notes

This release drops support for Python 3.11; Python >=3.12 is now required.

**Breaking changes**

* Python 3.11 is no longer supported. Building or installing on 3.11 will fail.
* `numpy.distutils` has been removed. Projects still importing it must migrate
  to `meson-python` or `setuptools`.
* Several long-deprecated aliases have now expired and been removed, including
  `np.float_`, `np.unicode_` and `np.NaN`. Use `np.float64`, `np.str_` and
  `np.nan` instead.
* The C ABI has changed. Extension modules and packages compiled against the
  numpy 1.x ABI must be rebuilt against 2.x, or they will fail to import.
* `copy=False` in `np.array` now raises instead of silently copying.

**Improvements**

* Faster sorting for small integer types.
* Improved error messages for shape mismatches.

---
updated-dependencies:
- dependency-name: numpy
  dependency-version: 2.5.0
  dependency-type: direct:production
  update-type: version-update:semver-major
...

Signed-off-by: dependabot[bot] <support@github.com>
