# Zig Server

This is an exploration of how to write a server with Zig's new async I/O.

See these blog posts for context:

- https://kristoff.it/blog/zig-new-async-io/
- https://andrewkelley.me/post/zig-new-async-io-text-version.html

## Purpose

I'm trying to figure out the right way to write a server in Zig in the new style. I have three requirements:

* It must allow a large number of concurrent requests.
* It must not leak memory when the server shuts down.
* Memory usage must reach a steady state, not grow without bound.

I believe an explicit goal of the new I/O system is to enable writing library code that's close to optimal yet agnostic of the specific `std.Io` it uses, at least for client operations. I want to find out if it that's also a goal for server code (or server-ish patterns that a client might do too!), and whether it's even possible.

## Usage

There's a `zig-server` program which echoes requests on a TCP port, and a [test.sh](test.sh) script that starts the server and sends lots of requests while monitoring RSS.

To check for leaks, run `zig build` and then `./test.sh 8080 MODE 0 1 1` for some `MODE`.

To monitor memory growth, run `zig build -Doptimize=ReleaseFast` and try something like `./test.sh 8080 MODE 0.1 10 50`.

## Modes

Everything here is using [`std.Io.Threaded`](https://ziglang.org/documentation/master/std/#std.Io.Threaded) since that's the only working I/O implementation right now.

Here are the server implementations (called "mode" in the code):

* `serial`: one at a time
* `forget`: leak all the futures
* `group`: use `std.Io.Group`
* `waiter`: spawn a task that awaits futures
* `waiter2`: like `waiter` but a bit more clever
* `workers`: use a fixed number of workers
* `select`: use select to juggle 1 accept and N handlers

All of them have problems. `serial` obviously can't handle concurrent requests. `forget` leaks memory. Of the rest, only `workers` reaches a steady state early on. The others all seem to have unbounded memory growth (though it's possible they would stabilize if I waited for longer).

See comments in [main.zig](main.zig) for more details.

## License

© 2025 Mitchell Kember

Zig Server is available under the MIT License; see [LICENSE](LICENSE.md) for details.
