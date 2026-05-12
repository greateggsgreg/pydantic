#!/usr/bin/env bash
# Run the pydantic test suite inside a Pyodide venv against freshly built
# pyemscripten wheels. Invoked by `.github/workflows/ci.yml` and by
# `make test-pyemscripten`. Requires `pyodide` on PATH and the freshly built
# wheels in pydantic-core/dist/ (pyemscripten) and dist/ (pure-Python pydantic).
set -euo pipefail

VENV_DIR=".venv-pyodide"

if [ ! -d "${VENV_DIR}" ]; then
    pyodide venv "${VENV_DIR}"
fi
# shellcheck disable=SC1090
source "${VENV_DIR}/bin/activate"

shopt -s nullglob
# Accept the PEP 783 `pyemscripten_<abi>_wasm32` tag and the legacy
# `emscripten_X_Y_Z_wasm32` tag so toolchain regressions surface here.
core_wheels=(
    pydantic-core/dist/pydantic_core-*-cp*-pyemscripten_*_wasm32.whl
    pydantic-core/dist/pydantic_core-*-cp*-emscripten_*_wasm32.whl
)
pyd_wheels=(dist/pydantic-*-py3-none-any.whl)
shopt -u nullglob

if [ ${#core_wheels[@]} -eq 0 ]; then
    echo "no pydantic-core wasm wheel in pydantic-core/dist/" >&2
    exit 1
fi
if [ ${#pyd_wheels[@]} -eq 0 ]; then
    echo "no pydantic wheel in dist/" >&2
    exit 1
fi

# --force-reinstall here so iteration picks up freshly-built binaries even
# when the wheel's version string is unchanged.
pip install --force-reinstall --no-deps "${core_wheels[0]}" "${pyd_wheels[0]}"
# Deliberately omitted (no wasm wheels / unsupported in Pyodide):
#   pytest-timeout (uses signal.setitimer; `timeout` marker registered in
#       pyproject.toml as a no-op), pytest-examples (depends on black/aiohttp),
#   pytest-benchmark, pytest-codspeed, pytest-memray, cloudpickle, cffi,
#   pandas, numpy.
pip install \
    pytest \
    pytest-mock \
    pytest-pretty \
    pytest-run-parallel \
    dirty-equals \
    hypothesis \
    inline-snapshot \
    typing-inspection \
    typing-extensions \
    annotated-types \
    eval-type-backport \
    jsonschema \
    pytz \
    tzdata

# `--override-ini=addopts=` strips the project's `--benchmark-*` defaults
# (pytest-benchmark has no wasm wheel; pytest would reject them as
# unrecognized). `-p no:timeout` because pytest-timeout is not installed.
pytest_log=$(mktemp)
plain_log=$(mktemp)
trap 'rm -f "${pytest_log}" "${plain_log}"' EXIT
set +e
pytest \
    --override-ini='addopts=' \
    -p no:cacheprovider \
    -p no:timeout \
    --ignore=tests/pydantic_core/benchmarks \
    --ignore=tests/mypy \
    --ignore=tests/typechecking \
    --ignore=tests/benchmarks \
    --ignore=tests/test_docs.py \
    tests/pydantic_core \
    tests 2>&1 | tee "${pytest_log}"
pytest_exit=${PIPESTATUS[0]}
set -e

# Strip ANSI escapes pytest-pretty emits, so the guard below greps the same
# text humans see rather than the colourised byte stream.
sed -E $'s/\x1b\\[[0-9;]*[a-zA-Z]//g' "${pytest_log}" > "${plain_log}"

# Pyodide 314.0.0a1 throws `RuntimeError: null function or function signature
# mismatch` during CPython interpreter teardown *after* pytest's summary line
# prints, leaving the process exit code at 1 even on a fully green run. The
# same symptom is reported in https://github.com/pyodide/pyodide/issues/5015
# (closed for an unrelated nanobind root cause). When pytest's own summary
# reports a clean run and the only failure signal is the teardown crash, treat
# the job as green; if any test fails, propagate the original exit code.
if [ "${pytest_exit}" -ne 0 ] \
    && grep -q 'Pyodide has suffered a fatal error' "${plain_log}" \
    && grep -qE '^Results \([0-9.]+s\):' "${plain_log}" \
    && ! grep -qE '(^|[[:space:]])[0-9]+ (failed|error)' "${plain_log}" \
    && ! grep -qE '(error|errors) during collection' "${plain_log}"; then
    echo "[pyemscripten-run-tests] pytest reported a clean run; treating Pyodide teardown crash as non-fatal."
    exit 0
fi
exit "${pytest_exit}"
