# Exile

[![CI](https://github.com/akash-akya/exile/actions/workflows/ci.yaml/badge.svg)](https://github.com/akash-akya/exile/actions/workflows/ci.yaml)
[![Hex.pm](https://img.shields.io/hexpm/v/exile.svg)](https://hex.pm/packages/exile)
[![docs](https://img.shields.io/badge/docs-hexpm-blue.svg)](https://hexdocs.pm/exile/)

Exile is an alternative to [ports](https://hexdocs.pm/elixir/Port.html) for running external programs. It provides back-pressure, non-blocking io, and tries to fix ports issues.

Exile is built around the idea of having demand-driven, asynchronous interaction with external process. Think of streaming a video through `ffmpeg` to serve a web request. Exile internally uses NIF. See [Rationale](#rationale) for details. It also provides stream abstraction for interacting with an external program. For example, getting audio out of a stream is as simple as

``` elixir
Exile.stream!(~w(ffmpeg -i pipe:0 -f mp3 pipe:1), input: File.stream!("music_video.mkv", [], 65535))
|> Stream.into(File.stream!("music.mp3"))
|> Stream.run()
```

See `Exile.stream!/2` module doc for more details about handling stderr and other options.

`Exile.stream!/2` is a convenience wrapper around `Exile.Process`. Prefer using `Exile.stream!` over using `Exile.Process` directly.

Exile requires OTP v22.1 and above.

Exile is based on NIF, please know consequence of that before using Exile. For basic use cases use [ExCmd](https://github.com/akash-akya/ex_cmd) instead.

## Installation

```elixir
def deps do
  [
    {:exile, "~> x.x.x"}
  ]
end
```

## Rationale

Existing approaches

#### Port

Port is the default way of executing external commands. This is okay when you have control over the external program's implementation and the interaction is minimal. Port has several important issues.

* it can end up creating [zombie process](https://hexdocs.pm/elixir/Port.html#module-zombie-operating-system-processes)
* cannot selectively close stdin. This is required when the external programs act on EOF from stdin
* it sends command output as a message to the beam process. This does not put back pressure on the external program and leads exhausting VM memory

#### Middleware based solutions

Libraries such as [Porcelain](https://github.com/alco/porcelain/), [Erlexec](https://github.com/saleyn/erlexec), [Rambo](https://github.com/jayjun/rambo), etc. solves the first two issues associated with ports - zombie process and selectively closing STDIN. But not the third issue - having back-pressure. At a high level, these libraries solve port issues by spawning an external middleware program which in turn spawns the program we want to run. Internally uses port for reading the output and writing input. Note that these libraries are solving a different subset of issues and have different functionality, please check the relevant project page for details.

* no back-pressure
* additional os process (middleware) for every execution of your program
* in few cases such as porcelain user has to install this external program explicitly
* might not be suitable when the program requires constant communication between beam process and external program

On the plus side, unlike Exile, bugs in the implementation does not bring down whole beam VM.

#### [ExCmd](https://github.com/akash-akya/ex_cmd)

This is my other stab at solving back pressure on the external program issue. It implements a demand-driven protocol using [odu](https://github.com/akash-akya/odu) to solve this. Since ExCmd is also a port based solution, concerns previously mentioned applies to ExCmd too.

## Exile

Internally Exile uses non-blocking asynchronous system calls to interact with the external process. It does not use port's message based communication instead does raw stdio using NIF. Uses asynchronous system calls for IO. Most of the system calls are non-blocking, so it should not block the beam schedulers. Makes use of dirty-schedulers for IO.

**Highlights**

* Back pressure
* no middleware program
  * no additional os process. No performance/resource cost
  * no need to install any external command
* tries to handle zombie process by attempting to clean up external process. *But* as there is no middleware involved with exile, so it is still possible to endup with zombie process if program misbehave.
* stream abstraction
* selectively consume stdout and stderr streams

If you are running executing huge number of external programs **concurrently** (more than few hundred) you might have to increase open file descriptors limit (`ulimit -n`)

Non-blocking io can be used for other interesting things. Such as reading named pipe (FIFO) files. `Exile.stream!(~w(cat data.pipe))` does not block schedulers, so you can open hundreds of fifo files unlike default `file` based io.

#### TODO

* add benchmarks results

### 🚨 Obligatory NIF warning

As with any NIF based solution, bugs or issues in Exile implementation **can bring down the beam VM**. But NIF implementation is comparatively small and mostly uses POSIX system calls. Also, spawned external processes are still completely isolated at OS level.

If all you want is to run a command with no communication, then just sticking with `System.cmd` is a better.

### License

Copyright (c) 2020 Akash Hiremath.

Exile source code is released under Apache License 2.0. Check [LICENSE](LICENSE.md) for more information.
