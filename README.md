# Exile

Exile is an alternative to beam [ports](https://hexdocs.pm/elixir/Port.html) for running external programs. It provides back-pressure, non-blocking io, and tries to fix issues with ports.

Exile is built around the idea of having demand-driven, asynchronous interaction with external command. Think of streaming a video through `ffmpeg` to serve a web request. Exile internally uses NIF. See [Rationale](#rationale) for details. It also provides stream abstraction for interacting with an external program. For example, getting audio out of a stream is as simple as
``` elixir
Exile.stream!(~w(ffmpeg -i pipe:0 -f mp3 pipe:1), input: File.stream!("music_video.mkv", [], 65535))
|> Stream.into(File.stream!("music.mp3"))
|> Stream.run()
```

`Exile.stream!` is a convenience wrapper around `Exile.Process`. If you want more control over stdin, stdout, and os process use `Exile.Process` directly.

**Note: Exile is experimental and it is still work-in-progress. Exile is based on NIF, please know the implications of it before using it**

## Rationale

Approaches, and issues

#### Port

Port is the default way of executing external commands. This is okay when you have control over the external program's implementation and the interaction is minimal. Port has several important issues.

* it can end up creating [zombie process](https://hexdocs.pm/elixir/Port.html#module-zombie-operating-system-processes)
* cannot selectively close stdin. This is required when the external programs act on EOF from stdin
* it sends command output as a message to the beam process. This does not put back pressure on the external program and leads exhausting VM memory

#### Port based solutions

There are many port based libraries such as [Porcelain](https://github.com/alco/porcelain/), [Erlexec](https://github.com/saleyn/erlexec), [Rambo](https://github.com/jayjun/rambo), etc. These solve the first two issues associated with ports: zombie process and selectively closing STDIN. But not the third issue: having back-pressure. At a high level, these libraries solve port issues by spawning an external middleware program which in turn spawns the program we want to run. Internally uses port for reading the output and writing input. Note that these libraries are solving a different subset of issues and have different functionality, please check the relevant project page for details.

* no back-pressure
* additional os process (middleware) for every execution of your program
* in few cases such as porcelain user has to install this external program explicitly
* might not be suitable when the program requires constant communication between beam process and external program

#### [ExCmd](https://github.com/akash-akya/ex_cmd)

This is my other stab at solving back pressure on the external program issue. ExCmd also uses a middleware for the operation. But unlike the above libraries, it uses named pipes (FIFO) for io instead of port. Back-pressure created by the blocking system calls.

__Issue__

ExCmd uses blocking system calls for building back-pressure. For example, reading the output from the program internally resolves to a blocking [`read()`](http://man7.org/linux/man-pages/man2/read.2.html) system call. This blocks the dirty io scheduler indefinitely. Since the scheduler can not preempt system call, the scheduler will be blocked until `read()` returns. Worst case scenario: there are as many blocking read/write as there are dirty io schedulers. This can lead to starvation of other io operations, low throughput, and dreaded scheduler collapse.

As of now, there are no non-blocking io file operations available to the user in beam. See ExCmd for possible workaround for this issue.

## Exile

Exile does non-blocking, asynchronous io system calls using NIF. Since it makes non-blocking system calls, schedulers are never blocked indefinitely. It does this in asynchronous fashion using `enif_select` so its efficient.

**Advantages over other approaches:**

* solves all three issues associated with port
* it does not use any middleware
  * no additional os process. no performance/resource cost
  * no need to install any external command
* can run many external programs in parallel without adversely affecting schedulers
* stream abstraction for interacting with the external program
* should be portable across POSIX compliant operating systems (not tested)

If you are running executing huge number of external programs **concurrently** (more than few hundred) you might have to increase open file descriptors limit (`ulimit -n`)

Non-blocking io can be used for other interesting things. Such as reading named pipe (FIFO) files. `Exile.stream!(~w(cat data.pipe))` does not block schedulers so you can open hundreds of fifo files unlike default `file` based io.

##### TODO
* add benchmarks results


### 🚨 Obligatory NIF warning

As with any NIF based solution, bugs or issues in Exile implementation **can bring down the beam VM**. But NIF implementation is comparatively small and mostly uses POSIX system calls, spawned external processes are still completely isolated at OS level and the port issues it tries to solve are critical.


### Usage
If all you want is to run a command with no communication, then just sticking with `System.cmd` is a better option.

For most of the use-cases using `Exile.stream!` abstraction should be enough. Use `Exile.Process` only if you need more control over the life-cycle of IO streams and OS process.
