#!/usr/bin/env bash
set -e
set -u

SCRIPTPATH="$(cd "$(dirname "$0")" ; pwd -P)"
ROOTDIR="$(dirname ${SCRIPTPATH})"
DIR="./..."
CODECOV_SKIP="${ROOTDIR}/codecov.skip"
SKIPPED_TESTS_GREP_ARGS=

if [ "${1:-}" != "" ]; then
    DIR="./$1/..."
fi

COVERAGEDIR="$(mktemp -d /tmp/XXXXX.coverage)"
mkdir -p $COVERAGEDIR

# coverage test needs to run one package per command.
# This script runs nproc/2 in parallel.
# Script fails if any one of the tests fail.

# half the number of cpus seem to saturate
if [[ -z ${MAXPROCS:-} ]];then
  MAXPROCS=$[$(getconf _NPROCESSORS_ONLN)/2]
fi
PIDS=()
FAILED_TESTS=()

declare -a PKGS

function code_coverage() {
  local filename="$(echo ${1} | tr '/' '-')"
  ( go test \
    -coverprofile=${COVERAGEDIR}/${filename}.txt \
    -covermode=atomic ${1} \
    | tee ${COVERAGEDIR}/${filename}.report ) &
  local pid=$!
  PKGS[${pid}]=${1}
  PIDS+=(${pid})
}

function wait_for_proc() {
  local num=$(jobs -p | wc -l)
  while [ ${num} -gt ${MAXPROCS} ]; do
    sleep 2
    num=$(jobs -p|wc -l)
  done
}

function join_procs() {
  local p
  for p in ${PIDS[@]}; do
      if ! wait ${p}; then
          FAILED_TESTS+=(${PKGS[${p}]})
      fi
  done
}

function parse_skipped_tests() {
  while read entry; do
    if [[ "${SKIPPED_TESTS_GREP_ARGS}" != '' ]]; then
      SKIPPED_TESTS_GREP_ARGS+='\|'
    fi
    SKIPPED_TESTS_GREP_ARGS+="\(${entry}\)"
  done < "${CODECOV_SKIP}"
}

cd "${ROOTDIR}"

parse_skipped_tests

echo "Code coverage test (concurrency ${MAXPROCS})"
for P in $(go list ${DIR} | grep -v vendor); do
  #FIXME remove mixer tools exclusion after tests can be run without bazel
  if echo ${P} | grep -q "${SKIPPED_TESTS_GREP_ARGS}"; then
    echo "Skipped ${P}"
    continue
  fi
  code_coverage "${P}"
  wait_for_proc
done

join_procs

touch "${COVERAGEDIR}/empty"
FINAL_CODECOV_DIR="${GOPATH}/out/codecov"
mkdir -p "${FINAL_CODECOV_DIR}"
pushd "${FINAL_CODECOV_DIR}"
cat "${COVERAGEDIR}"/*.txt > coverage.txt
cat "${COVERAGEDIR}"/*.report > codecov.report
popd
echo "Repors are stored in ${FINAL_CODECOV_DIR}"


if [[ -n ${FAILED_TESTS:-} ]]; then
  echo "The following tests failed"
  for T in ${FAILED_TESTS[@]}; do
    echo "FAIL: $T"
  done
  exit 1
fi

echo 'Checking package coverage'
go get -u istio.io/test-infra/toolbox/pkg_check

if [ "$CODECOV_NO_ENFORCE" == "true" ] ; then
# Coverage doesn't yet take into account files used for or covered by integration tests,
# only looks for unit test coverage. It can be enforced once real coverage can be measured.
pkg_check \
  --bucket= \
  --report_file=/go/out/codecov/codecov.report \
  --requirement_file=codecov.requirement || true
else
pkg_check \
  --bucket= \
  --report_file=/go/out/codecov/codecov.report \
  --requirement_file=codecov.requirement
fi
