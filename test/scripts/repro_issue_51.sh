#!/usr/bin/env bash
# Linux-only: bash test/scripts/repro_issue_51.sh
# Compare a working spawner with a temporary copy whose ELF loader is missing.
# The second run should report a spawner exit after two seconds and exit 1.
set -euo pipefail

cd "$(dirname "$0")/../.."
MIX_ENV=prod mix compile

workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT
mkdir -p "$workdir/exile/priv"
cp -R _build/prod/lib/exile/ebin "$workdir/exile/"
cp priv/exile.so "$workdir/exile/priv/"

run() {
    elixir -pa "$workdir/exile/ebin" -e '
      {:ok, _} = Application.ensure_all_started(:exile)
      {:ok, process} = Exile.Process.start_link(["true"])
      :eof = Exile.Process.read(process, 1)
      {:ok, 0} = Exile.Process.await_exit(process)
      IO.puts("Startup succeeded")
    '
}

printf '\n--- Control: normal ELF interpreter ---\n'
cc -std=c99 -D_POSIX_C_SOURCE=200809L -O2 c_src/spawner.c \
    -o "$workdir/exile/priv/spawner"
run

printf '\n--- Reproduction: missing ELF interpreter ---\n'
cc -std=c99 -D_POSIX_C_SOURCE=200809L -O2 c_src/spawner.c \
    -Wl,--dynamic-linker="$workdir/missing-loader" \
    -o "$workdir/exile/priv/spawner"
run
