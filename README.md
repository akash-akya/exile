# Exile

Exile is an alternative to beam [ports](https://hexdocs.pm/elixir/Port.html) for running external programs. It provides back-pressure, non-blocking io, and tries to fix issues with ports.

At high-level, exile is built around the idea of having demand-driven, asynchronous interaction with external command. Think of streaming a video through `ffmpeg` to serve a web request. Exile internally uses NIF. See [Rationale](#rationale) for details. It also provides stream abstraction for interacting with an external program. For example, getting audio out of a stream is as simple as
``` elixir
def audio_stream!(stream) do
  # read from stdin and write to stdout
  proc_stream = Exile.stream!("ffmpeg", ~w(-i - -f mp3 -))

  Task.async(fn ->
    Stream.into(stream, proc_stream)
    |> Stream.run()
  end)

  proc_stream
end

File.stream!("music_video.mkv", [], 65535)
|> audio_stream!()
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

There are many port based libraries such as [Porcelain](https://github.com/alco/porcelain/), [Erlexec](https://github.com/saleyn/erlexec), [Rambo](https://github.com/jayjun/rambo), etc. These solve the first two issues associated with ports: zombie process and selectively closing STDIN. But not the third issue: having back-pressure. At a high level, these libraries solve port issues by spawning an external middleware program which in turn spawns the program we want to run. Internally uses the port for reading the output and writing input. Note that these libraries are solving a different subset of issues and have different functionality, please check the relevant project page for details.

* no back-pressure
* additional os process (middleware) for every execution of your program
* in few cases such as porcelain user has to install this external program explicitly
* might not be suitable when the program requires constant communication between beam process and external program

#### [ExCmd](https://github.com/akash-akya/ex_cmd)

This is my other stab at solving back pressure on the external program issue. ExCmd also uses a middleware for the operation. But unlike the above libraries, it uses named pipes (FIFO) for io instead of port. Back-pressure created by the underlying operating system.

__Issue__

ExCmd uses named FIFO for blocking input and output operation for building back-pressure. The blocking happens at the system call level. For example, reading the output from the program internally resolves to a blocking [`read()`](http://man7.org/linux/man-pages/man2/read.2.html) system call. This blocks the dirty io scheduler indefinitely. Since the scheduler can not preempt system call, the scheduler will be blocked until `read()` returns. Worst case scenario: there are as many blocking read/write as there are dirty io schedulers. This can lead to starvation of other io operations, low throughput, and dreaded scheduler collapse.

As of now, there are no non-blocking io file operations available in the beam. Beam didn't allow opening FIFO files before OTP 21 for the same reason. One can fix this temporarily by starting beam with more dirty io schedulers.

## Exile

Exile takes a different NIF based approach. As of now the only way to do non-blocking, asynchronous io operations in the beam is to make the system calls ourselves with NIF (or port-driver). Exile uses a non-blocking system calls for io, so schedulers are never blocked indefinitely. It also uses POSIX `select()`. ie so polling is not done in userland.

Building back-pressure using non-blocking io is done by blocking the program at os level (using pipes) and blocking beam process *inside VM* using good old message massing, unlike ExCmd which uses blocking system calls.

**Advantages over other approaches:**

* solves all three issues of the port
* it does not use any middleware
  * no additional os process. no performance/resource cost
  * it is faster as there is no hop in between
  * no need to install any external command
* can run many external programs in parallel without adversely affecting schedulers
* stream abstraction for interacting with the external program
* should be portable across POSIX compliant operating systems (not tested)

If you are running executing huge number of external programs **concurrently** (more than few hundred) you might have to increase open file descriptors limit (`ulimit -n`)

Non-blocking io can be used for other interesting things. Such as reading named pipe (FIFO) files. `Exile.stream!("cat", ["data.pipe"])` does not block schedulers unlike default `file` based io.

##### TODO
* add benchmarks results


### 🚨 Obligatory NIF warning

As with any NIF based solution, bugs or issues in Exile implementation **can bring down the beam VM**. But NIF implementation is comparatively small and mostly uses POSIX system calls, spawned external processes are still completely isolated at OS level and the port issues it tries to solve are critical.


### Usage
If all you want is to run a command with no communication, then just sticking with `System.cmd` is a better option.

For most of the use-cases using `Exile.stream!` abstraction should be enough. Use `Exile.Process` only if you need more control over the life-cycle of IO streams and OS process.
