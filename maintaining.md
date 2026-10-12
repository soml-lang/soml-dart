# Maintaining

## Test

```sh
dart analyze
dart test test tool benchmark/test
```

The property and fuzz tests are seeded. Set `SOML_SEED` to an integer to try another seed and `SOML_RUNS` to a positive integer for more iterations. Defaults apply when the variables are unset:

```sh
SOML_SEED=7 SOML_RUNS=40000 dart test test/property_test.dart
```

## Conformance suite

`test/conformance` is a copy of the suite in the `soml` repository. Do not edit it here. To update it, check out `soml` next to this repository and run:

```sh
../soml/sync-conformance.sh test/conformance
```

## Differential test

`tool/differential/run.sh` decodes generated documents with this package and with the [JavaScript reference implementation](https://github.com/soml-lang/soml-javascript), and compares whether each is accepted, its canonical form, and the reason, position, and code frame of each error. It expects `soml-javascript` next to this repository and Node.js 26 or later. Run it after changing the parser, in both modes:

```sh
tool/differential/run.sh 100000 1 text
tool/differential/run.sh 100000 2 bytes
```

The count must be a positive safe integer and the seed a safe integer, including zero and negative values. Omitted arguments default to a count of 100000, seed 1, and text mode; explicitly empty arguments are invalid. The generator truncates the seed to 32 bits before generating random numbers.

It prints `diffs 0` and exits successfully only when every result agrees and neither implementation crashes. Differences, empty runs, and missing or extra results fail the command.

The tool tests require Node.js and the reference implementation.

## Benchmark

See the [benchmark results](readme.md#performance).

Run the wall-time complexity checks separately on an otherwise idle machine. Parallel functional tests can distort their timing ratios.

```sh
dart test benchmark/complexity_test.dart
```

`benchmark/fixtures` is a copy of the shared fixtures in the `soml` repository. To update it:

```sh
rsync --archive --delete ../soml/benchmark/ benchmark/fixtures/
```

Measure the AOT build:

```sh
mkdir -p benchmark/build
dart compile exe benchmark/bin/benchmark.dart -o benchmark/build/benchmark
benchmark/build/benchmark
```

On a busy machine, wall time is noisy. The count of retired instructions is steady, so compare a change by running this before and after it, on macOS:

```sh
benchmark/instructions.sh
```

The instruction counter requires a successful operation. Its regression tests use a stub operation and run on macOS.

## Publish

1. Bump the version in `pubspec.yaml`, and add the changes to `CHANGELOG.md`.
2. Check the package: `dart pub publish --dry-run`
3. Commit and push: `git commit -am "1.2.3" && git push`
4. Push the tag: `git tag v1.2.3 && git push origin v1.2.3`
5. Create the release on GitHub.

The tag starts `.github/workflows/publish.yml`, which publishes to pub.dev with [automated publishing](https://dart.dev/tools/pub/automated-publishing). The tag must match the version in `pubspec.yaml`.